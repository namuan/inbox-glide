import SwiftUI

struct AccountsSettingsView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var mailStore: MailStore

    @State private var provider: MailProvider = .gmail
    @State private var displayName: String = ""
    @State private var email: String = ""

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
                        HStack {
                            Circle()
                                .fill(Color(hex: account.colorHex) ?? .accentColor)
                                .frame(width: 10, height: 10)
                            Text(account.displayName)
                            Spacer()
                            Text(account.emailAddress)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Add Account") {
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
    }

    private func addAccount() {
        mailStore.addAccount(provider: provider, displayName: displayName, emailAddress: email)
        displayName = ""
        email = ""
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
