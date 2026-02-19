import Foundation

enum MessageCategory: String, Codable, CaseIterable, Identifiable {
    case work
    case personal
    case promotions
    case updates
    case forums
    case social

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .work: return "Work"
        case .personal: return "Personal"
        case .promotions: return "Promotions"
        case .updates: return "Updates"
        case .forums: return "Forums"
        case .social: return "Social"
        }
    }
}

struct EmailMessage: Identifiable, Codable, Hashable {
    var id: UUID
    var accountID: UUID
    var providerMessageID: String? = nil

    var receivedAt: Date
    var senderName: String
    var senderEmail: String
    var subject: String
    var preview: String
    var body: String
    var htmlBody: String? = nil

    var isRead: Bool
    var isStarred: Bool
    var isImportant: Bool
    var labels: [String]

    var archivedAt: Date?
    var deletedAt: Date?
    var snoozedUntil: Date?

    var category: MessageCategory?
}
