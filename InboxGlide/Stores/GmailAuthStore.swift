import Combine
import Foundation

extension Notification.Name {
    static let inboxGlideDidReceiveOAuthRedirect = Notification.Name("InboxGlideDidReceiveOAuthRedirect")
}

struct StoredGmailOAuthToken: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
}

private struct StoredGmailOAuthSessionStore: Codable {
    var tokensByEmail: [String: StoredGmailOAuthToken]
    var lastConnectedEmail: String?
}

@MainActor
final class GmailAuthStore: ObservableObject {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isLoading = false
    @Published private(set) var connectedEmail: String?
    @Published var authError: String?

    private let vault = ProviderAppPasswordVault.shared
    private let legacyKeychain = Keychain(service: "InboxGlide.GmailOAuth")
    private let sessionsAccount = "gmail.oauth.sessions.v2"
    private let legacyTokenAccount = "gmail.oauth.token"
    private let oauthService: OAuthService?
    private let gmailService = GmailService()
    private let logger = AppLogger.shared

    private var cancellables = Set<AnyCancellable>()
    private var tokensByEmail: [String: StoredGmailOAuthToken] = [:]
    private var hasAttemptedRestore = false

    init() {
        logger.info("Initializing GmailAuthStore.", category: "GmailAuth")
        do {
            let config = try GmailOAuthConfig.fromMainBundle()
            oauthService = OAuthService(config: config)
            logger.info(
                "Loaded Gmail OAuth configuration.",
                category: "GmailAuth",
                metadata: ["redirectURI": config.redirectURI]
            )
        } catch {
            oauthService = nil
            authError = error.localizedDescription
            logger.error(
                "Failed to initialize OAuth service.",
                category: "GmailAuth",
                metadata: ["error": error.localizedDescription]
            )
        }

        NotificationCenter.default.publisher(for: .inboxGlideDidReceiveOAuthRedirect)
            .compactMap { $0.object as? URL }
            .sink { [weak self] url in
                self?.logger.debug("Received OAuth redirect notification.", category: "GmailAuth", metadata: ["url": url.absoluteString])
                self?.handleRedirect(url)
            }
            .store(in: &cancellables)

    }

    func signIn(forceAccountSelection: Bool = false) async -> Bool {
        logger.info("Gmail sign-in requested.", category: "GmailAuth")
        await restoreSessionIfNeeded()
        if !forceAccountSelection, isAuthenticated, connectedEmail != nil {
            authError = nil
            logger.info("Using restored Gmail auth session; skipping OAuth flow.", category: "GmailAuth")
            return true
        }

        guard let oauthService else {
            authError = authError ?? "Gmail OAuth is not configured for this build."
            logger.error("Sign-in aborted: OAuth service unavailable.", category: "GmailAuth")
            return false
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let tokenResponse = try await oauthService.startAuthorization()
            var token = StoredGmailOAuthToken(
                accessToken: tokenResponse.accessToken,
                refreshToken: tokenResponse.refreshToken,
                expiresAt: Self.expiryDate(from: tokenResponse.expiresIn)
            )

            let profile = try await loadProfile(using: token.accessToken)
            let normalizedEmail = Self.normalizeEmail(profile.emailAddress)

            if token.refreshToken == nil {
                token.refreshToken = tokensByEmail[normalizedEmail]?.refreshToken
            }
            tokensByEmail[normalizedEmail] = token
            connectedEmail = profile.emailAddress
            isAuthenticated = !tokensByEmail.isEmpty
            try persistSessions()

            authError = nil
            logger.info(
                "Gmail sign-in succeeded.",
                category: "GmailAuth",
                metadata: ["email": profile.emailAddress, "sessionCount": "\(tokensByEmail.count)"]
            )
            return true
        } catch {
            authError = error.localizedDescription
            logger.error(
                "Gmail sign-in failed.",
                category: "GmailAuth",
                metadata: ["error": error.localizedDescription]
            )
            return false
        }
    }

    func signOut() {
        logger.info("Gmail sign-out requested (all sessions).", category: "GmailAuth")
        tokensByEmail = [:]
        connectedEmail = nil
        isAuthenticated = false
        authError = nil
        try? vault.deleteValue(key: sessionsAccount)
        try? legacyKeychain.deleteData(account: sessionsAccount)
        try? legacyKeychain.deleteData(account: legacyTokenAccount)
        logger.info("Stored Gmail sessions deleted from keychain vault.", category: "GmailAuth")
    }

    func hasSession(for emailAddress: String) async -> Bool {
        await restoreSessionIfNeeded()
        let key = Self.normalizeEmail(emailAddress)
        return tokensByEmail[key] != nil
    }

    func fetchRecentInboxMessages(for emailAddress: String, maxResults: Int = 25) async throws -> [GmailInboxMessage] {
        logger.info(
            "Fetching recent Gmail inbox messages through auth store.",
            category: "GmailAuth",
            metadata: ["email": emailAddress, "maxResults": "\(maxResults)"]
        )
        await restoreSessionIfNeeded()
        let accessToken = try await currentAccessToken(for: emailAddress)
        return try await gmailService.fetchRecentInboxMessages(accessToken: accessToken, maxResults: maxResults)
    }

    func trashMessage(id: String, for emailAddress: String) async throws {
        logger.info(
            "Requesting Gmail message trash operation.",
            category: "GmailAuth",
            metadata: ["messageID": id, "email": emailAddress]
        )
        await restoreSessionIfNeeded()
        let accessToken = try await currentAccessToken(for: emailAddress)
        try await gmailService.trashMessage(accessToken: accessToken, id: id)
    }

    private func handleRedirect(_ url: URL) {
        guard let oauthService else { return }
        Task {
            logger.debug("Passing redirect URL into OAuthService.", category: "GmailAuth")
            _ = await oauthService.handleRedirect(url: url)
        }
    }

    private func restoreSessionIfPossible() async {
        logger.info("Attempting to restore Gmail auth sessions.", category: "GmailAuth")
        do {
            try await restoreFromSessionStore()
        } catch KeychainError.itemNotFound {
            if migrateLegacySessionStoreIfPossible() {
                return
            }
            await migrateLegacyTokenIfPossible()
        } catch {
            isAuthenticated = false
            connectedEmail = nil
            authError = nil
            logger.warning(
                "Failed restoring Gmail sessions; continuing signed out.",
                category: "GmailAuth",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    private func restoreSessionIfNeeded() async {
        if hasAttemptedRestore { return }
        hasAttemptedRestore = true
        await restoreSessionIfPossible()
    }

    private func loadProfile(using accessToken: String) async throws -> GmailProfile {
        logger.debug("Fetching Gmail profile with access token.", category: "GmailAuth")
        let profile = try await gmailService.fetchProfile(accessToken: accessToken)
        logger.info("Fetched Gmail profile.", category: "GmailAuth", metadata: ["email": profile.emailAddress])
        return profile
    }

    private func currentAccessToken(for emailAddress: String) async throws -> String {
        let key = Self.normalizeEmail(emailAddress)
        guard var token = tokensByEmail[key] else {
            logger.error(
                "No token in memory for requested Gmail account.",
                category: "GmailAuth",
                metadata: ["email": emailAddress]
            )
            throw OAuthServiceError.tokenExchangeFailed("No Gmail session found for \(emailAddress). Connect that Gmail account again.")
        }

        if let expiresAt = token.expiresAt, expiresAt > Date().addingTimeInterval(60) {
            logger.debug("Using non-expired access token from memory.", category: "GmailAuth")
            return token.accessToken
        }

        guard let refreshToken = token.refreshToken,
              let oauthService else {
            logger.error("Unable to refresh token due to missing refresh token or OAuth service.", category: "GmailAuth")
            throw OAuthServiceError.tokenExchangeFailed("Gmail token is expired and cannot be refreshed.")
        }

        logger.info("Refreshing expired Gmail access token.", category: "GmailAuth")
        let refreshed = try await oauthService.refreshAccessToken(refreshToken: refreshToken)
        token.accessToken = refreshed.accessToken
        token.refreshToken = refreshed.refreshToken ?? refreshToken
        token.expiresAt = Self.expiryDate(from: refreshed.expiresIn)

        tokensByEmail[key] = token
        connectedEmail = emailAddress
        try persistSessions()
        logger.info(
            "Gmail access token refreshed and persisted.",
            category: "GmailAuth",
            metadata: ["email": emailAddress]
        )

        return token.accessToken
    }

    private func persistSessions() throws {
        let store = StoredGmailOAuthSessionStore(
            tokensByEmail: tokensByEmail,
            lastConnectedEmail: connectedEmail.map(Self.normalizeEmail)
        )
        let data = try JSONEncoder().encode(store)
        let encoded = data.base64EncodedString()
        try vault.saveValue(encoded, key: sessionsAccount)
        logger.debug(
            "Persisted Gmail sessions to keychain vault.",
            category: "GmailAuth",
            metadata: ["sessionCount": "\(tokensByEmail.count)"]
        )
    }

    private static func expiryDate(from expiresIn: Int?) -> Date? {
        guard let seconds = expiresIn else { return nil }
        return Date().addingTimeInterval(TimeInterval(seconds))
    }

    private func restoreFromSessionStore() async throws {
        let encoded = try vault.loadValue(key: sessionsAccount)
        guard let data = Data(base64Encoded: encoded) else {
            throw OAuthServiceError.tokenExchangeFailed("Stored Gmail session data is invalid.")
        }
        let store = try JSONDecoder().decode(StoredGmailOAuthSessionStore.self, from: data)
        tokensByEmail = store.tokensByEmail

        if let last = store.lastConnectedEmail, tokensByEmail[last] != nil {
            connectedEmail = last
        } else {
            connectedEmail = tokensByEmail.keys.sorted().first
        }
        isAuthenticated = !tokensByEmail.isEmpty
        authError = nil
        logger.info(
            "Restored Gmail auth sessions from keychain vault.",
            category: "GmailAuth",
            metadata: ["sessionCount": "\(tokensByEmail.count)", "connectedEmail": connectedEmail ?? "none"]
        )
    }

    private func migrateLegacySessionStoreIfPossible() -> Bool {
        do {
            let data = try legacyKeychain.readData(account: sessionsAccount)
            let store = try JSONDecoder().decode(StoredGmailOAuthSessionStore.self, from: data)
            tokensByEmail = store.tokensByEmail
            if let last = store.lastConnectedEmail, tokensByEmail[last] != nil {
                connectedEmail = last
            } else {
                connectedEmail = tokensByEmail.keys.sorted().first
            }
            isAuthenticated = !tokensByEmail.isEmpty
            authError = nil
            try persistSessions()
            try? legacyKeychain.deleteData(account: sessionsAccount)
            logger.info(
                "Migrated Gmail multi-session store into unified keychain vault.",
                category: "GmailAuth",
                metadata: ["sessionCount": "\(tokensByEmail.count)"]
            )
            return true
        } catch KeychainError.itemNotFound {
            return false
        } catch {
            logger.warning(
                "Failed migrating legacy Gmail session store.",
                category: "GmailAuth",
                metadata: ["error": error.localizedDescription]
            )
            return false
        }
    }

    private func migrateLegacyTokenIfPossible() async {
        do {
            let data = try legacyKeychain.readData(account: legacyTokenAccount)
            var legacyToken = try JSONDecoder().decode(StoredGmailOAuthToken.self, from: data)
            let accessToken = try await refreshedAccessTokenIfNeeded(&legacyToken)
            let profile = try await loadProfile(using: accessToken)
            let normalizedEmail = Self.normalizeEmail(profile.emailAddress)
            tokensByEmail[normalizedEmail] = legacyToken
            connectedEmail = normalizedEmail
            isAuthenticated = true
            authError = nil
            try persistSessions()
            try? legacyKeychain.deleteData(account: legacyTokenAccount)
            logger.info(
                "Migrated legacy Gmail token to multi-session storage.",
                category: "GmailAuth",
                metadata: ["email": normalizedEmail]
            )
        } catch KeychainError.itemNotFound {
            tokensByEmail = [:]
            connectedEmail = nil
            isAuthenticated = false
            authError = nil
            logger.debug("No saved Gmail session found in keychain.", category: "GmailAuth")
        } catch {
            tokensByEmail = [:]
            connectedEmail = nil
            isAuthenticated = false
            authError = nil
            logger.warning(
                "Failed migrating legacy Gmail token; continuing signed out.",
                category: "GmailAuth",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    private func refreshedAccessTokenIfNeeded(_ token: inout StoredGmailOAuthToken) async throws -> String {
        if let expiresAt = token.expiresAt, expiresAt > Date().addingTimeInterval(60) {
            return token.accessToken
        }

        guard let refreshToken = token.refreshToken,
              let oauthService else {
            throw OAuthServiceError.tokenExchangeFailed("Gmail token is expired and cannot be refreshed.")
        }
        let refreshed = try await oauthService.refreshAccessToken(refreshToken: refreshToken)
        token.accessToken = refreshed.accessToken
        token.refreshToken = refreshed.refreshToken ?? refreshToken
        token.expiresAt = Self.expiryDate(from: refreshed.expiresIn)
        return token.accessToken
    }

    private static func normalizeEmail(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
