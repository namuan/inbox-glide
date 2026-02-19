import Foundation

struct EmailSummary: Codable, Hashable {
    var headline: String
    var body: String
    var category: String
    var actionItems: [String]
    var urgency: String
}

enum EmailSummarySource: String, Hashable {
    case foundationModel
    case fallback
}

struct EmailSummaryResult: Hashable {
    var summary: EmailSummary
    var source: EmailSummarySource
    var note: String?
}

extension EmailSummary {
    static func minimal(subject: String) -> EmailSummary {
        EmailSummary(
            headline: subject.isEmpty ? "Very short email" : subject,
            body: "This email does not contain enough text to summarize reliably.",
            category: "informational",
            actionItems: [],
            urgency: "low"
        )
    }

    static func fallback(subject: String, body: String, actionItems: [String], category: String, urgency: String) -> EmailSummary {
        EmailSummary(
            headline: subject.isEmpty ? "Email summary" : subject,
            body: body,
            category: category,
            actionItems: actionItems,
            urgency: urgency
        )
    }

    static func redacted(subject: String) -> EmailSummary {
        EmailSummary(
            headline: subject.isEmpty ? "Email summary unavailable" : subject,
            body: "Content could not be summarized safely.",
            category: "informational",
            actionItems: [],
            urgency: "low"
        )
    }
}
