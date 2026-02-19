import CryptoKit
import Foundation

final class SecureStore {
    private let appName: String
    private let keychain: Keychain
    private let keyAccount = "encryptionKey"
    private let storeFileName = "store.bin"
    private let logger = AppLogger.shared
    private let keyLock = NSLock()
    private var cachedKey: SymmetricKey?

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
            logger.debug("Loaded encrypted store snapshot from disk.", category: "SecureStore", metadata: ["path": url.path])
            return try decoder.decode(T.self, from: plaintext)
        } catch {
            logger.warning("Secure store load failed or no data yet.", category: "SecureStore", metadata: ["error": error.localizedDescription])
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
            logger.debug("Saved encrypted store snapshot to disk.", category: "SecureStore", metadata: ["path": url.path])
        } catch {
            // Best-effort; app continues.
            logger.error("Secure store save failed.", category: "SecureStore", metadata: ["error": error.localizedDescription])
        }
    }

    func deleteStoreFile() {
        do {
            let url = try storeURL()
            try FileManager.default.removeItem(at: url)
            logger.info("Deleted secure store file.", category: "SecureStore", metadata: ["path": url.path])
        } catch {
            // Ignore.
            logger.warning("Delete secure store file failed or file missing.", category: "SecureStore", metadata: ["error": error.localizedDescription])
        }
    }

    private func storeURL() throws -> URL {
        let dir = try AppDirectories.applicationSupportDirectory(appName: appName)
        return dir.appendingPathComponent(storeFileName, isDirectory: false)
    }

    private func loadOrCreateKey() throws -> SymmetricKey {
        keyLock.lock()
        if let cachedKey {
            keyLock.unlock()
            return cachedKey
        }
        keyLock.unlock()

        do {
            let data = try keychain.readData(account: keyAccount)
            let key = SymmetricKey(data: data)
            keyLock.lock()
            cachedKey = key
            keyLock.unlock()
            return key
        } catch KeychainError.itemNotFound {
            let key = SymmetricKey(size: .bits256)
            let data = key.withUnsafeBytes { Data($0) }
            try keychain.upsertData(data, account: keyAccount)
            keyLock.lock()
            cachedKey = key
            keyLock.unlock()
            return key
        }
    }
}
