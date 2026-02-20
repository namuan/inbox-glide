import Foundation
import Network

struct MailProviderConfig {
    let hostname: String
    let port: UInt16
    let usesTLS: Bool
    let supportsIDLE: Bool
}

struct IMAPCredentials {
    let username: String
    let password: String
}

struct IMAPFetchedMessage {
    let uid: String
    let flags: [String]
    let internalDate: Date?
    let rawRFC822: Data
}

protocol MailClient {
    func connect() async throws
    func disconnect() async
    func fetchInboxUIDs(maxResults: Int, offset: Int) async throws -> [String]
    func fetchMessage(uid: String) async throws -> IMAPFetchedMessage
    func archiveMessage(uid: String, mailboxCandidates: [String]) async throws
    func trashMessage(uid: String) async throws
}

enum IMAPClientError: LocalizedError {
    case connectionFailed
    case disconnected
    case protocolError(String)
    case authenticationFailed
    case messageNotFound(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Failed to connect to IMAP server."
        case .disconnected:
            return "IMAP connection closed unexpectedly."
        case .protocolError(let message):
            return message
        case .authenticationFailed:
            return "IMAP authentication failed. Check your email/app password."
        case .messageNotFound(let uid):
            return "IMAP message \(uid) was not found."
        case .invalidResponse(let message):
            return message
        }
    }
}

actor IMAPNativeClient: MailClient {
    private let config: MailProviderConfig
    private let credentials: IMAPCredentials
    private let logger = AppLogger.shared

    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var commandCounter = 1
    private var isConnected = false
    private let commandTimeoutSeconds: Double = 20

    init(config: MailProviderConfig, credentials: IMAPCredentials) {
        self.config = config
        self.credentials = credentials
    }

    func connect() async throws {
        if isConnected { return }
        let connectStartedAt = Date()
        logger.debug(
            "IMAP connect starting.",
            category: "IMAP",
            metadata: ["host": config.hostname, "port": "\(config.port)"]
        )

        let port = NWEndpoint.Port(rawValue: config.port) ?? .imaps
        let params: NWParameters = config.usesTLS ? .tls : .tcp
        let connection = NWConnection(host: NWEndpoint.Host(config.hostname), port: port, using: params)
        self.connection = connection

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: IMAPClientError.connectionFailed)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }

        let greeting = try await readLine()
        guard greeting.hasPrefix("* ") else {
            throw IMAPClientError.invalidResponse("Invalid IMAP greeting.")
        }
        logger.debug("IMAP server greeting received.", category: "IMAP", metadata: ["greeting": greeting])

        do {
            _ = try await sendCommand("LOGIN \(imapQuoted(credentials.username)) \(imapQuoted(credentials.password))")
        } catch let error as IMAPClientError {
            if case .protocolError(let message) = error,
               message.localizedCaseInsensitiveContains("AUTH") || message.localizedCaseInsensitiveContains("LOGIN") {
                throw IMAPClientError.authenticationFailed
            }
            throw error
        }

        _ = try await sendCommand("SELECT INBOX")
        isConnected = true
        let durationMs = Int(Date().timeIntervalSince(connectStartedAt) * 1000)
        logger.info(
            "IMAP session connected.",
            category: "IMAP",
            metadata: ["host": config.hostname, "port": "\(config.port)", "durationMs": "\(durationMs)"]
        )
    }

    func disconnect() async {
        if let connection {
            _ = try? await sendCommand("LOGOUT")
            connection.cancel()
        }
        connection = nil
        receiveBuffer = Data()
        isConnected = false
    }

    func fetchInboxUIDs(maxResults: Int, offset: Int = 0) async throws -> [String] {
        logger.debug(
            "IMAP UID SEARCH requested.",
            category: "IMAP",
            metadata: ["maxResults": "\(maxResults)", "offset": "\(offset)"]
        )
        let raw = try await sendCommand("UID SEARCH ALL")
        let text = String(data: raw, encoding: .isoLatin1) ?? ""

        guard let line = text.components(separatedBy: "\r\n").first(where: { $0.hasPrefix("* SEARCH") }) else {
            return []
        }

        let parts = line.replacingOccurrences(of: "* SEARCH", with: "")
            .split(separator: " ")
            .map(String.init)
        let sorted = parts.sorted { (lhs, rhs) -> Bool in
            Int(lhs) ?? 0 > Int(rhs) ?? 0
        }
        let start = max(0, min(offset, sorted.count))
        let end = max(start, min(start + max(1, maxResults), sorted.count))
        let result = Array(sorted[start..<end])
        logger.debug(
            "IMAP UID SEARCH parsed.",
            category: "IMAP",
            metadata: ["totalUIDs": "\(sorted.count)", "returnedUIDs": "\(result.count)"]
        )
        return result
    }

    func fetchMessage(uid: String) async throws -> IMAPFetchedMessage {
        let startedAt = Date()
        let raw = try await sendCommand("UID FETCH \(uid) (FLAGS INTERNALDATE RFC822)")
        let text = String(data: raw, encoding: .isoLatin1) ?? ""

        let flags = parseFlags(from: text)
        let internalDate = parseInternalDate(from: text)
        let rawMessage: Data
        do {
            rawMessage = try parseLiteral(from: raw)
        } catch {
            logger.error(
                "IMAP UID FETCH missing RFC822 literal.",
                category: "IMAP",
                metadata: [
                    "uid": uid,
                    "response": preview(raw),
                    "error": error.localizedDescription
                ]
            )
            throw error
        }
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        logger.debug(
            "IMAP UID FETCH parsed.",
            category: "IMAP",
            metadata: [
                "uid": uid,
                "flags": "\(flags.count)",
                "rfc822Bytes": "\(rawMessage.count)",
                "durationMs": "\(durationMs)"
            ]
        )
        return IMAPFetchedMessage(uid: uid, flags: flags, internalDate: internalDate, rawRFC822: rawMessage)
    }

    func trashMessage(uid: String) async throws {
        do {
            _ = try await sendCommand("UID STORE \(uid) +FLAGS.SILENT (\\Deleted)")
            _ = try await sendCommand("EXPUNGE")
        } catch let error as IMAPClientError {
            if case .protocolError(let message) = error,
               message.localizedCaseInsensitiveContains("not") ||
               message.localizedCaseInsensitiveContains("no such") {
                throw IMAPClientError.messageNotFound(uid)
            }
            throw error
        }
    }

    func archiveMessage(uid: String, mailboxCandidates: [String]) async throws {
        let candidates = mailboxCandidates.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !candidates.isEmpty else {
            throw IMAPClientError.protocolError("No archive mailbox candidates provided.")
        }

        var lastError: Error?
        for mailbox in candidates {
            do {
                _ = try await sendCommand("UID COPY \(uid) \(imapQuoted(mailbox))")
                _ = try await sendCommand("UID STORE \(uid) +FLAGS.SILENT (\\Deleted)")
                _ = try await sendCommand("EXPUNGE")
                return
            } catch {
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }
        throw IMAPClientError.protocolError("Archiving failed for message \(uid).")
    }

    private func sendCommand(_ command: String) async throws -> Data {
        guard let connection else {
            throw IMAPClientError.disconnected
        }
        let startedAt = Date()
        let tag = nextTag()
        let payload = "\(tag) \(command)\r\n"
        let safeCommand = redactedCommand(command)
        logger.debug("IMAP command sent.", category: "IMAP", metadata: ["tag": tag, "command": safeCommand])
        try await sendRaw(payload, over: connection)
        let response = try await withTimeout(seconds: commandTimeoutSeconds) {
            try await self.readUntilTaggedLine(tag: tag)
        }
        let status = parseTaggedStatus(tag: tag, from: response)
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        switch status {
        case .ok:
            logger.debug(
                "IMAP command completed.",
                category: "IMAP",
                metadata: ["tag": tag, "command": safeCommand, "durationMs": "\(durationMs)"]
            )
            return response
        case .no:
            logger.warning(
                "IMAP command returned NO.",
                category: "IMAP",
                metadata: [
                    "tag": tag,
                    "command": safeCommand,
                    "durationMs": "\(durationMs)",
                    "response": preview(response)
                ]
            )
            throw IMAPClientError.protocolError("IMAP NO for command: \(safeCommand)")
        case .bad:
            logger.warning(
                "IMAP command returned BAD.",
                category: "IMAP",
                metadata: [
                    "tag": tag,
                    "command": safeCommand,
                    "durationMs": "\(durationMs)",
                    "response": preview(response)
                ]
            )
            throw IMAPClientError.protocolError("IMAP BAD for command: \(safeCommand)")
        case .unknown:
            logger.error(
                "Failed to parse IMAP tagged response.",
                category: "IMAP",
                metadata: [
                    "tag": tag,
                    "command": safeCommand,
                    "durationMs": "\(durationMs)",
                    "response": preview(response)
                ]
            )
            throw IMAPClientError.invalidResponse("Unable to parse IMAP tagged response.")
        }
    }

    private func sendRaw(_ string: String, over connection: NWConnection) async throws {
        let data = Data(string.utf8)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
            })
        }
    }

    private func readLine() async throws -> String {
        while true {
            if let range = receiveBuffer.range(of: Data("\r\n".utf8)) {
                let lineData = receiveBuffer.subdata(in: 0..<range.lowerBound)
                receiveBuffer.removeSubrange(0..<range.upperBound)
                return String(data: lineData, encoding: .isoLatin1) ?? ""
            }
            let chunk = try await receiveChunk()
            receiveBuffer.append(chunk)
        }
    }

    private func readUntilTaggedLine(tag: String) async throws -> Data {
        var output = Data()
        while true {
            if let end = taggedResponseEndIndex(in: receiveBuffer, tag: tag) {
                output.append(receiveBuffer.subdata(in: 0..<end))
                receiveBuffer.removeSubrange(0..<end)
                return output
            }
            let chunk = try await receiveChunk()
            receiveBuffer.append(chunk)
        }
    }

    private func taggedResponseEndIndex(in data: Data, tag: String) -> Int? {
        let text = String(data: data, encoding: .isoLatin1) ?? ""
        let token = "\(tag) "
        let starts: [Range<String.Index>?] = [
            text.range(of: "\r\n\(token)"),
            text.range(of: "\n\(token)")
        ]

        for maybeStart in starts {
            guard let startRange = maybeStart else { continue }
            let lineStart = text.index(after: startRange.lowerBound)
            if let lineEnd = text.range(of: "\r\n", range: lineStart..<text.endIndex)?.upperBound
                ?? text.range(of: "\n", range: lineStart..<text.endIndex)?.upperBound {
                let prefix = String(text[..<lineEnd])
                return prefix.data(using: .isoLatin1)?.count
            }
            if text[lineStart...].hasPrefix(token) {
                return data.count
            }
        }

        if text.hasPrefix(token) {
            if let lineEnd = text.range(of: "\r\n")?.upperBound ?? text.range(of: "\n")?.upperBound {
                let prefix = String(text[..<lineEnd])
                return prefix.data(using: .isoLatin1)?.count
            }
            return data.count
        }

        return nil
    }

    private func receiveChunk() async throws -> Data {
        guard let connection else {
            throw IMAPClientError.disconnected
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data, !data.isEmpty else {
                    if isComplete {
                        continuation.resume(throwing: IMAPClientError.disconnected)
                    } else {
                        continuation.resume(returning: Data())
                    }
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    private func nextTag() -> String {
        defer { commandCounter += 1 }
        return String(format: "A%04d", commandCounter)
    }

    private enum TaggedStatus {
        case ok
        case no
        case bad
        case unknown
    }

    private func parseTaggedStatus(tag: String, from data: Data) -> TaggedStatus {
        let text = String(data: data, encoding: .isoLatin1) ?? ""
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        guard let line = lines.last(where: { $0.hasPrefix(tag + " ") }) else {
            return .unknown
        }

        let upper = line.uppercased()
        if upper.contains(" OK") || upper == "\(tag) OK" { return .ok }
        if upper.contains(" NO") || upper == "\(tag) NO" { return .no }
        if upper.contains(" BAD") || upper == "\(tag) BAD" { return .bad }
        return .unknown
    }

    private func preview(_ data: Data, maxLength: Int = 500) -> String {
        let raw = String(data: data, encoding: .isoLatin1) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxLength {
            return trimmed
        }
        return String(trimmed.prefix(maxLength)) + "...(truncated)"
    }

    private func redactedCommand(_ command: String) -> String {
        if command.uppercased().hasPrefix("LOGIN ") {
            return "LOGIN [REDACTED]"
        }
        return command
    }

    private func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw IMAPClientError.protocolError("IMAP command timed out after \(Int(seconds))s.")
            }
            guard let result = try await group.next() else {
                throw IMAPClientError.protocolError("IMAP command timed out.")
            }
            group.cancelAll()
            return result
        }
    }

    private func parseLiteral(from data: Data) throws -> Data {
        let text = String(data: data, encoding: .isoLatin1) ?? ""
        let regex = try NSRegularExpression(pattern: "\\{([0-9]+)\\}\\r\\n")
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let lenRange = Range(match.range(at: 1), in: text),
              let fullRange = Range(match.range(at: 0), in: text) else {
            throw IMAPClientError.invalidResponse("Missing IMAP literal in FETCH response.")
        }

        let length = Int(text[lenRange]) ?? 0
        let start = text.distance(from: text.startIndex, to: fullRange.upperBound)
        let end = start + length
        guard end <= data.count else {
            throw IMAPClientError.invalidResponse("Invalid IMAP literal length.")
        }
        return data.subdata(in: start..<end)
    }

    private func parseFlags(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "FLAGS \\(([^)]*)\\)"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return []
        }
        return text[range]
            .split(separator: " ")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func parseInternalDate(from text: String) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: "INTERNALDATE \"([^\"]+)\""),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let raw = String(text[range])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        return formatter.date(from: raw)
    }

    private func imapQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
