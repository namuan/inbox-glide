import SwiftUI

struct EmailCardView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var mailStore: MailStore
    @EnvironmentObject private var summaries: EmailSummaryService

    let message: EmailMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            accountBanner
            header
            Text(message.subject)
                .font(.system(size: 20 + preferences.fontScale, weight: .semibold))
                .lineLimit(2)

            Text(message.preview)
                .font(.system(size: 14 + preferences.fontScale))
                .foregroundStyle(.secondary)
                .lineLimit(5)

            if preferences.aiMode != .off {
                summarySection
            }

            if shouldShowBody {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(message.body)
                        .font(.system(size: 14 + preferences.fontScale))
                        .foregroundStyle(.primary)
                        .lineLimit(nil)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                Spacer(minLength: 0)
            }

            footer
        }
        .padding(preferences.cardPadding)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 18, x: 0, y: 10)
        .accessibilityElement(children: .contain)
        .onAppear {
            if preferences.aiMode != .off {
                summaries.summarizeIfNeeded(message)
            }
        }
        .onChange(of: message.id) { _, _ in
            if preferences.aiMode != .off {
                summaries.summarizeIfNeeded(message)
            }
        }
    }

    private var accountBanner: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(hex: account?.colorHex ?? "#2563EB") ?? .accentColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            Text(account?.displayName ?? "Unknown Account")
                .font(.caption.weight(.semibold))

            Text(account?.emailAddress ?? "No account")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Text(account?.provider.displayName ?? "Account")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.thinMaterial, in: Capsule(style: .continuous))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(message.senderName)
                    .font(.system(size: 13 + preferences.fontScale, weight: .semibold))
                Text(message.senderEmail)
                    .font(.system(size: 12 + preferences.fontScale))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(message.receivedAt, style: .date)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if message.isStarred {
                Label("Starred", systemImage: "star.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Starred")
            }
            if message.isImportant {
                Label("Important", systemImage: "exclamationmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Important")
            }

            Spacer()

            Button {
                mailStore.perform(action: .skip, isSecondary: false, messageID: message.id)
            } label: {
                Label("Skip", systemImage: "arrow.uturn.right")
            }
            .buttonStyle(.bordered)
            .help("Move this email to the back of the stack")

            Button {
                mailStore.perform(action: .aiReply, isSecondary: false, messageID: message.id)
            } label: {
                Label("AI Reply", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .help("Generate a quick reply")

            if preferences.aiMode != .off {
                Button {
                    summaries.summarize(message, forceRefresh: true)
                } label: {
                    Label("Re-summarize", systemImage: "text.append")
                }
                .buttonStyle(.bordered)
                .help("Refresh on-device email summary")
            }
        }
        .font(.system(size: 12 + preferences.fontScale))
    }

    private var account: MailAccount? {
        mailStore.accounts.first(where: { $0.id == message.accountID })
    }

    private var shouldShowBody: Bool {
        let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return false }

        let preview = message.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.caseInsensitiveCompare(body) != .orderedSame
    }

    @ViewBuilder
    private var summarySection: some View {
        switch summaries.state(for: message.id) {
        case .idle:
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                Text("Preparing summary…")
                    .font(.system(size: 13 + preferences.fontScale))
                    .foregroundStyle(.secondary)
            }
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Summarizing on device…")
                    .font(.system(size: 13 + preferences.fontScale))
                    .foregroundStyle(.secondary)
            }
        case .failed(let reason):
            Text(reason)
                .font(.system(size: 13 + preferences.fontScale))
                .foregroundStyle(.red)
        case .ready(let result):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label(result.source == .foundationModel ? "On-device summary" : "Fallback summary", systemImage: "doc.text.magnifyingglass")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(displayUrgency(result.summary.urgency))
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.thinMaterial, in: Capsule(style: .continuous))
                }
                Text(result.summary.headline)
                    .font(.system(size: 15 + preferences.fontScale, weight: .semibold))
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text(result.summary.body)
                    .font(.system(size: 13 + preferences.fontScale))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .truncationMode(.tail)
                if !result.summary.actionItems.isEmpty {
                    Text("Action items: \(result.summary.actionItems.joined(separator: "; "))")
                        .font(.system(size: 12 + preferences.fontScale))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                if let note = result.note, !note.isEmpty {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 1)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Email summary")
        }
    }

    private func displayUrgency(_ value: String) -> String {
        switch value.lowercased() {
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        default: return "Info"
        }
    }
}

private struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        Flow(spacing: spacing) {
            content
        }
    }
}

private struct Flow<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder var content: Content

    init(spacing: CGFloat, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        GeometryReader { geo in
            build(width: geo.size.width)
        }
        .frame(minHeight: 0)
    }

    private func build(width: CGFloat) -> some View {
        var x: CGFloat = 0
        var y: CGFloat = 0

        return ZStack(alignment: .topLeading) {
            content
                .alignmentGuide(.leading) { d in
                    if x + d.width > width {
                        x = 0
                        y -= d.height + spacing
                    }
                    let result = x
                    x += d.width + spacing
                    return result
                }
                .alignmentGuide(.top) { d in
                    let result = y
                    return result
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard hex.hasPrefix("#") else { return nil }
        let start = hex.index(hex.startIndex, offsetBy: 1)
        let str = String(hex[start...])
        guard str.count == 6, let val = Int(str, radix: 16) else { return nil }
        let r = Double((val >> 16) & 0xFF) / 255.0
        let g = Double((val >> 8) & 0xFF) / 255.0
        let b = Double(val & 0xFF) / 255.0
        self = Color(red: r, green: g, blue: b)
    }
}
