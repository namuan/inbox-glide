import SwiftUI

struct ReplyComposerView: View {
    @EnvironmentObject private var mailStore: MailStore
    @EnvironmentObject private var ai: AIReplyService
    @Environment(\.dismiss) private var dismiss

    let presentation: ComposerPresentation

    @State private var note: String = ""
    @State private var bodyText: String = ""
    @State private var isGenerating: Bool = false

    var message: EmailMessage? {
        mailStore.messages.first(where: { $0.id == presentation.messageID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(presentation.mode == .aiReply ? "AI Reply" : "Reply")
                .font(.title3)
                .fontWeight(.semibold)

            if let message {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("To: \(message.senderName) <\(message.senderEmail)>")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Subject: Re: \(message.subject)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if presentation.mode == .aiReply {
                    TextField("What do you want to say?", text: $note)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button {
                            Task { await generate(message: message) }
                        } label: {
                            if isGenerating {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(isGenerating ? "Generating…" : "Generate")
                        }
                        .disabled(isGenerating)

                        Spacer()
                        Text("PII is scrubbed locally")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                TextEditor(text: $bodyText)
                    .font(.body)
                    .frame(minHeight: 220)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 1))

                HStack {
                    Button("Close") {
                        dismiss()
                    }
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(bodyText, forType: .string)
                    }
                    Button("Send") {
                        // Stub send: archive message locally.
                        mailStore.perform(action: .archive, isSecondary: false, messageID: message.id)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                Text("Message not found.")
                    .foregroundStyle(.secondary)
                Button("Close") { dismiss() }
            }
        }
        .padding(18)
        .frame(minWidth: 640, minHeight: 520)
        .onAppear {
            if bodyText.isEmpty, let message {
                bodyText = "Hi \(message.senderName),\n\n"
            }
        }
    }

    private func generate(message: EmailMessage) async {
        isGenerating = true
        let reply = await ai.generateReply(from: message, note: note)
        await MainActor.run {
            bodyText = reply
            isGenerating = false
        }
    }
}
