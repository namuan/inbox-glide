import SwiftUI
import WebKit

struct EmailCardView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var mailStore: MailStore
    @EnvironmentObject private var summaries: EmailSummaryService

    @State private var summaryColumnWidth: CGFloat = 280
    @State private var summaryColumnDragStartWidth: CGFloat?

    let message: EmailMessage
    private let summaryColumnMinWidth: CGFloat = 220
    private let summaryColumnMaxWidth: CGFloat = 520
    private let bodyColumnMinWidth: CGFloat = 280
    private let columnDividerWidth: CGFloat = 8

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
        .onAppear {
            if preferences.aiMode != .off {
                summaries.summarizeIfNeeded(message, length: preferences.aiSummaryLength)
            }
        }
        .onChange(of: message.id) { _, _ in
            if preferences.aiMode != .off {
                summaries.summarizeIfNeeded(message, length: preferences.aiSummaryLength)
            }
        }
        .onChange(of: preferences.aiSummaryLength) { _, _ in
            if preferences.aiMode != .off {
                summaries.summarizeIfNeeded(message, length: preferences.aiSummaryLength)
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
                    summaries.summarize(message, forceRefresh: true, length: preferences.aiSummaryLength)
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
        if sanitizedHTMLBody != nil {
            return true
        }
        let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return false }

        let preview = message.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.caseInsensitiveCompare(body) != .orderedSame
    }

    private var shouldRenderHTMLBody: Bool {
        preferences.emailBodyDisplayMode == .renderedHTML && sanitizedHTMLBody != nil
    }

    private var sanitizedHTMLBody: String? {
        let value = message.htmlBody?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return nil }
        return value
    }

    @ViewBuilder
    private var contentArea: some View {
        if shouldShowBody {
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
        Group {
            if shouldRenderHTMLBody, let htmlBody = sanitizedHTMLBody {
                EmailHTMLBodyView(html: htmlBody)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(message.body)
                        .font(.system(size: 14 + preferences.fontScale))
                        .foregroundStyle(.primary)
                        .lineLimit(nil)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
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

    private func displayUrgency(_ value: String) -> String {
        switch value.lowercased() {
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        default: return "Info"
        }
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
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data: cid:;">
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
            switch url.scheme?.lowercased() {
            case "about", "data":
                return .allow
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
