import Foundation

final class FastmailCredentialsStore {
    private let keychain = Keychain(service: "InboxGlide.FastmailAppPassword")
    private let logger = AppLogger.shared

    func saveAppPassword(_ password: String, emailAddress: String) throws {
        let cleanedEmail = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedEmail.isEmpty, !cleanedPassword.isEmpty else { return }

        guard let data = cleanedPassword.data(using: .utf8) else {
            throw OAuthServiceError.tokenExchangeFailed("Unable to encode Fastmail app password.")
        }

        try keychain.upsertData(data, account: cleanedEmail)
        logger.info(
            "Saved Fastmail app password in keychain.",
            category: "FastmailAuth",
            metadata: ["email": cleanedEmail]
        )
    }

    func loadAppPassword(emailAddress: String) throws -> String {
        let cleanedEmail = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let data = try keychain.readData(account: cleanedEmail)
        guard let password = String(data: data, encoding: .utf8), !password.isEmpty else {
            throw OAuthServiceError.tokenExchangeFailed("Stored Fastmail app password is invalid.")
        }
        return password
    }

    func deleteAppPassword(emailAddress: String) throws {
        let cleanedEmail = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        try keychain.deleteData(account: cleanedEmail)
        logger.info(
            "Deleted Fastmail app password from keychain.",
            category: "FastmailAuth",
            metadata: ["email": cleanedEmail]
        )
    }
}
