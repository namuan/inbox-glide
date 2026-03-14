import SwiftUI

struct QuickAssistView: View {
    @EnvironmentObject private var mailStore: MailStore
    @EnvironmentObject private var summaries: EmailSummaryService
    @EnvironmentObject private var ai: AIReplyService
    @EnvironmentObject private var preferences: PreferencesStore

    let message: EmailMessage

    private var thread: EmailThread? {
        mailStore.thread(containing: message.id)
    }

    @State private var summaryText: String = ""
    @State private var suggestedReply: String = ""
    @State private var isGeneratingReply: Bool = false
    @State private var opacity: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                    .font(.system(size: 14))

                Text("Quick Assist")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                HStack(spacing: 4) {
                    Circle()
                        .fill(.secondary.opacity(0.3))
                        .frame(width: 4, height: 4)
                    Circle()
                        .fill(.secondary.opacity(0.3))
                        .frame(width: 4, height: 4)
                    Circle()
                        .fill(.secondary.opacity(0.3))
                        .frame(width: 4, height: 4)
                }
            }

            Divider()
                .opacity(0.5)

            if let thread, thread.messageCount > 1 {
                Label("\(thread.messageCount) messages in thread", systemImage: "square.stack.3d.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                    .opacity(0.5)
            }

            summarySection

            if !suggestedReply.isEmpty {
                Divider()
                    .opacity(0.5)

                replySection
            } else if isGeneratingReply {
                Divider()
                    .opacity(0.5)

                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Generating reply...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.purple.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 6)
        .opacity(opacity)
        .scaleEffect(opacity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.15)) {
                opacity = 1
            }
            loadSummary()
            generateSuggestedReply()
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        if summaryText.isEmpty {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Loading summary...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(summaryText)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var replySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "bubble.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.purple)
                Text("Suggested Reply")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Text(suggestedReply)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Button("Copy Reply") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(suggestedReply, forType: .string)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.caption2)
        }
    }

    private func loadSummary() {
        switch summaries.state(for: message.id) {
        case .ready(let result):
            let headline = result.summary.headline
            let body = result.summary.body
            summaryText = "\(headline). \(body)"
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .loading:
            summaryText = ""
        case .idle:
            if preferences.aiMode != .off {
                summaries.summarizeIfNeeded(message, length: preferences.aiSummaryLength)
            }
            summaryText = message.preview.isEmpty
                ? message.subject
                : message.preview
        case .failed(let reason):
            summaryText = reason.isEmpty
                ? (message.preview.isEmpty ? message.subject : message.preview)
                : reason
        }
    }

    private func generateSuggestedReply() {
        guard preferences.aiMode != .off else { return }
        isGeneratingReply = true
        Task {
            let reply: String
            if let thread {
                reply = await ai.generateQuickReply(for: thread)
            } else {
                reply = await ai.generateQuickReply(for: message)
            }
            await MainActor.run {
                suggestedReply = reply
                isGeneratingReply = false
            }
        }
    }
}
