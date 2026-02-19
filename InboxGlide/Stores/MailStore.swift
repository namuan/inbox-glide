import Foundation
import SwiftUI

struct ErrorAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct PendingConfirmation: Identifiable {
    let id = UUID()
    let action: GlideAction
    let isSecondary: Bool
    let messageID: UUID
}

enum MessagePrompt: Identifiable {
    case moveToFolder(messageID: UUID)
    case applyLabel(messageID: UUID)

    var id: String {
        switch self {
        case .moveToFolder(let id): return "moveToFolder:\(id.uuidString)"
        case .applyLabel(let id): return "applyLabel:\(id.uuidString)"
        }
    }
}

enum ComposerMode: String {
    case reply
    case aiReply
}

struct ComposerPresentation: Identifiable {
    let id = UUID()
    let messageID: UUID
    let mode: ComposerMode
}

struct ReminderPresentation: Identifiable {
    let id = UUID()
    let messageID: UUID
}

struct StoreSnapshot: Codable {
    var accounts: [MailAccount]
    var messages: [EmailMessage]
    var blockedSenders: Set<String>
    var unsubscribedSenders: Set<String>
    var queuedActions: [QueuedMailAction]
}

final class MailStore: ObservableObject {
    @Published private(set) var accounts: [MailAccount] = []
    @Published private(set) var messages: [EmailMessage] = []

    @Published var selectedAccountID: UUID? = nil { didSet { rebuildDeck() } }
    @Published var selectedCategory: MessageCategory? = nil { didSet { rebuildDeck() } }

    @Published private(set) var deckMessageIDs: [UUID] = []
    @Published private(set) var queuedActions: [QueuedMailAction] = []
    @Published private(set) var blockedSenders: Set<String> = []
    @Published private(set) var unsubscribedSenders: Set<String> = []

    @Published var pendingConfirmation: PendingConfirmation? = nil
    @Published var prompt: MessagePrompt? = nil
    @Published var composer: ComposerPresentation? = nil
    @Published var reminder: ReminderPresentation? = nil
    @Published var errorAlert: ErrorAlert? = nil

    private let preferences: PreferencesStore
    private let networkMonitor: NetworkMonitor
    private let gmailAuthStore: GmailAuthStore
    private let yahooService: YahooService
    private let yahooCredentialsStore: YahooCredentialsStore
    private let fastmailService: FastmailService
    private let fastmailCredentialsStore: FastmailCredentialsStore
    private let logger = AppLogger.shared
    private let appName = "InboxGlide"
    private let storeFileName = "store.json"

    private var saveWorkItem: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "InboxGlide.MailStore.Save", qos: .utility)
    private var refreshTimer: Timer?
    private var providerSyncTimer: Timer?
    private var isBackgroundSyncInProgress = false
    private var pendingAdvanceMessageID: UUID?
    private var yahooSyncInProgressEmails: Set<String> = []
    private var fastmailSyncInProgressEmails: Set<String> = []

    init(preferences: PreferencesStore, networkMonitor: NetworkMonitor, gmailAuthStore: GmailAuthStore) {
        self.preferences = preferences
        self.networkMonitor = networkMonitor
        self.gmailAuthStore = gmailAuthStore
        self.yahooService = YahooService()
        self.yahooCredentialsStore = YahooCredentialsStore()
        self.fastmailService = FastmailService()
        self.fastmailCredentialsStore = FastmailCredentialsStore()
        logger.info("Initializing MailStore.", category: "MailStore")

        loadOrBootstrap()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.rebuildDeck()
        }

        providerSyncTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            self?.triggerBackgroundProviderSync()
        }

        triggerBackgroundProviderSync()
    }

    deinit {
        refreshTimer?.invalidate()
        providerSyncTimer?.invalidate()
    }

    var currentMessage: EmailMessage? {
        guard let id = deckMessageIDs.first else { return nil }
        return messages.first(where: { $0.id == id })
    }

    func rebuildDeck() {
        let now = Date()
        let unified = preferences.unifiedInboxEnabled

        let visible = messages
            .filter { $0.deletedAt == nil }
            .filter { $0.archivedAt == nil }
            .filter { ($0.snoozedUntil ?? .distantPast) <= now }
            .filter { !blockedSenders.contains($0.senderEmail.lowercased()) }
            .filter { msg in
                guard let category = selectedCategory else { return true }
                return msg.category == category
            }
            .filter { msg in
                if unified {
                    if let selected = selectedAccountID { return msg.accountID == selected }
                    return true
                }
                // If unified inbox disabled, fall back to first account.
                if let selected = selectedAccountID { return msg.accountID == selected }
                return msg.accountID == accounts.first?.id
            }
            .sorted(by: { $0.receivedAt > $1.receivedAt })

        deckMessageIDs = visible.map { $0.id }

        if let pending = pendingAdvanceMessageID {
            pendingAdvanceMessageID = nil
            if let index = deckMessageIDs.firstIndex(of: pending), deckMessageIDs.count > 1 {
                let moved = deckMessageIDs.remove(at: index)
                deckMessageIDs.append(moved)
            }
        }
    }

    func performGlide(_ direction: GlideDirection, useSecondary: Bool) {
        guard let msg = currentMessage else { return }
        let action = preferences.action(for: direction, useSecondary: useSecondary)
        perform(action: action, isSecondary: useSecondary, messageID: msg.id)
    }

    func perform(action: GlideAction, isSecondary: Bool, messageID: UUID) {
        guard messages.contains(where: { $0.id == messageID }) else { return }
        if action.isDestructive, action != .delete, preferences.confirmDestructiveActions {
            pendingConfirmation = PendingConfirmation(action: action, isSecondary: isSecondary, messageID: messageID)
            return
        }
        apply(action: action, isSecondary: isSecondary, messageID: messageID)
    }

    func confirmPendingAction() {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        apply(action: pending.action, isSecondary: pending.isSecondary, messageID: pending.messageID)
    }

    func cancelPendingAction() {
        pendingConfirmation = nil
    }

    func syncIfPossible() {
        guard networkMonitor.isOnline else { return }
        if queuedActions.isEmpty { return }
        queuedActions.removeAll()
        scheduleSave()
    }

    func addAccount(provider: MailProvider, displayName: String, emailAddress: String) {
        let cleanedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedEmail = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty, !cleanedEmail.isEmpty else { return }

        let account = MailAccount(
            id: UUID(),
            provider: provider,
            displayName: cleanedName,
            emailAddress: cleanedEmail,
            colorHex: nextColorHex()
        )
        accounts.append(account)
        logger.info(
            "Added account to local store.",
            category: "MailStore",
            metadata: ["provider": provider.rawValue, "email": cleanedEmail, "accountID": account.id.uuidString]
        )
        if selectedAccountID == nil {
            selectedAccountID = account.id
        }
        scheduleSave()
        rebuildDeck()
    }

    func deleteAccount(_ account: MailAccount) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts.remove(at: index)
        logger.info(
            "Deleted account from local store.",
            category: "MailStore",
            metadata: ["provider": account.provider.rawValue, "email": account.emailAddress, "accountID": account.id.uuidString]
        )
        messages.removeAll { $0.accountID == account.id }
        queuedActions.removeAll { $0.accountID == account.id }
        if selectedAccountID == account.id {
            selectedAccountID = accounts.first?.id
        }
        switch account.provider {
        case .yahoo:
            try? yahooCredentialsStore.deleteAppPassword(emailAddress: account.emailAddress)
        case .fastmail:
            try? fastmailCredentialsStore.deleteAppPassword(emailAddress: account.emailAddress)
        case .gmail:
            break
        }
        scheduleSave()
        rebuildDeck()
    }

    func upsertGmailMessages(for emailAddress: String, items: [GmailInboxMessage]) {
        guard let account = accounts.first(where: {
            $0.provider == .gmail && $0.emailAddress.caseInsensitiveCompare(emailAddress) == .orderedSame
        }) else {
            logger.warning(
                "Cannot upsert Gmail messages because no matching account exists.",
                category: "MailStore",
                metadata: ["email": emailAddress]
            )
            return
        }

        var indexByProviderID: [String: Int] = [:]
        for idx in messages.indices where messages[idx].accountID == account.id {
            if let providerID = messages[idx].providerMessageID {
                indexByProviderID[providerID] = idx
            }
        }

        var inserted = 0
        var updated = 0

        for item in items {
            if let existingIndex = indexByProviderID[item.id] {
                messages[existingIndex].receivedAt = item.receivedAt
                messages[existingIndex].senderName = item.senderName
                messages[existingIndex].senderEmail = item.senderEmail
                messages[existingIndex].subject = item.subject
                messages[existingIndex].preview = item.snippet
                messages[existingIndex].body = item.body.isEmpty ? item.snippet : item.body
                messages[existingIndex].isRead = !item.isUnread
                messages[existingIndex].isStarred = item.isStarred
                messages[existingIndex].isImportant = item.isImportant
                messages[existingIndex].labels = item.labels
                messages[existingIndex].category = Self.category(for: item.labels)
                updated += 1
                continue
            }

            let message = EmailMessage(
                id: UUID(),
                accountID: account.id,
                providerMessageID: item.id,
                receivedAt: item.receivedAt,
                senderName: item.senderName,
                senderEmail: item.senderEmail,
                subject: item.subject,
                preview: item.snippet,
                body: item.body.isEmpty ? item.snippet : item.body,
                isRead: !item.isUnread,
                isStarred: item.isStarred,
                isImportant: item.isImportant,
                labels: item.labels,
                archivedAt: nil,
                deletedAt: nil,
                snoozedUntil: nil,
                category: Self.category(for: item.labels)
            )
            messages.append(message)
            indexByProviderID[item.id] = messages.count - 1
            inserted += 1
        }

        if selectedAccountID == nil {
            selectedAccountID = account.id
        }
        logger.info(
            "Upserted Gmail messages.",
            category: "MailStore",
            metadata: [
                "email": emailAddress,
                "fetched": "\(items.count)",
                "inserted": "\(inserted)",
                "updated": "\(updated)"
            ]
        )
        scheduleSave()
        rebuildDeck()
    }

    func syncYahooInbox(for emailAddress: String, maxResults: Int = 30) async throws {
        logger.info(
            "Starting Yahoo sync (single-call wrapper).",
            category: "MailStore",
            metadata: ["email": emailAddress, "maxResults": "\(maxResults)"]
        )
        _ = try await syncYahooInboxProgressive(
            for: emailAddress,
            maxResults: maxResults,
            batchSize: maxResults
        )
    }

    @discardableResult
    func syncYahooInboxProgressive(
        for emailAddress: String,
        maxResults: Int = 90,
        batchSize: Int = 15,
        onBatch: ((Int, Int) -> Void)? = nil
    ) async throws -> Int {
        let normalizedEmail = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if yahooSyncInProgressEmails.contains(normalizedEmail) {
            logger.warning(
                "Skipping Yahoo sync because one is already in progress for this account.",
                category: "MailStore",
                metadata: ["email": emailAddress]
            )
            return 0
        }
        yahooSyncInProgressEmails.insert(normalizedEmail)
        defer { yahooSyncInProgressEmails.remove(normalizedEmail) }

        logger.info(
            "Starting Yahoo progressive sync.",
            category: "MailStore",
            metadata: [
                "email": emailAddress,
                "maxResults": "\(maxResults)",
                "batchSize": "\(batchSize)"
            ]
        )
        let appPassword = try yahooCredentialsStore.loadAppPassword(emailAddress: emailAddress)
        logger.debug(
            "Loaded Yahoo app password from keychain for sync.",
            category: "MailStore",
            metadata: ["email": emailAddress]
        )
        let total = try await yahooService.fetchRecentInboxMessagesProgressive(
            emailAddress: emailAddress,
            appPassword: appPassword,
            maxResults: maxResults,
            batchSize: batchSize
        ) { [weak self] cumulative, batchCount, messages in
            guard let self else { return }
            Task { @MainActor in
                self.logger.debug(
                    "Applying Yahoo sync batch to local store.",
                    category: "MailStore",
                    metadata: [
                        "email": emailAddress,
                        "batchCount": "\(batchCount)",
                        "cumulative": "\(cumulative)"
                    ]
                )
                self.upsertYahooMessages(for: emailAddress, items: messages)
                onBatch?(cumulative, batchCount)
            }
        }
        logger.info(
            "Finished Yahoo progressive sync.",
            category: "MailStore",
            metadata: ["email": emailAddress, "totalFetched": "\(total)"]
        )
        return total
    }

    func upsertYahooMessages(for emailAddress: String, items: [YahooInboxMessage]) {
        guard let account = accounts.first(where: {
            $0.provider == .yahoo && $0.emailAddress.caseInsensitiveCompare(emailAddress) == .orderedSame
        }) else {
            logger.warning(
                "Cannot upsert Yahoo messages because no matching account exists.",
                category: "MailStore",
                metadata: ["email": emailAddress]
            )
            return
        }

        var indexByProviderID: [String: Int] = [:]
        for idx in messages.indices where messages[idx].accountID == account.id {
            if let providerID = messages[idx].providerMessageID {
                indexByProviderID[providerID] = idx
            }
        }

        var inserted = 0
        var updated = 0

        for item in items {
            if let existingIndex = indexByProviderID[item.id] {
                messages[existingIndex].receivedAt = item.receivedAt
                messages[existingIndex].senderName = item.senderName
                messages[existingIndex].senderEmail = item.senderEmail
                messages[existingIndex].subject = item.subject
                messages[existingIndex].preview = item.snippet
                messages[existingIndex].body = item.body.isEmpty ? item.snippet : item.body
                messages[existingIndex].isRead = !item.isUnread
                messages[existingIndex].isStarred = item.isStarred
                messages[existingIndex].isImportant = item.isImportant
                messages[existingIndex].labels = item.labels
                messages[existingIndex].category = Self.category(for: item.labels)
                updated += 1
                continue
            }

            let message = EmailMessage(
                id: UUID(),
                accountID: account.id,
                providerMessageID: item.id,
                receivedAt: item.receivedAt,
                senderName: item.senderName,
                senderEmail: item.senderEmail,
                subject: item.subject,
                preview: item.snippet,
                body: item.body.isEmpty ? item.snippet : item.body,
                isRead: !item.isUnread,
                isStarred: item.isStarred,
                isImportant: item.isImportant,
                labels: item.labels,
                archivedAt: nil,
                deletedAt: nil,
                snoozedUntil: nil,
                category: Self.category(for: item.labels)
            )
            messages.append(message)
            indexByProviderID[item.id] = messages.count - 1
            inserted += 1
        }

        if selectedAccountID == nil {
            selectedAccountID = account.id
        }
        logger.info(
            "Upserted Yahoo messages.",
            category: "MailStore",
            metadata: [
                "email": emailAddress,
                "fetched": "\(items.count)",
                "inserted": "\(inserted)",
                "updated": "\(updated)"
            ]
        )
        scheduleSave()
        rebuildDeck()
    }

    func syncFastmailInbox(for emailAddress: String, maxResults: Int = 30) async throws {
        logger.info(
            "Starting Fastmail sync (single-call wrapper).",
            category: "MailStore",
            metadata: ["email": emailAddress, "maxResults": "\(maxResults)"]
        )
        _ = try await syncFastmailInboxProgressive(
            for: emailAddress,
            maxResults: maxResults,
            batchSize: maxResults
        )
    }

    @discardableResult
    func syncFastmailInboxProgressive(
        for emailAddress: String,
        maxResults: Int = 90,
        batchSize: Int = 15,
        onBatch: ((Int, Int) -> Void)? = nil
    ) async throws -> Int {
        let normalizedEmail = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if fastmailSyncInProgressEmails.contains(normalizedEmail) {
            logger.warning(
                "Skipping Fastmail sync because one is already in progress for this account.",
                category: "MailStore",
                metadata: ["email": emailAddress]
            )
            return 0
        }
        fastmailSyncInProgressEmails.insert(normalizedEmail)
        defer { fastmailSyncInProgressEmails.remove(normalizedEmail) }

        logger.info(
            "Starting Fastmail progressive sync.",
            category: "MailStore",
            metadata: [
                "email": emailAddress,
                "maxResults": "\(maxResults)",
                "batchSize": "\(batchSize)"
            ]
        )
        let appPassword = try fastmailCredentialsStore.loadAppPassword(emailAddress: emailAddress)
        logger.debug(
            "Loaded Fastmail app password from keychain for sync.",
            category: "MailStore",
            metadata: ["email": emailAddress]
        )
        let total = try await fastmailService.fetchRecentInboxMessagesProgressive(
            emailAddress: emailAddress,
            appPassword: appPassword,
            maxResults: maxResults,
            batchSize: batchSize
        ) { [weak self] cumulative, batchCount, messages in
            guard let self else { return }
            Task { @MainActor in
                self.logger.debug(
                    "Applying Fastmail sync batch to local store.",
                    category: "MailStore",
                    metadata: [
                        "email": emailAddress,
                        "batchCount": "\(batchCount)",
                        "cumulative": "\(cumulative)"
                    ]
                )
                self.upsertFastmailMessages(for: emailAddress, items: messages)
                onBatch?(cumulative, batchCount)
            }
        }
        logger.info(
            "Finished Fastmail progressive sync.",
            category: "MailStore",
            metadata: ["email": emailAddress, "totalFetched": "\(total)"]
        )
        return total
    }

    func upsertFastmailMessages(for emailAddress: String, items: [FastmailInboxMessage]) {
        guard let account = accounts.first(where: {
            $0.provider == .fastmail && $0.emailAddress.caseInsensitiveCompare(emailAddress) == .orderedSame
        }) else {
            logger.warning(
                "Cannot upsert Fastmail messages because no matching account exists.",
                category: "MailStore",
                metadata: ["email": emailAddress]
            )
            return
        }

        var indexByProviderID: [String: Int] = [:]
        for idx in messages.indices where messages[idx].accountID == account.id {
            if let providerID = messages[idx].providerMessageID {
                indexByProviderID[providerID] = idx
            }
        }

        var inserted = 0
        var updated = 0

        for item in items {
            if let existingIndex = indexByProviderID[item.id] {
                messages[existingIndex].receivedAt = item.receivedAt
                messages[existingIndex].senderName = item.senderName
                messages[existingIndex].senderEmail = item.senderEmail
                messages[existingIndex].subject = item.subject
                messages[existingIndex].preview = item.snippet
                messages[existingIndex].body = item.body.isEmpty ? item.snippet : item.body
                messages[existingIndex].isRead = !item.isUnread
                messages[existingIndex].isStarred = item.isStarred
                messages[existingIndex].isImportant = item.isImportant
                messages[existingIndex].labels = item.labels
                messages[existingIndex].category = Self.category(for: item.labels)
                updated += 1
                continue
            }

            let message = EmailMessage(
                id: UUID(),
                accountID: account.id,
                providerMessageID: item.id,
                receivedAt: item.receivedAt,
                senderName: item.senderName,
                senderEmail: item.senderEmail,
                subject: item.subject,
                preview: item.snippet,
                body: item.body.isEmpty ? item.snippet : item.body,
                isRead: !item.isUnread,
                isStarred: item.isStarred,
                isImportant: item.isImportant,
                labels: item.labels,
                archivedAt: nil,
                deletedAt: nil,
                snoozedUntil: nil,
                category: Self.category(for: item.labels)
            )
            messages.append(message)
            indexByProviderID[item.id] = messages.count - 1
            inserted += 1
        }

        if selectedAccountID == nil {
            selectedAccountID = account.id
        }
        logger.info(
            "Upserted Fastmail messages.",
            category: "MailStore",
            metadata: [
                "email": emailAddress,
                "fetched": "\(items.count)",
                "inserted": "\(inserted)",
                "updated": "\(updated)"
            ]
        )
        scheduleSave()
        rebuildDeck()
    }

    func applyMoveToFolder(_ folder: String, messageID: UUID) {
        let value = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard let idx = messages.firstIndex(where: { $0.id == messageID }) else { return }

        let tag = "Folder: \(value)"
        messages[idx].labels = Array(Set(messages[idx].labels + [tag])).sorted()
        messages[idx].archivedAt = Date()
        scheduleSave()
        rebuildDeck()
    }

    func applyLabel(_ label: String, messageID: UUID) {
        let value = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard let idx = messages.firstIndex(where: { $0.id == messageID }) else { return }

        messages[idx].labels = Array(Set(messages[idx].labels + [value])).sorted()
        scheduleSave()
        rebuildDeck()
    }

    func deleteAllData() {
        accounts = []
        messages = []
        blockedSenders = []
        unsubscribedSenders = []
        queuedActions = []
        selectedAccountID = nil
        selectedCategory = nil
        deckMessageIDs = []
        deleteStoreFile()
    }

    func exportData(to url: URL) throws {
        let snapshot = StoreSnapshot(
            accounts: accounts,
            messages: messages,
            blockedSenders: blockedSenders,
            unsubscribedSenders: unsubscribedSenders,
            queuedActions: queuedActions
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: [.atomic])
    }

    // MARK: - Internals

    private func loadOrBootstrap() {
        do {
            let data = try Data(contentsOf: storeURL())
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(StoreSnapshot.self, from: data)
            accounts = snapshot.accounts
            messages = snapshot.messages
            blockedSenders = snapshot.blockedSenders
            unsubscribedSenders = snapshot.unsubscribedSenders
            queuedActions = snapshot.queuedActions
            logger.debug("Loaded local store snapshot from disk.", category: "MailStore")
        } catch {
            logger.debug("No local store snapshot loaded.", category: "MailStore", metadata: ["error": error.localizedDescription])
        }
        rebuildDeck()
    }


    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.persist()
        }
        saveWorkItem = item
        saveQueue.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private static func category(for labels: [String]) -> MessageCategory? {
        let set = Set(labels.map { $0.uppercased() })
        if set.contains("CATEGORY_PERSONAL") { return .personal }
        if set.contains("CATEGORY_PROMOTIONS") { return .promotions }
        if set.contains("CATEGORY_UPDATES") { return .updates }
        if set.contains("CATEGORY_FORUMS") { return .forums }
        if set.contains("CATEGORY_SOCIAL") { return .social }
        if set.contains("CATEGORY_PRIMARY") { return .work }
        return nil
    }

    private func nextColorHex() -> String {
        let palette = [
            "#2563EB", "#16A34A", "#F97316", "#DC2626", "#0EA5E9",
            "#D97706", "#7C3AED", "#0891B2", "#BE123C", "#059669"
        ]

        let usedColors = Set(accounts.map(\.colorHex))

        if let firstUnused = palette.first(where: { !usedColors.contains($0) }) {
            return firstUnused
        }

        let usageCount = accounts.reduce(into: [String: Int]()) { acc, account in
            acc[account.colorHex, default: 0] += 1
        }
        return palette.min { usageCount[$0, default: 0] < usageCount[$1, default: 0] } ?? "#2563EB"
    }

    private func persist() {
        let snapshot = StoreSnapshot(
            accounts: accounts,
            messages: messages,
            blockedSenders: blockedSenders,
            unsubscribedSenders: unsubscribedSenders,
            queuedActions: queuedActions
        )
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: storeURL(), options: [.atomic])
        } catch {
            logger.error("Failed to persist local store snapshot.", category: "MailStore", metadata: ["error": error.localizedDescription])
        }
    }

    private func deleteStoreFile() {
        do {
            try FileManager.default.removeItem(at: storeURL())
            logger.info("Deleted local store snapshot file.", category: "MailStore")
        } catch {
            logger.warning("Delete local store snapshot failed or file missing.", category: "MailStore", metadata: ["error": error.localizedDescription])
        }
    }

    private func storeURL() throws -> URL {
        let dir = try AppDirectories.applicationSupportDirectory(appName: appName)
        return dir.appendingPathComponent(storeFileName, isDirectory: false)
    }

    private func apply(action: GlideAction, isSecondary: Bool, messageID: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }) else { return }
        let sender = messages[idx].senderEmail.lowercased()

        if networkMonitor.isOnline == false {
            queuedActions.append(QueuedMailAction(id: UUID(), createdAt: Date(), accountID: messages[idx].accountID, messageID: messageID, action: action, isSecondary: isSecondary))
        }

        switch action {
        case .delete:
            let message = messages[idx]
            messages[idx].deletedAt = Date()
            deckMessageIDs.removeAll(where: { $0 == messageID })
            trashOnProviderIfPossible(message)

        case .archive:
            messages[idx].archivedAt = Date()
            deckMessageIDs.removeAll(where: { $0 == messageID })

        case .markRead:
            messages[idx].isRead = true
            advanceToNextMessage(after: messageID)

        case .markUnread:
            messages[idx].isRead = false

        case .star:
            messages[idx].isStarred = true

        case .unstar:
            messages[idx].isStarred = false

        case .markImportant:
            messages[idx].isImportant = true

        case .unmarkImportant:
            messages[idx].isImportant = false

        case .moveToFolder:
            prompt = .moveToFolder(messageID: messageID)
            return

        case .applyLabel:
            prompt = .applyLabel(messageID: messageID)
            return

        case .unsubscribe:
            unsubscribedSenders.insert(sender)
            messages[idx].archivedAt = Date()
            deckMessageIDs.removeAll(where: { $0 == messageID })

        case .unsubscribeAndDeleteAllFromSender:
            unsubscribedSenders.insert(sender)
            for i in messages.indices {
                if messages[i].senderEmail.lowercased() == sender {
                    messages[i].deletedAt = Date()
                }
            }
            deckMessageIDs.removeAll(where: { id in
                messages.first(where: { $0.id == id })?.senderEmail.lowercased() == sender
            })

        case .blockSender:
            blockedSenders.insert(sender)
            for i in messages.indices {
                if messages[i].senderEmail.lowercased() == sender {
                    messages[i].archivedAt = Date()
                }
            }
            deckMessageIDs.removeAll(where: { id in
                messages.first(where: { $0.id == id })?.senderEmail.lowercased() == sender
            })

        case .snooze1h:
            messages[idx].snoozedUntil = Date().addingTimeInterval(60 * 60)
            deckMessageIDs.removeAll(where: { $0 == messageID })

        case .snooze4h:
            messages[idx].snoozedUntil = Date().addingTimeInterval(60 * 60 * 4)
            deckMessageIDs.removeAll(where: { $0 == messageID })

        case .snooze1d:
            messages[idx].snoozedUntil = Date().addingTimeInterval(60 * 60 * 24)
            deckMessageIDs.removeAll(where: { $0 == messageID })

        case .createReminder:
            reminder = ReminderPresentation(messageID: messageID)
            scheduleSave()
            return

        case .skip:
            advanceToNextMessage(after: messageID)

        case .reply:
            composer = ComposerPresentation(messageID: messageID, mode: .reply)

        case .aiReply:
            composer = ComposerPresentation(messageID: messageID, mode: .aiReply)
        }

        scheduleSave()
        if networkMonitor.isOnline {
            syncIfPossible()
        }
        rebuildDeck()
    }

    private func advanceToNextMessage(after messageID: UUID) {
        pendingAdvanceMessageID = messageID
        if let first = deckMessageIDs.first, first == messageID {
            deckMessageIDs.removeFirst()
            deckMessageIDs.append(first)
        }
    }

    private func triggerBackgroundProviderSync() {
        guard networkMonitor.isOnline else { return }
        logger.debug("Background provider sync tick triggered.", category: "MailStore")
        Task { [weak self] in
            await self?.runBackgroundProviderSync()
        }
    }

    @MainActor
    private func runBackgroundProviderSync() async {
        if isBackgroundSyncInProgress { return }
        isBackgroundSyncInProgress = true
        defer { isBackgroundSyncInProgress = false }
        logger.debug("Background provider sync started.", category: "MailStore")

        await backgroundSyncGmailIfConnected()
        await backgroundSyncYahooAccounts()
        await backgroundSyncFastmailAccounts()
        logger.debug("Background provider sync finished.", category: "MailStore")
    }

    @MainActor
    private func backgroundSyncGmailIfConnected() async {
        let gmailAccounts = accounts.filter { $0.provider == .gmail }
        guard !gmailAccounts.isEmpty else { return }

        for account in gmailAccounts {
            do {
                let hasSession = await gmailAuthStore.hasSession(for: account.emailAddress)
                if !hasSession {
                    logger.debug(
                        "Skipping background Gmail sync: no OAuth session for account.",
                        category: "MailStore",
                        metadata: ["email": account.emailAddress]
                    )
                    continue
                }
                let items = try await gmailAuthStore.fetchRecentInboxMessages(for: account.emailAddress, maxResults: 30)
                upsertGmailMessages(for: account.emailAddress, items: items)
                logger.debug(
                    "Background Gmail sync completed.",
                    category: "MailStore",
                    metadata: ["email": account.emailAddress, "fetched": "\(items.count)"]
                )
            } catch {
                logger.warning(
                    "Background Gmail sync failed.",
                    category: "MailStore",
                    metadata: ["email": account.emailAddress, "error": error.localizedDescription]
                )
            }
        }
    }

    @MainActor
    private func backgroundSyncYahooAccounts() async {
        let yahooAccounts = accounts.filter { $0.provider == .yahoo }
        guard !yahooAccounts.isEmpty else { return }

        for account in yahooAccounts {
            do {
                try await syncYahooInbox(for: account.emailAddress, maxResults: 30)
                logger.debug(
                    "Background Yahoo sync completed.",
                    category: "MailStore",
                    metadata: ["email": account.emailAddress]
                )
            } catch {
                logger.warning(
                    "Background Yahoo sync failed.",
                    category: "MailStore",
                    metadata: ["email": account.emailAddress, "error": error.localizedDescription]
                )
            }
        }
    }

    @MainActor
    private func backgroundSyncFastmailAccounts() async {
        let fastmailAccounts = accounts.filter { $0.provider == .fastmail }
        guard !fastmailAccounts.isEmpty else { return }

        for account in fastmailAccounts {
            do {
                try await syncFastmailInbox(for: account.emailAddress, maxResults: 30)
                logger.debug(
                    "Background Fastmail sync completed.",
                    category: "MailStore",
                    metadata: ["email": account.emailAddress]
                )
            } catch {
                logger.warning(
                    "Background Fastmail sync failed.",
                    category: "MailStore",
                    metadata: ["email": account.emailAddress, "error": error.localizedDescription]
                )
            }
        }
    }

    private func trashOnProviderIfPossible(_ message: EmailMessage) {
        guard let account = accounts.first(where: { $0.id == message.accountID }),
              let providerMessageID = message.providerMessageID else {
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                switch account.provider {
                case .gmail:
                    try await gmailAuthStore.trashMessage(id: providerMessageID, for: account.emailAddress)
                    logger.info(
                        "Deleted Gmail message on provider.",
                        category: "MailStore",
                        metadata: ["messageID": providerMessageID, "email": account.emailAddress]
                    )
                case .yahoo:
                    let appPassword = try yahooCredentialsStore.loadAppPassword(emailAddress: account.emailAddress)
                    try await yahooService.trashMessage(
                        emailAddress: account.emailAddress,
                        appPassword: appPassword,
                        id: providerMessageID
                    )
                    logger.info(
                        "Deleted Yahoo message on provider.",
                        category: "MailStore",
                        metadata: ["messageID": providerMessageID, "email": account.emailAddress]
                    )
                case .fastmail:
                    let appPassword = try fastmailCredentialsStore.loadAppPassword(emailAddress: account.emailAddress)
                    try await fastmailService.trashMessage(
                        emailAddress: account.emailAddress,
                        appPassword: appPassword,
                        id: providerMessageID
                    )
                    logger.info(
                        "Deleted Fastmail message on provider.",
                        category: "MailStore",
                        metadata: ["messageID": providerMessageID, "email": account.emailAddress]
                    )
                }
            } catch let gmailError as GmailServiceError where gmailError.statusCode == 404 {
                logger.warning(
                    "Gmail message already missing on provider; treating local delete as complete.",
                    category: "MailStore",
                    metadata: ["messageID": providerMessageID, "email": account.emailAddress]
                )
            } catch let yahooError as YahooServiceError {
                switch yahooError {
                case .messageNotFound:
                    logger.warning(
                        "Yahoo message already missing on provider; treating local delete as complete.",
                        category: "MailStore",
                        metadata: ["messageID": providerMessageID, "email": account.emailAddress]
                    )
                default:
                    logger.error(
                        "Failed deleting Yahoo message on provider.",
                        category: "MailStore",
                        metadata: ["messageID": providerMessageID, "error": yahooError.localizedDescription]
                    )
                    await MainActor.run {
                        self.errorAlert = ErrorAlert(
                            title: "Yahoo Delete Failed",
                            message: "Deleted locally, but Yahoo delete failed: \(yahooError.localizedDescription)"
                        )
                    }
                }
            } catch let fastmailError as FastmailServiceError {
                switch fastmailError {
                case .messageNotFound:
                    logger.warning(
                        "Fastmail message already missing on provider; treating local delete as complete.",
                        category: "MailStore",
                        metadata: ["messageID": providerMessageID, "email": account.emailAddress]
                    )
                default:
                    logger.error(
                        "Failed deleting Fastmail message on provider.",
                        category: "MailStore",
                        metadata: ["messageID": providerMessageID, "error": fastmailError.localizedDescription]
                    )
                    await MainActor.run {
                        self.errorAlert = ErrorAlert(
                            title: "Fastmail Delete Failed",
                            message: "Deleted locally, but Fastmail delete failed: \(fastmailError.localizedDescription)"
                        )
                    }
                }
            } catch {
                logger.error(
                    "Failed deleting message on provider.",
                    category: "MailStore",
                    metadata: ["messageID": providerMessageID, "error": error.localizedDescription]
                )
                await MainActor.run {
                    self.errorAlert = ErrorAlert(
                        title: "\(account.provider.displayName) Delete Failed",
                        message: "Deleted locally, but provider delete failed: \(error.localizedDescription)"
                    )
                }
            }
        }
    }
}
