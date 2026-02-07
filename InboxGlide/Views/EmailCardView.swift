import SwiftUI

struct EmailCardView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var mailStore: MailStore

    let message: EmailMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Text(message.subject)
                .font(.system(size: 20 + preferences.fontScale, weight: .semibold))
                .lineLimit(2)

            Text(message.preview)
                .font(.system(size: 14 + preferences.fontScale))
                .foregroundStyle(.secondary)
                .lineLimit(5)

            if !message.labels.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(message.labels.sorted(), id: \.self) { label in
                        Text(label)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.thinMaterial, in: Capsule(style: .continuous))
                    }
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 0)

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
                mailStore.perform(action: .aiReply, isSecondary: false, messageID: message.id)
            } label: {
                Label("AI Reply", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .help("Generate a quick reply")
        }
        .font(.system(size: 12 + preferences.fontScale))
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
