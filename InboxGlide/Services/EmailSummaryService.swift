import Foundation
import NaturalLanguage
import SwiftUI

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
        let normalized = Self.normalizedBody(textBody: email.body, htmlBody: email.htmlBody)
        let trimmedBody = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        let spamAssessment = Self.inferSpamAssessment(for: email, normalizedBody: trimmedBody)

        guard !trimmedBody.isEmpty else {
            return EmailSummaryResult(
                summary: .minimal(subject: subject, spamConfidence: spamAssessment.confidence, spamReason: spamAssessment.reason),
                source: .fallback,
                note: "No text body to summarize."
            )
        }

        guard trimmedBody.count >= 50 else {
            return EmailSummaryResult(
                summary: .minimal(subject: subject, spamConfidence: spamAssessment.confidence, spamReason: spamAssessment.reason),
                source: .fallback,
                note: "Email is too short for full summarization."
            )
        }

        let supportedLanguages: Set<NLLanguage> = [
            .english, .french, .german, .italian, .spanish, .portuguese,
            .simplifiedChinese, .japanese, .korean
        ]
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmedBody)
        if let language = recognizer.dominantLanguage, !supportedLanguages.contains(language) {
            let fallback = Self.fallbackSummary(for: email, subject: subject, body: trimmedBody, length: length)
            return EmailSummaryResult(summary: fallback, source: .fallback, note: "Language may be unsupported for on-device summarization.")
        }

        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical {
            let fallback = Self.fallbackSummary(for: email, subject: subject, body: trimmedBody, length: length)
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
                email: email,
                inputBody: inputBody,
                fullBody: trimmedBody,
                length: length,
                fallbackNote: note
            )
        }
        #endif

        let fallback = Self.fallbackSummary(for: email, subject: subject, body: trimmedBody, length: length)
        return EmailSummaryResult(summary: fallback, source: .fallback, note: note ?? "On-device model unavailable on this OS version.")
    }

    private static func prompt(for email: EmailMessage, subject: String, body: String) -> String {
        let preview = email.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        let labels = email.labels.isEmpty ? "None" : email.labels.joined(separator: ", ")
        let senderDomain = senderDomain(for: email.senderEmail) ?? "Unknown"
        return """
        Analyze and summarize the following email. Use only the metadata and content below.
        Assess whether it appears to be legitimate, promotional, or potentially spam/phishing.
        Avoid false positives for ordinary newsletters or marketing emails unless the content is deceptive or unsafe.
        Treat sender-domain mismatch, brand impersonation, fake security alerts, fake refund/payment recovery requests, coercive calls to action, and awkward corporate wording as strong phishing indicators.
        From: \(email.senderName) <\(email.senderEmail)>
        Sender domain: \(senderDomain)
        Subject: \(subject)
        Received: \(email.receivedAt.formatted(date: .abbreviated, time: .shortened))
        Labels: \(labels)
        Preview: \(preview.isEmpty ? "None" : preview)
        ---
        \(body)
        """
    }

    private static func normalizedBody(textBody: String, htmlBody: String?) -> String {
        let trimmedTextBody = textBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTextBody.isEmpty {
            if HTMLContentCleaner.sanitizeHTML(trimmedTextBody) != nil {
                return HTMLContentCleaner.extractDisplayText(fromHTML: trimmedTextBody)
            }
            return HTMLContentCleaner.cleanText(trimmedTextBody)
        }

        let trimmedHTMLBody = htmlBody?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedHTMLBody.isEmpty {
            return HTMLContentCleaner.extractDisplayText(fromHTML: trimmedHTMLBody)
        }

        return ""
    }

    private static func fallbackSummary(for email: EmailMessage, subject: String, body: String, length: AISummaryLength) -> EmailSummary {
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
        let spamAssessment = inferSpamAssessment(for: email, normalizedBody: body)
        let category = spamAssessment.confidence >= EmailSummary.spamWarningThreshold
            ? "spam"
            : inferCategory(subject: subject, body: body)
        return .fallback(
            subject: subject,
            body: summaryBody,
            actionItems: extractActionItems(from: body),
            category: category,
            urgency: inferUrgency(subject: subject, body: body),
            spamConfidence: spamAssessment.confidence,
            spamReason: spamAssessment.reason
        )
    }

    private static func inferSpamAssessment(for email: EmailMessage, normalizedBody: String) -> (confidence: Double, reason: String?) {
        let loweredLabels = email.labels.map { $0.lowercased() }
        if loweredLabels.contains(where: { $0.contains("spam") || $0.contains("junk") || $0.contains("phishing") }) {
            return (0.99, "The provider metadata already labels this message as spam.")
        }

        let subject = email.subject.lowercased()
        let preview = email.preview.lowercased()
        let body = normalizedBody.lowercased()
        let sender = "\(email.senderName)\n\(email.senderEmail)".lowercased()
        let combined = [subject, preview, body].joined(separator: "\n")
        let senderDomain = senderDomain(for: email.senderEmail)

        var confidence = 0.04
        var reasons: [String] = []

        let signalGroups: [(reason: String, terms: [String], weight: Double)] = [
            (
                "The message uses account-verification or password-reset language.",
                ["verify your account", "confirm your account", "reset your password", "password expires", "unusual sign-in", "account suspended", "account locked"],
                0.28
            ),
            (
                "The message pressures you with urgent or threatening language.",
                ["urgent action required", "immediately", "within 24 hours", "final warning", "act now", "avoid suspension", "respond today"],
                0.2
            ),
            (
                "The message requests sensitive payment or personal information.",
                ["social security", "bank account", "wire transfer", "gift card", "crypto", "payment failure", "billing information", "wallet phrase", "payment attempts", "unauthorized payment", "refund process", "reimbursement", "authorize refund", "financial position"],
                0.26
            ),
            (
                "The message pushes you to click a link, open an attachment, or download a file.",
                ["click the link", "click below", "open the attachment", "download the file", "scan the qr code", "enable macros", "view complete details", "approve reimbursement process", "authorize refund process"],
                0.18
            )
        ]

        for group in signalGroups {
            if containsAny(group.terms, in: combined) {
                confidence += group.weight
                reasons.append(group.reason)
            }
        }

        if containsAny(["lottery", "prize", "winner", "claim reward", "free money"], in: combined) {
            confidence += 0.24
            reasons.append("The message includes giveaway or prize-claim language.")
        }

        if let domain = senderDomain,
           domain.contains("xn--") || domain.hasSuffix(".zip") || domain.hasSuffix(".top") {
            confidence += 0.18
            reasons.append("The sender domain looks unusual.")
        }

        if let impersonatedBrand = matchedImpersonatedBrand(in: combined, senderDomain: senderDomain) {
            confidence += 0.62
            reasons.append("The email claims to be from \(impersonatedBrand.displayName), but the sender domain does not match.")
        }

        if containsAny(["security alert", "unusual activity", "suspicious account", "account restricted", "suspicious payment attempts", "unauthorized payment requests"], in: combined) {
            confidence += 0.22
            reasons.append("The message uses a fake security or account-compromise alert pattern.")
        }

        if containsAny(["refund", "reimbursement", "authorize refund", "approve reimbursement", "fund return"], in: combined),
           containsAny(["security alert", "unusual activity", "suspicious account", "unauthorized payment"], in: combined) {
            confidence += 0.18
            reasons.append("The email combines a scare tactic with a refund or reimbursement workflow.")
        }

        if containsAny(["client support group", "support team", "help resources"], in: combined),
           containsAny(["paypal", "apple", "microsoft", "amazon", "google", "bank"], in: combined) {
            confidence += 0.08
        }

        if containsAny(["unsubscribe", "newsletter", "sale", "discount", "limited time offer"], in: combined),
           confidence < EmailSummary.spamWarningThreshold {
            confidence = max(0.12, confidence - 0.08)
        }

        if containsAny(["ceo", "finance", "hr", "support", "security"], in: sender),
           containsAny(["gift card", "wire transfer", "password", "verify"], in: combined) {
            confidence += 0.12
            reasons.append("The sender identity and request pattern look mismatched.")
        }

        let clampedConfidence = min(max(confidence, 0), 0.99)
        let reason = reasons.isEmpty ? nil : reasons.prefix(2).joined(separator: " ")
        return (clampedConfidence, reason)
    }

    private static func containsAny(_ terms: [String], in text: String) -> Bool {
        terms.contains(where: { text.contains($0) })
    }

    private static func senderDomain(for senderEmail: String) -> String? {
        senderEmail.split(separator: "@").last.map { String($0).lowercased() }
    }

    private static func matchedImpersonatedBrand(in text: String, senderDomain: String?) -> (displayName: String, domainToken: String)? {
        guard let senderDomain else { return nil }

        let brands: [(displayName: String, mentions: [String], domainToken: String)] = [
            ("PayPal", ["paypal"], "paypal"),
            ("Apple", ["apple", "icloud", "app store"], "apple"),
            ("Microsoft", ["microsoft", "office 365", "outlook"], "microsoft"),
            ("Amazon", ["amazon", "prime"], "amazon"),
            ("Google", ["google", "gmail"], "google"),
            ("Bank", ["bank of america", "chase", "wells fargo", "citibank", "bank"], "bank")
        ]

        for brand in brands where containsAny(brand.mentions, in: text) {
            if !senderDomain.contains(brand.domainToken) {
                return (brand.displayName, brand.domainToken)
            }
        }

        return nil
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
        hasher.combine(email.senderName)
        hasher.combine(email.senderEmail)
        hasher.combine(email.subject)
        hasher.combine(email.preview)
        hasher.combine(email.body)
        hasher.combine(email.htmlBody)
        hasher.combine(email.labels.joined(separator: "|"))
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
        email: EmailMessage,
        inputBody: String,
        fullBody: String,
        length: AISummaryLength,
        fallbackNote: String?
    ) async -> EmailSummaryResult {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            let fallback = Self.fallbackSummary(for: email, subject: email.subject, body: fullBody, length: length)
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
        Assess spam risk using the sender, metadata, and message body.
        If an email claims to be from a well-known company but uses a mismatched sender domain, treat that as a major phishing signal.
        Give high spam confidence to fake security alerts, login warnings, payment or refund authorization requests, and suspicious reimbursement workflows.
        Return `spamConfidence` as a value from 0.0 to 1.0 and keep it low for ordinary promotions or newsletters unless the email appears deceptive, coercive, or unsafe.
        Provide a short `spamReason` only when there is a meaningful risk signal.
        Focus only on the provided content.
        Do not hallucinate or infer details not in the email.
        """

        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(
                to: Self.prompt(for: email, subject: email.subject, body: inputBody),
                generating: FoundationGeneratedEmailSummary.self
            )
            let generated = response.content
            let summary = EmailSummary(
                headline: generated.headline.trimmingCharacters(in: .whitespacesAndNewlines),
                body: generated.body.trimmingCharacters(in: .whitespacesAndNewlines),
                category: generated.category.trimmingCharacters(in: .whitespacesAndNewlines),
                actionItems: generated.actionItems.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                urgency: generated.urgency.trimmingCharacters(in: .whitespacesAndNewlines),
                spamConfidence: min(max(generated.spamConfidence, 0), 1),
                spamReason: Self.normalizedOptionalText(generated.spamReason)
            )
            return EmailSummaryResult(summary: summary, source: .foundationModel, note: fallbackNote)
        } catch {
            logger.warning(
                "Email summary generation failed, using fallback.",
                category: "EmailSummary",
                metadata: ["error": String(describing: error)]
            )
            let fallback = Self.fallbackSummary(for: email, subject: email.subject, body: fullBody, length: length)
            return EmailSummaryResult(summary: fallback, source: .fallback, note: fallbackNote ?? "Model generation failed, fallback used.")
        }
    }
    #endif

    private static func normalizedOptionalText(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

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

    @Guide(description: "A spam risk score from 0.0 for likely legitimate to 1.0 for highly suspicious or deceptive.")
    var spamConfidence: Double

    @Guide(description: "A short explanation of the most important spam or phishing signal. Return an empty string if no meaningful signal is present.")
    var spamReason: String
}
#endif
