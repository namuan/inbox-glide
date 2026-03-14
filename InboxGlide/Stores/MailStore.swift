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

enum ReplyProviderSendError: LocalizedError {
    case notSupported(MailProvider)

    var errorDescription: String? {
        switch self {
        case .notSupported(let provider):
            switch provider {
            case .yahoo:
                return "Sending replies from Yahoo accounts is not supported yet."
            case .fastmail:
                return "Sending replies from Fastmail accounts is not supported yet."
            case .gmail:
                return "Reply send is available for Gmail accounts."
            }
        }
    }
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

struct EmailThread: Identifiable {
    let id: String
    let accountID: UUID
    let messages: [EmailMessage]
    let visibleMessages: [EmailMessage]

    var leadMessage: EmailMessage {
        visibleMessages.last ?? messages.last ?? messages[0]
    }

    var latestMessage: EmailMessage {
        messages.last ?? visibleMessages.last ?? messages[0]
    }

    var messageIDs: [UUID] {
        messages.map { $0.id }
    }

    var messageCount: Int {
        messages.count
    }

    var unreadCount: Int {
        visibleMessages.filter { !$0.isRead }.count
    }

    var hasPinnedMessages: Bool {
        messages.contains { $0.pinnedAt != nil }
    }

    var latestPinnedAt: Date? {
        messages.compactMap { $0.pinnedAt }.max()
    }

    var participants: [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for message in messages.reversed() {
            let trimmedName = message.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedEmail = message.senderEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = trimmedName.isEmpty || trimmedName.caseInsensitiveCompare(trimmedEmail) == .orderedSame
                ? trimmedEmail
                : "\(trimmedName) <\(trimmedEmail)>"
            guard !label.isEmpty else { continue }
            let key = trimmedEmail.lowercased().isEmpty ? label.lowercased() : trimmedEmail.lowercased()
            guard seen.insert(key).inserted else { continue }
            ordered.append(label)
        }

        return ordered
    }
}

private struct ThreadSeed {
    let id: String
    let accountID: UUID
    let messages: [EmailMessage]
}

private struct UnionFind {
    private var parents: [Int]

    init(count: Int) {
        parents = Array(0 ..< count)
    }

    mutating func find(_ value: Int) -> Int {
        if parents[value] != value {
            parents[value] = find(parents[value])
        }
        return parents[value]
    }

    mutating func union(_ lhs: Int, _ rhs: Int) {
        let leftRoot = find(lhs)
        let rightRoot = find(rhs)
        guard leftRoot != rightRoot else { return }
        parents[rightRoot] = leftRoot
    }
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
    @Published var showingPinnedOnly: Bool = false { didSet { rebuildDeck() } }

    @Published private(set) var deckMessageIDs: [UUID] = []
    @Published private(set) var visibleThreads: [EmailThread] = []
    @Published private(set) var queuedActions: [QueuedMailAction] = []
    @Published private(set) var blockedSenders: Set<String> = []
    @Published private(set) var unsubscribedSenders: Set<String> = []
    @Published private(set) var syncingProviders: Set<MailProvider> = []

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
    private var deckRebuildWorkItem: DispatchWorkItem?
    private var refreshTimer: Timer?
    private var providerSyncTimer: Timer?
    private var isBackgroundSyncInProgress = false
    private var lastProactiveSyncAt: Date = .distantPast
    private var lastPeriodicSyncAt: Date = .distantPast
    private var pendingAdvanceThreadID: String?
    private var skippedThreadIDs: [String] = []
    private var yahooSyncInProgressEmails: Set<String> = []
    private var fastmailSyncInProgressEmails: Set<String> = []
    private var syncProviderCounts: [MailProvider: Int] = [:]
    private let lowDeckSyncThreshold = 16
    private let proactiveSyncCooldown: TimeInterval = 45
    private var threadsByID: [String: EmailThread] = [:]
    private var threadIDByMessageID: [UUID: String] = [:]
    private var visibleThreadIDByLeadMessageID: [UUID: String] = [:]

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

        providerSyncTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.maybeTriggerPeriodicSync()
        }

        triggerBackgroundProviderSync()
    }

    deinit {
        refreshTimer?.invalidate()
        providerSyncTimer?.invalidate()
    }

    var currentMessage: EmailMessage? {
        currentThread?.leadMessage
    }

    var currentThread: EmailThread? {
        guard let id = deckMessageIDs.first,
              let threadID = visibleThreadIDByLeadMessageID[id] else {
            return nil
        }
        return threadsByID[threadID]
    }

    var pinnedMessageIDs: Set<UUID> {
        Set(messages.compactMap {
            $0.pinnedAt != nil && $0.deletedAt == nil && $0.archivedAt == nil ? $0.id : nil
        })
    }

    var isSyncing: Bool {
        !syncingProviders.isEmpty
    }

    var syncingProvidersLabel: String {
        syncingProviders
            .map(\.displayName)
            .sorted()
            .joined(separator: ", ")
    }
    
    var emailDurationBucketCounts: [EmailDurationBucket: Int] {
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
                if let selected = selectedAccountID { return msg.accountID == selected }
                return msg.accountID == accounts.first?.id
            }
        
        var counts: [EmailDurationBucket: Int] = [:]
        for bucket in EmailDurationBucket.allCases {
            counts[bucket] = 0
        }
        
        for message in visible {
            let bucket = EmailDurationBucket.bucket(for: message.receivedAt, relativeTo: now)
            counts[bucket, default: 0] += 1
        }
        
        return counts
    }

    func rebuildDeck() {
        let now = Date()
        let unified = preferences.unifiedInboxEnabled

        let firstAccountID = accounts.first?.id
        let seeds = buildThreadSeeds(
            from: messages.filter { $0.deletedAt == nil }
        )

        var nextThreadsByID: [String: EmailThread] = [:]
        var nextThreadIDByMessageID: [UUID: String] = [:]
        var nextVisibleThreads: [EmailThread] = []

        for seed in seeds {
            let orderedMessages = seed.messages.sorted { lhs, rhs in
                if lhs.receivedAt != rhs.receivedAt {
                    return lhs.receivedAt < rhs.receivedAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }

            let visibleMessages = orderedMessages.filter { msg in
                guard msg.archivedAt == nil,
                      (msg.snoozedUntil ?? .distantPast) <= now,
                      !blockedSenders.contains(msg.senderEmail.lowercased())
                else { return false }
                if showingPinnedOnly && msg.pinnedAt == nil { return false }
                if let category = selectedCategory, msg.category != category { return false }
                if unified {
                    if let selected = selectedAccountID { return msg.accountID == selected }
                    return true
                }
                if let selected = selectedAccountID { return msg.accountID == selected }
                return msg.accountID == firstAccountID
            }

            let thread = EmailThread(
                id: seed.id,
                accountID: seed.accountID,
                messages: orderedMessages,
                visibleMessages: visibleMessages
            )
            nextThreadsByID[thread.id] = thread
            for message in orderedMessages {
                nextThreadIDByMessageID[message.id] = thread.id
            }
            if !visibleMessages.isEmpty {
                nextVisibleThreads.append(thread)
            }
        }

        nextVisibleThreads.sort {
            let lPinned = $0.latestPinnedAt != nil
            let rPinned = $1.latestPinnedAt != nil
            if lPinned != rPinned { return lPinned }
            if lPinned { return ($0.latestPinnedAt ?? .distantPast) > ($1.latestPinnedAt ?? .distantPast) }
            return $0.leadMessage.receivedAt > $1.leadMessage.receivedAt
        }

        threadsByID = nextThreadsByID
        threadIDByMessageID = nextThreadIDByMessageID
        visibleThreads = nextVisibleThreads

        let visibleThreadIDs = Set(nextVisibleThreads.map(\.id))
        skippedThreadIDs = skippedThreadIDs.filter { visibleThreadIDs.contains($0) }

        let visibleThreadByID = Dictionary(uniqueKeysWithValues: nextVisibleThreads.map { ($0.id, $0) })
        let skippedSet = Set(skippedThreadIDs)
        let unskipped = nextVisibleThreads
            .filter { !skippedSet.contains($0.id) }
            .map { $0.leadMessage.id }
        let skipped = skippedThreadIDs.compactMap { visibleThreadByID[$0]?.leadMessage.id }
        deckMessageIDs = unskipped + skipped
        visibleThreadIDByLeadMessageID = Dictionary(uniqueKeysWithValues: nextVisibleThreads.map { ($0.leadMessage.id, $0.id) })

        if let pending = pendingAdvanceThreadID,
           let pendingLeadMessageID = visibleThreadByID[pending]?.leadMessage.id {
            pendingAdvanceThreadID = nil
            if let index = deckMessageIDs.firstIndex(of: pendingLeadMessageID), deckMessageIDs.count > 1 {
                let moved = deckMessageIDs.remove(at: index)
                deckMessageIDs.append(moved)
            }
        } else {
            pendingAdvanceThreadID = nil
        }

        maybeTriggerLowDeckSync()
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

    @discardableResult
    func sendReply(
        messageID: UUID,
        composerMode: ComposerMode,
        body: String
    ) async -> Bool {
        let result = makeReplySendRequest(
            messageID: messageID,
            composerMode: composerMode,
            body: body
        )

        switch result {
        case .success(let request):
            logger.info(
                "Reply send entry point invoked.",
                category: "MailStore",
                metadata: [
                    "messageID": messageID.uuidString,
                    "provider": request.account.provider.rawValue,
                    "email": request.account.emailAddress,
                    "mode": composerMode.rawValue
                ]
            )
            do {
                try await sendReplyOnProvider(request)
                await MainActor.run {
                    markMessageReadAfterSend(messageID: messageID)
                }
                logger.info(
                    "Reply sent through provider.",
                    category: "MailStore",
                    metadata: [
                        "messageID": messageID.uuidString,
                        "provider": request.account.provider.rawValue,
                        "email": request.account.emailAddress,
                        "mode": composerMode.rawValue
                    ]
                )
                return true
            } catch {
                if error is ReplyProviderSendError {
                    logger.warning(
                        "Reply send is not supported for provider in this phase.",
                        category: "MailStore",
                        metadata: [
                            "messageID": messageID.uuidString,
                            "provider": request.account.provider.rawValue,
                            "email": request.account.emailAddress,
                            "mode": composerMode.rawValue
                        ]
                    )
                } else {
                    logger.error(
                        "Reply send failed on provider.",
                        category: "MailStore",
                        metadata: [
                            "messageID": messageID.uuidString,
                            "provider": request.account.provider.rawValue,
                            "email": request.account.emailAddress,
                            "mode": composerMode.rawValue,
                            "error": error.localizedDescription
                        ]
                    )
                }
                errorAlert = ErrorAlert(
                    title: error is ReplyProviderSendError ? "\(request.account.provider.displayName) Reply Not Supported" : "Reply Not Sent",
                    message: Self.replySendErrorMessage(for: error, provider: request.account.provider)
                )
                return false
            }

        case .failure(let error):
            logger.warning(
                "Reply send request validation failed.",
                category: "MailStore",
                metadata: [
                    "messageID": messageID.uuidString,
                    "mode": composerMode.rawValue,
                    "error": error.localizedDescription
                ]
            )
            errorAlert = ErrorAlert(
                title: "Reply Not Sent",
                message: error.localizedDescription
            )
            return false
        }
    }

    private func markMessageReadAfterSend(messageID: UUID) {
        for relatedID in threadMessageIDs(containing: messageID) {
            guard let index = messages.firstIndex(where: { $0.id == relatedID }) else { continue }
            messages[index].isRead = true
        }
        scheduleSave()
        rebuildDeck()
    }

    func thread(containing messageID: UUID) -> EmailThread? {
        guard let threadID = threadIDByMessageID[messageID] else { return nil }
        return threadsByID[threadID]
    }

    private func makeReplySendRequest(
        messageID: UUID,
        composerMode: ComposerMode,
        body: String
    ) -> Result<ReplySendRequest, ReplySendPreparationError> {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else {
            return .failure(.emptyBody)
        }

        guard let message = messages.first(where: { $0.id == messageID }) else {
            return .failure(.messageNotFound)
        }

        guard let account = accounts.first(where: { $0.id == message.accountID }) else {
            return .failure(.accountNotFound)
        }

        let recipientEmail = message.senderEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recipientEmail.isEmpty else {
            return .failure(.recipientMissing)
        }

        let request = ReplySendRequest(
            account: ReplySendAccount(
                id: account.id,
                provider: account.provider,
                emailAddress: account.emailAddress
            ),
            recipient: ReplyRecipient(
                name: message.senderName,
                emailAddress: recipientEmail
            ),
            subject: Self.replySubject(for: message.subject),
            body: trimmedBody,
            threading: ReplyProviderThreadingIdentifiers(
                providerMessageID: message.providerMessageID,
                providerThreadID: message.providerThreadID,
                inReplyToMessageID: message.providerMessageHeaderID ?? message.providerInReplyToMessageID,
                referenceMessageIDs: Self.combineReferenceMessageIDs(
                    message.providerReferenceMessageIDs ?? [],
                    include: message.providerMessageHeaderID
                )
            )
        )

        logger.debug(
            "Prepared reply send request.",
            category: "MailStore",
            metadata: [
                "messageID": messageID.uuidString,
                "provider": account.provider.rawValue,
                "mode": composerMode.rawValue
            ]
        )
        return .success(request)
    }

    func syncAccountNow(_ account: MailAccount) async {
        guard networkMonitor.isOnline else {
            await MainActor.run {
                errorAlert = ErrorAlert(title: "Offline", message: "Connect to the internet to sync this account.")
            }
            return
        }

        switch account.provider {
        case .gmail:
            await markSyncStarted(provider: .gmail)
            let hasSession = await gmailAuthStore.hasSession(for: account.emailAddress)
            if !hasSession {
                await MainActor.run {
                    errorAlert = ErrorAlert(
                        title: "Gmail Sync Failed",
                        message: "No Gmail session found for \(account.emailAddress). Reconnect Gmail in Settings."
                    )
                }
            } else {
                do {
                    let items = try await gmailAuthStore.fetchRecentInboxMessages(
                        for: account.emailAddress,
                        maxResults: 30
                    )
                    upsertGmailMessages(for: account.emailAddress, items: items)
                } catch {
                    await MainActor.run {
                        errorAlert = ErrorAlert(
                            title: "Gmail Sync Failed",
                            message: error.localizedDescription
                        )
                    }
                }
            }
            await markSyncFinished(provider: .gmail)

        case .yahoo:
            do {
                _ = try await syncYahooInboxProgressive(
                    for: account.emailAddress,
                    maxResults: max(20, min(120, preferences.connectSyncMaxResults)),
                    batchSize: min(
                        max(4, preferences.connectSyncBatchSize),
                        max(20, min(120, preferences.connectSyncMaxResults))
                    )
                )
            } catch {
                await MainActor.run {
                    errorAlert = ErrorAlert(
                        title: "Yahoo Sync Failed",
                        message: error.localizedDescription
                    )
                }
            }

        case .fastmail:
            do {
                _ = try await syncFastmailInboxProgressive(
                    for: account.emailAddress,
                    maxResults: max(20, min(120, preferences.connectSyncMaxResults)),
                    batchSize: min(
                        max(4, preferences.connectSyncBatchSize),
                        max(20, min(120, preferences.connectSyncMaxResults))
                    )
                )
            } catch {
                await MainActor.run {
                    errorAlert = ErrorAlert(
                        title: "Fastmail Sync Failed",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    func syncAllProviders() async {
        guard networkMonitor.isOnline else {
            await MainActor.run {
                errorAlert = ErrorAlert(title: "Offline", message: "Connect to the internet to sync all accounts.")
            }
            return
        }

        let gmailAccounts = accounts.filter { $0.provider == .gmail }
        let yahooAccounts = accounts.filter { $0.provider == .yahoo }
        let fastmailAccounts = accounts.filter { $0.provider == .fastmail }

        await withTaskGroup(of: Void.self) { group in
            for account in gmailAccounts {
                group.addTask {
                    await self.syncAccountNow(account)
                }
            }
            for account in yahooAccounts {
                group.addTask {
                    await self.syncAccountNow(account)
                }
            }
            for account in fastmailAccounts {
                group.addTask {
                    await self.syncAccountNow(account)
                }
            }
        }
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
        if selectedAccountID == nil && !preferences.unifiedInboxEnabled {
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
                messages[existingIndex].providerThreadID = item.threadID
                messages[existingIndex].providerMessageHeaderID = item.messageHeaderID
                messages[existingIndex].providerInReplyToMessageID = item.inReplyToMessageID
                messages[existingIndex].providerReferenceMessageIDs = item.referenceMessageIDs
                messages[existingIndex].receivedAt = item.receivedAt
                messages[existingIndex].senderName = item.senderName
                messages[existingIndex].senderEmail = item.senderEmail
                messages[existingIndex].subject = item.subject
                messages[existingIndex].preview = item.snippet
                messages[existingIndex].body = item.body.isEmpty ? item.snippet : item.body
                messages[existingIndex].htmlBody = item.htmlBody
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
                providerThreadID: item.threadID,
                providerMessageHeaderID: item.messageHeaderID,
                providerInReplyToMessageID: item.inReplyToMessageID,
                providerReferenceMessageIDs: item.referenceMessageIDs,
                receivedAt: item.receivedAt,
                senderName: item.senderName,
                senderEmail: item.senderEmail,
                subject: item.subject,
                preview: item.snippet,
                body: item.body.isEmpty ? item.snippet : item.body,
                htmlBody: item.htmlBody,
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

        if selectedAccountID == nil && !preferences.unifiedInboxEnabled {
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
        scheduleDeckRebuild()
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
            batchSize: min(12, max(6, maxResults / 3))
        )
    }

    @discardableResult
    func syncYahooInboxProgressive(
        for emailAddress: String,
        maxResults: Int = 90,
        batchSize: Int = 15,
        onBatch: ((Int, Int) -> Void)? = nil
    ) async throws -> Int {
        await markSyncStarted(provider: .yahoo)
        do {
            let normalizedEmail = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if yahooSyncInProgressEmails.contains(normalizedEmail) {
                logger.warning(
                    "Skipping Yahoo sync because one is already in progress for this account.",
                    category: "MailStore",
                    metadata: ["email": emailAddress]
                )
                await markSyncFinished(provider: .yahoo)
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
            await markSyncFinished(provider: .yahoo)
            return total
        } catch {
            await markSyncFinished(provider: .yahoo)
            throw error
        }
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
                messages[existingIndex].providerMessageHeaderID = item.messageHeaderID
                messages[existingIndex].providerInReplyToMessageID = item.inReplyToMessageID
                messages[existingIndex].providerReferenceMessageIDs = item.referenceMessageIDs
                messages[existingIndex].receivedAt = item.receivedAt
                messages[existingIndex].senderName = item.senderName
                messages[existingIndex].senderEmail = item.senderEmail
                messages[existingIndex].subject = item.subject
                messages[existingIndex].preview = item.snippet
                messages[existingIndex].body = item.body.isEmpty ? item.snippet : item.body
                messages[existingIndex].htmlBody = item.htmlBody
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
                providerMessageHeaderID: item.messageHeaderID,
                providerInReplyToMessageID: item.inReplyToMessageID,
                providerReferenceMessageIDs: item.referenceMessageIDs,
                receivedAt: item.receivedAt,
                senderName: item.senderName,
                senderEmail: item.senderEmail,
                subject: item.subject,
                preview: item.snippet,
                body: item.body.isEmpty ? item.snippet : item.body,
                htmlBody: item.htmlBody,
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

        if selectedAccountID == nil && !preferences.unifiedInboxEnabled {
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
        scheduleDeckRebuild()
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
            batchSize: min(12, max(6, maxResults / 3))
        )
    }

    @discardableResult
    func syncFastmailInboxProgressive(
        for emailAddress: String,
        maxResults: Int = 90,
        batchSize: Int = 15,
        onBatch: ((Int, Int) -> Void)? = nil
    ) async throws -> Int {
        await markSyncStarted(provider: .fastmail)
        do {
            let normalizedEmail = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if fastmailSyncInProgressEmails.contains(normalizedEmail) {
                logger.warning(
                    "Skipping Fastmail sync because one is already in progress for this account.",
                    category: "MailStore",
                    metadata: ["email": emailAddress]
                )
                await markSyncFinished(provider: .fastmail)
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
            await markSyncFinished(provider: .fastmail)
            return total
        } catch {
            await markSyncFinished(provider: .fastmail)
            throw error
        }
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
                messages[existingIndex].providerMessageHeaderID = item.messageHeaderID
                messages[existingIndex].providerInReplyToMessageID = item.inReplyToMessageID
                messages[existingIndex].providerReferenceMessageIDs = item.referenceMessageIDs
                messages[existingIndex].receivedAt = item.receivedAt
                messages[existingIndex].senderName = item.senderName
                messages[existingIndex].senderEmail = item.senderEmail
                messages[existingIndex].subject = item.subject
                messages[existingIndex].preview = item.snippet
                messages[existingIndex].body = item.body.isEmpty ? item.snippet : item.body
                messages[existingIndex].htmlBody = item.htmlBody
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
                providerMessageHeaderID: item.messageHeaderID,
                providerInReplyToMessageID: item.inReplyToMessageID,
                providerReferenceMessageIDs: item.referenceMessageIDs,
                receivedAt: item.receivedAt,
                senderName: item.senderName,
                senderEmail: item.senderEmail,
                subject: item.subject,
                preview: item.snippet,
                body: item.body.isEmpty ? item.snippet : item.body,
                htmlBody: item.htmlBody,
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

        if selectedAccountID == nil && !preferences.unifiedInboxEnabled {
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
        scheduleDeckRebuild()
    }

    func applyMoveToFolder(_ folder: String, messageID: UUID) {
        let value = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }

        let tag = "Folder: \(value)"
        let relatedIDs = threadMessageIDs(containing: messageID)
        for relatedID in relatedIDs {
            guard let idx = messages.firstIndex(where: { $0.id == relatedID }) else { continue }
            messages[idx].labels = Array(Set(messages[idx].labels + [tag])).sorted()
            messages[idx].archivedAt = Date()
        }
        scheduleSave()
        rebuildDeck()
    }

    func applyLabel(_ label: String, messageID: UUID) {
        let value = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }

        let relatedIDs = threadMessageIDs(containing: messageID)
        for relatedID in relatedIDs {
            guard let idx = messages.firstIndex(where: { $0.id == relatedID }) else { continue }
            messages[idx].labels = Array(Set(messages[idx].labels + [value])).sorted()
        }
        scheduleSave()
        rebuildDeck()
    }

    func deleteAllData() {
        accounts = []
        messages = []
        visibleThreads = []
        blockedSenders = []
        unsubscribedSenders = []
        queuedActions = []
        selectedAccountID = nil
        selectedCategory = nil
        deckMessageIDs = []
        threadsByID = [:]
        threadIDByMessageID = [:]
        visibleThreadIDByLeadMessageID = [:]
        skippedThreadIDs = []
        pendingAdvanceThreadID = nil
        deleteStoreFile()
    }

    func clearLocalState(for providers: Set<MailProvider>) {
        guard !providers.isEmpty else { return }

        let targetAccountIDs = Set(
            accounts
                .filter { providers.contains($0.provider) }
                .map(\.id)
        )
        guard !targetAccountIDs.isEmpty else { return }

        messages.removeAll { targetAccountIDs.contains($0.accountID) }
        queuedActions.removeAll { targetAccountIDs.contains($0.accountID) }
        logger.info(
            "Cleared local state for selected providers.",
            category: "MailStore",
            metadata: ["providers": providers.map(\.displayName).sorted().joined(separator: ", ")]
        )
        scheduleSave()
        rebuildDeck()
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

    private func scheduleDeckRebuild() {
        deckRebuildWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.rebuildDeck()
        }
        deckRebuildWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
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

    private static func replySubject(for originalSubject: String) -> String {
        let trimmed = originalSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Re: (No Subject)"
        }
        if trimmed.lowercased().hasPrefix("re:") {
            return trimmed
        }
        return "Re: \(trimmed)"
    }

    private static func combineReferenceMessageIDs(_ baseIDs: [String], include messageID: String?) -> [String] {
        var combined = baseIDs
        if let messageID, !messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            combined.append(messageID)
        }

        var seen = Set<String>()
        var deduplicated: [String] = []
        for item in combined {
            let normalized = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else {
                continue
            }
            deduplicated.append(normalized)
        }
        return deduplicated
    }

    private func threadMessageIDs(containing messageID: UUID) -> [UUID] {
        guard let threadID = threadIDByMessageID[messageID],
              let thread = threadsByID[threadID] else {
            return [messageID]
        }
        return thread.messageIDs
    }

    private func leadMessageID(forThreadContaining messageID: UUID) -> UUID {
        guard let threadID = threadIDByMessageID[messageID],
              let thread = threadsByID[threadID] else {
            return messageID
        }
        return thread.leadMessage.id
    }

    func leadMessageID(containing messageID: UUID) -> UUID {
        leadMessageID(forThreadContaining: messageID)
    }

    private func threadID(containing messageID: UUID) -> String? {
        threadIDByMessageID[messageID]
    }

    private func buildThreadSeeds(from messages: [EmailMessage]) -> [ThreadSeed] {
        let messagesByAccount = Dictionary(grouping: messages, by: \.accountID)
        var seeds: [ThreadSeed] = []

        for (accountID, accountMessages) in messagesByAccount {
            let sorted = accountMessages.sorted { lhs, rhs in
                if lhs.receivedAt != rhs.receivedAt {
                    return lhs.receivedAt < rhs.receivedAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            guard !sorted.isEmpty else { continue }

            var unions = UnionFind(count: sorted.count)
            var indicesByProviderThreadID: [String: Int] = [:]
            var indicesByHeaderID: [String: Int] = [:]

            for (index, message) in sorted.enumerated() {
                if let providerThreadID = normalizedThreadIdentifier(message.providerThreadID) {
                    if let existingIndex = indicesByProviderThreadID[providerThreadID] {
                        unions.union(existingIndex, index)
                    } else {
                        indicesByProviderThreadID[providerThreadID] = index
                    }
                }

                if let headerID = normalizedMessageIdentifier(message.providerMessageHeaderID) {
                    if let existingIndex = indicesByHeaderID[headerID] {
                        unions.union(existingIndex, index)
                    } else {
                        indicesByHeaderID[headerID] = index
                    }
                }
            }

            for (index, message) in sorted.enumerated() {
                let relatedHeaderIDs = Self.combineReferenceMessageIDs(
                    message.providerReferenceMessageIDs ?? [],
                    include: message.providerInReplyToMessageID
                )
                for reference in relatedHeaderIDs {
                    guard let referenceID = normalizedMessageIdentifier(reference),
                          let targetIndex = indicesByHeaderID[referenceID] else {
                        continue
                    }
                    unions.union(index, targetIndex)
                }
            }

            let subjectGroups = Dictionary(grouping: Array(sorted.enumerated())) { entry in
                normalizedThreadSubject(entry.element.subject)
            }

            for (subjectKey, entries) in subjectGroups where subjectKey != "(no-subject)" && entries.count > 1 {
                let orderedEntries = entries.sorted { lhs, rhs in
                    if lhs.element.receivedAt != rhs.element.receivedAt {
                        return lhs.element.receivedAt < rhs.element.receivedAt
                    }
                    return lhs.element.id.uuidString < rhs.element.id.uuidString
                }

                var anchorIndex = orderedEntries[0].offset
                var anchorDate = orderedEntries[0].element.receivedAt
                for entry in orderedEntries.dropFirst() {
                    let delta = entry.element.receivedAt.timeIntervalSince(anchorDate)
                    if delta <= 60 * 60 * 24 * 5 {
                        unions.union(anchorIndex, entry.offset)
                    } else {
                        anchorIndex = entry.offset
                        anchorDate = entry.element.receivedAt
                    }
                }
            }

            var grouped: [Int: [EmailMessage]] = [:]
            for (index, message) in sorted.enumerated() {
                let root = unions.find(index)
                grouped[root, default: []].append(message)
            }

            for group in grouped.values {
                let orderedGroup = group.sorted { lhs, rhs in
                    if lhs.receivedAt != rhs.receivedAt {
                        return lhs.receivedAt < rhs.receivedAt
                    }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                guard let first = orderedGroup.first else { continue }
                let last = orderedGroup.last ?? first
                let provider = accounts.first(where: { $0.id == accountID })?.provider
                let providerThreadID = orderedGroup.compactMap { normalizedThreadIdentifier($0.providerThreadID) }.first
                let headerID = orderedGroup.compactMap { normalizedMessageIdentifier($0.providerMessageHeaderID) }.first
                let fallbackKey = normalizedThreadSubject(last.subject)
                let threadID = providerThreadID
                    ?? headerID
                    ?? "subject:\(fallbackKey):\(Int(first.receivedAt.timeIntervalSince1970 / (60 * 60 * 24 * 5)))"
                let providerPrefix = provider?.rawValue ?? "local"
                seeds.append(ThreadSeed(id: "\(providerPrefix):\(accountID.uuidString):\(threadID)", accountID: accountID, messages: orderedGroup))
            }
        }

        return seeds.sorted { lhs, rhs in
            let lhsDate = lhs.messages.last?.receivedAt ?? .distantPast
            let rhsDate = rhs.messages.last?.receivedAt ?? .distantPast
            return lhsDate > rhsDate
        }
    }

    private func normalizedThreadIdentifier(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    private func normalizedMessageIdentifier(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        let lowercased = trimmed.lowercased()
        return lowercased.hasPrefix("<") && lowercased.hasSuffix(">") ? lowercased : "<\(lowercased)>"
    }

    private func normalizedThreadSubject(_ subject: String) -> String {
        var normalized = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return "(no-subject)" }

        let pattern = "^(?:(?:re|fw|fwd)\\s*:\\s*)+"
        while let range = normalized.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
            normalized.removeSubrange(range)
            normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if normalized.isEmpty { return "(no-subject)" }
        return normalized.lowercased()
    }

    private static func replySendErrorMessage(for error: Error, provider: MailProvider) -> String {
        if let providerError = error as? ReplyProviderSendError {
            return providerError.localizedDescription
        }
        if let gmailError = error as? GmailServiceError {
            return gmailError.localizedDescription
        }
        if let yahooError = error as? YahooServiceError {
            return yahooError.localizedDescription
        }
        if let fastmailError = error as? FastmailServiceError {
            return fastmailError.localizedDescription
        }
        if let oauthError = error as? OAuthServiceError {
            return oauthError.localizedDescription
        }
        if let smtpError = error as? SMTPClientError {
            return smtpError.localizedDescription
        }
        return "Could not send reply through \(provider.displayName). \(error.localizedDescription)"
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
        let relatedIDs = threadMessageIDs(containing: messageID)
        let relatedMessages = relatedIDs.compactMap { id in
            messages.first(where: { $0.id == id })
        }

        if networkMonitor.isOnline == false && !action.isLocalOnly {
            queuedActions.append(QueuedMailAction(id: UUID(), createdAt: Date(), accountID: messages[idx].accountID, messageID: messageID, action: action, isSecondary: isSecondary))
        }

        switch action {
        case .delete:
            markMessagesRead(ids: relatedIDs)
            for relatedID in relatedIDs {
                guard let relatedIndex = messages.firstIndex(where: { $0.id == relatedID }) else { continue }
                messages[relatedIndex].deletedAt = Date()
            }
            deckMessageIDs.removeAll(where: { $0 == leadMessageID(forThreadContaining: messageID) })
            clearSkippedState(for: messageID)
            for message in relatedMessages {
                trashOnProviderIfPossible(message)
            }

        case .archive:
            markMessagesRead(ids: relatedIDs)
            for relatedID in relatedIDs {
                guard let relatedIndex = messages.firstIndex(where: { $0.id == relatedID }) else { continue }
                messages[relatedIndex].archivedAt = Date()
            }
            deckMessageIDs.removeAll(where: { $0 == leadMessageID(forThreadContaining: messageID) })
            clearSkippedState(for: messageID)
            for message in relatedMessages {
                archiveOnProviderIfPossible(message)
            }

        case .markUnread:
            for relatedID in relatedIDs {
                guard let relatedIndex = messages.firstIndex(where: { $0.id == relatedID }) else { continue }
                messages[relatedIndex].isRead = false
            }

        case .unstar:
            for relatedID in relatedIDs {
                guard let relatedIndex = messages.firstIndex(where: { $0.id == relatedID }) else { continue }
                messages[relatedIndex].isStarred = false
            }

        case .markImportant:
            for relatedID in relatedIDs {
                guard let relatedIndex = messages.firstIndex(where: { $0.id == relatedID }) else { continue }
                messages[relatedIndex].isImportant = true
            }

        case .unmarkImportant:
            for relatedID in relatedIDs {
                guard let relatedIndex = messages.firstIndex(where: { $0.id == relatedID }) else { continue }
                messages[relatedIndex].isImportant = false
            }

        case .moveToFolder:
            prompt = .moveToFolder(messageID: messageID)
            return

        case .applyLabel:
            prompt = .applyLabel(messageID: messageID)
            return

        case .unsubscribe:
            unsubscribedSenders.insert(sender)
            markMessagesRead(ids: relatedIDs)
            for relatedID in relatedIDs {
                guard let relatedIndex = messages.firstIndex(where: { $0.id == relatedID }) else { continue }
                messages[relatedIndex].archivedAt = Date()
            }
            deckMessageIDs.removeAll(where: { $0 == leadMessageID(forThreadContaining: messageID) })
            clearSkippedState(for: messageID)

        case .unsubscribeAndDeleteAllFromSender:
            unsubscribedSenders.insert(sender)
            markMessagesRead(where: { $0.senderEmail.lowercased() == sender })
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
            markMessagesRead(where: { $0.senderEmail.lowercased() == sender })
            for i in messages.indices {
                if messages[i].senderEmail.lowercased() == sender {
                    messages[i].archivedAt = Date()
                }
            }
            deckMessageIDs.removeAll(where: { id in
                messages.first(where: { $0.id == id })?.senderEmail.lowercased() == sender
            })

        case .snooze1h:
            for relatedID in relatedIDs {
                guard let relatedIndex = messages.firstIndex(where: { $0.id == relatedID }) else { continue }
                messages[relatedIndex].snoozedUntil = Date().addingTimeInterval(60 * 60)
            }
            deckMessageIDs.removeAll(where: { $0 == leadMessageID(forThreadContaining: messageID) })
            clearSkippedState(for: messageID)

        case .snooze4h:
            for relatedID in relatedIDs {
                guard let relatedIndex = messages.firstIndex(where: { $0.id == relatedID }) else { continue }
                messages[relatedIndex].snoozedUntil = Date().addingTimeInterval(60 * 60 * 4)
            }
            deckMessageIDs.removeAll(where: { $0 == leadMessageID(forThreadContaining: messageID) })
            clearSkippedState(for: messageID)

        case .snooze1d:
            for relatedID in relatedIDs {
                guard let relatedIndex = messages.firstIndex(where: { $0.id == relatedID }) else { continue }
                messages[relatedIndex].snoozedUntil = Date().addingTimeInterval(60 * 60 * 24)
            }
            deckMessageIDs.removeAll(where: { $0 == leadMessageID(forThreadContaining: messageID) })
            clearSkippedState(for: messageID)

        case .createReminder:
            reminder = ReminderPresentation(messageID: leadMessageID(forThreadContaining: messageID))
            scheduleSave()
            return

        case .skip:
            markSkipped(messageID)
            advanceToNextMessage(after: messageID)

        case .reply:
            composer = ComposerPresentation(messageID: leadMessageID(forThreadContaining: messageID), mode: .reply)

        case .aiReply:
            composer = ComposerPresentation(messageID: leadMessageID(forThreadContaining: messageID), mode: .aiReply)

        case .pin:
            let shouldPin = relatedMessages.allSatisfy { $0.pinnedAt == nil }
            for relatedID in relatedIDs {
                guard let relatedIndex = messages.firstIndex(where: { $0.id == relatedID }) else { continue }
                messages[relatedIndex].pinnedAt = shouldPin ? Date() : nil
            }
        }

        scheduleSave()
        if networkMonitor.isOnline && !action.isLocalOnly {
            syncIfPossible()
        }
        rebuildDeck()
    }

    private func markMessagesRead(ids: [UUID]) {
        for messageID in ids {
            guard let index = messages.firstIndex(where: { $0.id == messageID }) else { continue }
            messages[index].isRead = true
        }
    }

    private func markMessagesRead(where predicate: (EmailMessage) -> Bool) {
        for index in messages.indices where predicate(messages[index]) {
            messages[index].isRead = true
        }
    }

    private func advanceToNextMessage(after messageID: UUID) {
        guard let threadID = threadID(containing: messageID) else { return }
        pendingAdvanceThreadID = threadID
        let leadMessageID = leadMessageID(forThreadContaining: messageID)
        if let first = deckMessageIDs.first, first == leadMessageID {
            deckMessageIDs.removeFirst()
            deckMessageIDs.append(first)
        }
    }

    private func markSkipped(_ messageID: UUID) {
        guard let threadID = threadID(containing: messageID) else { return }
        skippedThreadIDs.removeAll(where: { $0 == threadID })
        skippedThreadIDs.append(threadID)
    }

    private func clearSkippedState(for messageID: UUID) {
        guard let threadID = threadID(containing: messageID) else { return }
        skippedThreadIDs.removeAll(where: { $0 == threadID })
    }

    private func triggerBackgroundProviderSync() {
        guard networkMonitor.isOnline else { return }
        guard preferences.isAnyAutoSyncEnabled else { return }
        logger.debug("Background provider sync tick triggered.", category: "MailStore")
        Task { [weak self] in
            await self?.runBackgroundProviderSync()
        }
    }

    private func maybeTriggerPeriodicSync() {
        let interval = max(30, preferences.backgroundSyncIntervalSeconds)
        guard Date().timeIntervalSince(lastPeriodicSyncAt) >= Double(interval) else { return }
        lastPeriodicSyncAt = Date()
        triggerBackgroundProviderSync()
    }

    private func maybeTriggerLowDeckSync() {
        guard networkMonitor.isOnline else { return }
        guard deckMessageIDs.count <= lowDeckSyncThreshold else { return }
        guard Date().timeIntervalSince(lastProactiveSyncAt) >= proactiveSyncCooldown else { return }
        lastProactiveSyncAt = Date()
        logger.debug(
            "Deck running low; triggering proactive provider sync.",
            category: "MailStore",
            metadata: ["deckCount": "\(deckMessageIDs.count)"]
        )
        triggerBackgroundProviderSync()
    }

    private func markSyncStarted(provider: MailProvider) async {
        await MainActor.run {
            syncProviderCounts[provider, default: 0] += 1
            syncingProviders.insert(provider)
        }
    }

    private func markSyncFinished(provider: MailProvider) async {
        await MainActor.run {
            let nextCount = max(0, (syncProviderCounts[provider] ?? 0) - 1)
            if nextCount == 0 {
                syncProviderCounts[provider] = nil
                syncingProviders.remove(provider)
            } else {
                syncProviderCounts[provider] = nextCount
            }
        }
    }

    @MainActor
    private func runBackgroundProviderSync() async {
        if isBackgroundSyncInProgress { return }
        isBackgroundSyncInProgress = true
        defer { isBackgroundSyncInProgress = false }
        logger.debug("Background provider sync started.", category: "MailStore")

        async let gmailSync: Void = backgroundSyncGmailIfConnected()
        async let yahooSync: Void = backgroundSyncYahooAccounts()
        async let fastmailSync: Void = backgroundSyncFastmailAccounts()
        _ = await (gmailSync, yahooSync, fastmailSync)
        logger.debug("Background provider sync finished.", category: "MailStore")
    }

    @MainActor
    private func backgroundSyncGmailIfConnected() async {
        guard preferences.backgroundSyncGmailEnabled else { return }
        let gmailAccounts = accounts.filter { $0.provider == .gmail }
        guard !gmailAccounts.isEmpty else { return }

        for account in gmailAccounts {
            await markSyncStarted(provider: .gmail)
            do {
                let hasSession = await gmailAuthStore.hasSession(for: account.emailAddress)
                if !hasSession {
                    logger.debug(
                        "Skipping background Gmail sync: no OAuth session for account.",
                        category: "MailStore",
                        metadata: ["email": account.emailAddress]
                    )
                    await markSyncFinished(provider: .gmail)
                    continue
                }
                let items = try await gmailAuthStore.fetchRecentInboxMessages(
                    for: account.emailAddress,
                    maxResults: max(10, min(200, preferences.backgroundGmailFetchCount))
                )
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
            await markSyncFinished(provider: .gmail)
        }
    }

    @MainActor
    private func backgroundSyncYahooAccounts() async {
        guard preferences.backgroundSyncYahooEnabled else { return }
        let yahooAccounts = accounts.filter { $0.provider == .yahoo }
        guard !yahooAccounts.isEmpty else { return }

        for account in yahooAccounts {
            do {
                try await syncYahooInbox(
                    for: account.emailAddress,
                    maxResults: max(10, min(120, preferences.backgroundIMAPFetchCount))
                )
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
        guard preferences.backgroundSyncFastmailEnabled else { return }
        let fastmailAccounts = accounts.filter { $0.provider == .fastmail }
        guard !fastmailAccounts.isEmpty else { return }

        for account in fastmailAccounts {
            do {
                try await syncFastmailInbox(
                    for: account.emailAddress,
                    maxResults: max(10, min(120, preferences.backgroundIMAPFetchCount))
                )
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

    private func sendReplyOnProvider(_ request: ReplySendRequest) async throws {
        switch request.account.provider {
        case .gmail:
            try await gmailAuthStore.sendReply(request)
        case .yahoo:
            let appPassword = try yahooCredentialsStore.loadAppPassword(emailAddress: request.account.emailAddress)
            try await yahooService.sendReply(
                emailAddress: request.account.emailAddress,
                appPassword: appPassword,
                request: request
            )
        case .fastmail:
            let appPassword = try fastmailCredentialsStore.loadAppPassword(emailAddress: request.account.emailAddress)
            try await fastmailService.sendReply(
                emailAddress: request.account.emailAddress,
                appPassword: appPassword,
                request: request
            )
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

    private func archiveOnProviderIfPossible(_ message: EmailMessage) {
        guard let account = accounts.first(where: { $0.id == message.accountID }),
              let providerMessageID = message.providerMessageID else {
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                switch account.provider {
                case .gmail:
                    try await gmailAuthStore.archiveMessage(id: providerMessageID, for: account.emailAddress)
                    logger.info(
                        "Archived Gmail message on provider.",
                        category: "MailStore",
                        metadata: ["messageID": providerMessageID, "email": account.emailAddress]
                    )
                case .yahoo:
                    let appPassword = try yahooCredentialsStore.loadAppPassword(emailAddress: account.emailAddress)
                    try await yahooService.archiveMessage(
                        emailAddress: account.emailAddress,
                        appPassword: appPassword,
                        id: providerMessageID
                    )
                    logger.info(
                        "Archived Yahoo message on provider.",
                        category: "MailStore",
                        metadata: ["messageID": providerMessageID, "email": account.emailAddress]
                    )
                case .fastmail:
                    let appPassword = try fastmailCredentialsStore.loadAppPassword(emailAddress: account.emailAddress)
                    try await fastmailService.archiveMessage(
                        emailAddress: account.emailAddress,
                        appPassword: appPassword,
                        id: providerMessageID
                    )
                    logger.info(
                        "Archived Fastmail message on provider.",
                        category: "MailStore",
                        metadata: ["messageID": providerMessageID, "email": account.emailAddress]
                    )
                }
            } catch let gmailError as GmailServiceError where gmailError.statusCode == 404 {
                logger.warning(
                    "Gmail message already missing on provider during archive; treating local archive as complete.",
                    category: "MailStore",
                    metadata: ["messageID": providerMessageID, "email": account.emailAddress]
                )
            } catch let yahooError as YahooServiceError {
                switch yahooError {
                case .messageNotFound:
                    logger.warning(
                        "Yahoo message already missing on provider during archive; treating local archive as complete.",
                        category: "MailStore",
                        metadata: ["messageID": providerMessageID, "email": account.emailAddress]
                    )
                default:
                    logger.error(
                        "Failed archiving Yahoo message on provider.",
                        category: "MailStore",
                        metadata: ["messageID": providerMessageID, "error": yahooError.localizedDescription]
                    )
                    await MainActor.run {
                        self.errorAlert = ErrorAlert(
                            title: "Yahoo Archive Failed",
                            message: "Archived locally, but Yahoo archive failed: \(yahooError.localizedDescription)"
                        )
                    }
                }
            } catch let fastmailError as FastmailServiceError {
                switch fastmailError {
                case .messageNotFound:
                    logger.warning(
                        "Fastmail message already missing on provider during archive; treating local archive as complete.",
                        category: "MailStore",
                        metadata: ["messageID": providerMessageID, "email": account.emailAddress]
                    )
                default:
                    logger.error(
                        "Failed archiving Fastmail message on provider.",
                        category: "MailStore",
                        metadata: ["messageID": providerMessageID, "error": fastmailError.localizedDescription]
                    )
                    await MainActor.run {
                        self.errorAlert = ErrorAlert(
                            title: "Fastmail Archive Failed",
                            message: "Archived locally, but Fastmail archive failed: \(fastmailError.localizedDescription)"
                        )
                    }
                }
            } catch {
                logger.error(
                    "Failed archiving message on provider.",
                    category: "MailStore",
                    metadata: ["messageID": providerMessageID, "error": error.localizedDescription]
                )
                await MainActor.run {
                    self.errorAlert = ErrorAlert(
                        title: "\(account.provider.displayName) Archive Failed",
                        message: "Archived locally, but provider archive failed: \(error.localizedDescription)"
                    )
                }
            }
        }
    }
}
