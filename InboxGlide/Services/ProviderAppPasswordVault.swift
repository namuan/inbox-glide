import Foundation

final class ProviderAppPasswordVault {
    static let shared = ProviderAppPasswordVault()

    private let keychain = Keychain(service: "InboxGlide.ProviderAppPasswords")
    private let account = "provider.app-passwords.v1"
    private var cachedPasswords: [String: String]?
    private let lock = NSLock()

    private init() {}

    func savePassword(_ password: String, providerKey: String, emailAddress: String) throws {
        let cleanedEmail = Self.normalizeEmail(emailAddress)
        let cleanedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedEmail.isEmpty, !cleanedPassword.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        var allPasswords = try loadAllPasswordsLocked()
        allPasswords[credentialKey(providerKey: providerKey, emailAddress: cleanedEmail)] = cleanedPassword
        try persistLocked(allPasswords)
    }

    func loadPassword(providerKey: String, emailAddress: String) throws -> String {
        let cleanedEmail = Self.normalizeEmail(emailAddress)

        lock.lock()
        defer { lock.unlock() }

        let allPasswords = try loadAllPasswordsLocked()
        let key = credentialKey(providerKey: providerKey, emailAddress: cleanedEmail)
        guard let password = allPasswords[key], !password.isEmpty else {
            throw KeychainError.itemNotFound
        }
        return password
    }

    func deletePassword(providerKey: String, emailAddress: String) throws {
        let cleanedEmail = Self.normalizeEmail(emailAddress)

        lock.lock()
        defer { lock.unlock() }

        var allPasswords = try loadAllPasswordsLocked()
        allPasswords.removeValue(forKey: credentialKey(providerKey: providerKey, emailAddress: cleanedEmail))
        try persistLocked(allPasswords)
    }

    private func loadAllPasswordsLocked() throws -> [String: String] {
        if let cachedPasswords {
            return cachedPasswords
        }

        do {
            let data = try keychain.readData(account: account)
            let decoded = try JSONDecoder().decode([String: String].self, from: data)
            cachedPasswords = decoded
            return decoded
        } catch KeychainError.itemNotFound {
            let empty: [String: String] = [:]
            cachedPasswords = empty
            return empty
        } catch {
            throw error
        }
    }

    private func persistLocked(_ passwords: [String: String]) throws {
        let data = try JSONEncoder().encode(passwords)
        try keychain.upsertData(data, account: account)
        cachedPasswords = passwords
    }

    private func credentialKey(providerKey: String, emailAddress: String) -> String {
        "\(providerKey):\(emailAddress)"
    }

    private static func normalizeEmail(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
