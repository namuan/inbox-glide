import AppKit
import SwiftUI

struct DeckView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var mailStore: MailStore
    @EnvironmentObject private var keyEvents: KeyEventMonitor

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging: Bool = false

    var body: some View {
        ZStack {
            if let message = mailStore.currentMessage {
                cardStack(message: message)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState
            }
        }
        .onAppear {
            mailStore.rebuildDeck()
            keyEvents.start { event in
                handleKey(event)
            }
        }
        .onDisappear {
            keyEvents.stop()
        }
        .alert(item: $mailStore.errorAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .alert("Confirm Action", isPresented: Binding(get: {
            mailStore.pendingConfirmation != nil
        }, set: { newValue in
            if !newValue { mailStore.cancelPendingAction() }
        })) {
            Button("Cancel", role: .cancel) { mailStore.cancelPendingAction() }
            Button("Confirm", role: .destructive) { mailStore.confirmPendingAction() }
        } message: {
            if let pending = mailStore.pendingConfirmation {
                Text("\(pending.action.displayName) this email?")
            } else {
                Text("")
            }
        }
        .sheet(item: $mailStore.prompt) { prompt in
            MessagePromptView(prompt: prompt)
        }
        .sheet(item: $mailStore.composer) { presentation in
            ReplyComposerView(presentation: presentation)
        }
    }

    private func cardStack(message: EmailMessage) -> some View {
        let actionOverlay = overlayAction

        return ZStack {
            if mailStore.deckMessageIDs.count > 1 {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.thinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(.separator, lineWidth: 1)
                    )
                    .padding(.horizontal, 22)
                    .padding(.vertical, 22)
                    .offset(y: 10)
                    .opacity(0.6)
                    .accessibilityHidden(true)
            }

            EmailCardView(message: message)
                .padding(preferences.cardPadding)
                .offset(dragOffset)
                .rotationEffect(.degrees(Double(dragOffset.width) / 40.0))
                .overlay(actionOverlay)
                .gesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { value in
                            isDragging = true
                            dragOffset = value.translation
                        }
                        .onEnded { value in
                            isDragging = false
                            let direction = inferDirection(from: value.translation)
                            if let direction {
                                let useSecondary = NSEvent.modifierFlags.contains(.option)
                                let action = preferences.action(for: direction, useSecondary: useSecondary)
                                if action.isDestructive, action != .delete, preferences.confirmDestructiveActions {
                                    withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.85)) {
                                        dragOffset = .zero
                                    }
                                    mailStore.performGlide(direction, useSecondary: useSecondary)
                                    return
                                }

                                let fling = flingOffset(for: direction)
                                withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.85)) {
                                    dragOffset = fling
                                }

                                DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.18)) {
                                    dragOffset = .zero
                                    mailStore.performGlide(direction, useSecondary: useSecondary)
                                }
                            } else {
                                withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.85)) {
                                    dragOffset = .zero
                                }
                            }
                        }
                )
                .accessibilityHint("Use trackpad drag or arrow keys to glide")

            VStack {
                Spacer()
                ActionPadView()
                    .padding(.bottom, 18)
            }
        }
    }

    private var overlayAction: some View {
        Group {
            if let direction = inferDirection(from: dragOffset), abs(dragOffset.width) + abs(dragOffset.height) > 40 {
                let useSecondary = NSEvent.modifierFlags.contains(.option)
                let action = preferences.action(for: direction, useSecondary: useSecondary)

                HStack(spacing: 10) {
                    Image(systemName: action.systemImage)
                    Text(action.displayName)
                        .font(.headline)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(.separator, lineWidth: 1))
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: overlayAlignment(for: direction))
                .accessibilityHidden(true)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("All clear")
                .font(.title2)
                .fontWeight(.semibold)
            Text(emptyStateMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateMessage: String {
        if let selectedID = mailStore.selectedAccountID,
           let account = mailStore.accounts.first(where: { $0.id == selectedID }),
           account.provider == .yahoo {
            return "No Yahoo emails in view. Use Settings > Accounts > Sync Yahoo Inbox to refresh."
        }
        return "No emails in the current view."
    }

    private func inferDirection(from translation: CGSize) -> GlideDirection? {
        let threshold: CGFloat = 90
        if abs(translation.width) > abs(translation.height) {
            if translation.width > threshold { return .right }
            if translation.width < -threshold { return .left }
        } else {
            if translation.height < -threshold { return .up }
            if translation.height > threshold { return .down }
        }
        return nil
    }

    private func flingOffset(for direction: GlideDirection) -> CGSize {
        switch direction {
        case .left: return CGSize(width: -700, height: 0)
        case .right: return CGSize(width: 700, height: 0)
        case .up: return CGSize(width: 0, height: -500)
        case .down: return CGSize(width: 0, height: 500)
        }
    }

    private func overlayAlignment(for direction: GlideDirection) -> Alignment {
        switch direction {
        case .left: return .topLeading
        case .right: return .topTrailing
        case .up: return .top
        case .down: return .bottom
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        // Avoid hijacking arrow keys while typing.
        if let responder = NSApp.keyWindow?.firstResponder {
            if responder is NSTextView { return false }
        }

        let useSecondary = event.modifierFlags.contains(.option)
        switch event.keyCode {
        case 123: // left
            mailStore.performGlide(.left, useSecondary: useSecondary)
            return true
        case 124: // right
            mailStore.performGlide(.right, useSecondary: useSecondary)
            return true
        case 126: // up
            mailStore.performGlide(.up, useSecondary: useSecondary)
            return true
        case 125: // down
            mailStore.performGlide(.down, useSecondary: useSecondary)
            return true
        default:
            return false
        }
    }
}

private struct MessagePromptView: View {
    @EnvironmentObject private var mailStore: MailStore
    let prompt: MessagePrompt

    @State private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)

            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    mailStore.prompt = nil
                }
                Button("Apply") {
                    apply()
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 380)
    }

    private var title: String {
        switch prompt {
        case .moveToFolder: return "Move to Folder"
        case .applyLabel: return "Apply Label"
        }
    }

    private var placeholder: String {
        switch prompt {
        case .moveToFolder: return "Folder name"
        case .applyLabel: return "Label name"
        }
    }

    private func apply() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }

        switch prompt {
        case .moveToFolder(let messageID):
            mailStore.applyMoveToFolder(value, messageID: messageID)
        case .applyLabel(let messageID):
            mailStore.applyLabel(value, messageID: messageID)
        }

        mailStore.prompt = nil
    }
}
