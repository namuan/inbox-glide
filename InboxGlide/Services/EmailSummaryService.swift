import Foundation
import NaturalLanguage
import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

#if canImport(FoundationModels)
import FoundationModels
#endif

enum EmailSummaryViewState: Hashable {
    case idle
    case loading
    case ready(EmailSummaryResult)
    case failed(String)
}

@MainActor
final class EmailSummaryService: ObservableObject {
    @Published private(set) var states: [UUID: EmailSummaryViewState] = [:]

    private let summarizer = EmailSummarizer()

    func state(for messageID: UUID) -> EmailSummaryViewState {
        states[messageID] ?? .idle
    }

    func summarizeIfNeeded(_ email: EmailMessage) {
        switch state(for: email.id) {
        case .loading, .ready:
            return
        case .idle, .failed:
            summarize(email, forceRefresh: false)
        }
    }

    func summarize(_ email: EmailMessage, forceRefresh: Bool) {
        states[email.id] = .loading
        Task {
            let result = await summarizer.summarize(email, forceRefresh: forceRefresh)
            await MainActor.run {
                states[email.id] = .ready(result)
            }
        }
    }
}

actor EmailSummarizer {
    private struct CachedSummary {
        var fingerprint: String
        var result: EmailSummaryResult
    }

    private var cache: [UUID: CachedSummary] = [:]
    private var inFlight: [UUID: Task<EmailSummaryResult, Never>] = [:]
    private let logger = AppLogger.shared

    init() {}

    func summarize(_ email: EmailMessage, forceRefresh: Bool) async -> EmailSummaryResult {
        let fingerprint = Self.fingerprint(for: email)

        if !forceRefresh, let cached = cache[email.id], cached.fingerprint == fingerprint {
            return cached.result
        }

        if forceRefresh, let existing = inFlight[email.id] {
            existing.cancel()
            inFlight[email.id] = nil
        } else if let existing = inFlight[email.id] {
            return await existing.value
        }

        let task = Task { () -> EmailSummaryResult in
            await self.computeSummary(for: email)
        }
        inFlight[email.id] = task

        let result = await task.value
        inFlight[email.id] = nil
        cache[email.id] = CachedSummary(fingerprint: fingerprint, result: result)
        return result
    }

    private func computeSummary(for email: EmailMessage) async -> EmailSummaryResult {
        let subject = email.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = Self.normalizedBody(email.body)
        let trimmedBody = normalized.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedBody.isEmpty else {
            return EmailSummaryResult(summary: .minimal(subject: subject), source: .fallback, note: "No text body to summarize.")
        }

        guard trimmedBody.count >= 50 else {
            return EmailSummaryResult(summary: .minimal(subject: subject), source: .fallback, note: "Email is too short for full summarization.")
        }

        let supportedLanguages: Set<NLLanguage> = [
            .english, .french, .german, .italian, .spanish, .portuguese,
            .simplifiedChinese, .japanese, .korean
        ]
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmedBody)
        if let language = recognizer.dominantLanguage, !supportedLanguages.contains(language) {
            let fallback = Self.fallbackSummary(subject: subject, body: trimmedBody)
            return EmailSummaryResult(summary: fallback, source: .fallback, note: "Language may be unsupported for on-device summarization.")
        }

        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical {
            let fallback = Self.fallbackSummary(subject: subject, body: trimmedBody)
            return EmailSummaryResult(
                summary: fallback,
                source: .fallback,
                note: "Summarization slowed to protect your device due to thermal conditions."
            )
        }

        var note: String? = nil
        let inputBody: String
        if trimmedBody.count > 10_000 {
            inputBody = Self.hierarchicalInput(from: trimmedBody)
            note = "Summarizing first portion of long email."
        } else if trimmedBody.count > 4_000 {
            inputBody = String(trimmedBody.prefix(4_000))
            note = "Summarizing first portion of long email."
        } else {
            inputBody = trimmedBody
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return await summarizeWithFoundationModel(
                subject: subject,
                email: email,
                inputBody: inputBody,
                fallbackNote: note
            )
        }
        #endif

        let fallback = Self.fallbackSummary(subject: subject, body: inputBody)
        return EmailSummaryResult(summary: fallback, source: .fallback, note: note ?? "On-device model unavailable on this OS version.")
    }

    private static func prompt(subject: String, senderName: String, senderEmail: String, receivedAt: Date, body: String) -> String {
        """
        Summarize the following email. Focus only on facts from the text.
        From: \(senderName) <\(senderEmail)>
        Subject: \(subject)
        Received: \(receivedAt.formatted(date: .abbreviated, time: .shortened))
        ---
        \(body)
        """
    }

    private static func normalizedBody(_ body: String) -> String {
        let strippedHTML = stripHTML(body)
        return strippedHTML
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripHTML(_ value: String) -> String {
        guard value.contains("<"), value.contains(">"), let data = value.data(using: .utf8) else {
            return value
        }
        #if canImport(AppKit)
        if let attributed = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        ) {
            return attributed.string
        }
        #endif
        return value
    }

    private static func fallbackSummary(subject: String, body: String) -> EmailSummary {
        let sentenceSummary = firstSentences(in: body, maxCount: 3)
        let summaryBody = sentenceSummary.isEmpty ? String(body.prefix(220)) : sentenceSummary
        return .fallback(
            subject: subject,
            body: summaryBody,
            actionItems: extractActionItems(from: body),
            category: inferCategory(subject: subject, body: body),
            urgency: inferUrgency(subject: subject, body: body)
        )
    }

    private static func firstSentences(in text: String, maxCount: Int) -> String {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            return sentences.count < maxCount
        }
        return sentences.joined(separator: " ")
    }

    private static func extractActionItems(from body: String) -> [String] {
        let lines = body.components(separatedBy: .newlines)
        let candidates = lines.compactMap { raw -> String? in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            let lowercase = line.lowercased()
            if line.hasPrefix("- ") || line.hasPrefix("* ") || lowercase.hasPrefix("please ") || lowercase.contains("action required") || lowercase.contains("todo") {
                return line
            }
            return nil
        }
        return Array(candidates.prefix(5))
    }

    private static func inferCategory(subject: String, body: String) -> String {
        let combined = "\(subject)\n\(body)".lowercased()
        if combined.contains("unsubscribe") || combined.contains("sale") || combined.contains("offer") {
            return "promotional"
        }
        if combined.contains("newsletter") || combined.contains("digest") {
            return "newsletter"
        }
        if combined.contains("urgent") || combined.contains("action required") || combined.contains("please review") {
            return "action-required"
        }
        if combined.contains("invoice") || combined.contains("meeting") || combined.contains("schedule") {
            return "informational"
        }
        return "informational"
    }

    private static func inferUrgency(subject: String, body: String) -> String {
        let combined = "\(subject)\n\(body)".lowercased()
        if combined.contains("urgent") || combined.contains("asap") || combined.contains("immediately") || combined.contains("today") {
            return "high"
        }
        if combined.contains("tomorrow") || combined.contains("this week") || combined.contains("deadline") {
            return "medium"
        }
        return "low"
    }

    private static func hierarchicalInput(from body: String) -> String {
        var chunks: [String] = []
        var start = body.startIndex
        let chunkSize = 4_000
        let overlap = 250

        while start < body.endIndex {
            let end = body.index(start, offsetBy: chunkSize, limitedBy: body.endIndex) ?? body.endIndex
            chunks.append(String(body[start..<end]))
            if end == body.endIndex { break }
            start = body.index(end, offsetBy: -overlap, limitedBy: body.startIndex) ?? body.startIndex
        }

        let partials = chunks.prefix(3).map { firstSentences(in: $0, maxCount: 2) }
        return partials.joined(separator: "\n")
    }

    private static func fingerprint(for email: EmailMessage) -> String {
        var hasher = Hasher()
        hasher.combine(email.id)
        hasher.combine(email.subject)
        hasher.combine(email.body)
        hasher.combine(email.receivedAt.timeIntervalSince1970)
        hasher.combine(modelFingerprint)
        return String(hasher.finalize())
    }

    private static var modelFingerprint: String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let availability = String(describing: SystemLanguageModel.default.availability)
            return "foundation-models|\(availability)|\(os)"
        }
        return "foundation-models-unavailable|\(os)"
        #else
        return "fallback-only|\(os)"
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func summarizeWithFoundationModel(
        subject: String,
        email: EmailMessage,
        inputBody: String,
        fallbackNote: String?
    ) async -> EmailSummaryResult {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            let fallback = Self.fallbackSummary(subject: subject, body: inputBody)
            return EmailSummaryResult(
                summary: fallback,
                source: .fallback,
                note: fallbackNote ?? "On-device model unavailable (\(String(describing: model.availability)))."
            )
        }

        let instructions = """
        You are an email summarization assistant.
        Summarize emails concisely in 2-4 sentences.
        Extract action items when present.
        Classify category and urgency.
        Focus only on the provided content.
        Do not hallucinate or infer details not in the email.
        """

        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(
                to: Self.prompt(subject: subject, senderName: email.senderName, senderEmail: email.senderEmail, receivedAt: email.receivedAt, body: inputBody),
                generating: FoundationGeneratedEmailSummary.self
            )
            let generated = response.content
            let summary = EmailSummary(
                headline: generated.headline.trimmingCharacters(in: .whitespacesAndNewlines),
                body: generated.body.trimmingCharacters(in: .whitespacesAndNewlines),
                category: generated.category.trimmingCharacters(in: .whitespacesAndNewlines),
                actionItems: generated.actionItems.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                urgency: generated.urgency.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            return EmailSummaryResult(summary: summary, source: .foundationModel, note: fallbackNote)
        } catch {
            logger.warning(
                "Email summary generation failed, using fallback.",
                category: "EmailSummary",
                metadata: ["error": String(describing: error)]
            )
            let fallback = Self.fallbackSummary(subject: subject, body: inputBody)
            return EmailSummaryResult(summary: fallback, source: .fallback, note: fallbackNote ?? "Model generation failed, fallback used.")
        }
    }
    #endif
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
private struct FoundationGeneratedEmailSummary {
    @Guide(description: "One sentence summary headline.")
    var headline: String

    @Guide(description: "A concise 2-4 sentence summary.")
    var body: String

    @Guide(.anyOf(["action-required", "informational", "promotional", "newsletter", "spam"]))
    var category: String

    @Guide(description: "Action items extracted from the email if any.")
    var actionItems: [String]

    @Guide(.anyOf(["low", "medium", "high"]))
    var urgency: String
}
#endif
