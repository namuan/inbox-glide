import AppKit
import SwiftUI

struct ActionPadView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var mailStore: MailStore
    @EnvironmentObject private var summaries: EmailSummaryService

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                actionButton(direction: .left)
                actionButton(direction: .down)
                actionButton(direction: .up)
                actionButton(direction: .right)
            }

            HStack(spacing: 10) {
                if let message = mailStore.currentMessage {
                    Button {
                        mailStore.perform(action: .skip, isSecondary: false, messageID: message.id)
                    } label: {
                        VStack(spacing: 6) {
                            shortcutBadge("⌘↓")
                            Label("Skip", systemImage: "arrow.uturn.right")
                        }
                        .frame(width: 110)
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.downArrow, modifiers: [.command])
                    .help("Move this email to the back of the stack")

                    Button {
                        mailStore.perform(action: .aiReply, isSecondary: false, messageID: message.id)
                    } label: {
                        VStack(spacing: 6) {
                            shortcutBadge("⌘R")
                            Label("AI Reply", systemImage: "sparkles")
                        }
                        .frame(width: 110)
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("r", modifiers: [.command])
                    .help("Generate a quick reply")

                    if preferences.aiMode != .off {
                        Button {
                            summaries.summarize(message, forceRefresh: true, length: preferences.aiSummaryLength)
                        } label: {
                            VStack(spacing: 6) {
                                shortcutBadge("⌘⇧S")
                                Label("Re-summarize", systemImage: "text.append")
                            }
                            .frame(width: 110)
                        }
                        .buttonStyle(.bordered)
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                        .help("Refresh on-device email summary")
                    }
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator, lineWidth: 1))
        .help("Hold Option for secondary actions")
    }

    private func actionButton(direction: GlideDirection) -> some View {
        let useSecondary = NSEvent.modifierFlags.contains(.option)
        let action = preferences.action(for: direction, useSecondary: useSecondary)

        return Button {
            mailStore.performGlide(direction, useSecondary: useSecondary)
        } label: {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Text(directionSymbol(for: direction))
                        .font(.caption.weight(.bold))
                    Text(direction.displayName)
                        .font(.caption2.weight(.semibold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(directionColor(for: direction).opacity(0.18), in: Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(directionColor(for: direction).opacity(0.55), lineWidth: 1)
                )

                Image(systemName: action.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                Text(action.displayName)
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(width: 110)
        }
        .buttonStyle(.bordered)
        .help("Swipe \(direction.displayName.lowercased()) to \(action.displayName)")
        .accessibilityLabel("\(direction.displayName): \(action.displayName)")
    }

    private func directionSymbol(for direction: GlideDirection) -> String {
        switch direction {
        case .left: return "←"
        case .right: return "→"
        case .up: return "↑"
        case .down: return "↓"
        }
    }

    private func directionColor(for direction: GlideDirection) -> Color {
        switch direction {
        case .left: return .red
        case .right: return .green
        case .up: return .blue
        case .down: return .orange
        }
    }

    private func shortcutBadge(_ value: String) -> some View {
        Text(value)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.thinMaterial, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(.separator.opacity(0.7), lineWidth: 1)
            )
    }
}
