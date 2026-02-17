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

    private var saveWorkItem: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "InboxGlide.MailStore.Save", qos: .utility)
    private var refreshTimer: Timer?

    init(preferences: PreferencesStore, networkMonitor: NetworkMonitor, secureStore: SecureStore) {
        self.preferences = preferences
        self.networkMonitor = networkMonitor
        self.secureStore = secureStore

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

    func addSampleAccount() {
        bootstrapSampleData()
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
        if selectedAccountID == nil {
            selectedAccountID = account.id
        }
        scheduleSave()
        rebuildDeck()
    }

    func deleteAccount(_ account: MailAccount) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts.remove(at: index)
        messages.removeAll { $0.accountID == account.id }
        queuedActions.removeAll { $0.accountID == account.id }
        if selectedAccountID == account.id {
            selectedAccountID = accounts.first?.id
        }
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

    private func bootstrapSampleData() {
        let a1 = MailAccount(id: UUID(), provider: .gmail, displayName: "Work", emailAddress: "you@company.com", colorHex: "#2563EB")
        let a2 = MailAccount(id: UUID(), provider: .fastmail, displayName: "Personal", emailAddress: "you@home.com", colorHex: "#16A34A")
        let a3 = MailAccount(id: UUID(), provider: .yahoo, displayName: "Legacy", emailAddress: "you@yahoo.com", colorHex: "#F97316")
        accounts = [a1, a2, a3]

        selectedAccountID = a1.id

        let now = Date()
        func make(_ account: MailAccount, _ offsetHours: Int, _ sender: String, _ email: String, _ subject: String, _ preview: String, _ body: String, _ cat: MessageCategory) -> EmailMessage {
            EmailMessage(
                id: UUID(),
                accountID: account.id,
                receivedAt: Calendar.current.date(byAdding: .hour, value: -offsetHours, to: now) ?? now,
                senderName: sender,
                senderEmail: email,
                subject: subject,
                preview: preview,
                body: body,
                isRead: false,
                isStarred: false,
                isImportant: false,
                labels: [],
                archivedAt: nil,
                deletedAt: nil,
                snoozedUntil: nil,
                category: cat
            )
        }

        messages = [
            make(a1, 1, "Ava", "ava@company.com", "Project update", "Quick status update for this week.", "Hi! Here's the status update...", .work),
            make(a1, 3, "Build Bot", "ci@company.com", "Build failed", "The latest build failed on main.", "Details: ...", .updates),
            make(a1, 6, "Team Forum", "forum@company.com", "Thread: Q1 planning", "New reply in the Q1 planning thread.", "...", .forums),
            make(a2, 2, "Mom", "mom@example.com", "Dinner Sunday?", "Are you free on Sunday night?", "Call me when you can.", .personal),
            make(a2, 5, "Neighborhood", "news@local.org", "Community updates", "This week's highlights.", "...", .updates),
            make(a3, 4, "Sale Alerts", "newsletter@shop.com", "48-hour sale", "Everything is 30% off.", "Unsubscribe anytime.", .promotions),
            make(a3, 7, "Social", "notify@social.example", "You have new mentions", "Two new mentions.", "...", .social)
        ]

        blockedSenders = []
        unsubscribedSenders = []
        queuedActions = []

        secureStore.save(StoreSnapshot(accounts: accounts, messages: messages, blockedSenders: blockedSenders, unsubscribedSenders: unsubscribedSenders, queuedActions: queuedActions))
        
        if selectedAccountID == nil {
            selectedAccountID = a1.id
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
