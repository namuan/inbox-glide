# RFC-2025-001: Email Summarization App Using Apple Foundation Models

## 1. Abstract

This RFC defines the architecture, API usage patterns, edge case handling, and implementation guidelines for an iOS/macOS application that summarises emails on-device using Apple's Foundation Models framework, introduced with Apple Intelligence at WWDC 2025. The application leverages the ~3B parameter on-device language model to provide private, offline-capable email summarization without data leaving the user's device.

The framework is available on iOS 26+, iPadOS 26+, macOS 26+, and visionOS 26+, and requires an Apple Intelligence-compatible device with Apple Intelligence enabled.

---

## 2. Motivation & Goals

### 2.1 Problem Statement

Users receive high volumes of email daily. Manually reading and triaging these messages is time-consuming. Cloud-based summarization services (e.g. OpenAI, Gemini) raise significant privacy concerns as email content is transmitted to third-party servers.

### 2.2 Goals

- Provide accurate, concise email summaries fully on-device
- Leverage Apple Foundation Models for zero-cost inference with no API keys
- Ensure user email content never leaves the device
- Support offline operation with graceful degradation
- Deliver structured, typed summaries using Guided Generation (`@Generable`)
- Stream summaries progressively for low-latency perceived performance
- Handle all edge cases gracefully with clear user feedback

### 2.3 Non-Goals

- Replying to, composing, or sending emails
- Synchronizing email state with mail servers (Mail app integration handles this)
- Supporting devices or OS versions that do not support Apple Intelligence
- Acting as a general-purpose chatbot or Q&A assistant over email

---

## 3. Technical Background

### 3.1 Apple Foundation Models Framework

The Foundation Models framework provides a Swift-native API to access Apple's on-device LLM. Key characteristics:

- **Model size:** approximately 3 billion parameters with aggressive 2-bit quantization
- **Architecture:** Grouped-query attention, 49K vocabulary, KV-cache sharing (37.5% memory reduction)
- **Inference:** Runs on Apple Neural Engine (ANE) and GPU via Apple Silicon
- **Cost:** Zero cost for inference; no API key required
- **Privacy:** All data processed on-device; no telemetry sent to Apple
- **Availability:** iOS 26+, iPadOS 26+, macOS 26+, visionOS 26+

### 3.2 Key APIs Used

#### 3.2.1 SystemLanguageModel

The entry point for checking model availability before any inference:

```swift
import FoundationModels

let model = SystemLanguageModel.default
guard model.isAvailable else {
    // Handle unavailability — show onboarding or fallback
    return
}
```

#### 3.2.2 LanguageModelSession

Stateful session object that processes prompts and maintains conversation context. Each session records a transcript of all prompts and responses.

#### 3.2.3 @Generable and @Guide Macros

Guided Generation enables type-safe structured output from the model. The `@Generable` macro generates a compile-time schema and deserializer. `@Guide` constrains or annotates individual properties.

```swift
@Generable
struct EmailSummary {
    @Guide(description: "One-sentence summary of the email")
    var headline: String

    @Guide(description: "2-4 sentence summary of key information")
    var body: String

    @Guide(.anyOf(["action-required", "informational", "promotional", "newsletter", "spam"]))
    var category: String

    @Guide(description: "Comma-separated action items if any, else empty")
    var actionItems: [String]

    @Guide(.anyOf(["low", "medium", "high"]))
    var urgency: String
}
```

#### 3.2.4 Streaming Responses

The `streamResponse` API delivers partial `@Generable` objects progressively, enabling UI updates as content generates:

```swift
let stream = session.streamResponse(
    to: prompt,
    generating: EmailSummary.self
)

for try await partial in stream {
    await MainActor.run { updateUI(with: partial) }
}
```

#### 3.2.5 Tool Calling

Tools allow the model to invoke app-defined Swift functions to retrieve additional context. For email summarization, tools can be used to fetch thread history or calendar context.

---

## 4. Application Architecture

### 4.1 Layers

The application is structured in four distinct layers:

- **Presentation Layer** — SwiftUI views that display summaries and handle user interaction
- **Summarization Layer** — Swift actors managing `LanguageModelSession` lifecycle and prompt construction
- **Mail Integration Layer** — Access to `EmailMessage` models via MailKit or custom sync
- **Persistence Layer** — SwiftData for caching summaries and user preferences

### 4.2 Core Data Model

```swift
@Generable
struct EmailSummary {
    var headline: String
    var body: String
    var category: String
    var actionItems: [String]
    var urgency: String
}

struct EmailMessage {
    let id: String
    let subject: String
    let sender: String
    let body: String
    let receivedDate: Date
    let isThreaded: Bool
    let threadMessages: [EmailMessage]
}
```

### 4.3 EmailSummarizer Actor

```swift
actor EmailSummarizer {
    private let session: LanguageModelSession

    init() {
        let instructions = """
            You are an email summarization assistant.
            Summarize emails concisely, extract action items,
            classify category, and assess urgency.
            Focus only on the email content provided.
            Do not infer or hallucinate information not present.
            """
        self.session = LanguageModelSession(instructions: instructions)
    }

    func summarize(_ email: EmailMessage) async throws -> EmailSummary {
        let prompt = buildPrompt(for: email)
        let response = try await session.respond(
            to: prompt, generating: EmailSummary.self
        )
        return response.content
    }
}
```

---

## 5. Prompt Engineering

### 5.1 System Instructions

The system instructions define the model's role and constrain its behavior to prevent hallucination and scope creep. Instructions must explicitly tell the model to operate only on provided content and not use general world knowledge.

### 5.2 Prompt Template

```swift
func buildPrompt(for email: EmailMessage) -> String {
    let threadContext = email.isThreaded
        ? "This is part of a thread with \(email.threadMessages.count) prior messages."
        : ""
    return """
    Summarize the following email. \(threadContext)
    From: \(email.sender)
    Subject: \(email.subject)
    Received: \(email.receivedDate.formatted())
    ---
    \(email.body.prefix(4000))
    """
}
```

### 5.3 Context Window Constraints

The model operates with a limited context window. Email bodies must be truncated or chunked to avoid exceeding the limit. The recommended limit for email body input is 4,000 characters. For very long emails, a hierarchical summarization strategy is used: chunk the body into 4,000-character segments, summarize each chunk, then summarize the summaries.

---

## 6. Edge Cases & Mitigations

### 6.1 Model Unavailability

The most critical edge case is that the Foundation Models framework is not available on all devices or configurations.

#### 6.1.1 Apple Intelligence Disabled

Users may have Apple Intelligence disabled in Settings. The app should detect this via `SystemLanguageModel.default.availability` and show an actionable onboarding screen with a deep link to the Apple Intelligence settings page.

```swift
switch SystemLanguageModel.default.availability {
case .available:
    // Proceed
case .unavailable(.appleIntelligenceNotEnabled):
    showEnableAppleIntelligencePrompt()
case .unavailable(.deviceNotSupported):
    showUnsupportedDeviceMessage()
case .unavailable(.modelNotReady):
    showModelDownloadingMessage()
case .unavailable(let reason):
    showGenericUnavailableMessage(reason: reason)
}
```

#### 6.1.2 Device Not Supported

Devices without Apple Silicon (or pre-A17 Pro chips for iPhone) do not support Apple Intelligence. The app should degrade gracefully to a rule-based preview (first 3 sentences of the email) with clear messaging that AI summarization is unavailable on this device.

#### 6.1.3 Model Downloading / Not Ready

After enabling Apple Intelligence, the model may take time to download. The app should poll availability with exponential backoff and display an appropriate loading state.

```swift
func waitForModelAvailability() async {
    var delay: Double = 2.0
    for _ in 0..<6 {
        if SystemLanguageModel.default.isAvailable { return }
        try? await Task.sleep(for: .seconds(delay))
        delay = min(delay * 2, 60)
    }
}
```

### 6.2 Context Window Overflow

Extremely long emails (e.g. newsletters, legal agreements, HTML email dumps) may exceed the model's effective context window.

- Truncate email body to 4,000 characters by default
- For structured HTML emails, strip tags first using `NSAttributedString` or a Swift HTML parser before sending to the model
- For emails exceeding 10,000 characters, use hierarchical summarization: split into overlapping chunks, summarize each, then produce a meta-summary
- Inform the user when truncation occurs ("Summarizing first portion of long email")

### 6.3 Empty or Minimal Content Emails

Emails with only a subject line, a single word, an image attachment with no text, or a forwarding notice with no body require special handling before invoking the model:

```swift
func summarize(_ email: EmailMessage) async throws -> EmailSummary {
    let bodyText = email.body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard bodyText.count >= 50 else {
        return EmailSummary.minimal(subject: email.subject)
    }
    // proceed with model
}
```

### 6.4 Non-English Emails

Apple Intelligence supports English, French, German, Italian, Portuguese (Brazil), Spanish, Chinese (Simplified), Japanese, and Korean as of the initial release. For unsupported languages, the app should detect the language using `NLLanguageRecognizer` before sending to the model and either warn the user or pass through with a disclaimer.

```swift
import NaturalLanguage

let recognizer = NLLanguageRecognizer()
recognizer.processString(email.body)
let dominantLanguage = recognizer.dominantLanguage
let supportedLanguages: Set<NLLanguage> = [
    .english, .french, .german, .italian, .spanish,
    .portuguese, .simplifiedChinese, .japanese, .korean
]
let isSupported = supportedLanguages.contains(dominantLanguage ?? .undetermined)
```

### 6.5 Concurrent Summarization Requests

The user may open multiple emails rapidly, triggering multiple concurrent summarization requests. Since `LanguageModelSession` is stateful and the on-device model has limited resources, excessive concurrent sessions can degrade performance or cause errors.

- Use a global actor or serial queue to serialize summarization requests
- Implement a request queue with configurable concurrency (recommended: 1 concurrent session at a time)
- Cache completed summaries in SwiftData to avoid redundant inference
- Implement request deduplication: if a summary for email ID X is in-flight, return the same `Task` rather than starting a new one

### 6.6 Thermal Throttling & Performance

Sustained LLM inference on-device generates heat. iOS may throttle performance during thermal events, causing inference to slow or time out.

- Use `ProcessInfo.thermalState` to check thermal conditions before starting inference
- Defer non-urgent batch summarization when `thermalState` is `.serious` or `.critical`
- Show a gentle message ("Summarization temporarily slowed to protect your device") rather than an error
- Use `session.prewarm()` during idle periods to reduce cold-start latency

```swift
if ProcessInfo.processInfo.thermalState == .critical {
    deferSummarizationQueue()
    return
}
```

### 6.7 Model Errors & Inference Failures

The model may fail to generate a valid response due to the prompt being flagged, context length issues, or internal errors. All session calls must be wrapped in `do-catch`:

```swift
do {
    let response = try await session.respond(to: prompt, generating: EmailSummary.self)
    return response.content
} catch LanguageModelError.guardrailViolation {
    // Email content triggered safety filter
    return EmailSummary.redacted()
} catch LanguageModelError.contextLengthExceeded {
    // Retry with truncated prompt
    return try await summarizeWithTruncation(email)
} catch {
    // Generic error — show fallback summary
    return EmailSummary.fallback(subject: email.subject)
}
```

### 6.8 Safety Filter / Content Policy Violations

Phishing emails, spam with disturbing content, or malicious HTML may trigger the model's content guardrails. The app should catch guardrail violations and return a "Content could not be summarized" placeholder without crashing or exposing raw model errors to the user.

### 6.9 Thread Summarization Complexity

Email threads with many messages create large combined contexts. Strategies for thread summarization:

- Include only the most recent N messages (default: 5) from the thread in the prompt
- Summarize the thread progressively: summarize older messages first, then incorporate the summary into the prompt for newer messages
- Deduplicate quoted content (common in reply chains) before passing to the model

### 6.10 Attachments

The Foundation Models framework processes text only. Emails with only attachments (PDFs, images, calendar invites) and no text body require special handling:

- Detect attachment-only emails and show a specialised UI ("This email contains an attachment — no text to summarize")
- For PDF attachments, consider extracting text via PDFKit and summarizing the PDF content as a separate action
- For calendar invites (`.ics` files), parse structured fields directly rather than using the LLM

### 6.11 Privacy Sensitive Content

Emails may contain passwords, OTPs, financial data, and medical information. Since summarization is fully on-device, data never leaves the device. However, cached summaries in SwiftData should:

- Be excluded from iCloud backup by default
- Be stored with Data Protection level `.completeUnlessOpen`
- Be cleared when the user logs out of the app or revokes Mail access

### 6.12 Stale Summaries & Cache Invalidation

The cache must be invalidated when:

- The email body changes
- The Apple Intelligence model is updated (OS update may change model version)
- The user explicitly requests a re-summarization

Store a version fingerprint (hash of email body + model version identifier) with each cached summary to detect staleness.

### 6.13 Accessibility

Summaries must be fully accessible:

- All summary text must be VoiceOver-compatible with meaningful `accessibilityLabel` values
- Streaming text updates must use `accessibilityAnnouncement` to avoid overwhelming VoiceOver
- Respect the user's Reduce Motion preference when animating streaming text

### 6.14 Low Memory Conditions

On-device LLM inference requires significant memory. The app must handle memory pressure:

- Subscribe to `UIApplicationDelegate.applicationDidReceiveMemoryWarning` and cancel in-flight summarization tasks
- Release `LanguageModelSession` instances that are not actively in use
- Use weak references to session objects where appropriate

---

## 7. Security & Privacy

- All inference is 100% on-device — no email data is transmitted to any server
- Cached summaries stored with `NSFileProtectionCompleteUnlessOpen` data protection class
- Summaries excluded from iCloud backup
- App does not log email content to any analytics service
- Summarization session transcript is cleared on app backgrounding for sensitive modes
- The app requests minimum Mail permissions: read-only access, no send capability

---

## 8. References

- [Apple Developer Documentation: Foundation Models](https://developer.apple.com/documentation/FoundationModels)
- WWDC 2025 Session 286: Meet the Foundation Models framework
- WWDC 2025 Session 301: Deep dive into the Foundation Models framework
- WWDC 2025 Session 259: Code-along: Bring on-device AI to your app using the Foundation Models framework
- Apple Machine Learning Research: Apple Intelligence Foundation Language Models Tech Report 2025
- Apple Newsroom: Apple's Foundation Models framework unlocks new intelligent app experiences (September 2025)

---

*End of RFC-2025-001*