import SwiftUI

struct AccountsSettingsView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var mailStore: MailStore
    @EnvironmentObject private var gmailAuth: GmailAuthStore

    @State private var accountPendingDeletion: MailAccount?
    @State private var isSyncingGmail: Bool = false
    @State private var isSyncingYahoo: Bool = false
    @State private var isSyncingFastmail: Bool = false
    @State private var isShowingYahooSetup = false
    @State private var isShowingFastmailSetup = false
    @State private var yahooErrorMessage: String?
    @State private var yahooInfoMessage: String?
    @State private var yahooSyncStatus: String?
    @State private var fastmailErrorMessage: String?
    @State private var fastmailInfoMessage: String?
    @State private var fastmailSyncStatus: String?
    private let logger = AppLogger.shared
    private let yahooCredentialsStore = YahooCredentialsStore()
    private let fastmailCredentialsStore = FastmailCredentialsStore()

    var body: some View {
        Form {
            Section("Unified Inbox") {
                Toggle("Enable unified inbox", isOn: $preferences.unifiedInboxEnabled)
            }

            Section("Sync Tuning") {
                Stepper(
                    "Background sync interval: \(preferences.backgroundSyncIntervalSeconds)s",
                    value: $preferences.backgroundSyncIntervalSeconds,
                    in: 30...300,
                    step: 15
                )

                Stepper(
                    "Background Gmail fetch: \(preferences.backgroundGmailFetchCount)",
                    value: $preferences.backgroundGmailFetchCount,
                    in: 20...200,
                    step: 10
                )

                Stepper(
                    "Background Yahoo/Fastmail fetch: \(preferences.backgroundIMAPFetchCount)",
                    value: $preferences.backgroundIMAPFetchCount,
                    in: 15...120,
                    step: 5
                )

                Stepper(
                    "Connect sync max results: \(preferences.connectSyncMaxResults)",
                    value: $preferences.connectSyncMaxResults,
                    in: 20...120,
                    step: 2
                )

                Stepper(
                    "Connect sync batch size: \(preferences.connectSyncBatchSize)",
                    value: $preferences.connectSyncBatchSize,
                    in: 4...20,
                    step: 1
                )
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
                            } else if account.provider == .fastmail && isSyncingFastmail {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(fastmailSyncStatus ?? "Syncing Fastmail inbox…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            Section("Add Account") {
                HStack(spacing: 8) {
                    Button("Connect Gmail") {
                        Task {
                            await connectGmail()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(gmailAuth.isLoading)

                    Button("Connect Yahoo") {
                        isShowingYahooSetup = true
                    }
                    .buttonStyle(.bordered)

                    Button("Connect Fastmail") {
                        isShowingFastmailSetup = true
                    }
                    .buttonStyle(.bordered)
                }

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
        .sheet(isPresented: $isShowingFastmailSetup) {
            FastmailSetupSheet { displayName, emailAddress, appPassword in
                Task {
                    await connectFastmail(displayName: displayName, emailAddress: emailAddress, appPassword: appPassword)
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
        .alert("Fastmail Connection Failed", isPresented: Binding(
            get: { fastmailErrorMessage != nil },
            set: { if !$0 { fastmailErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {
                fastmailErrorMessage = nil
            }
        } message: {
            Text(fastmailErrorMessage ?? "Unable to connect Fastmail.")
        }
        .alert("Fastmail Connected", isPresented: Binding(
            get: { fastmailInfoMessage != nil },
            set: { if !$0 { fastmailInfoMessage = nil } }
        )) {
            Button("OK", role: .cancel) {
                fastmailInfoMessage = nil
            }
        } message: {
            Text(fastmailInfoMessage ?? "")
        }
    }

    private func canSync(_ account: MailAccount) -> Bool {
        account.provider == .gmail || account.provider == .yahoo || account.provider == .fastmail
    }

    private func isSyncInProgress(for account: MailAccount) -> Bool {
        switch account.provider {
        case .gmail:
            return isSyncingGmail
        case .yahoo:
            return isSyncingYahoo
        case .fastmail:
            return isSyncingFastmail
        }
    }

    private func syncConnectedAccount(_ account: MailAccount) async {
        switch account.provider {
        case .gmail:
            await syncGmailInbox(for: account.emailAddress)
        case .yahoo:
            await syncYahooInbox(for: account.emailAddress)
        case .fastmail:
            await syncFastmailInbox(for: account.emailAddress)
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
            displayName: defaultDisplayName(for: emailAddress, provider: .gmail),
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

    private func defaultDisplayName(for emailAddress: String, provider: MailProvider) -> String {
        let localPart = emailAddress.split(separator: "@").first.map(String.init) ?? provider.displayName
        let cleaned = localPart.replacingOccurrences(of: ".", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            return provider.displayName
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
            let name = cleanedName.isEmpty ? defaultDisplayName(for: cleanedEmail, provider: .yahoo) : cleanedName

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
                maxResults: max(20, min(120, preferences.connectSyncMaxResults)),
                batchSize: min(
                    max(4, preferences.connectSyncBatchSize),
                    max(20, min(120, preferences.connectSyncMaxResults))
                )
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

    private func connectFastmail(displayName: String, emailAddress: String, appPassword: String) async {
        let cleanedEmail = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedPassword = appPassword.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanedEmail.isEmpty, !cleanedPassword.isEmpty else {
            fastmailErrorMessage = "Please enter your Fastmail email and app password."
            return
        }

        do {
            try fastmailCredentialsStore.saveAppPassword(cleanedPassword, emailAddress: cleanedEmail)
            let name = cleanedName.isEmpty ? defaultDisplayName(for: cleanedEmail, provider: .fastmail) : cleanedName

            let alreadyExists = mailStore.accounts.contains { account in
                account.provider == .fastmail && account.emailAddress.caseInsensitiveCompare(cleanedEmail) == .orderedSame
            }
            if alreadyExists {
                logger.info("Fastmail account already exists locally; refreshed saved app password only.", category: "AccountsSettings", metadata: ["email": cleanedEmail])
                await syncFastmailInbox(for: cleanedEmail)
                return
            }

            mailStore.addAccount(
                provider: .fastmail,
                displayName: name,
                emailAddress: cleanedEmail
            )
            logger.info("Added Fastmail account after app password setup.", category: "AccountsSettings", metadata: ["email": cleanedEmail])
            await syncFastmailInbox(for: cleanedEmail)
        } catch {
            fastmailErrorMessage = error.localizedDescription
            logger.error(
                "Fastmail account setup failed.",
                category: "AccountsSettings",
                metadata: ["email": cleanedEmail, "error": error.localizedDescription]
            )
        }
    }

    private func syncFastmailInbox(for emailAddress: String) async {
        if isSyncingFastmail {
            logger.debug("Fastmail connect-triggered sync skipped because another Fastmail sync is running.", category: "AccountsSettings", metadata: ["email": emailAddress])
            return
        }
        logger.info("Fastmail connect-triggered sync requested.", category: "AccountsSettings", metadata: ["email": emailAddress])

        isSyncingFastmail = true
        fastmailSyncStatus = "Starting Fastmail sync…"
        defer {
            isSyncingFastmail = false
            fastmailSyncStatus = nil
        }

        do {
            let fetched = try await mailStore.syncFastmailInboxProgressive(
                for: emailAddress,
                maxResults: max(20, min(120, preferences.connectSyncMaxResults)),
                batchSize: min(
                    max(4, preferences.connectSyncBatchSize),
                    max(20, min(120, preferences.connectSyncMaxResults))
                )
            ) { cumulative, batchCount in
                DispatchQueue.main.async {
                    fastmailSyncStatus = "Fastmail \(emailAddress): +\(batchCount), \(cumulative) loaded"
                }
            }
            fastmailInfoMessage = "Fastmail connected and inbox synced."
            logger.info(
                "Fastmail inbox sync completed after connect.",
                category: "AccountsSettings",
                metadata: ["email": emailAddress, "fetched": "\(fetched)"]
            )
        } catch {
            fastmailErrorMessage = "Account saved, but inbox sync failed: \(error.localizedDescription)"
            logger.error(
                "Fastmail inbox sync failed after connect.",
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

private enum SetupSheetLayout {
    static let minWidth: CGFloat = 620
    static let idealWidth: CGFloat = 780
    static let maxWidth: CGFloat = 980
    static let minHeight: CGFloat = 520
    static let idealHeight: CGFloat = 620
    static let maxHeight: CGFloat = 760
}

private enum AppPasswordProviderSetup {
    case yahoo
    case fastmail

    var displayName: String {
        switch self {
        case .yahoo: return "Yahoo Mail"
        case .fastmail: return "FastMail"
        }
    }

    var connectTitle: String {
        switch self {
        case .yahoo: return "Connect Yahoo"
        case .fastmail: return "Connect FastMail"
        }
    }

    var systemImage: String {
        switch self {
        case .yahoo: return "envelope.badge"
        case .fastmail: return "paperplane.fill"
        }
    }

    var tint: Color {
        switch self {
        case .yahoo: return Color.orange
        case .fastmail: return Color.blue
        }
    }

    var helperText: String {
        switch self {
        case .yahoo:
            return "Use an app password from Yahoo Account Security. Your account password will not be accepted."
        case .fastmail:
            return "Use an app password from FastMail settings. Your account password will not be accepted."
        }
    }

    var appPasswordURL: URL {
        switch self {
        case .yahoo:
            return URL(string: "https://login.yahoo.com/account/security")!
        case .fastmail:
            return URL(string: "https://app.fastmail.com/settings/security/app-passwords")!
        }
    }

    var appPasswordLinkTitle: String {
        switch self {
        case .yahoo: return "Open Yahoo Account Security"
        case .fastmail: return "Open FastMail App Password Settings"
        }
    }

    var appPasswordSteps: [String] {
        switch self {
        case .yahoo:
            return [
                "Go to Account Security.",
                "Select Generate app password.",
                "Create one for InboxGlide and copy it."
            ]
        case .fastmail:
            return [
                "Go to Settings > Privacy & Security > App Passwords.",
                "Create a new password named InboxGlide.",
                "Grant mail access and copy it."
            ]
        }
    }

    var emailPlaceholder: String {
        switch self {
        case .yahoo: return "Yahoo email address"
        case .fastmail: return "FastMail email address"
        }
    }

    var appPasswordPlaceholder: String {
        switch self {
        case .yahoo: return "Yahoo app password"
        case .fastmail: return "FastMail app password"
        }
    }

    var imapLine: String {
        switch self {
        case .yahoo: return "imap.mail.yahoo.com:993 (SSL)"
        case .fastmail: return "imap.fastmail.com:993 (SSL)"
        }
    }

    var smtpLine: String {
        switch self {
        case .yahoo: return "smtp.mail.yahoo.com:465 or 587 (TLS)"
        case .fastmail: return "smtp.fastmail.com:465 or 587 (TLS)"
        }
    }
}

private struct YahooSetupSheet: View {
    let onConnect: (_ displayName: String, _ emailAddress: String, _ appPassword: String) -> Void

    var body: some View {
        AppPasswordProviderSetupSheet(provider: .yahoo, onConnect: onConnect)
    }
}

private struct FastmailSetupSheet: View {
    let onConnect: (_ displayName: String, _ emailAddress: String, _ appPassword: String) -> Void

    var body: some View {
        AppPasswordProviderSetupSheet(provider: .fastmail, onConnect: onConnect)
    }
}

private struct AppPasswordProviderSetupSheet: View {
    let provider: AppPasswordProviderSetup
    let onConnect: (_ displayName: String, _ emailAddress: String, _ appPassword: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var emailAddress = ""
    @State private var appPassword = ""

    private var canConnect: Bool {
        !emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !appPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()

                ScrollView {
                    VStack(spacing: 18) {
                        stepCard
                        credentialsCard
                        serverCard
                    }
                    .padding(24)
                }

                Divider()
                footer
            }
            .background(
                LinearGradient(
                    colors: [provider.tint.opacity(0.10), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        .frame(
            minWidth: SetupSheetLayout.minWidth,
            idealWidth: SetupSheetLayout.idealWidth,
            maxWidth: SetupSheetLayout.maxWidth,
            minHeight: SetupSheetLayout.minHeight,
            idealHeight: SetupSheetLayout.idealHeight,
            maxHeight: SetupSheetLayout.maxHeight
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: provider.systemImage)
                .font(.title2.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(provider.tint.opacity(0.2), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(provider.tint)

            VStack(alignment: .leading, spacing: 4) {
                Text(provider.connectTitle)
                    .font(.title3.weight(.semibold))
                Text("App-password setup")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var stepCard: some View {
        setupCard(title: "Step 1. Create App Password", icon: "key.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Text(provider.helperText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Link(provider.appPasswordLinkTitle, destination: provider.appPasswordURL)
                    .font(.subheadline.weight(.semibold))

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(provider.appPasswordSteps.indices, id: \.self) { index in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1).")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(provider.tint)
                                .frame(width: 14, alignment: .leading)
                            Text(provider.appPasswordSteps[index])
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var credentialsCard: some View {
        setupCard(title: "Step 2. Enter Account Details", icon: "person.crop.circle.badge.checkmark") {
            VStack(spacing: 12) {
                TextField(provider.emailPlaceholder, text: $emailAddress)
                    .textFieldStyle(.roundedBorder)
                TextField("Display name (optional)", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                SecureField(provider.appPasswordPlaceholder, text: $appPassword)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var serverCard: some View {
        setupCard(title: "Server Settings", icon: "network") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("IMAP")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(provider.tint)
                        .frame(width: 42, alignment: .leading)
                    Text(provider.imapLine)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text("SMTP")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(provider.tint)
                        .frame(width: 42, alignment: .leading)
                    Text(provider.smtpLine)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
            Spacer()
            Button("Connect") {
                onConnect(displayName, emailAddress, appPassword)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canConnect)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func setupCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(provider.tint)
                Text(title)
                    .font(.headline)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
