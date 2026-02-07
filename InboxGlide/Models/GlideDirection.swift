import Foundation

enum GlideDirection: String, Codable, CaseIterable, Identifiable {
    case left
    case right
    case up
    case down

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .up: return "Up"
        case .down: return "Down"
        }
    }

    var systemImage: String {
        switch self {
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        }
    }
}
