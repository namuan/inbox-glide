import SwiftUI

struct AccountsSettingsView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var mailStore: MailStore
    @EnvironmentObject private var gmailAuth: GmailAuthStore

    @State private var accountPendingDeletion: MailAccount?
    @State private var isSyncingGmail: Bool = false
    @State private var isSyncingYahoo: Bool = false
    @State private var isShowingYahooSetup = false
    @State private var yahooErrorMessage: String?
    @State private var yahooInfoMessage: String?
    @State private var yahooSyncStatus: String?
    private let logger = AppLogger.shared
    private let yahooCredentialsStore = YahooCredentialsStore()

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
                        VStack(alignment: .leading, spacing: 6) {
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
                                Button("Sync") {
                                    Task {
                                        await syncConnectedAccount(account)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(!canSync(account) || isSyncInProgress(for: account))
                                Button(role: .destructive) {
                                    accountPendingDeletion = account
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Delete \(account.displayName)")
                            }

                            if account.provider == .gmail && isSyncingGmail {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Syncing inbox…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else if account.provider == .yahoo && isSyncingYahoo {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(yahooSyncStatus ?? "Syncing Yahoo inbox…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
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
                }

                Button("Connect Yahoo") {
                    isShowingYahooSetup = true
                }
                .buttonStyle(.bordered)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Accounts")
        .sheet(isPresented: $isShowingYahooSetup) {
            YahooSetupSheet { displayName, emailAddress, appPassword in
                Task {
                    await connectYahoo(displayName: displayName, emailAddress: emailAddress, appPassword: appPassword)
                }
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
        .alert("Yahoo Connection Failed", isPresented: Binding(
            get: { yahooErrorMessage != nil },
            set: { if !$0 { yahooErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {
                yahooErrorMessage = nil
            }
        } message: {
            Text(yahooErrorMessage ?? "Unable to connect Yahoo.")
        }
        .alert("Yahoo Connected", isPresented: Binding(
            get: { yahooInfoMessage != nil },
            set: { if !$0 { yahooInfoMessage = nil } }
        )) {
            Button("OK", role: .cancel) {
                yahooInfoMessage = nil
            }
        } message: {
            Text(yahooInfoMessage ?? "")
        }
    }

    private func canSync(_ account: MailAccount) -> Bool {
        account.provider == .gmail || account.provider == .yahoo
    }

    private func isSyncInProgress(for account: MailAccount) -> Bool {
        switch account.provider {
        case .gmail:
            return isSyncingGmail
        case .yahoo:
            return isSyncingYahoo
        case .fastmail:
            return false
        }
    }

    private func syncConnectedAccount(_ account: MailAccount) async {
        switch account.provider {
        case .gmail:
            await syncGmailInbox(for: account.emailAddress)
        case .yahoo:
            await syncYahooInbox(for: account.emailAddress)
        case .fastmail:
            logger.debug(
                "Sync requested for unsupported provider.",
                category: "AccountsSettings",
                metadata: ["provider": account.provider.rawValue, "email": account.emailAddress]
            )
        }
    }

    private func connectGmail() async {
        logger.info("User tapped Connect Gmail.", category: "AccountsSettings")
        let connected = await gmailAuth.signIn(forceAccountSelection: true)
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

    private func syncGmailInbox(for requestedEmail: String? = nil) async {
        guard let emailAddress = requestedEmail ?? gmailAuth.connectedEmail else {
            logger.warning("Sync requested without target Gmail email.", category: "AccountsSettings")
            return
        }

        if isSyncingGmail { return }
        isSyncingGmail = true
        defer { isSyncingGmail = false }

        do {
            let hasSession = await gmailAuth.hasSession(for: emailAddress)
            if !hasSession {
                gmailAuth.authError = "No Gmail session found for \(emailAddress). Use Connect Gmail to authorize it."
                logger.warning(
                    "Gmail sync requested for account without OAuth session.",
                    category: "AccountsSettings",
                    metadata: ["email": emailAddress]
                )
                return
            }

            let items = try await gmailAuth.fetchRecentInboxMessages(for: emailAddress, maxResults: 30)
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

    private func connectYahoo(displayName: String, emailAddress: String, appPassword: String) async {
        let cleanedEmail = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedPassword = appPassword.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanedEmail.isEmpty, !cleanedPassword.isEmpty else {
            yahooErrorMessage = "Please enter your Yahoo email and app password."
            return
        }

        do {
            try yahooCredentialsStore.saveAppPassword(cleanedPassword, emailAddress: cleanedEmail)
            let name = cleanedName.isEmpty ? defaultDisplayName(for: cleanedEmail) : cleanedName

            let alreadyExists = mailStore.accounts.contains { account in
                account.provider == .yahoo && account.emailAddress.caseInsensitiveCompare(cleanedEmail) == .orderedSame
            }
            if alreadyExists {
                logger.info("Yahoo account already exists locally; refreshed saved app password only.", category: "AccountsSettings", metadata: ["email": cleanedEmail])
                await syncYahooInbox(for: cleanedEmail)
                return
            }

            mailStore.addAccount(
                provider: .yahoo,
                displayName: name,
                emailAddress: cleanedEmail
            )
            logger.info("Added Yahoo account after app password setup.", category: "AccountsSettings", metadata: ["email": cleanedEmail])
            await syncYahooInbox(for: cleanedEmail)
        } catch {
            yahooErrorMessage = error.localizedDescription
            logger.error(
                "Yahoo account setup failed.",
                category: "AccountsSettings",
                metadata: ["email": cleanedEmail, "error": error.localizedDescription]
            )
        }
    }

    private func syncYahooInbox(for emailAddress: String) async {
        if isSyncingYahoo {
            logger.debug("Yahoo connect-triggered sync skipped because another Yahoo sync is running.", category: "AccountsSettings", metadata: ["email": emailAddress])
            return
        }
        logger.info("Yahoo connect-triggered sync requested.", category: "AccountsSettings", metadata: ["email": emailAddress])

        isSyncingYahoo = true
        yahooSyncStatus = "Starting Yahoo sync…"
        defer {
            isSyncingYahoo = false
            yahooSyncStatus = nil
        }

        do {
            let fetched = try await mailStore.syncYahooInboxProgressive(
                for: emailAddress,
                maxResults: 90,
                batchSize: 15
            ) { cumulative, batchCount in
                DispatchQueue.main.async {
                    yahooSyncStatus = "Yahoo \(emailAddress): +\(batchCount), \(cumulative) loaded"
                }
            }
            yahooInfoMessage = "Yahoo connected and inbox synced."
            logger.info(
                "Yahoo inbox sync completed after connect.",
                category: "AccountsSettings",
                metadata: ["email": emailAddress, "fetched": "\(fetched)"]
            )
        } catch {
            yahooErrorMessage = "Account saved, but inbox sync failed: \(error.localizedDescription)"
            logger.error(
                "Yahoo inbox sync failed after connect.",
                category: "AccountsSettings",
                metadata: ["email": emailAddress, "error": error.localizedDescription]
            )
        }
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

private struct YahooSetupSheet: View {
    let onConnect: (_ displayName: String, _ emailAddress: String, _ appPassword: String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var emailAddress = ""
    @State private var appPassword = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Step 1: Generate Yahoo App Password") {
                    Text("Open Yahoo Account Security and create an app password for InboxGlide.")
                        .foregroundStyle(.secondary)
                    Link("Open Yahoo Account Security", destination: URL(string: "https://login.yahoo.com/account/security")!)
                }

                Section("Step 2: Enter Account Details") {
                    TextField("Yahoo email address", text: $emailAddress)
                    TextField("Display name (optional)", text: $displayName)
                    SecureField("Yahoo app password", text: $appPassword)
                }

                Section("Server Settings") {
                    Text("IMAP: imap.mail.yahoo.com:993 (SSL)")
                    Text("SMTP: smtp.mail.yahoo.com:465 or 587 (TLS)")
                }
            }
            .navigationTitle("Connect Yahoo")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        onConnect(displayName, emailAddress, appPassword)
                        dismiss()
                    }
                    .disabled(emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}
