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
