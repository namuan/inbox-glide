import Foundation

struct QueuedMailAction: Identifiable, Codable, Hashable {
    var id: UUID
    var createdAt: Date
    var accountID: UUID
    var messageID: UUID
    var action: GlideAction
    var isSecondary: Bool
}
