import Foundation

struct FastmailInboxMessage: Sendable {
    let id: String
    let receivedAt: Date
    let senderName: String
    let senderEmail: String
    let subject: String
    let snippet: String
    let body: String
    let labels: [String]
    let isUnread: Bool
    let isStarred: Bool
    let isImportant: Bool
}

struct FastmailInboxPage: Sendable {
    let messages: [FastmailInboxMessage]
    let hasMore: Bool
    let nextOffset: Int?
}

enum FastmailServiceError: LocalizedError {
    case messageNotFound(String)
    case connectionFailed(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .messageNotFound(let id):
            return "Fastmail message \(id) was not found on provider."
        case .connectionFailed(let message):
            return message
        case .parseFailed(let message):
            return message
        }
    }
}

final class FastmailService {
    private let logger = AppLogger.shared
    private let providerConfig = MailProviderConfig(
        hostname: "imap.fastmail.com",
        port: 993,
        usesTLS: true,
        supportsIDLE: true
    )

    func fetchRecentInboxMessages(emailAddress: String, appPassword: String, maxResults: Int = 25) async throws -> [FastmailInboxMessage] {
        let page = try await fetchRecentInboxMessagesPage(
            emailAddress: emailAddress,
            appPassword: appPassword,
            maxResults: maxResults,
            offset: 0
        )
        return page.messages
    }

    func fetchRecentInboxMessagesPage(emailAddress: String, appPassword: String, maxResults: Int = 25, offset: Int = 0) async throws -> FastmailInboxPage {
        let credentials = IMAPCredentials(username: emailAddress, password: appPassword)
        let client = IMAPNativeClient(config: providerConfig, credentials: credentials)
        do {
            try await client.connect()
            defer { Task { await client.disconnect() } }

            let uids = try await client.fetchInboxUIDs(maxResults: maxResults, offset: offset)
            var items: [FastmailInboxMessage] = []
            items.reserveCapacity(uids.count)
            for uid in uids {
                let fetched = try await client.fetchMessage(uid: uid)
                items.append(parseFastmailMessage(from: fetched))
            }

            let hasMore = uids.count == max(1, maxResults)
            let nextOffset = hasMore ? (offset + uids.count) : nil
            logger.info(
                "Fetched Fastmail inbox messages.",
                category: "FastmailAPI",
                metadata: [
                    "email": emailAddress,
                    "count": "\(items.count)",
                    "offset": "\(offset)",
                    "hasMore": "\(hasMore)"
                ]
            )
            return FastmailInboxPage(messages: items, hasMore: hasMore, nextOffset: nextOffset)
        } catch let error as IMAPClientError {
            throw mapIMAPError(error, messageID: nil)
        }
    }

    @discardableResult
    func fetchRecentInboxMessagesProgressive(
        emailAddress: String,
        appPassword: String,
        maxResults: Int = 90,
        batchSize: Int = 15,
        onBatch: @escaping (_ cumulative: Int, _ batchCount: Int, _ messages: [FastmailInboxMessage]) -> Void
    ) async throws -> Int {
        logger.info(
            "Fastmail service progressive fetch requested.",
            category: "FastmailAPI",
            metadata: [
                "email": emailAddress,
                "maxResults": "\(maxResults)",
                "batchSize": "\(batchSize)"
            ]
        )
        let startedAt = Date()
        let credentials = IMAPCredentials(username: emailAddress, password: appPassword)
        let client = IMAPNativeClient(config: providerConfig, credentials: credentials)
        do {
            try await client.connect()
            defer { Task { await client.disconnect() } }
            logger.debug("Fastmail IMAP client connected for progressive fetch.", category: "FastmailAPI", metadata: ["email": emailAddress])

            let target = max(1, min(maxResults, 200))
            let uids = try await client.fetchInboxUIDs(maxResults: target, offset: 0)
            let chunkSize = max(1, min(batchSize, target))
            logger.info(
                "Fastmail UID list fetched for progressive sync.",
                category: "FastmailAPI",
                metadata: [
                    "email": emailAddress,
                    "uidCount": "\(uids.count)",
                    "chunkSize": "\(chunkSize)"
                ]
            )

            var cumulative = 0
            var index = 0
            var batchIndex = 0
            while index < uids.count {
                batchIndex += 1
                let end = min(uids.count, index + chunkSize)
                let batchUIDs = uids[index..<end]
                var batchMessages: [FastmailInboxMessage] = []
                batchMessages.reserveCapacity(batchUIDs.count)
                logger.debug(
                    "Fastmail progressive batch started.",
                    category: "FastmailAPI",
                    metadata: [
                        "email": emailAddress,
                        "batchIndex": "\(batchIndex)",
                        "batchUIDCount": "\(batchUIDs.count)",
                        "offset": "\(index)"
                    ]
                )

                for uid in batchUIDs {
                    let fetched = try await client.fetchMessage(uid: uid)
                    batchMessages.append(parseFastmailMessage(from: fetched))
                }

                cumulative += batchMessages.count
                onBatch(cumulative, batchMessages.count, batchMessages)
                logger.debug(
                    "Fastmail progressive batch completed.",
                    category: "FastmailAPI",
                    metadata: [
                        "email": emailAddress,
                        "batchIndex": "\(batchIndex)",
                        "batchCount": "\(batchMessages.count)",
                        "cumulative": "\(cumulative)"
                    ]
                )
                index = end
            }

            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            logger.info(
                "Progressive Fastmail fetch completed.",
                category: "FastmailAPI",
                metadata: [
                    "email": emailAddress,
                    "fetched": "\(cumulative)",
                    "durationMs": "\(durationMs)"
                ]
            )
            return cumulative
        } catch let error as IMAPClientError {
            logger.error(
                "Fastmail progressive fetch failed.",
                category: "FastmailAPI",
                metadata: ["email": emailAddress, "error": error.localizedDescription]
            )
            throw mapIMAPError(error, messageID: nil)
        }
    }

    func trashMessage(emailAddress: String, appPassword: String, id: String) async throws {
        let credentials = IMAPCredentials(username: emailAddress, password: appPassword)
        let client = IMAPNativeClient(config: providerConfig, credentials: credentials)
        do {
            try await client.connect()
            defer { Task { await client.disconnect() } }
            try await client.trashMessage(uid: id)
            logger.info(
                "Moved Fastmail message to trash.",
                category: "FastmailAPI",
                metadata: ["email": emailAddress, "messageID": id]
            )
        } catch let error as IMAPClientError {
            throw mapIMAPError(error, messageID: id)
        }
    }

    private func parseFastmailMessage(from fetched: IMAPFetchedMessage) -> FastmailInboxMessage {
        let parsed = FastmailParsedRFC822Message.parse(from: fetched.rawRFC822)
        let flags = fetched.flags

        return FastmailInboxMessage(
            id: fetched.uid,
            receivedAt: fetched.internalDate ?? parsed.date ?? Date(),
            senderName: parsed.senderName,
            senderEmail: parsed.senderEmail,
            subject: parsed.subject.isEmpty ? "(No Subject)" : parsed.subject,
            snippet: parsed.snippet,
            body: parsed.body,
            labels: flags,
            isUnread: !flags.contains(where: { $0.caseInsensitiveCompare("\\Seen") == .orderedSame }),
            isStarred: flags.contains(where: { $0.caseInsensitiveCompare("\\Flagged") == .orderedSame }),
            isImportant: flags.contains(where: { $0.caseInsensitiveCompare("\\Flagged") == .orderedSame })
        )
    }

    private func mapIMAPError(_ error: IMAPClientError, messageID: String?) -> FastmailServiceError {
        switch error {
        case .messageNotFound(let id):
            return .messageNotFound(messageID ?? id)
        default:
            return .connectionFailed(error.localizedDescription)
        }
    }
}

private struct FastmailParsedRFC822Message {
    let senderName: String
    let senderEmail: String
    let subject: String
    let date: Date?
    let body: String

    var snippet: String {
        body
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(220)
            .description
    }

    static func parse(from data: Data) -> FastmailParsedRFC822Message {
        let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let separator = raw.range(of: "\r\n\r\n") ?? raw.range(of: "\n\n")
        let headerPart = separator.map { String(raw[..<$0.lowerBound]) } ?? raw
        let bodyPart = separator.map { String(raw[$0.upperBound...]) } ?? ""

        let headers = parseHeaders(from: headerPart)
        let fromRaw = headers["from"] ?? ""
        let sender = parseFromHeader(fromRaw)
        let subject = headers["subject"] ?? "(No Subject)"
        let date = parseDate(headers["date"])

        let body: String
        if bodyPart.contains("<html") || bodyPart.contains("<HTML") {
            body = htmlToText(bodyPart)
        } else {
            body = bodyPart.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return FastmailParsedRFC822Message(
            senderName: sender.name,
            senderEmail: sender.email,
            subject: subject.trimmingCharacters(in: .whitespacesAndNewlines),
            date: date,
            body: body
        )
    }

    private static func parseHeaders(from headerBlock: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentKey: String?

        let lines = headerBlock.components(separatedBy: .newlines)
        for line in lines {
            if line.hasPrefix(" ") || line.hasPrefix("\t"), let currentKey {
                result[currentKey, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            result[key] = value
            currentKey = key
        }
        return result
    }

    private static func parseFromHeader(_ raw: String) -> (name: String, email: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = trimmed.lastIndex(of: "<"), let end = trimmed.lastIndex(of: ">"), start < end {
            let namePart = trimmed[..<start].trimmingCharacters(in: .whitespacesAndNewlines)
            let emailPart = trimmed[trimmed.index(after: start)..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanName = namePart.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let finalName = cleanName.isEmpty ? emailPart : cleanName
            return (finalName, emailPart.isEmpty ? "unknown@example.com" : emailPart)
        }
        return (trimmed.isEmpty ? "Unknown" : trimmed, trimmed.contains("@") ? trimmed : "unknown@example.com")
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        if let date = formatter.date(from: raw) { return date }
        formatter.dateFormat = "d MMM yyyy HH:mm:ss Z"
        return formatter.date(from: raw)
    }

    private static func htmlToText(_ html: String) -> String {
        guard let data = html.data(using: .utf8) else { return html }
        if let attributed = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        ) {
            return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return html
    }
}
