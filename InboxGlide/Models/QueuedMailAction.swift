import Foundation

struct QueuedMailAction: Identifiable, Codable, Hashable {
    var id: UUID
    var createdAt: Date
    var accountID: UUID
    var messageID: UUID
    var action: GlideAction
    var isSecondary: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case accountID
        case messageID
        case action
        case isSecondary
    }

    init(id: UUID, createdAt: Date, accountID: UUID, messageID: UUID, action: GlideAction, isSecondary: Bool) {
        self.id = id
        self.createdAt = createdAt
        self.accountID = accountID
        self.messageID = messageID
        self.action = action
        self.isSecondary = isSecondary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        accountID = try container.decode(UUID.self, forKey: .accountID)
        messageID = try container.decode(UUID.self, forKey: .messageID)
        isSecondary = try container.decode(Bool.self, forKey: .isSecondary)

        let rawAction = try container.decode(String.self, forKey: .action)
        if let decodedAction = GlideAction(rawValue: rawAction) {
            action = decodedAction
            return
        }

        switch rawAction {
        case "markRead":
            action = .skip
        case "star":
            action = .archive
        default:
            action = .archive
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(accountID, forKey: .accountID)
        try container.encode(messageID, forKey: .messageID)
        try container.encode(action.rawValue, forKey: .action)
        try container.encode(isSecondary, forKey: .isSecondary)
    }
}
