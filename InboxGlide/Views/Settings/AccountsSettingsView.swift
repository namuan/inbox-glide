import SwiftUI

struct AccountsSettingsView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var mailStore: MailStore
    @EnvironmentObject private var gmailAuth: GmailAuthStore

    @State private var setupFlow: SetupFlow?
    @State private var provider: MailProvider = .gmail
    @State private var displayName: String = ""
    @State private var email: String = ""
    @State private var accountPendingDeletion: MailAccount?
    @State private var isSyncingGmail: Bool = false
    private let logger = AppLogger.shared

    var body: some View {
        Form {
            Section("Unified Inbox") {
                Toggle("Enable unified inbox", isOn: $preferences.unifiedInboxEnabled)
            }

            Section("Connected Accounts") {
                if mailStore.accounts.isEmpty {
                    Text("No accounts yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(mailStore.accounts) { account in
                        HStack(alignment: .center, spacing: 12) {
                            Circle()
                                .fill(Color(hex: account.colorHex) ?? .accentColor)
                                .frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.displayName)
                                Text(account.emailAddress)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                accountPendingDeletion = account
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete \(account.displayName)")
                        }
                    }
                }
            }

            Section("Add Account") {
                Button("Connect Gmail") {
                    Task {
                        await connectGmail()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(gmailAuth.isLoading)

                if gmailAuth.isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Connecting Gmail...")
                            .foregroundStyle(.secondary)
                    }
                } else if let connectedEmail = gmailAuth.connectedEmail {
                    Label("Connected: \(connectedEmail)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline)

                    Button("Sync Gmail Inbox") {
                        Task {
                            await syncGmailInbox()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSyncingGmail)

                    if isSyncingGmail {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Syncing inbox…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                Divider()

                Text("Other Providers")
                    .font(.headline)
                    .padding(.top, 8)

                Button("Open Full Setup Guide") {
                    setupFlow = .fullSetup
                }
                .buttonStyle(.bordered)
                
                Text("Quick Add (Advanced)")
                    .font(.headline)
                    .padding(.top, 8)
                
                Picker("Provider", selection: $provider) {
                    ForEach(MailProvider.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                TextField("Display name", text: $displayName)
                TextField("Email address", text: $email)
                Button("Add (Stub)") {
                    addAccount()
                }
                .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Text("Gmail uses OAuth. Other providers are currently local setup stubs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Accounts")
        .sheet(item: $setupFlow) { flow in
            switch flow {
            case .fullSetup:
                AccountSetupGuideView(
                    onComplete: { setupFlow = nil },
                    onBack: { setupFlow = nil }
                )
                .environmentObject(mailStore)
            }
        }
        .alert(item: $accountPendingDeletion) { account in
            Alert(
                title: Text("Delete Account"),
                message: Text("Are you sure you want to delete \(account.displayName) (\(account.emailAddress))? This removes the account and any locally stored messages."),
                primaryButton: .destructive(Text("Delete")) {
                    mailStore.deleteAccount(account)
                },
                secondaryButton: .cancel()
            )
        }
        .alert("Gmail Connection Failed", isPresented: Binding(
            get: { gmailAuth.authError != nil },
            set: { if !$0 { gmailAuth.authError = nil } }
        )) {
            Button("OK", role: .cancel) {
                gmailAuth.authError = nil
            }
        } message: {
            Text(gmailAuth.authError ?? "Unable to connect Gmail.")
        }
    }

    private func addAccount() {
        mailStore.addAccount(provider: provider, displayName: displayName, emailAddress: email)
        displayName = ""
        email = ""
    }

    private func connectGmail() async {
        logger.info("User tapped Connect Gmail.", category: "AccountsSettings")
        let connected = await gmailAuth.signIn()
        guard connected, let emailAddress = gmailAuth.connectedEmail else {
            logger.warning(
                "Connect Gmail did not complete successfully.",
                category: "AccountsSettings",
                metadata: ["authError": gmailAuth.authError ?? "none"]
            )
            return
        }

        let alreadyExists = mailStore.accounts.contains { account in
            account.provider == .gmail && account.emailAddress.caseInsensitiveCompare(emailAddress) == .orderedSame
        }
        if alreadyExists {
            logger.info("Gmail account already exists locally; skipping duplicate add.", category: "AccountsSettings", metadata: ["email": emailAddress])
            await syncGmailInbox()
            return
        }

        mailStore.addAccount(
            provider: .gmail,
            displayName: defaultDisplayName(for: emailAddress),
            emailAddress: emailAddress
        )
        logger.info("Added Gmail account after successful OAuth connection.", category: "AccountsSettings", metadata: ["email": emailAddress])
        await syncGmailInbox()
    }

    private func syncGmailInbox() async {
        guard let emailAddress = gmailAuth.connectedEmail else {
            logger.warning("Sync requested without connected Gmail email.", category: "AccountsSettings")
            return
        }

        if isSyncingGmail { return }
        isSyncingGmail = true
        defer { isSyncingGmail = false }

        do {
            let items = try await gmailAuth.fetchRecentInboxMessages(maxResults: 30)
            mailStore.upsertGmailMessages(for: emailAddress, items: items)
            logger.info(
                "Gmail inbox sync completed from settings.",
                category: "AccountsSettings",
                metadata: ["email": emailAddress, "fetched": "\(items.count)"]
            )
        } catch {
            gmailAuth.authError = error.localizedDescription
            logger.error(
                "Gmail inbox sync failed from settings.",
                category: "AccountsSettings",
                metadata: ["email": emailAddress, "error": error.localizedDescription]
            )
        }
    }

    private func defaultDisplayName(for emailAddress: String) -> String {
        let localPart = emailAddress.split(separator: "@").first.map(String.init) ?? "Gmail"
        let cleaned = localPart.replacingOccurrences(of: ".", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            return "Gmail"
        }
        return cleaned.capitalized
    }
}

private enum SetupFlow: String, Identifiable {
    case fullSetup

    var id: String { rawValue }
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
