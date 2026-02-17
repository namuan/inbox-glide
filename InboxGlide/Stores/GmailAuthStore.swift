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

@MainActor
final class GmailAuthStore: ObservableObject {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isLoading = false
    @Published private(set) var connectedEmail: String?
    @Published var authError: String?

    private let keychain = Keychain(service: "InboxGlide.GmailOAuth")
    private let tokenAccount = "gmail.oauth.token"
    private let oauthService: OAuthService?
    private let gmailService = GmailService()
    private let logger = AppLogger.shared

    private var cancellables = Set<AnyCancellable>()
    private var token: StoredGmailOAuthToken?

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

        Task {
            await restoreSessionIfPossible()
        }
    }

    func signIn() async -> Bool {
        logger.info("Gmail sign-in requested.", category: "GmailAuth")
        guard let oauthService else {
            authError = authError ?? "Gmail OAuth is not configured for this build."
            logger.error("Sign-in aborted: OAuth service unavailable.", category: "GmailAuth")
            return false
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let tokenResponse = try await oauthService.startAuthorization()
            let currentRefresh = token?.refreshToken

            token = StoredGmailOAuthToken(
                accessToken: tokenResponse.accessToken,
                refreshToken: tokenResponse.refreshToken ?? currentRefresh,
                expiresAt: Self.expiryDate(from: tokenResponse.expiresIn)
            )

            try persistToken()
            try await loadProfileWithCurrentToken()

            authError = nil
            isAuthenticated = true
            logger.info(
                "Gmail sign-in succeeded.",
                category: "GmailAuth",
                metadata: ["email": connectedEmail ?? "unknown"]
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
        logger.info("Gmail sign-out requested.", category: "GmailAuth")
        token = nil
        connectedEmail = nil
        isAuthenticated = false
        authError = nil
        try? keychain.deleteData(account: tokenAccount)
        logger.info("Stored Gmail token deleted from keychain.", category: "GmailAuth")
    }

    func fetchRecentInboxMessages(maxResults: Int = 25) async throws -> [GmailInboxMessage] {
        logger.info(
            "Fetching recent Gmail inbox messages through auth store.",
            category: "GmailAuth",
            metadata: ["maxResults": "\(maxResults)"]
        )
        let accessToken = try await currentAccessToken()
        return try await gmailService.fetchRecentInboxMessages(accessToken: accessToken, maxResults: maxResults)
    }

    private func handleRedirect(_ url: URL) {
        guard let oauthService else { return }
        Task {
            logger.debug("Passing redirect URL into OAuthService.", category: "GmailAuth")
            _ = await oauthService.handleRedirect(url: url)
        }
    }

    private func restoreSessionIfPossible() async {
        logger.info("Attempting to restore Gmail auth session.", category: "GmailAuth")
        do {
            let data = try keychain.readData(account: tokenAccount)
            token = try JSONDecoder().decode(StoredGmailOAuthToken.self, from: data)
            try await loadProfileWithCurrentToken()
            isAuthenticated = true
            authError = nil
            logger.info(
                "Restored Gmail auth session from keychain.",
                category: "GmailAuth",
                metadata: ["email": connectedEmail ?? "unknown"]
            )
        } catch KeychainError.itemNotFound {
            isAuthenticated = false
            logger.debug("No saved Gmail token found in keychain.", category: "GmailAuth")
        } catch {
            isAuthenticated = false
            authError = nil
            logger.warning("Failed restoring Gmail session; continuing signed out.", category: "GmailAuth", metadata: ["error": error.localizedDescription])
        }
    }

    private func loadProfileWithCurrentToken() async throws {
        logger.debug("Fetching Gmail profile with current token.", category: "GmailAuth")
        let accessToken = try await currentAccessToken()
        let profile = try await gmailService.fetchProfile(accessToken: accessToken)
        connectedEmail = profile.emailAddress
        logger.info("Fetched Gmail profile.", category: "GmailAuth", metadata: ["email": profile.emailAddress])
    }

    private func currentAccessToken() async throws -> String {
        guard var token else {
            logger.error("No token in memory when requesting access token.", category: "GmailAuth")
            throw OAuthServiceError.tokenExchangeFailed("No Gmail token found.")
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

        self.token = token
        try persistToken()
        logger.info("Gmail access token refreshed and persisted.", category: "GmailAuth")

        return token.accessToken
    }

    private func persistToken() throws {
        guard let token else { return }
        let data = try JSONEncoder().encode(token)
        try keychain.upsertData(data, account: tokenAccount)
        logger.debug(
            "Persisted Gmail token to keychain.",
            category: "GmailAuth",
            metadata: ["hasRefreshToken": "\(token.refreshToken != nil)"]
        )
    }

    private static func expiryDate(from expiresIn: Int?) -> Date? {
        guard let seconds = expiresIn else { return nil }
        return Date().addingTimeInterval(TimeInterval(seconds))
    }
}
