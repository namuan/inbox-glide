import AppKit
import SwiftUI

struct ActionPadView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var mailStore: MailStore

    var body: some View {
        HStack(spacing: 10) {
            actionButton(direction: .left)
            actionButton(direction: .down)
            actionButton(direction: .up)
            actionButton(direction: .right)
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
                Image(systemName: action.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                Text(action.displayName)
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(width: 110)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("\(direction.displayName): \(action.displayName)")
    }
}
