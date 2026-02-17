import Foundation

struct GmailOAuthConfig {
    let clientID: String
    let clientSecret: String?
    let redirectURI: String
    let scopes: [String]

    static func fromMainBundle() throws -> GmailOAuthConfig {
        let logger = AppLogger.shared
        let dict = Bundle.main.infoDictionary ?? [:]

        guard let clientID = dict["GmailOAuthClientID"] as? String,
              !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OAuthServiceError.invalidConfiguration("Missing GmailOAuthClientID in Info.plist")
        }

        let redirectURI = (dict["GmailOAuthRedirectURI"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let finalRedirectURI: String
        if let redirectURI, !redirectURI.isEmpty {
            finalRedirectURI = redirectURI
        } else {
            finalRedirectURI = "http://127.0.0.1:53682/oauth/callback"
        }

        let clientSecretValue = (dict["GmailOAuthClientSecret"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = (clientSecretValue?.isEmpty == false) ? clientSecretValue : nil

        let scopesString = (dict["GmailOAuthScopes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopes = scopesString?
            .split(separator: " ")
            .map { String($0) }
            .filter { !$0.isEmpty } ?? ["https://www.googleapis.com/auth/gmail.readonly"]

        let config = GmailOAuthConfig(
            clientID: clientID,
            clientSecret: clientSecret,
            redirectURI: finalRedirectURI,
            scopes: scopes
        )
        logger.info(
            "Loaded Gmail OAuth config from Info.plist.",
            category: "OAuthConfig",
            metadata: [
                "redirectURI": config.redirectURI,
                "scopeCount": "\(config.scopes.count)",
                "usesClientSecret": "\(config.clientSecret != nil)"
            ]
        )
        return config
    }
}
