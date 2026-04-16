import SwiftUI
import WebKit
import AppKit

struct EmailCardView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var mailStore: MailStore
    @EnvironmentObject private var summaries: EmailSummaryService

    @State private var summaryColumnWidth: CGFloat = 280
    @State private var summaryColumnDragStartWidth: CGFloat?

    let thread: EmailThread
    private let summaryColumnMinWidth: CGFloat = 220
    private let summaryColumnMaxWidth: CGFloat = 520
    private let bodyColumnMinWidth: CGFloat = 280
    private let columnDividerWidth: CGFloat = 8

    private var message: EmailMessage { thread.leadMessage }
    private var visibleMessages: [EmailMessage] { thread.visibleMessages }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            accountBanner
            header
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(message.subject)
                    .font(.system(size: 20 + preferences.fontScale, weight: .semibold))
                    .lineLimit(2)

                Spacer()

                HStack(spacing: 6) {
                    Circle()
                        .fill(ageIndicatorColor())
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)

                    Text(relativeTimeSinceReceived())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            threadMetaRow
            contentArea
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
        .onAppear { summarizeLeadIfNeeded() }
        .onChange(of: message.id) { _, _ in summarizeLeadIfNeeded() }
        .onChange(of: preferences.aiSummaryLength) { _, _ in summarizeLeadIfNeeded() }
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
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(ageIndicatorColor(), in: Capsule(style: .continuous))
                    .foregroundStyle(.white)
                HStack(spacing: 6) {
                    Text(message.senderEmail)
                    Text("(\(formatFullDate(message.receivedAt)))")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12 + preferences.fontScale))
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var threadMetaRow: some View {
        HStack(spacing: 8) {
            Label(thread.messageCount == 1 ? "1 message" : "\(thread.messageCount) messages", systemImage: "square.stack.3d.up")
                .font(.caption.weight(.semibold))

            if thread.unreadCount > 0 {
                Label(thread.unreadCount == 1 ? "1 unread" : "\(thread.unreadCount) unread", systemImage: "circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
            }

            if !thread.participants.isEmpty {
                Text(thread.participants.prefix(3).joined(separator: "  |  "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let snoozedUntil = message.snoozedUntil, snoozedUntil > Date() {
                let snoozeLabel = formatSnoozeDate(snoozedUntil)
                Label("Wakes \(snoozeLabel)", systemImage: "zzz")
                    .font(.system(size: 11 + preferences.fontScale, weight: .medium))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Snoozed until \(snoozeLabel)")
            }
            if thread.hasPinnedMessages {
                Label("Pinned", systemImage: "pin.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.blue)
                    .accessibilityLabel("Pinned")
            }
            if visibleMessages.contains(where: { $0.isStarred }) {
                Label("Starred", systemImage: "star.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Starred")
            }
            if visibleMessages.contains(where: { $0.isImportant }) {
                Label("Important", systemImage: "exclamationmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Important")
            }

            Spacer()
        }
        .font(.system(size: 12 + preferences.fontScale))
    }

    private var account: MailAccount? {
        mailStore.accounts.first(where: { $0.id == message.accountID })
    }

    private var shouldShowBody: Bool {
        if sanitizedHTMLBody(for: message) != nil {
            return true
        }
        let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return false }

        let preview = message.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.caseInsensitiveCompare(body) != .orderedSame
    }

    private var shouldRenderHTMLBody: Bool {
        preferences.emailBodyDisplayMode == .renderedHTML && sanitizedHTMLBody(for: message) != nil
    }

    @ViewBuilder
    private var contentArea: some View {
        if shouldShowBody || visibleMessages.count > 1 {
            if preferences.aiMode != .off {
                GeometryReader { proxy in
                    let clampedSummaryWidth = clampedSummaryWidth(for: proxy.size.width)
                    HStack(alignment: .top, spacing: 0) {
                        bodySection
                            .frame(
                                width: max(bodyColumnMinWidth, proxy.size.width - clampedSummaryWidth - columnDividerWidth),
                                alignment: .topLeading
                            )

                        Rectangle()
                            .fill(.clear)
                            .frame(width: columnDividerWidth)
                            .contentShape(Rectangle())
                            .overlay {
                                Capsule(style: .continuous)
                                    .fill(.separator.opacity(0.9))
                                    .frame(width: 3, height: 34)
                            }
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        let start = summaryColumnDragStartWidth ?? clampedSummaryWidth
                                        if summaryColumnDragStartWidth == nil {
                                            summaryColumnDragStartWidth = start
                                        }
                                        summaryColumnWidth = clamped(
                                            start - value.translation.width,
                                            min: summaryColumnMinWidth,
                                            max: maxSummaryWidth(for: proxy.size.width)
                                        )
                                    }
                                    .onEnded { _ in
                                        summaryColumnDragStartWidth = nil
                                    }
                            )

                        summarySection
                            .frame(width: clampedSummaryWidth, alignment: .topLeading)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                bodySection
            }
        } else if preferences.aiMode != .off {
            HStack(alignment: .top, spacing: 12) {
                Spacer(minLength: 0)
                summarySection
                    .frame(width: 280, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            Spacer(minLength: 0)
        }
    }

    private func maxSummaryWidth(for totalWidth: CGFloat) -> CGFloat {
        max(summaryColumnMinWidth, min(summaryColumnMaxWidth, totalWidth - bodyColumnMinWidth - columnDividerWidth))
    }

    private func clampedSummaryWidth(for totalWidth: CGFloat) -> CGFloat {
        clamped(summaryColumnWidth, min: summaryColumnMinWidth, max: maxSummaryWidth(for: totalWidth))
    }

    private func clamped(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.max(lower, Swift.min(value, upper))
    }

    @ViewBuilder
    private var bodySection: some View {
        if visibleMessages.count > 1 {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(visibleMessages, id: \.id) { threadMessage in
                        conversationMessageCard(threadMessage)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else if shouldRenderHTMLBody, let htmlBody = sanitizedHTMLBody(for: message) {
            EmailHTMLBodyView(html: htmlBody)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                Text(displayBody(for: message))
                    .font(.system(size: 14 + preferences.fontScale))
                    .foregroundStyle(.primary)
                    .lineLimit(nil)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func conversationMessageCard(_ threadMessage: EmailMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(threadMessage.senderName)
                        .font(.system(size: 13 + preferences.fontScale, weight: .semibold))
                    Text(formatFullDate(threadMessage.receivedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if threadMessage.id == message.id {
                    Label("Latest", systemImage: "clock.badge.checkmark")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.thinMaterial, in: Capsule(style: .continuous))
                } else if !threadMessage.isRead {
                    Label("Unread", systemImage: "circle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.blue)
                }
            }

            if let htmlBody = sanitizedHTMLBody(for: threadMessage),
               threadMessage.id == message.id,
               preferences.emailBodyDisplayMode == .renderedHTML {
                EmailHTMLBodyView(html: htmlBody)
                    .frame(minHeight: 220, maxHeight: 320, alignment: .topLeading)
            } else {
                Text(displayBody(for: threadMessage))
                    .font(.system(size: 14 + preferences.fontScale))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(lineColor(for: threadMessage), lineWidth: 1)
        }
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
            ScrollView(.vertical, showsIndicators: true) {
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
                        .fixedSize(horizontal: false, vertical: true)
                    Text(result.summary.body)
                        .font(.system(size: 13 + preferences.fontScale))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if preferences.aiSpamWarningsEnabled {
                        spamLikelihoodView(for: result.summary)
                    }
                    if preferences.aiSpamWarningsEnabled, result.summary.isPotentialSpam {
                        Text(result.summary.spamReason ?? "This message shows spam or phishing-like signals in its sender, metadata, or content.")
                            .font(.system(size: 12 + preferences.fontScale, weight: .semibold))
                            .foregroundStyle(spamIndicatorColor(for: result.summary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !result.summary.actionItems.isEmpty {
                        Text("Action items: \(result.summary.actionItems.joined(separator: "; "))")
                            .font(.system(size: 12 + preferences.fontScale))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let note = result.note, !note.isEmpty {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
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

    private func summarizeLeadIfNeeded() {
        if preferences.aiMode != .off {
            summaries.summarizeIfNeeded(message, length: preferences.aiSummaryLength)
        }
    }

    private func formatFullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formatSnoozeDate(_ date: Date) -> String {
        let now = Date()
        let components = Calendar.current.dateComponents([.minute, .hour, .day], from: now, to: date)
        if let days = components.day, days >= 1 {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        if let hours = components.hour, hours > 0 { return "in \(hours)h" }
        if let minutes = components.minute, minutes > 0 { return "in \(minutes)m" }
        return "soon"
    }

    private func relativeTimeSinceReceived() -> String {
        let now = Date()
        let components = Calendar.current.dateComponents([.minute, .hour, .day, .weekOfYear, .month, .year], from: message.receivedAt, to: now)

        if let years = components.year, years > 0 { return "\(years)y ago" }
        if let months = components.month, months >= 3 { return "Over 3 months ago" }
        if let months = components.month, months >= 1 { return "\(months)mo ago" }
        if let weeks = components.weekOfYear, weeks >= 1 { return "\(weeks)w ago" }
        if let days = components.day, days >= 1 { return "\(days)d ago" }
        if let hours = components.hour, hours > 0 { return "\(hours)h ago" }
        if let minutes = components.minute, minutes > 0 { return "\(minutes)m ago" }
        return "Just now"
    }

    private func ageIndicatorColor() -> Color {
        let now = Date()
        let components = Calendar.current.dateComponents([.day, .weekOfYear, .month], from: message.receivedAt, to: now)

        if let months = components.month, months >= 3 { return .gray }
        if let months = components.month, months >= 1 { return .brown }
        if let weeks = components.weekOfYear, weeks >= 1 { return .orange }
        if let days = components.day, days >= 1 { return .yellow }
        return .green
    }

    private func sanitizedHTMLBody(for message: EmailMessage) -> String? {
        let value = message.htmlBody?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return nil }
        return HTMLContentCleaner.sanitizeHTMLForDisplay(
            value,
            blockTrackingPixels: preferences.blockTrackingPixels
        ) ?? value
    }

    private func displayBody(for message: EmailMessage) -> String {
        let trimmedBody = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBody.isEmpty {
            return trimmedBody
        }
        let trimmedPreview = message.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPreview.isEmpty ? "No message body available." : trimmedPreview
    }

    private func lineColor(for threadMessage: EmailMessage) -> Color {
        threadMessage.id == message.id ? ageIndicatorColor().opacity(0.45) : Color(nsColor: .separatorColor)
    }

    private func displayUrgency(_ value: String) -> String {
        switch value.lowercased() {
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        default: return "Info"
        }
    }

    private func spamIndicatorColor(for summary: EmailSummary) -> Color {
        summary.clampedSpamConfidence >= 0.85 ? .red : .orange
    }

    private func spamLikelihoodView(for summary: EmailSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Spam risk")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Text("\(spamRiskLabel(for: summary)) · \(spamLikelihoodPercent(for: summary))%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(spamIndicatorColor(for: summary))
            }

            ProgressView(value: summary.clampedSpamConfidence, total: 1.0)
                .progressViewStyle(.linear)
                .tint(spamIndicatorColor(for: summary))
                .controlSize(.small)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Spam risk \(spamRiskLabel(for: summary)), \(spamLikelihoodPercent(for: summary)) percent")
    }

    private func spamRiskLabel(for summary: EmailSummary) -> String {
        switch summary.clampedSpamConfidence {
        case ..<0.25:
            return "Low"
        case ..<0.65:
            return "Medium"
        case ..<0.85:
            return "Elevated"
        default:
            return "High"
        }
    }

    private func spamLikelihoodPercent(for summary: EmailSummary) -> Int {
        Int((summary.clampedSpamConfidence * 100).rounded())
    }
}

private struct EmailHTMLBodyView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = false
        webView.loadHTMLString(Self.wrapHTML(html), baseURL: nil)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.loadHTMLString(Self.wrapHTML(html), baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private static func wrapHTML(_ rawHTML: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data: cid: https: http:;">
        <style>
        :root { color-scheme: light dark; }
        html, body {
          margin: 0;
          padding: 0;
          font: -apple-system-body;
          line-height: 1.45;
          overflow-wrap: anywhere;
        }
        body { padding: 2px 1px; }
        img, table, pre, blockquote {
          max-width: 100% !important;
          height: auto !important;
        }
        </style>
        </head>
        <body>\(rawHTML)</body>
        </html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            let scheme = url.scheme?.lowercased()

            switch scheme {
            case "about", "data":
                return .allow
            case "http", "https", "mailto":
                if navigationAction.navigationType == .linkActivated {
                    NSWorkspace.shared.open(HTMLContentCleaner.untrackedDestination(from: url))
                }
                return .cancel
            default:
                return .cancel
            }
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
