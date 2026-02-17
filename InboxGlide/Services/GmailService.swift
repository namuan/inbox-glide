import Foundation

struct GmailProfile: Decodable {
    let emailAddress: String
    let messagesTotal: Int?
    let threadsTotal: Int?
}

final class GmailService {
    private let session: URLSession
    private let logger = AppLogger.shared

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchProfile(accessToken: String) async throws -> GmailProfile {
        logger.debug("Requesting Gmail profile endpoint.", category: "GmailAPI")
        guard let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile") else {
            throw OAuthServiceError.tokenExchangeFailed("Invalid Gmail profile URL.")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            logger.error("Gmail profile response was not HTTP.", category: "GmailAPI")
            throw OAuthServiceError.tokenExchangeFailed("Invalid Gmail profile response.")
        }

        guard (200 ..< 300).contains(http.statusCode) else {
            logger.error("Gmail profile request failed.", category: "GmailAPI", metadata: ["status": "\(http.statusCode)"])
            throw OAuthServiceError.tokenExchangeFailed("Failed to fetch Gmail profile (HTTP \(http.statusCode)).")
        }

        let profile = try JSONDecoder().decode(GmailProfile.self, from: data)
        logger.info(
            "Gmail profile request succeeded.",
            category: "GmailAPI",
            metadata: ["email": profile.emailAddress]
        )
        return profile
    }
}
