import Foundation

struct FastmailInboxMessage: Sendable {
    let id: String
    let messageHeaderID: String?
    let inReplyToMessageID: String?
    let referenceMessageIDs: [String]
    let receivedAt: Date
    let senderName: String
    let senderEmail: String
    let subject: String
    let snippet: String
    let body: String
    let htmlBody: String?
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
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .messageNotFound(let id):
            return "Fastmail message \(id) was not found on provider."
        case .connectionFailed(let message):
            return message
        case .parseFailed(let message):
            return message
        case .sendFailed(let message):
            return message
        }
    }
}

final class FastmailService {
    private let logger = AppLogger.shared
    private let timeoutQueue = DispatchQueue(label: "InboxGlide.FastmailService.Timeouts", qos: .utility)
    private var timedOutUIDExpiryByEmail: [String: [String: Date]] = [:]
    private let timeoutSkipDuration: TimeInterval = 20 * 60
    private let providerConfig = MailProviderConfig(
        hostname: "imap.fastmail.com",
        port: 993,
        usesTLS: true,
        supportsIDLE: true
    )
    private let smtpConfig = SMTPProviderConfig(
        hostname: "smtp.fastmail.com",
        port: 465,
        usesTLS: true
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
            await client.disconnect()
            return FastmailInboxPage(messages: items, hasMore: hasMore, nextOffset: nextOffset)
        } catch let error as IMAPClientError {
            await client.disconnect()
            throw mapIMAPError(error, messageID: nil)
        } catch {
            await client.disconnect()
            throw error
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
                    if shouldSkipTimedOutUID(uid, emailAddress: emailAddress) {
                        logger.debug(
                            "Skipping Fastmail message due to recent timeout cooldown.",
                            category: "FastmailAPI",
                            metadata: ["email": emailAddress, "messageID": uid]
                        )
                        continue
                    }
                    do {
                        let fetched = try await client.fetchMessage(uid: uid)
                        batchMessages.append(parseFastmailMessage(from: fetched))
                    } catch let error as IMAPClientError where Self.isTimeout(error) {
                        markTimedOutUID(uid, emailAddress: emailAddress)
                        logger.warning(
                            "Skipping Fastmail message after IMAP timeout during batch fetch.",
                            category: "FastmailAPI",
                            metadata: ["email": emailAddress, "messageID": uid]
                        )
                        continue
                    }
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
            await client.disconnect()
            return cumulative
        } catch let error as IMAPClientError {
            await client.disconnect()
            logger.error(
                "Fastmail progressive fetch failed.",
                category: "FastmailAPI",
                metadata: ["email": emailAddress, "error": error.localizedDescription]
            )
            throw mapIMAPError(error, messageID: nil)
        } catch {
            await client.disconnect()
            throw error
        }
    }

    func trashMessage(emailAddress: String, appPassword: String, id: String) async throws {
        let credentials = IMAPCredentials(username: emailAddress, password: appPassword)
        let client = IMAPNativeClient(config: providerConfig, credentials: credentials)
        do {
            try await client.connect()
            try await client.trashMessage(uid: id)
            await client.disconnect()
            logger.info(
                "Moved Fastmail message to trash.",
                category: "FastmailAPI",
                metadata: ["email": emailAddress, "messageID": id]
            )
        } catch let error as IMAPClientError {
            await client.disconnect()
            throw mapIMAPError(error, messageID: id)
        } catch {
            await client.disconnect()
            throw error
        }
    }

    func archiveMessage(emailAddress: String, appPassword: String, id: String) async throws {
        let credentials = IMAPCredentials(username: emailAddress, password: appPassword)
        let client = IMAPNativeClient(config: providerConfig, credentials: credentials)
        do {
            try await client.connect()
            try await client.archiveMessage(
                uid: id,
                mailboxCandidates: ["Archive", "Archives", "INBOX.Archive", "INBOX.Archives"]
            )
            await client.disconnect()
            logger.info(
                "Archived Fastmail message.",
                category: "FastmailAPI",
                metadata: ["email": emailAddress, "messageID": id]
            )
        } catch let error as IMAPClientError {
            await client.disconnect()
            throw mapIMAPError(error, messageID: id)
        } catch {
            await client.disconnect()
            throw error
        }
    }

    func sendReply(emailAddress: String, appPassword: String, request: ReplySendRequest) async throws {
        let credentials = SMTPCredentials(username: emailAddress, password: appPassword)
        let client = SMTPNativeClient(config: smtpConfig, credentials: credentials)
        let rfc822 = ReplyRFC822Builder.buildReply(from: request, includeFromHeader: true)
        do {
            try await client.sendMail(
                from: emailAddress,
                recipients: [request.recipient.emailAddress],
                rfc822: rfc822
            )
            logger.info(
                "Sent Fastmail reply over SMTP.",
                category: "FastmailAPI",
                metadata: ["email": emailAddress]
            )
        } catch let error as SMTPClientError {
            throw FastmailServiceError.sendFailed(Self.userFacingSendError(for: error))
        }
    }

    private func parseFastmailMessage(from fetched: IMAPFetchedMessage) -> FastmailInboxMessage {
        let parsed = FastmailParsedRFC822Message.parse(from: fetched.rawRFC822)
        let flags = fetched.flags

        return FastmailInboxMessage(
            id: fetched.uid,
            messageHeaderID: parsed.messageHeaderID,
            inReplyToMessageID: parsed.inReplyToMessageID,
            referenceMessageIDs: parsed.referenceMessageIDs,
            receivedAt: fetched.internalDate ?? parsed.date ?? Date(),
            senderName: parsed.senderName,
            senderEmail: parsed.senderEmail,
            subject: parsed.subject.isEmpty ? "(No Subject)" : parsed.subject,
            snippet: parsed.snippet,
            body: parsed.body,
            htmlBody: parsed.htmlBody,
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

    private static func userFacingSendError(for error: SMTPClientError) -> String {
        switch error {
        case .authenticationFailed:
            return "Fastmail rejected authentication. Re-enter your Fastmail app password in Settings and try again."
        case .sendFailed(let statusCode, _):
            switch statusCode {
            case 421, 450, 451, 452:
                return "Fastmail is temporarily unavailable for sending. Please try again shortly."
            case 550, 551, 552, 553, 554:
                return "Fastmail rejected this recipient or message content. Review the reply and try again."
            default:
                return error.localizedDescription
            }
        default:
            return error.localizedDescription
        }
    }

    private static func isTimeout(_ error: IMAPClientError) -> Bool {
        if case .protocolError(let message) = error {
            return message.localizedCaseInsensitiveContains("timed out")
        }
        return false
    }

    private func shouldSkipTimedOutUID(_ uid: String, emailAddress: String) -> Bool {
        timeoutQueue.sync {
            let key = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            cleanupExpiredTimeoutsLocked(for: key)
            guard let expiry = timedOutUIDExpiryByEmail[key]?[uid] else { return false }
            return expiry > Date()
        }
    }

    private func markTimedOutUID(_ uid: String, emailAddress: String) {
        timeoutQueue.sync {
            let key = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            cleanupExpiredTimeoutsLocked(for: key)
            var map = timedOutUIDExpiryByEmail[key] ?? [:]
            map[uid] = Date().addingTimeInterval(timeoutSkipDuration)
            timedOutUIDExpiryByEmail[key] = map
        }
    }

    private func cleanupExpiredTimeoutsLocked(for key: String) {
        guard var map = timedOutUIDExpiryByEmail[key] else { return }
        let now = Date()
        map = map.filter { $0.value > now }
        if map.isEmpty {
            timedOutUIDExpiryByEmail[key] = nil
        } else {
            timedOutUIDExpiryByEmail[key] = map
        }
    }
}

private struct FastmailParsedRFC822Message {
    let senderName: String
    let senderEmail: String
    let subject: String
    let messageHeaderID: String?
    let inReplyToMessageID: String?
    let referenceMessageIDs: [String]
    let date: Date?
    let body: String
    let htmlBody: String?

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
        let messageHeaderID = firstMessageID(from: headers["message-id"])
        let inReplyToMessageID = firstMessageID(from: headers["in-reply-to"])
        let referenceMessageIDs = extractMessageIDList(from: headers["references"])

        let extracted = RFC822BodyExtractor.extract(headers: headers, body: bodyPart)

        return FastmailParsedRFC822Message(
            senderName: sender.name,
            senderEmail: sender.email,
            subject: subject.trimmingCharacters(in: .whitespacesAndNewlines),
            messageHeaderID: messageHeaderID,
            inReplyToMessageID: inReplyToMessageID,
            referenceMessageIDs: referenceMessageIDs,
            date: date,
            body: extracted.text,
            htmlBody: extracted.html
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

    private static func firstMessageID(from rawHeaderValue: String?) -> String? {
        extractMessageIDList(from: rawHeaderValue).first
    }

    private static func extractMessageIDList(from rawHeaderValue: String?) -> [String] {
        guard let rawHeaderValue else { return [] }
        let clean = sanitizeHeaderValue(rawHeaderValue)
        guard !clean.isEmpty else { return [] }

        var extracted: [String] = []
        var current = ""
        var isCapturing = false

        for character in clean {
            if character == "<" {
                current = "<"
                isCapturing = true
                continue
            }
            if isCapturing {
                current.append(character)
                if character == ">" {
                    extracted.append(current)
                    current = ""
                    isCapturing = false
                }
            }
        }

        if extracted.isEmpty {
            extracted = clean.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        return deduplicatedMessageIDs(extracted)
    }

    private static func deduplicatedMessageIDs(_ ids: [String]) -> [String] {
        var unique: [String] = []
        var seen: Set<String> = []
        for raw in ids {
            guard let normalized = normalizedMessageID(raw), seen.insert(normalized).inserted else {
                continue
            }
            unique.append(normalized)
        }
        return unique
    }

    private static func normalizedMessageID(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let clean = sanitizeHeaderValue(rawValue)
        guard !clean.isEmpty else { return nil }

        if clean.hasPrefix("<"), clean.hasSuffix(">") {
            return clean
        }
        if let start = clean.firstIndex(of: "<"), let end = clean[start...].firstIndex(of: ">"), start < end {
            return String(clean[start...end])
        }
        let firstToken = clean.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? clean
        guard !firstToken.isEmpty else { return nil }
        return "<\(firstToken)>"
    }

    private static func sanitizeHeaderValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
