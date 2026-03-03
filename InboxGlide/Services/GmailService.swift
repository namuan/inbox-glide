import Foundation

enum GmailServiceError: LocalizedError {
    case httpStatus(operation: String, statusCode: Int, messageID: String)
    case sendFailed(statusCode: Int, providerMessage: String?)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let operation, let statusCode, _):
            return "Failed to \(operation) (HTTP \(statusCode))."
        case .sendFailed(let statusCode, let providerMessage):
            return Self.userFacingSendError(statusCode: statusCode, providerMessage: providerMessage)
        }
    }

    var statusCode: Int {
        switch self {
        case .httpStatus(_, let statusCode, _):
            return statusCode
        case .sendFailed(let statusCode, _):
            return statusCode
        }
    }

    private static func userFacingSendError(statusCode: Int, providerMessage: String?) -> String {
        let providerDetail = providerMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch statusCode {
        case 400:
            return "Gmail rejected the reply content. Review the message and try again."
        case 401, 403:
            return "Your Gmail session has expired or lost permission. Reconnect Gmail in Settings, then try again."
        case 404:
            return "This Gmail conversation could not be found. Sync your inbox and try again."
        case 429:
            return "Gmail rate limit reached. Wait a moment and try sending again."
        case 500 ... 599:
            return "Gmail is temporarily unavailable. Please try again shortly."
        default:
            if let providerDetail, !providerDetail.isEmpty {
                return "Gmail reply failed (HTTP \(statusCode)): \(providerDetail)"
            }
            return "Gmail reply failed (HTTP \(statusCode))."
        }
    }
}

struct GmailInboxMessage: Sendable {
    let id: String
    let threadID: String?
    let messageHeaderID: String?
    let inReplyToMessageID: String?
    let referenceMessageIDs: [String]
    let receivedAt: Date
    let senderName: String
    let senderEmail: String
    let subject: String
    let snippet: String
    let body: String
    let htmlBody: String?
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

        let maxConcurrentDetails = min(8, refs.count)
        var nextIndex = 0

        try await withThrowingTaskGroup(of: GmailInboxMessage.self) { group in
            while nextIndex < maxConcurrentDetails {
                let messageID = refs[nextIndex].id
                nextIndex += 1
                group.addTask { [self] in
                    try await fetchMessageDetail(accessToken: accessToken, id: messageID)
                }
            }

            while let detail = try await group.next() {
                results.append(detail)
                if nextIndex < refs.count {
                    let messageID = refs[nextIndex].id
                    nextIndex += 1
                    group.addTask { [self] in
                        try await fetchMessageDetail(accessToken: accessToken, id: messageID)
                    }
                }
            }
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

    func archiveMessage(accessToken: String, id: String) async throws {
        guard let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(encodedID)/modify") else {
            throw OAuthServiceError.tokenExchangeFailed("Invalid Gmail archive message URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = #"{"removeLabelIds":["INBOX"]}"#.data(using: .utf8)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthServiceError.tokenExchangeFailed("Invalid Gmail archive response.")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            logger.error(
                "Gmail archive request failed.",
                category: "GmailAPI",
                metadata: ["status": "\(http.statusCode)", "messageID": id]
            )
            throw GmailServiceError.httpStatus(operation: "archive Gmail message", statusCode: http.statusCode, messageID: id)
        }

        logger.info("Archived Gmail message.", category: "GmailAPI", metadata: ["messageID": id])
    }

    func sendReply(accessToken: String, request: ReplySendRequest) async throws {
        guard let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send") else {
            throw OAuthServiceError.tokenExchangeFailed("Invalid Gmail send URL.")
        }

        let rfc822 = Self.rfc822ReplyMessage(from: request)
        let raw = Self.encodeBase64URL(Data(rfc822.utf8))
        let payload = GmailSendMessageRequest(
            raw: raw,
            threadId: request.threading.providerThreadID?.trimmedNilIfEmpty
        )

        var apiRequest = URLRequest(url: url)
        apiRequest.httpMethod = "POST"
        apiRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        apiRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        apiRequest.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: apiRequest)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthServiceError.tokenExchangeFailed("Invalid Gmail send response.")
        }

        guard (200 ..< 300).contains(http.statusCode) else {
            let apiMessage = Self.extractAPIErrorMessage(from: data)
            logger.error(
                "Gmail reply send request failed.",
                category: "GmailAPI",
                metadata: [
                    "status": "\(http.statusCode)",
                    "threadID": request.threading.providerThreadID ?? "none"
                ]
            )
            throw GmailServiceError.sendFailed(statusCode: http.statusCode, providerMessage: apiMessage)
        }

        let sendResponse = try? JSONDecoder().decode(GmailSendMessageResponse.self, from: data)
        logger.info(
            "Sent Gmail reply.",
            category: "GmailAPI",
            metadata: [
                "threadID": sendResponse?.threadId ?? request.threading.providerThreadID ?? "none",
                "messageID": sendResponse?.id ?? "unknown"
            ]
        )
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
        let messageHeaderID = Self.firstMessageID(from: Self.headerValue(name: "Message-ID", from: headers))
        let inReplyToHeaderID = Self.firstMessageID(from: Self.headerValue(name: "In-Reply-To", from: headers))
        let referenceHeaderIDs = Self.extractMessageIDList(from: Self.headerValue(name: "References", from: headers))
        let extractedBody = Self.extractBody(from: message.payload)

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
            messageHeaderID: messageHeaderID,
            inReplyToMessageID: inReplyToHeaderID,
            referenceMessageIDs: referenceHeaderIDs,
            receivedAt: receivedAt,
            senderName: sender.name,
            senderEmail: sender.email,
            subject: subject,
            snippet: message.snippet ?? "",
            body: extractedBody.text,
            htmlBody: extractedBody.html,
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

    private static func rfc822ReplyMessage(from request: ReplySendRequest) -> String {
        var headerLines: [String] = [
            "To: \(formatAddress(name: request.recipient.name, email: request.recipient.emailAddress))",
            "Subject: \(sanitizeHeaderValue(request.subject))"
        ]

        if let inReplyTo = normalizedMessageID(request.threading.inReplyToMessageID) {
            headerLines.append("In-Reply-To: \(inReplyTo)")
        }

        let referencesHeader = referencesHeaderValue(
            referenceMessageIDs: request.threading.referenceMessageIDs,
            inReplyToMessageID: request.threading.inReplyToMessageID
        )
        if !referencesHeader.isEmpty {
            headerLines.append("References: \(referencesHeader)")
        }

        headerLines.append(contentsOf: [
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: 8bit"
        ])

        return headerLines.joined(separator: "\r\n") + "\r\n\r\n" + normalizeRFC822Body(request.body)
    }

    private static func formatAddress(name: String, email: String) -> String {
        let cleanEmail = sanitizeHeaderValue(email)
        let cleanName = sanitizeHeaderValue(name)
        if cleanName.isEmpty {
            return cleanEmail
        }
        let escapedName = cleanName.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escapedName)\" <\(cleanEmail)>"
    }

    private static func referencesHeaderValue(referenceMessageIDs: [String], inReplyToMessageID: String?) -> String {
        var all = referenceMessageIDs
        if let inReplyToMessageID {
            all.append(inReplyToMessageID)
        }
        return deduplicatedMessageIDs(all).joined(separator: " ")
    }

    private static func deduplicatedMessageIDs(_ ids: [String]) -> [String] {
        var unique: [String] = []
        var seen: Set<String> = []
        for raw in ids {
            guard let normalized = normalizedMessageID(raw), seen.insert(normalized).inserted else {
                continue
            }
            unique.append(normalized)
        }
        return unique
    }

    private static func firstMessageID(from rawHeaderValue: String?) -> String? {
        extractMessageIDList(from: rawHeaderValue).first
    }

    private static func extractMessageIDList(from rawHeaderValue: String?) -> [String] {
        guard let rawHeaderValue else { return [] }
        let clean = sanitizeHeaderValue(rawHeaderValue)
        guard !clean.isEmpty else { return [] }

        var extracted: [String] = []
        var current = ""
        var isCapturing = false

        for character in clean {
            if character == "<" {
                current = "<"
                isCapturing = true
                continue
            }

            if isCapturing {
                current.append(character)
                if character == ">" {
                    extracted.append(current)
                    current = ""
                    isCapturing = false
                }
            }
        }

        if extracted.isEmpty {
            extracted = clean.split(whereSeparator: \.isWhitespace).map(String.init)
        }

        return deduplicatedMessageIDs(extracted)
    }

    private static func normalizedMessageID(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let clean = sanitizeHeaderValue(rawValue)
        guard !clean.isEmpty else { return nil }

        if clean.hasPrefix("<"), clean.hasSuffix(">") {
            return clean
        }

        if let start = clean.firstIndex(of: "<"), let end = clean[start...].firstIndex(of: ">"), start < end {
            return String(clean[start...end])
        }

        let firstToken = clean.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? clean
        guard !firstToken.isEmpty else { return nil }
        return "<\(firstToken)>"
    }

    private static func sanitizeHeaderValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeRFC822Body(_ body: String) -> String {
        body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
    }

    private static func encodeBase64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func extractAPIErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let envelope = try? JSONDecoder().decode(GmailAPIErrorEnvelope.self, from: data)
        return envelope?.error.message?.trimmedNilIfEmpty
    }

    private static func extractBody(from payload: GmailPayload?) -> (text: String, html: String?) {
        guard let payload else { return ("", nil) }

        var plainParts: [String] = []
        var htmlParts: [String] = []
        collectBodyParts(from: payload, plainParts: &plainParts, htmlParts: &htmlParts)

        if !plainParts.isEmpty {
            return (joinSections(plainParts), joinSections(htmlParts).nilIfEmpty)
        }
        if !htmlParts.isEmpty {
            let html = joinSections(htmlParts)
            return (HTMLContentCleaner.extractDisplayText(fromHTML: html), html.nilIfEmpty)
        }
        return ("", nil)
    }

    private static func collectBodyParts(from part: GmailPayload, plainParts: inout [String], htmlParts: inout [String]) {
        let mimeType = part.mimeType?.lowercased() ?? ""

        if let data = part.body?.data, !data.isEmpty, let decoded = decodeBase64URL(data) {
            let text = decodeBodyTextData(decoded).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                if mimeType.hasPrefix("text/plain") {
                    plainParts.append(HTMLContentCleaner.cleanText(text))
                } else if mimeType.hasPrefix("text/html") {
                    if let sanitizedHTML = HTMLContentCleaner.sanitizeHTML(text) {
                        htmlParts.append(sanitizedHTML)
                    }
                } else if mimeType.hasPrefix("text/") {
                    plainParts.append(HTMLContentCleaner.cleanText(text))
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

    private static func decodeBodyTextData(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

private struct GmailSendMessageRequest: Encodable {
    let raw: String
    let threadId: String?
}

private struct GmailSendMessageResponse: Decodable {
    let id: String
    let threadId: String?
}

private struct GmailAPIErrorEnvelope: Decodable {
    let error: GmailAPIErrorPayload
}

private struct GmailAPIErrorPayload: Decodable {
    let message: String?
}
