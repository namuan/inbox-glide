import Foundation

enum GmailServiceError: LocalizedError {
    case httpStatus(operation: String, statusCode: Int, messageID: String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let operation, let statusCode, _):
            return "Failed to \(operation) (HTTP \(statusCode))."
        }
    }

    var statusCode: Int {
        switch self {
        case .httpStatus(_, let statusCode, _):
            return statusCode
        }
    }
}

struct GmailInboxMessage: Sendable {
    let id: String
    let threadID: String?
    let receivedAt: Date
    let senderName: String
    let senderEmail: String
    let subject: String
    let snippet: String
    let body: String
    let labels: [String]
    let isUnread: Bool
    let isStarred: Bool
    let isImportant: Bool
}

struct GmailProfile: Decodable {
    let emailAddress: String
    let messagesTotal: Int?
    let threadsTotal: Int?
}

final class GmailService {
    private let session: URLSession
    private let logger = AppLogger.shared

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchProfile(accessToken: String) async throws -> GmailProfile {
        logger.debug("Requesting Gmail profile endpoint.", category: "GmailAPI")
        guard let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile") else {
            throw OAuthServiceError.tokenExchangeFailed("Invalid Gmail profile URL.")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            logger.error("Gmail profile response was not HTTP.", category: "GmailAPI")
            throw OAuthServiceError.tokenExchangeFailed("Invalid Gmail profile response.")
        }

        guard (200 ..< 300).contains(http.statusCode) else {
            logger.error("Gmail profile request failed.", category: "GmailAPI", metadata: ["status": "\(http.statusCode)"])
            throw OAuthServiceError.tokenExchangeFailed("Failed to fetch Gmail profile (HTTP \(http.statusCode)).")
        }

        let profile = try JSONDecoder().decode(GmailProfile.self, from: data)
        logger.info(
            "Gmail profile request succeeded.",
            category: "GmailAPI",
            metadata: ["email": profile.emailAddress]
        )
        return profile
    }

    func fetchRecentInboxMessages(accessToken: String, maxResults: Int = 25) async throws -> [GmailInboxMessage] {
        logger.info(
            "Fetching recent Gmail inbox messages.",
            category: "GmailAPI",
            metadata: ["maxResults": "\(maxResults)"]
        )

        var listComponents = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")
        listComponents?.queryItems = [
            URLQueryItem(name: "maxResults", value: "\(max(1, min(maxResults, 100)))"),
            URLQueryItem(name: "q", value: "in:inbox")
        ]

        guard let listURL = listComponents?.url else {
            throw OAuthServiceError.tokenExchangeFailed("Invalid Gmail list URL.")
        }

        var listRequest = URLRequest(url: listURL)
        listRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (listData, listResponse) = try await session.data(for: listRequest)
        guard let listHTTP = listResponse as? HTTPURLResponse else {
            throw OAuthServiceError.tokenExchangeFailed("Invalid Gmail list response.")
        }
        guard (200 ..< 300).contains(listHTTP.statusCode) else {
            throw OAuthServiceError.tokenExchangeFailed("Failed to list Gmail messages (HTTP \(listHTTP.statusCode)).")
        }

        let listPayload = try JSONDecoder().decode(GmailMessageListResponse.self, from: listData)
        let refs = listPayload.messages ?? []
        logger.info("Fetched Gmail message list.", category: "GmailAPI", metadata: ["count": "\(refs.count)"])

        var results: [GmailInboxMessage] = []
        results.reserveCapacity(refs.count)

        for ref in refs {
            let detail = try await fetchMessageDetail(accessToken: accessToken, id: ref.id)
            results.append(detail)
        }

        logger.info("Fetched Gmail message details.", category: "GmailAPI", metadata: ["count": "\(results.count)"])
        return results.sorted { $0.receivedAt > $1.receivedAt }
    }

    func trashMessage(accessToken: String, id: String) async throws {
        guard let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(encodedID)/trash") else {
            throw OAuthServiceError.tokenExchangeFailed("Invalid Gmail trash message URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthServiceError.tokenExchangeFailed("Invalid Gmail trash message response.")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            logger.error(
                "Gmail trash message request failed.",
                category: "GmailAPI",
                metadata: ["status": "\(http.statusCode)", "messageID": id]
            )
            throw GmailServiceError.httpStatus(operation: "delete Gmail message", statusCode: http.statusCode, messageID: id)
        }

        logger.info("Moved Gmail message to trash.", category: "GmailAPI", metadata: ["messageID": id])
    }

    private func fetchMessageDetail(accessToken: String, id: String) async throws -> GmailInboxMessage {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)")
        components?.queryItems = [
            URLQueryItem(name: "format", value: "full")
        ]
        guard let url = components?.url else {
            throw OAuthServiceError.tokenExchangeFailed("Invalid Gmail message detail URL.")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthServiceError.tokenExchangeFailed("Invalid Gmail message detail response.")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw OAuthServiceError.tokenExchangeFailed("Failed to fetch Gmail message \(id) (HTTP \(http.statusCode)).")
        }

        let message = try JSONDecoder().decode(GmailMessageResponse.self, from: data)
        let headers = message.payload?.headers ?? []
        let fromValue = Self.headerValue(name: "From", from: headers) ?? "Unknown <unknown@example.com>"
        let subject = Self.headerValue(name: "Subject", from: headers) ?? "(No Subject)"
        let body = Self.extractBody(from: message.payload)

        let sender = Self.parseFromHeader(fromValue)
        let receivedAt: Date
        if let raw = message.internalDate, let millis = Double(raw) {
            receivedAt = Date(timeIntervalSince1970: millis / 1000.0)
        } else {
            receivedAt = Date()
        }

        let labels = message.labelIds ?? []
        return GmailInboxMessage(
            id: message.id,
            threadID: message.threadId,
            receivedAt: receivedAt,
            senderName: sender.name,
            senderEmail: sender.email,
            subject: subject,
            snippet: message.snippet ?? "",
            body: body,
            labels: labels,
            isUnread: labels.contains("UNREAD"),
            isStarred: labels.contains("STARRED"),
            isImportant: labels.contains("IMPORTANT")
        )
    }

    private static func headerValue(name: String, from headers: [GmailHeader]) -> String? {
        headers.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value
    }

    private static func parseFromHeader(_ raw: String) -> (name: String, email: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = trimmed.lastIndex(of: "<"), let end = trimmed.lastIndex(of: ">"), start < end {
            let namePart = trimmed[..<start].trimmingCharacters(in: .whitespacesAndNewlines)
            let emailPart = trimmed[trimmed.index(after: start)..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanName = namePart.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let finalName = cleanName.isEmpty ? emailPart : cleanName
            return (finalName, emailPart.isEmpty ? "unknown@example.com" : emailPart)
        }
        return (trimmed, trimmed.contains("@") ? trimmed : "unknown@example.com")
    }

    private static func extractBody(from payload: GmailPayload?) -> String {
        guard let payload else { return "" }

        var plainParts: [String] = []
        var htmlParts: [String] = []
        collectBodyParts(from: payload, plainParts: &plainParts, htmlParts: &htmlParts)

        if !plainParts.isEmpty {
            return joinSections(plainParts)
        }
        if !htmlParts.isEmpty {
            let converted = htmlParts.map(htmlToText)
            return joinSections(converted)
        }
        return ""
    }

    private static func collectBodyParts(from part: GmailPayload, plainParts: inout [String], htmlParts: inout [String]) {
        let mimeType = part.mimeType?.lowercased() ?? ""

        if let data = part.body?.data, !data.isEmpty, let decoded = decodeBase64URL(data) {
            let text = String(data: decoded, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty {
                if mimeType.hasPrefix("text/plain") {
                    plainParts.append(text)
                } else if mimeType.hasPrefix("text/html") {
                    htmlParts.append(text)
                } else if mimeType.hasPrefix("text/") {
                    plainParts.append(text)
                }
            }
        }

        for child in part.parts ?? [] {
            collectBodyParts(from: child, plainParts: &plainParts, htmlParts: &htmlParts)
        }
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var b64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = b64.count % 4
        if padding > 0 {
            b64 += String(repeating: "=", count: 4 - padding)
        }
        return Data(base64Encoded: b64)
    }

    private static func joinSections(_ sections: [String]) -> String {
        sections
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private static func htmlToText(_ html: String) -> String {
        guard let data = html.data(using: .utf8) else { return html }
        if let attributed = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        ) {
            return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return html
    }
}

private struct GmailMessageListResponse: Decodable {
    let messages: [GmailMessageRef]?
}

private struct GmailMessageRef: Decodable {
    let id: String
}

private struct GmailMessageResponse: Decodable {
    let id: String
    let threadId: String?
    let labelIds: [String]?
    let snippet: String?
    let internalDate: String?
    let payload: GmailPayload?
}

private struct GmailPayload: Decodable {
    let mimeType: String?
    let headers: [GmailHeader]?
    let body: GmailBody?
    let parts: [GmailPayload]?
}

private struct GmailBody: Decodable {
    let size: Int?
    let data: String?
    let attachmentId: String?
}

private struct GmailHeader: Decodable {
    let name: String
    let value: String
}
