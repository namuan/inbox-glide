import Foundation

final class FastmailCredentialsStore {
    private let vault = ProviderAppPasswordVault.shared
    private let legacyKeychain = Keychain(service: "InboxGlide.FastmailAppPassword")
    private let logger = AppLogger.shared
    private let providerKey = "fastmail"

    func saveAppPassword(_ password: String, emailAddress: String) throws {
        let cleanedEmail = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedEmail.isEmpty, !cleanedPassword.isEmpty else { return }

        try vault.savePassword(cleanedPassword, providerKey: providerKey, emailAddress: cleanedEmail)
        logger.info(
            "Saved Fastmail app password in keychain.",
            category: "FastmailAuth",
            metadata: ["email": cleanedEmail]
        )
    }

    func loadAppPassword(emailAddress: String) throws -> String {
        let cleanedEmail = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        do {
            return try vault.loadPassword(providerKey: providerKey, emailAddress: cleanedEmail)
        } catch KeychainError.itemNotFound {
            // Migrate legacy per-provider keychain entries into unified vault.
            let data = try legacyKeychain.readData(account: cleanedEmail)
            guard let password = String(data: data, encoding: .utf8), !password.isEmpty else {
                throw OAuthServiceError.tokenExchangeFailed("Stored Fastmail app password is invalid.")
            }
            try vault.savePassword(password, providerKey: providerKey, emailAddress: cleanedEmail)
            try? legacyKeychain.deleteData(account: cleanedEmail)
            return password
        }
    }

    func deleteAppPassword(emailAddress: String) throws {
        let cleanedEmail = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        try vault.deletePassword(providerKey: providerKey, emailAddress: cleanedEmail)
        try? legacyKeychain.deleteData(account: cleanedEmail)
        logger.info(
            "Deleted Fastmail app password from keychain.",
            category: "FastmailAuth",
            metadata: ["email": cleanedEmail]
        )
    }
}
