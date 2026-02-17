import Foundation

struct GmailInboxMessage: Sendable {
    let id: String
    let threadID: String?
    let receivedAt: Date
    let senderName: String
    let senderEmail: String
    let subject: String
    let snippet: String
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
            throw OAuthServiceError.tokenExchangeFailed("Failed to delete Gmail message (HTTP \(http.statusCode)).")
        }

        logger.info("Moved Gmail message to trash.", category: "GmailAPI", metadata: ["messageID": id])
    }

    private func fetchMessageDetail(accessToken: String, id: String) async throws -> GmailInboxMessage {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)")
        components?.queryItems = [
            URLQueryItem(name: "format", value: "metadata"),
            URLQueryItem(name: "metadataHeaders", value: "From"),
            URLQueryItem(name: "metadataHeaders", value: "Subject"),
            URLQueryItem(name: "metadataHeaders", value: "Date")
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
    let headers: [GmailHeader]?
}

private struct GmailHeader: Decodable {
    let name: String
    let value: String
}
