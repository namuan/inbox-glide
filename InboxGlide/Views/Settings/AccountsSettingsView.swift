import SwiftUI

struct AccountsSettingsView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var mailStore: MailStore

    @State private var setupFlow: SetupFlow?
    @State private var provider: MailProvider = .gmail
    @State private var displayName: String = ""
    @State private var email: String = ""
    @State private var accountPendingDeletion: MailAccount?

    var body: some View {
        Form {
            Section("Unified Inbox") {
                Toggle("Enable unified inbox", isOn: $preferences.unifiedInboxEnabled)
            }

            Section("Connected Accounts (Local Stub)") {
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
                    setupFlow = .gmailOnboarding
                }
                .buttonStyle(.borderedProminent)
                
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

                Text("OAuth + syncing is not implemented yet; accounts are stored locally so you can exercise the UI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Accounts")
        .sheet(item: $setupFlow) { flow in
            switch flow {
            case .gmailOnboarding:
                AccountSetupGuideView(
                    onComplete: { setupFlow = nil },
                    onBack: { setupFlow = nil },
                    initialProvider: .gmail,
                    title: "Connect Gmail Account",
                    subtitle: "Authorize InboxGlide for Gmail and finish setup with your account details.",
                    allowsProviderSelection: false,
                    backButtonTitle: "Cancel"
                )
                .environmentObject(mailStore)
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
    }

    private func addAccount() {
        mailStore.addAccount(provider: provider, displayName: displayName, emailAddress: email)
        displayName = ""
        email = ""
    }
}

private enum SetupFlow: String, Identifiable {
    case gmailOnboarding
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
