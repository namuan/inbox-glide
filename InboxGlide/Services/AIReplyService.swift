import Foundation

final class AIReplyService: ObservableObject {
    func generateReply(from email: EmailMessage, note: String) async -> String {
        let safeNote = PIIScrubber.scrub(note)
        let safePreview = PIIScrubber.scrub(email.preview)

        let greeting = "Hi \(email.senderName),"
        let body = "\n\nThanks for the note. Regarding \"\(email.subject)\":\n\n\(safeNote.isEmpty ? safePreview : safeNote)\n\nBest,\n"
        return greeting + body
    }

    func generateReply(from thread: EmailThread, note: String) async -> String {
        let lead = thread.leadMessage
        let context = thread.messages
            .suffix(3)
            .map { "\($0.senderName): \($0.preview.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n")
        let safeNote = PIIScrubber.scrub(note)
        let safeContext = PIIScrubber.scrub(context)
        let greeting = "Hi \(lead.senderName),"
        let body = "\n\nThanks for the thread update regarding \"\(lead.subject)\".\n\n\(safeNote.isEmpty ? safeContext : safeNote)\n\nBest,\n"
        return greeting + body
    }

    func generateQuickReply(for email: EmailMessage) async -> String {
        let safePreview = PIIScrubber.scrub(email.preview)
        let safeSubject = email.subject.trimmingCharacters(in: .whitespacesAndNewlines)

        if safePreview.isEmpty {
            return "Thank you for your email. I'll review the content and get back to you shortly."
        }

        let lowercased = safePreview.lowercased()

        if lowercased.contains("meeting") || lowercased.contains("schedule") || lowercased.contains("calendar") {
            return "Thanks for the invite. I'll check my calendar and confirm my availability shortly."
        }

        if lowercased.contains("question") || lowercased.contains("help") || lowercased.contains("need") {
            return "Thanks for reaching out. Let me review this and I'll follow up with a detailed response soon."
        }

        if lowercased.contains("update") || lowercased.contains("status") || lowercased.contains("report") {
            return "Thanks for the update. I've reviewed the information and will keep an eye on it."
        }

        if lowercased.contains("invoice") || lowercased.contains("payment") || lowercased.contains("receipt") {
            return "Thanks for sending this over. I'll review the details and process accordingly."
        }

        if lowercased.contains("urgent") || lowercased.contains("asap") || lowercased.contains("immediately") {
            return "Received your urgent message. I'm looking into this now and will respond shortly."
        }

        return "Thanks for your email. I'll review the details about \"\(safeSubject)\" and get back to you."
    }

    func generateQuickReply(for thread: EmailThread) async -> String {
        await generateQuickReply(for: thread.leadMessage)
    }
}
