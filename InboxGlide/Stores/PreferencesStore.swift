import SwiftUI

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

enum CardDensity: String, Codable, CaseIterable, Identifiable {
    case compact
    case comfortable
    case spacious

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .compact: return "Compact"
        case .comfortable: return "Comfortable"
        case .spacious: return "Spacious"
        }
    }
}

enum EmailBodyDisplayMode: String, Codable, CaseIterable, Identifiable {
    case renderedHTML
    case parsedText

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .renderedHTML: return "Rendered HTML"
        case .parsedText: return "Parsed Text"
        }
    }
}

enum AIMode: String, Codable, CaseIterable, Identifiable {
    case off
    case local
    case cloud

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .local: return "Local (Offline)"
        case .cloud: return "Cloud (Stub)"
        }
    }
}

enum AISummaryLength: String, Codable, CaseIterable, Identifiable {
    case short
    case medium
    case full

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .short: return "Short"
        case .medium: return "Medium"
        case .full: return "Full"
        }
    }
}

final class PreferencesStore: ObservableObject {
    private enum Keys {
        static let leftPrimary = "glide.left.primary"
        static let rightPrimary = "glide.right.primary"
        static let upPrimary = "glide.up.primary"
        static let downPrimary = "glide.down.primary"

        static let leftSecondary = "glide.left.secondary"
        static let rightSecondary = "glide.right.secondary"
        static let upSecondary = "glide.up.secondary"
        static let downSecondary = "glide.down.secondary"

        static let confirmDestructive = "glide.confirmDestructive"

        static let appearanceMode = "appearance.mode"
        static let cardDensity = "appearance.cardDensity"
        static let fontScale = "appearance.fontScale"
        static let emailBodyDisplayMode = "appearance.emailBodyDisplayMode"

        static let unifiedInbox = "accounts.unifiedInbox"
        static let smartCategories = "inbox.smartCategories"

        static let dailyReminderEnabled = "notifications.daily.enabled"
        static let dailyReminderHour = "notifications.daily.hour"
        static let dailyReminderMinute = "notifications.daily.minute"

        static let aiMode = "ai.mode"
        static let aiSummaryLength = "ai.summaryLength"
        static let analyticsOptIn = "privacy.analyticsOptIn"
        static let crashOptIn = "privacy.crashOptIn"
        
        static let hasCompletedOnboarding = "onboarding.completed"
    }

    private let defaults: UserDefaults

    @Published var leftPrimaryAction: GlideAction { didSet { defaults.set(leftPrimaryAction.rawValue, forKey: Keys.leftPrimary) } }
    @Published var rightPrimaryAction: GlideAction { didSet { defaults.set(rightPrimaryAction.rawValue, forKey: Keys.rightPrimary) } }
    @Published var upPrimaryAction: GlideAction { didSet { defaults.set(upPrimaryAction.rawValue, forKey: Keys.upPrimary) } }
    @Published var downPrimaryAction: GlideAction { didSet { defaults.set(downPrimaryAction.rawValue, forKey: Keys.downPrimary) } }

    @Published var leftSecondaryAction: GlideAction { didSet { defaults.set(leftSecondaryAction.rawValue, forKey: Keys.leftSecondary) } }
    @Published var rightSecondaryAction: GlideAction { didSet { defaults.set(rightSecondaryAction.rawValue, forKey: Keys.rightSecondary) } }
    @Published var upSecondaryAction: GlideAction { didSet { defaults.set(upSecondaryAction.rawValue, forKey: Keys.upSecondary) } }
    @Published var downSecondaryAction: GlideAction { didSet { defaults.set(downSecondaryAction.rawValue, forKey: Keys.downSecondary) } }

    @Published var confirmDestructiveActions: Bool { didSet { defaults.set(confirmDestructiveActions, forKey: Keys.confirmDestructive) } }

    @Published var appearanceMode: AppearanceMode { didSet { defaults.set(appearanceMode.rawValue, forKey: Keys.appearanceMode) } }
    @Published var cardDensity: CardDensity { didSet { defaults.set(cardDensity.rawValue, forKey: Keys.cardDensity) } }
    @Published var emailBodyDisplayMode: EmailBodyDisplayMode { didSet { defaults.set(emailBodyDisplayMode.rawValue, forKey: Keys.emailBodyDisplayMode) } }

    /// -2.0 ... +4.0 (roughly)
    @Published var fontScale: Double { didSet { defaults.set(fontScale, forKey: Keys.fontScale) } }

    @Published var unifiedInboxEnabled: Bool { didSet { defaults.set(unifiedInboxEnabled, forKey: Keys.unifiedInbox) } }
    @Published var smartCategoriesEnabled: Bool { didSet { defaults.set(smartCategoriesEnabled, forKey: Keys.smartCategories) } }

    @Published var dailyReminderEnabled: Bool { didSet { defaults.set(dailyReminderEnabled, forKey: Keys.dailyReminderEnabled) } }
    @Published var dailyReminderHour: Int { didSet { defaults.set(dailyReminderHour, forKey: Keys.dailyReminderHour) } }
    @Published var dailyReminderMinute: Int { didSet { defaults.set(dailyReminderMinute, forKey: Keys.dailyReminderMinute) } }

    @Published var aiMode: AIMode { didSet { defaults.set(aiMode.rawValue, forKey: Keys.aiMode) } }
    @Published var aiSummaryLength: AISummaryLength { didSet { defaults.set(aiSummaryLength.rawValue, forKey: Keys.aiSummaryLength) } }

    @Published var analyticsOptIn: Bool { didSet { defaults.set(analyticsOptIn, forKey: Keys.analyticsOptIn) } }
    @Published var crashReportingOptIn: Bool { didSet { defaults.set(crashReportingOptIn, forKey: Keys.crashOptIn) } }
    
    @Published var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let leftP = Self.sanitizedAction(raw: defaults.string(forKey: Keys.leftPrimary), fallback: .delete)
        let rightP = Self.sanitizedAction(raw: defaults.string(forKey: Keys.rightPrimary), fallback: .star)
        let upP = Self.sanitizedAction(raw: defaults.string(forKey: Keys.upPrimary), fallback: .archive)
        let downP = Self.sanitizedAction(raw: defaults.string(forKey: Keys.downPrimary), fallback: .markRead)

        let leftS = Self.sanitizedAction(raw: defaults.string(forKey: Keys.leftSecondary), fallback: .archive)
        let rightS = Self.sanitizedAction(raw: defaults.string(forKey: Keys.rightSecondary), fallback: .markImportant)
        let upS = Self.sanitizedAction(raw: defaults.string(forKey: Keys.upSecondary), fallback: .snooze4h)
        let downS = Self.sanitizedAction(raw: defaults.string(forKey: Keys.downSecondary), fallback: .skip)

        self.leftPrimaryAction = leftP
        self.rightPrimaryAction = rightP
        self.upPrimaryAction = upP
        self.downPrimaryAction = downP

        self.leftSecondaryAction = leftS
        self.rightSecondaryAction = rightS
        self.upSecondaryAction = upS
        self.downSecondaryAction = downS

        self.confirmDestructiveActions = defaults.object(forKey: Keys.confirmDestructive) as? Bool ?? true

        self.appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearanceMode) ?? "") ?? .system
        self.cardDensity = CardDensity(rawValue: defaults.string(forKey: Keys.cardDensity) ?? "") ?? .comfortable
        self.emailBodyDisplayMode = EmailBodyDisplayMode(rawValue: defaults.string(forKey: Keys.emailBodyDisplayMode) ?? "") ?? .renderedHTML
        self.fontScale = defaults.object(forKey: Keys.fontScale) as? Double ?? 0

        self.unifiedInboxEnabled = defaults.object(forKey: Keys.unifiedInbox) as? Bool ?? true
        self.smartCategoriesEnabled = defaults.object(forKey: Keys.smartCategories) as? Bool ?? false

        self.dailyReminderEnabled = defaults.object(forKey: Keys.dailyReminderEnabled) as? Bool ?? false
        self.dailyReminderHour = defaults.object(forKey: Keys.dailyReminderHour) as? Int ?? 9
        self.dailyReminderMinute = defaults.object(forKey: Keys.dailyReminderMinute) as? Int ?? 0

        self.aiMode = AIMode(rawValue: defaults.string(forKey: Keys.aiMode) ?? "") ?? .local
        self.aiSummaryLength = AISummaryLength(rawValue: defaults.string(forKey: Keys.aiSummaryLength) ?? "") ?? .short
        self.analyticsOptIn = defaults.object(forKey: Keys.analyticsOptIn) as? Bool ?? false
        self.crashReportingOptIn = defaults.object(forKey: Keys.crashOptIn) as? Bool ?? false
        
        self.hasCompletedOnboarding = defaults.object(forKey: Keys.hasCompletedOnboarding) as? Bool ?? false
    }

    func action(for direction: GlideDirection, useSecondary: Bool) -> GlideAction {
        switch (direction, useSecondary) {
        case (.left, false): return leftPrimaryAction
        case (.right, false): return rightPrimaryAction
        case (.up, false): return upPrimaryAction
        case (.down, false): return downPrimaryAction
        case (.left, true): return leftSecondaryAction
        case (.right, true): return rightSecondaryAction
        case (.up, true): return upSecondaryAction
        case (.down, true): return downSecondaryAction
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var cardPadding: CGFloat {
        switch cardDensity {
        case .compact: return 10
        case .comfortable: return 14
        case .spacious: return 18
        }
    }

    private static func sanitizedAction(raw: String?, fallback: GlideAction) -> GlideAction {
        guard let raw, let action = GlideAction(rawValue: raw), action.isSelectableInUI else {
            return fallback
        }
        return action
    }
}
