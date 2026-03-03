import Foundation

struct ReplySendAccount: Codable, Hashable, Sendable {
    let id: UUID
    let provider: MailProvider
    let emailAddress: String
}

struct ReplyRecipient: Codable, Hashable, Sendable {
    let name: String
    let emailAddress: String
}

struct ReplyProviderThreadingIdentifiers: Codable, Hashable, Sendable {
    let providerMessageID: String?
    let providerThreadID: String?
    let inReplyToMessageID: String?
    let referenceMessageIDs: [String]

    init(
        providerMessageID: String?,
        providerThreadID: String?,
        inReplyToMessageID: String? = nil,
        referenceMessageIDs: [String] = []
    ) {
        self.providerMessageID = providerMessageID
        self.providerThreadID = providerThreadID
        self.inReplyToMessageID = inReplyToMessageID
        self.referenceMessageIDs = referenceMessageIDs
    }
}

struct ReplySendRequest: Codable, Hashable, Sendable {
    let account: ReplySendAccount
    let recipient: ReplyRecipient
    let subject: String
    let body: String
    let threading: ReplyProviderThreadingIdentifiers
}

enum ReplySendPreparationError: LocalizedError {
    case messageNotFound
    case accountNotFound
    case recipientMissing
    case emptyBody

    var errorDescription: String? {
        switch self {
        case .messageNotFound:
            return "Message not found."
        case .accountNotFound:
            return "Account for this message could not be resolved."
        case .recipientMissing:
            return "Recipient is missing."
        case .emptyBody:
            return "Reply body cannot be empty."
        }
    }
}

enum ReplyRFC822Builder {
    static func buildReply(from request: ReplySendRequest, includeFromHeader: Bool) -> String {
        var headerLines: [String] = []
        if includeFromHeader {
            headerLines.append("From: \(formatAddress(name: "", email: request.account.emailAddress))")
        }
        headerLines.append(contentsOf: [
            "To: \(formatAddress(name: request.recipient.name, email: request.recipient.emailAddress))",
            "Subject: \(sanitizeHeaderValue(request.subject))"
        ])

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
}
