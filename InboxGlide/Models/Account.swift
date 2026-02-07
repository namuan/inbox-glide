import SwiftUI

enum MailProvider: String, Codable, CaseIterable, Identifiable {
    case gmail
    case yahoo
    case fastmail

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gmail: return "Gmail"
        case .yahoo: return "Yahoo Mail"
        case .fastmail: return "Fastmail"
        }
    }

    var systemImage: String {
        switch self {
        case .gmail: return "envelope"
        case .yahoo: return "envelope.badge"
        case .fastmail: return "paperplane"
        }
    }
}

struct MailAccount: Identifiable, Codable, Hashable {
    var id: UUID
    var provider: MailProvider
    var displayName: String
    var emailAddress: String
    var colorHex: String
}
