import Foundation

final class AIReplyService: ObservableObject {
    func generateReply(from email: EmailMessage, note: String) async -> String {
        let safeNote = PIIScrubber.scrub(note)
        let safePreview = PIIScrubber.scrub(email.preview)

        let greeting = "Hi \(email.senderName),"
        let body = "\n\nThanks for the note. Regarding \"\(email.subject)\":\n\n\(safeNote.isEmpty ? safePreview : safeNote)\n\nBest,\n"
        return greeting + body
    }
}
