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
    private var requestedLengths: [UUID: AISummaryLength] = [:]

    func state(for messageID: UUID) -> EmailSummaryViewState {
        states[messageID] ?? .idle
    }

    func summarizeIfNeeded(_ email: EmailMessage, length: AISummaryLength) {
        let isSameRequestedLength = requestedLengths[email.id] == length
        switch state(for: email.id) {
        case .loading where isSameRequestedLength, .ready where isSameRequestedLength:
            return
        case .idle, .failed, .loading, .ready:
            summarize(email, forceRefresh: false, length: length)
        }
    }

    func summarize(_ email: EmailMessage, forceRefresh: Bool, length: AISummaryLength) {
        requestedLengths[email.id] = length
        states[email.id] = .loading
        Task {
            let result = await summarizer.summarize(email, forceRefresh: forceRefresh, length: length)
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

    func summarize(_ email: EmailMessage, forceRefresh: Bool, length: AISummaryLength) async -> EmailSummaryResult {
        let fingerprint = Self.fingerprint(for: email, length: length)

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
            await self.computeSummary(for: email, length: length)
        }
        inFlight[email.id] = task

        let result = await task.value
        inFlight[email.id] = nil
        cache[email.id] = CachedSummary(fingerprint: fingerprint, result: result)
        return result
    }

    private func computeSummary(for email: EmailMessage, length: AISummaryLength) async -> EmailSummaryResult {
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
            let fallback = Self.fallbackSummary(subject: subject, body: trimmedBody, length: length)
            return EmailSummaryResult(summary: fallback, source: .fallback, note: "Language may be unsupported for on-device summarization.")
        }

        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical {
            let fallback = Self.fallbackSummary(subject: subject, body: trimmedBody, length: length)
            return EmailSummaryResult(
                summary: fallback,
                source: .fallback,
                note: "Summarization slowed to protect your device due to thermal conditions."
            )
        }

        let inputBody: String
        let note: String?
        if trimmedBody.count > 4_000 {
            inputBody = Self.hierarchicalInput(from: trimmedBody, length: length)
            note = "Summarized using \(length == .full ? "full" : "short") full-email chunking."
        } else {
            inputBody = trimmedBody
            note = nil
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return await summarizeWithFoundationModel(
                subject: subject,
                email: email,
                inputBody: inputBody,
                fullBody: trimmedBody,
                length: length,
                fallbackNote: note
            )
        }
        #endif

        let fallback = Self.fallbackSummary(subject: subject, body: trimmedBody, length: length)
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

    private static func fallbackSummary(subject: String, body: String, length: AISummaryLength) -> EmailSummary {
        let sentenceCount: Int
        let characterCap: Int
        switch length {
        case .short:
            sentenceCount = 3
            characterCap = 220
        case .medium:
            sentenceCount = 5
            characterCap = 700
        case .full:
            sentenceCount = 8
            characterCap = 1_200
        }
        let sentenceSummary = firstSentences(in: body, maxCount: sentenceCount)
        let summaryBody = sentenceSummary.isEmpty ? String(body.prefix(characterCap)) : sentenceSummary
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

    private static func hierarchicalInput(from body: String, length: AISummaryLength) -> String {
        var chunks: [String] = []
        var start = body.startIndex
        let chunkSize = 4_000
        let overlap = 250
        let targetCharacterBudget: Int
        let sentenceCount: Int
        switch length {
        case .short:
            targetCharacterBudget = 12_000
            sentenceCount = 1
        case .medium:
            targetCharacterBudget = 16_000
            sentenceCount = 1
        case .full:
            targetCharacterBudget = 20_000
            sentenceCount = 2
        }

        while start < body.endIndex {
            let end = body.index(start, offsetBy: chunkSize, limitedBy: body.endIndex) ?? body.endIndex
            chunks.append(String(body[start..<end]))
            if end == body.endIndex { break }
            start = body.index(end, offsetBy: -overlap, limitedBy: body.startIndex) ?? body.startIndex
        }

        guard chunks.count > 1 else { return body }

        let perChunkBudget = max(40, (targetCharacterBudget / chunks.count) - 20)
        let partials = chunks.enumerated().map { index, chunk in
            let sentence = firstSentences(in: chunk, maxCount: sentenceCount)
            let excerptSource = sentence.isEmpty ? chunk : sentence
            let excerpt = excerptSource.trimmingCharacters(in: .whitespacesAndNewlines)
            return "[Part \(index + 1)/\(chunks.count)] \(String(excerpt.prefix(perChunkBudget)))"
        }
        return partials.joined(separator: "\n")
    }

    private static func fingerprint(for email: EmailMessage, length: AISummaryLength) -> String {
        var hasher = Hasher()
        hasher.combine(email.id)
        hasher.combine(email.subject)
        hasher.combine(email.body)
        hasher.combine(email.receivedAt.timeIntervalSince1970)
        hasher.combine(length.rawValue)
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
        fullBody: String,
        length: AISummaryLength,
        fallbackNote: String?
    ) async -> EmailSummaryResult {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            let fallback = Self.fallbackSummary(subject: subject, body: fullBody, length: length)
            return EmailSummaryResult(
                summary: fallback,
                source: .fallback,
                note: fallbackNote ?? "On-device model unavailable (\(String(describing: model.availability)))."
            )
        }

        let instructions = """
        You are an email summarization assistant.
        \(summaryInstruction(for: length))
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
            let fallback = Self.fallbackSummary(subject: subject, body: fullBody, length: length)
            return EmailSummaryResult(summary: fallback, source: .fallback, note: fallbackNote ?? "Model generation failed, fallback used.")
        }
    }
    #endif

    private func summaryInstruction(for length: AISummaryLength) -> String {
        switch length {
        case .short:
            return "Summarize emails concisely in 2-4 sentences."
        case .medium:
            return "Generate a moderately detailed summary in 4-7 sentences covering key points and important context."
        case .full:
            return "Generate a complete, detailed summary that covers all major points in the email in 6-12 sentences."
        }
    }
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
