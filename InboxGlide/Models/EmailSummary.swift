import Foundation

struct EmailSummary: Codable, Hashable {
    var headline: String
    var body: String
    var category: String
    var actionItems: [String]
    var urgency: String
    var spamConfidence: Double
    var spamReason: String?
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
    static let spamWarningThreshold = 0.68

    var clampedSpamConfidence: Double {
        min(max(spamConfidence, 0), 1)
    }

    var isPotentialSpam: Bool {
        category.caseInsensitiveCompare("spam") == .orderedSame || clampedSpamConfidence >= Self.spamWarningThreshold
    }

    static func minimal(subject: String, spamConfidence: Double = 0, spamReason: String? = nil) -> EmailSummary {
        EmailSummary(
            headline: subject.isEmpty ? "Very short email" : subject,
            body: "This email does not contain enough text to summarize reliably.",
            category: "informational",
            actionItems: [],
            urgency: "low",
            spamConfidence: spamConfidence,
            spamReason: spamReason
        )
    }

    static func fallback(
        subject: String,
        body: String,
        actionItems: [String],
        category: String,
        urgency: String,
        spamConfidence: Double = 0,
        spamReason: String? = nil
    ) -> EmailSummary {
        EmailSummary(
            headline: subject.isEmpty ? "Email summary" : subject,
            body: body,
            category: category,
            actionItems: actionItems,
            urgency: urgency,
            spamConfidence: spamConfidence,
            spamReason: spamReason
        )
    }

    static func redacted(subject: String) -> EmailSummary {
        EmailSummary(
            headline: subject.isEmpty ? "Email summary unavailable" : subject,
            body: "Content could not be summarized safely.",
            category: "informational",
            actionItems: [],
            urgency: "low",
            spamConfidence: 0,
            spamReason: nil
        )
    }
}
