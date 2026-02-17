import Foundation

final class AppLogger {
    static let shared = AppLogger(appName: "InboxGlide")

    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    private let appName: String
    private let queue = DispatchQueue(label: "InboxGlide.AppLogger", qos: .utility)
    private let isoFormatter = ISO8601DateFormatter()
    private var fileURL: URL?

    init(appName: String) {
        self.appName = appName
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        queue.async { [weak self] in
            self?.initializeLogFile()
        }
    }

    func debug(_ message: String, category: String = "App", metadata: [String: String] = [:]) {
        log(level: .debug, category: category, message: message, metadata: metadata)
    }

    func info(_ message: String, category: String = "App", metadata: [String: String] = [:]) {
        log(level: .info, category: category, message: message, metadata: metadata)
    }

    func warning(_ message: String, category: String = "App", metadata: [String: String] = [:]) {
        log(level: .warning, category: category, message: message, metadata: metadata)
    }

    func error(_ message: String, category: String = "App", metadata: [String: String] = [:]) {
        log(level: .error, category: category, message: message, metadata: metadata)
    }

    var currentLogFilePath: String? {
        var path: String?
        queue.sync {
            path = fileURL?.path
        }
        return path
    }

    private func log(level: Level, category: String, message: String, metadata: [String: String]) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.fileURL == nil {
                self.initializeLogFile()
            }

            let timestamp = self.isoFormatter.string(from: Date())
            let metadataString: String
            if metadata.isEmpty {
                metadataString = ""
            } else {
                let ordered = metadata.keys.sorted().map { key in
                    "\(key)=\(Self.sanitize(metadata[key] ?? ""))"
                }
                metadataString = " [\(ordered.joined(separator: " "))]"
            }

            let line = "\(timestamp) [\(level.rawValue)] [\(category)] \(Self.sanitize(message))\(metadataString)\n"
            self.append(line)
        }
    }

    private func initializeLogFile() {
        do {
            let logDir = try AppDirectories.logsDirectory(appName: appName)
            try cleanupOldLogs(in: logDir, keep: 12)

            let stamp = isoFormatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let file = logDir.appendingPathComponent("session-\(stamp).log", isDirectory: false)
            let header = "\n=== InboxGlide Log Session Started \(isoFormatter.string(from: Date())) ===\n"

            if !FileManager.default.fileExists(atPath: file.path) {
                try header.data(using: .utf8)?.write(to: file, options: .atomic)
            }
            fileURL = file

            let latest = logDir.appendingPathComponent("latest.log", isDirectory: false)
            try? FileManager.default.removeItem(at: latest)
            try? FileManager.default.createSymbolicLink(at: latest, withDestinationURL: file)
        } catch {
            fputs("[InboxGlideLogger] Failed to initialize log file: \(error)\n", stderr)
        }
    }

    private func append(_ line: String) {
        guard let fileURL, let data = line.data(using: .utf8) else {
            return
        }

        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            fputs("[InboxGlideLogger] Failed to write log: \(error)\n", stderr)
        }
    }

    private func cleanupOldLogs(in directory: URL, keep: Int) throws {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let sessionLogs = urls.filter { $0.lastPathComponent.hasPrefix("session-") && $0.pathExtension == "log" }
        let sorted = try sessionLogs.sorted { lhs, rhs in
            let lv = try lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            let rv = try rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            return lv > rv
        }
        guard sorted.count > keep else { return }

        for url in sorted.dropFirst(keep) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
    }
}
