import AppKit
import CryptoKit
import Foundation
import Network

enum OAuthServiceError: LocalizedError {
    case invalidConfiguration(String)
    case alreadyInProgress
    case unableToOpenBrowser
    case invalidRedirect
    case missingAuthorizationCode
    case stateMismatch
    case authorizationDenied(String)
    case tokenExchangeFailed(String)
    case oauthTimeout

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return message
        case .alreadyInProgress:
            return "A Gmail sign-in is already in progress."
        case .unableToOpenBrowser:
            return "Unable to open the browser for Gmail sign-in."
        case .invalidRedirect:
            return "Received an invalid OAuth callback URL."
        case .missingAuthorizationCode:
            return "Google did not return an authorization code."
        case .stateMismatch:
            return "OAuth state validation failed. Try connecting again."
        case .authorizationDenied(let message):
            return message
        case .tokenExchangeFailed(let message):
            return message
        case .oauthTimeout:
            return "Timed out waiting for OAuth callback. Please try again."
        }
    }
}

struct OAuthTokenResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    let scope: String?
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
        case tokenType = "token_type"
    }
}

private struct OAuthTokenErrorResponse: Decodable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

actor OAuthService {
    private let config: GmailOAuthConfig
    private let session: URLSession
    private let logger = AppLogger.shared

    private var pendingCodeContinuation: CheckedContinuation<String, Error>?
    private var pendingState: String?
    private var pendingVerifier: String?

    init(config: GmailOAuthConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
        logger.info(
            "OAuthService initialized.",
            category: "OAuth",
            metadata: [
                "redirectURI": config.redirectURI,
                "scopeCount": "\(config.scopes.count)",
                "usesClientSecret": "\(config.clientSecret != nil)"
            ]
        )
    }

    func startAuthorization() async throws -> OAuthTokenResponse {
        logger.info("Starting Gmail OAuth authorization.", category: "OAuth")
        guard pendingCodeContinuation == nil else {
            logger.warning("Authorization already in progress.", category: "OAuth")
            throw OAuthServiceError.alreadyInProgress
        }

        let state = Self.randomBase64URL(length: 32)
        let verifier = Self.randomBase64URL(length: 64)
        let challenge = Self.sha256Base64URL(verifier)

        pendingState = state
        pendingVerifier = verifier

        let authURL = try buildAuthorizationURL(state: state, codeChallenge: challenge)
        logger.debug(
            "Built authorization URL.",
            category: "OAuth",
            metadata: ["host": authURL.host ?? "unknown", "path": authURL.path]
        )

        let didOpen = await MainActor.run {
            NSWorkspace.shared.open(authURL)
        }
        guard didOpen else {
            clearPendingAuthorization()
            logger.error("Failed to open browser for OAuth.", category: "OAuth")
            throw OAuthServiceError.unableToOpenBrowser
        }
        logger.info("Browser opened for OAuth authorization.", category: "OAuth")

        let code: String
        if shouldUseLoopbackReceiver {
            do {
                logger.debug("Using loopback redirect receiver.", category: "OAuth")
                code = try await receiveCodeFromLoopbackRedirect(expectedState: state)
            } catch {
                clearPendingAuthorization()
                logger.error(
                    "Loopback receiver failed.",
                    category: "OAuth",
                    metadata: ["error": error.localizedDescription]
                )
                throw error
            }
        } else {
            do {
                logger.debug("Waiting for custom URL callback redirect.", category: "OAuth")
                code = try await withCheckedThrowingContinuation { continuation in
                    pendingCodeContinuation = continuation
                }
            } catch {
                clearPendingAuthorization()
                logger.error(
                    "Callback redirect waiting failed.",
                    category: "OAuth",
                    metadata: ["error": error.localizedDescription]
                )
                throw error
            }
        }

        guard let codeVerifier = pendingVerifier else {
            clearPendingAuthorization()
            logger.error("Missing pending PKCE verifier during token exchange.", category: "OAuth")
            throw OAuthServiceError.invalidRedirect
        }

        do {
            logger.info("Exchanging authorization code for access token.", category: "OAuth")
            let token = try await exchangeCodeForToken(code: code, codeVerifier: codeVerifier)
            clearPendingAuthorization()
            logger.info(
                "Token exchange succeeded.",
                category: "OAuth",
                metadata: [
                    "hasRefreshToken": "\(token.refreshToken != nil)",
                    "expiresIn": "\(token.expiresIn ?? -1)"
                ]
            )
            return token
        } catch {
            clearPendingAuthorization()
            logger.error(
                "Token exchange failed.",
                category: "OAuth",
                metadata: ["error": error.localizedDescription]
            )
            throw error
        }
    }

    func handleRedirect(url: URL) -> Bool {
        logger.debug("Received redirect URL for OAuth handler.", category: "OAuth", metadata: ["url": url.absoluteString])
        guard matchesRedirectURL(url) else {
            logger.debug("Redirect URL ignored because it does not match configured callback.", category: "OAuth")
            return false
        }

        guard let continuation = pendingCodeContinuation else {
            logger.debug("Redirect matched but no pending continuation exists.", category: "OAuth")
            return true
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            logger.error("Failed parsing redirect URL components.", category: "OAuth")
            continuation.resume(throwing: OAuthServiceError.invalidRedirect)
            pendingCodeContinuation = nil
            return true
        }

        let queryItems = components.queryItems ?? []

        if let error = queryItems.first(where: { $0.name == "error" })?.value {
            let description = queryItems.first(where: { $0.name == "error_description" })?.value
            logger.error(
                "Authorization denied or failed at provider callback.",
                category: "OAuth",
                metadata: ["error": description ?? error]
            )
            continuation.resume(throwing: OAuthServiceError.authorizationDenied(description ?? error))
            pendingCodeContinuation = nil
            return true
        }

        let returnedState = queryItems.first(where: { $0.name == "state" })?.value
        if returnedState != pendingState {
            logger.error("OAuth state mismatch on callback.", category: "OAuth")
            continuation.resume(throwing: OAuthServiceError.stateMismatch)
            pendingCodeContinuation = nil
            return true
        }

        guard let code = queryItems.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            logger.error("OAuth callback missing authorization code.", category: "OAuth")
            continuation.resume(throwing: OAuthServiceError.missingAuthorizationCode)
            pendingCodeContinuation = nil
            return true
        }

        logger.info("OAuth callback returned authorization code.", category: "OAuth")
        continuation.resume(returning: code)
        pendingCodeContinuation = nil
        return true
    }

    func refreshAccessToken(refreshToken: String) async throws -> OAuthTokenResponse {
        logger.info("Refreshing OAuth access token.", category: "OAuth")
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var bodyItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken)
        ]
        if let clientSecret = config.clientSecret {
            bodyItems.append(URLQueryItem(name: "client_secret", value: clientSecret))
        }

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = bodyItems
        request.httpBody = bodyComponents.query?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            logger.error("Refresh token response was not HTTP.", category: "OAuth")
            throw OAuthServiceError.tokenExchangeFailed("Invalid token response.")
        }

        if (200 ..< 300).contains(http.statusCode) {
            logger.info("Access token refresh succeeded.", category: "OAuth")
            return try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        }

        let decodedError = try? JSONDecoder().decode(OAuthTokenErrorResponse.self, from: data)
        let message = decodedError?.errorDescription ?? decodedError?.error ?? "Failed to refresh Gmail access token (HTTP \(http.statusCode))."
        logger.error("Access token refresh failed.", category: "OAuth", metadata: ["status": "\(http.statusCode)", "error": message])
        throw OAuthServiceError.tokenExchangeFailed(message)
    }

    private func exchangeCodeForToken(code: String, codeVerifier: String) async throws -> OAuthTokenResponse {
        logger.debug("Posting OAuth token exchange request.", category: "OAuth")
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var bodyItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI)
        ]
        if let clientSecret = config.clientSecret {
            bodyItems.append(URLQueryItem(name: "client_secret", value: clientSecret))
        }

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = bodyItems
        request.httpBody = bodyComponents.query?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            logger.error("Token exchange response was not HTTP.", category: "OAuth")
            throw OAuthServiceError.tokenExchangeFailed("Invalid token response.")
        }

        if (200 ..< 300).contains(http.statusCode) {
            logger.info("Token exchange HTTP response succeeded.", category: "OAuth")
            return try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        }

        let decodedError = try? JSONDecoder().decode(OAuthTokenErrorResponse.self, from: data)
        let message = decodedError?.errorDescription ?? decodedError?.error ?? "Failed to exchange authorization code (HTTP \(http.statusCode))."
        logger.error("Token exchange HTTP response failed.", category: "OAuth", metadata: ["status": "\(http.statusCode)", "error": message])
        throw OAuthServiceError.tokenExchangeFailed(message)
    }

    private func buildAuthorizationURL(state: String, codeChallenge: String) throws -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "include_granted_scopes", value: "true")
        ]

        guard let url = components?.url else {
            throw OAuthServiceError.invalidConfiguration("Could not build Gmail OAuth authorization URL.")
        }
        return url
    }

    private var shouldUseLoopbackReceiver: Bool {
        guard let components = URLComponents(string: config.redirectURI),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              components.port != nil else {
            return false
        }
        guard scheme == "http" || scheme == "https" else {
            return false
        }
        return host == "127.0.0.1" || host == "localhost"
    }

    private func receiveCodeFromLoopbackRedirect(expectedState: String) async throws -> String {
        guard let redirect = URLComponents(string: config.redirectURI),
              let portValue = redirect.port,
              let port = NWEndpoint.Port(rawValue: UInt16(portValue)) else {
            throw OAuthServiceError.invalidConfiguration("Loopback redirect URI must include a valid localhost port.")
        }

        let expectedPath = redirect.path.isEmpty ? "/" : redirect.path
        let queue = DispatchQueue(label: "InboxGlide.OAuth.Loopback")
        let listener = try NWListener(using: .tcp, on: port)
        let completionState = LoopbackCompletionState()
        logger.info(
            "Starting loopback listener for OAuth callback.",
            category: "OAuth",
            metadata: ["port": "\(portValue)", "path": expectedPath]
        )

        return try await withCheckedThrowingContinuation { continuation in
            @Sendable func finish(_ result: Result<String, Error>) {
                guard completionState.markIfNotCompleted() else { return }
                listener.cancel()
                switch result {
                case .success(let code):
                    continuation.resume(returning: code)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    self.logger.error("Loopback listener failed.", category: "OAuth", metadata: ["error": error.localizedDescription])
                    finish(.failure(error))
                }
            }

            listener.newConnectionHandler = { connection in
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, error in
                    if let error {
                        self.logger.error("Loopback receive failed.", category: "OAuth", metadata: ["error": error.localizedDescription])
                        finish(.failure(error))
                        connection.cancel()
                        return
                    }

                    guard let data, let request = String(data: data, encoding: .utf8) else {
                        self.logger.error("Loopback request payload could not be decoded.", category: "OAuth")
                        finish(.failure(OAuthServiceError.invalidRedirect))
                        connection.cancel()
                        return
                    }

                    let pathAndQuery = Self.pathAndQuery(fromHTTPRequest: request)
                    guard let rawPathAndQuery = pathAndQuery else {
                        self.logger.error("Loopback callback request line malformed.", category: "OAuth")
                        Self.respondPlainText(connection: connection, statusCode: 400, body: "Invalid OAuth callback.")
                        finish(.failure(OAuthServiceError.invalidRedirect))
                        return
                    }

                    guard let callbackURL = URL(string: "http://localhost\(rawPathAndQuery)"),
                          let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
                        self.logger.error("Loopback callback URL parsing failed.", category: "OAuth")
                        Self.respondPlainText(connection: connection, statusCode: 400, body: "Invalid OAuth callback.")
                        finish(.failure(OAuthServiceError.invalidRedirect))
                        return
                    }

                    guard callbackComponents.path == expectedPath else {
                        self.logger.error(
                            "Loopback callback path mismatch.",
                            category: "OAuth",
                            metadata: ["receivedPath": callbackComponents.path, "expectedPath": expectedPath]
                        )
                        Self.respondPlainText(connection: connection, statusCode: 400, body: "Unexpected OAuth callback path.")
                        finish(.failure(OAuthServiceError.invalidRedirect))
                        return
                    }

                    let queryItems = callbackComponents.queryItems ?? []
                    if let error = queryItems.first(where: { $0.name == "error" })?.value {
                        let description = queryItems.first(where: { $0.name == "error_description" })?.value
                        self.logger.error("Loopback callback contains OAuth error.", category: "OAuth", metadata: ["error": description ?? error])
                        Self.respondPlainText(connection: connection, statusCode: 400, body: "Google authorization failed. Return to InboxGlide.")
                        finish(.failure(OAuthServiceError.authorizationDenied(description ?? error)))
                        return
                    }

                    let returnedState = queryItems.first(where: { $0.name == "state" })?.value
                    guard returnedState == expectedState else {
                        self.logger.error("Loopback callback state mismatch.", category: "OAuth")
                        Self.respondPlainText(connection: connection, statusCode: 400, body: "OAuth state mismatch. Return to InboxGlide and try again.")
                        finish(.failure(OAuthServiceError.stateMismatch))
                        return
                    }

                    guard let code = queryItems.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
                        self.logger.error("Loopback callback missing code.", category: "OAuth")
                        Self.respondPlainText(connection: connection, statusCode: 400, body: "Missing authorization code. Return to InboxGlide.")
                        finish(.failure(OAuthServiceError.missingAuthorizationCode))
                        return
                    }

                    self.logger.info("Loopback callback completed successfully.", category: "OAuth")
                    Self.respondPlainText(connection: connection, statusCode: 200, body: "Gmail connected. You can close this tab and return to InboxGlide.")
                    finish(.success(code))
                }
            }

            listener.start(queue: queue)

            queue.asyncAfter(deadline: .now() + 180) {
                self.logger.warning("Loopback callback listener timed out.", category: "OAuth")
                finish(.failure(OAuthServiceError.oauthTimeout))
            }
        }
    }

    private func matchesRedirectURL(_ url: URL) -> Bool {
        guard let expected = URLComponents(string: config.redirectURI),
              let actual = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }

        let expectedScheme = expected.scheme ?? ""
        let actualScheme = actual.scheme ?? ""
        if expectedScheme != actualScheme {
            return false
        }

        let expectedHost = expected.host ?? ""
        let actualHost = actual.host ?? ""
        if expectedHost != actualHost {
            return false
        }

        let expectedPath = expected.path
        let actualPath = actual.path
        return expectedPath == actualPath
    }

    private static func pathAndQuery(fromHTTPRequest request: String) -> String? {
        guard let firstLine = request.components(separatedBy: "\r\n").first else {
            return nil
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            return nil
        }
        return String(parts[1])
    }

    private static func respondPlainText(connection: NWConnection, statusCode: Int, body: String) {
        let statusText = statusCode == 200 ? "OK" : "Bad Request"
        let bytes = Array(body.utf8)
        let response = """
        HTTP/1.1 \(statusCode) \(statusText)\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Length: \(bytes.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func clearPendingAuthorization() {
        pendingCodeContinuation = nil
        pendingState = nil
        pendingVerifier = nil
    }

    private static func randomBase64URL(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if result != errSecSuccess {
            // Fallback is acceptable here because this only runs if secure random fails.
            bytes = (0..<length).map { _ in UInt8.random(in: 0...255) }
        }

        return Data(bytes).base64URLEncodedString()
    }

    private static func sha256Base64URL(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

private final class LoopbackCompletionState: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func markIfNotCompleted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if completed {
            return false
        }
        completed = true
        return true
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
