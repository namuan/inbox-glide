import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var mailStore: MailStore

    var body: some View {
        List(selection: $mailStore.selectedAccountID) {
            Section {
                Toggle("Unified Inbox", isOn: $preferences.unifiedInboxEnabled)
                if preferences.unifiedInboxEnabled {
                    Button {
                        mailStore.selectedAccountID = nil
                    } label: {
                        Label("All Accounts", systemImage: "tray")
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }
            }

            Section("Accounts") {
                ForEach(mailStore.accounts) { account in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(hex: account.colorHex) ?? .accentColor)
                            .frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.displayName)
                            Text(account.emailAddress)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(Optional(account.id))
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("InboxGlide")
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
