import Foundation

enum AppDirectories {
    static func applicationSupportDirectory(appName: String) throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent(appName, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func logsDirectory(appName: String) throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let logsRoot = base.appendingPathComponent("Logs", isDirectory: true)
        let dir = logsRoot.appendingPathComponent(appName, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
