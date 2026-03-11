import Foundation

enum GlideAction: String, Codable, CaseIterable, Identifiable {
    case delete
    case archive
    case markUnread
    case unstar
    case markImportant
    case unmarkImportant
    case moveToFolder
    case applyLabel
    case unsubscribe
    case unsubscribeAndDeleteAllFromSender
    case blockSender
    case snooze1h
    case snooze4h
    case snooze1d
    case createReminder
    case skip
    case reply
    case aiReply
    case pin

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .delete: return "Delete"
        case .archive: return "Archive"
        case .markUnread: return "Mark Unread"
        case .unstar: return "Unstar"
        case .markImportant: return "Mark Important"
        case .unmarkImportant: return "Unmark Important"
        case .moveToFolder: return "Move to Folder"
        case .applyLabel: return "Apply Label"
        case .unsubscribe: return "Unsubscribe"
        case .unsubscribeAndDeleteAllFromSender: return "Unsubscribe + Delete All"
        case .blockSender: return "Block Sender"
        case .snooze1h: return "Snooze 1 Hour"
        case .snooze4h: return "Snooze 4 Hours"
        case .snooze1d: return "Snooze 1 Day"
        case .createReminder: return "Create Reminder"
        case .skip: return "Skip"
        case .reply: return "Reply"
        case .aiReply: return "AI Reply"
        case .pin: return "Pin"
        }
    }

    var systemImage: String {
        switch self {
        case .delete: return "trash"
        case .archive: return "archivebox"
        case .markUnread: return "envelope.badge"
        case .unstar: return "star.slash"
        case .markImportant: return "exclamationmark.circle"
        case .unmarkImportant: return "exclamationmark.circle.fill"
        case .moveToFolder: return "folder"
        case .applyLabel: return "tag"
        case .unsubscribe: return "bell.slash"
        case .unsubscribeAndDeleteAllFromSender: return "bell.slash.fill"
        case .blockSender: return "hand.raised"
        case .snooze1h, .snooze4h, .snooze1d: return "zzz"
        case .createReminder: return "checklist"
        case .skip: return "arrow.uturn.right"
        case .reply: return "arrowshape.turn.up.left"
        case .aiReply: return "sparkles"
        case .pin: return "pin.fill"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .delete, .blockSender, .unsubscribe, .unsubscribeAndDeleteAllFromSender:
            return true
        default:
            return false
        }
    }

    var isSelectableInUI: Bool {
        switch self {
        case .blockSender, .unsubscribe, .unsubscribeAndDeleteAllFromSender:
            return false
        default:
            return true
        }
    }

    var isLocalOnly: Bool {
        self == .pin
    }

    static var supportedInUI: [GlideAction] {
        allCases.filter(\.isSelectableInUI)
    }
}
