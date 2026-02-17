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

    @Published var selectedAccountID: UUID? = nil
    @Published var selectedCategory: MessageCategory? = nil

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
    private let secureStore: SecureStore
    private let logger = AppLogger.shared

    private var saveWorkItem: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "InboxGlide.MailStore.Save", qos: .utility)
    private var refreshTimer: Timer?

    init(preferences: PreferencesStore, networkMonitor: NetworkMonitor, secureStore: SecureStore) {
        self.preferences = preferences
        self.networkMonitor = networkMonitor
        self.secureStore = secureStore
        logger.info("Initializing MailStore.", category: "MailStore")

        loadOrBootstrap()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.rebuildDeck()
        }
    }

    deinit {
        refreshTimer?.invalidate()
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
    }

    func performGlide(_ direction: GlideDirection, useSecondary: Bool) {
        guard let msg = currentMessage else { return }
        let action = preferences.action(for: direction, useSecondary: useSecondary)
        perform(action: action, isSecondary: useSecondary, messageID: msg.id)
    }

    func perform(action: GlideAction, isSecondary: Bool, messageID: UUID) {
        guard messages.contains(where: { $0.id == messageID }) else { return }
        if action.isDestructive, preferences.confirmDestructiveActions {
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
            colorHex: ["#2563EB", "#16A34A", "#F97316", "#DC2626", "#0EA5E9"].randomElement() ?? "#2563EB"
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
                messages[existingIndex].body = item.snippet
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
                body: item.snippet,
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
        secureStore.deleteStoreFile()
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
        if let snapshot = secureStore.load(StoreSnapshot.self) {
            accounts = snapshot.accounts
            messages = snapshot.messages
            blockedSenders = snapshot.blockedSenders
            unsubscribedSenders = snapshot.unsubscribedSenders
            queuedActions = snapshot.queuedActions
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

    private func persist() {
        let snapshot = StoreSnapshot(
            accounts: accounts,
            messages: messages,
            blockedSenders: blockedSenders,
            unsubscribedSenders: unsubscribedSenders,
            queuedActions: queuedActions
        )
        secureStore.save(snapshot)
    }

    private func apply(action: GlideAction, isSecondary: Bool, messageID: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }) else { return }
        let sender = messages[idx].senderEmail.lowercased()

        if networkMonitor.isOnline == false {
            queuedActions.append(QueuedMailAction(id: UUID(), createdAt: Date(), accountID: messages[idx].accountID, messageID: messageID, action: action, isSecondary: isSecondary))
        }

        switch action {
        case .delete:
            messages[idx].deletedAt = Date()
            deckMessageIDs.removeAll(where: { $0 == messageID })

        case .archive:
            messages[idx].archivedAt = Date()
            deckMessageIDs.removeAll(where: { $0 == messageID })

        case .markRead:
            messages[idx].isRead = true

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
            if let first = deckMessageIDs.first, first == messageID {
                deckMessageIDs.removeFirst()
                deckMessageIDs.append(first)
            }

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
}
