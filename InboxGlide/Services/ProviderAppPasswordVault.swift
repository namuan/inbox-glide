import Foundation

final class ProviderAppPasswordVault {
    static let shared = ProviderAppPasswordVault()

    private let keychain = Keychain(service: "InboxGlide.ProviderAppPasswords")
    private let account = "provider.app-passwords.v1"
    private var cachedPasswords: [String: String]?
    private let lock = NSLock()

    private init() {}

    func saveValue(_ value: String, key: String) throws {
        let cleanedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedKey.isEmpty, !cleanedValue.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        var allValues = try loadAllPasswordsLocked()
        allValues[cleanedKey] = cleanedValue
        try persistLocked(allValues)
    }

    func loadValue(key: String) throws -> String {
        let cleanedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)

        lock.lock()
        defer { lock.unlock() }

        let allValues = try loadAllPasswordsLocked()
        guard let value = allValues[cleanedKey], !value.isEmpty else {
            throw KeychainError.itemNotFound
        }
        return value
    }

    func deleteValue(key: String) throws {
        let cleanedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)

        lock.lock()
        defer { lock.unlock() }

        var allValues = try loadAllPasswordsLocked()
        allValues.removeValue(forKey: cleanedKey)
        try persistLocked(allValues)
    }

    func savePassword(_ password: String, providerKey: String, emailAddress: String) throws {
        let cleanedEmail = Self.normalizeEmail(emailAddress)
        let cleanedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedEmail.isEmpty, !cleanedPassword.isEmpty else { return }
        try saveValue(cleanedPassword, key: credentialKey(providerKey: providerKey, emailAddress: cleanedEmail))
    }

    func loadPassword(providerKey: String, emailAddress: String) throws -> String {
        let cleanedEmail = Self.normalizeEmail(emailAddress)
        return try loadValue(key: credentialKey(providerKey: providerKey, emailAddress: cleanedEmail))
    }

    func deletePassword(providerKey: String, emailAddress: String) throws {
        let cleanedEmail = Self.normalizeEmail(emailAddress)
        try deleteValue(key: credentialKey(providerKey: providerKey, emailAddress: cleanedEmail))
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
