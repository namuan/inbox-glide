import CryptoKit
import Foundation

final class SecureStore {
    private let appName: String
    private let keychain: Keychain
    private let keyAccount = "encryptionKey"
    private let storeFileName = "store.bin"

    init(appName: String) {
        self.appName = appName
        self.keychain = Keychain(service: "\(appName).SecureStore")
    }

    func load<T: Decodable>(_ type: T.Type) -> T? {
        do {
            let url = try storeURL()
            let data = try Data(contentsOf: url)
            let key = try loadOrCreateKey()

            let box = try AES.GCM.SealedBox(combined: data)
            let plaintext = try AES.GCM.open(box, using: key)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: plaintext)
        } catch {
            return nil
        }
    }

    func save<T: Encodable>(_ value: T) {
        do {
            let url = try storeURL()
            let key = try loadOrCreateKey()

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let plaintext = try encoder.encode(value)

            let sealed = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealed.combined else { return }
            try combined.write(to: url, options: [.atomic])
        } catch {
            // Best-effort; app continues.
        }
    }

    func deleteStoreFile() {
        do {
            let url = try storeURL()
            try FileManager.default.removeItem(at: url)
        } catch {
            // Ignore.
        }
    }

    private func storeURL() throws -> URL {
        let dir = try AppDirectories.applicationSupportDirectory(appName: appName)
        return dir.appendingPathComponent(storeFileName, isDirectory: false)
    }

    private func loadOrCreateKey() throws -> SymmetricKey {
        do {
            let data = try keychain.readData(account: keyAccount)
            return SymmetricKey(data: data)
        } catch KeychainError.itemNotFound {
            let key = SymmetricKey(size: .bits256)
            let data = key.withUnsafeBytes { Data($0) }
            try keychain.upsertData(data, account: keyAccount)
            return key
        }
    }
}
