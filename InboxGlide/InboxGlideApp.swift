import SwiftUI

@main
struct InboxGlideApp: App {
    @StateObject private var preferences: PreferencesStore
    @StateObject private var networkMonitor: NetworkMonitor
    @StateObject private var mailStore: MailStore
    @StateObject private var reminders: RemindersService
    @StateObject private var notifications: NotificationScheduler
    @StateObject private var ai: AIReplyService
    @StateObject private var keyEvents: KeyEventMonitor

    init() {
        let prefs = PreferencesStore()
        let network = NetworkMonitor()
        let secureStore = SecureStore(appName: "InboxGlide")
        let store = MailStore(preferences: prefs, networkMonitor: network, secureStore: secureStore)

        _preferences = StateObject(wrappedValue: prefs)
        _networkMonitor = StateObject(wrappedValue: network)
        _mailStore = StateObject(wrappedValue: store)
        _reminders = StateObject(wrappedValue: RemindersService())
        _notifications = StateObject(wrappedValue: NotificationScheduler())
        _ai = StateObject(wrappedValue: AIReplyService())
        _keyEvents = StateObject(wrappedValue: KeyEventMonitor())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(preferences)
                .environmentObject(networkMonitor)
                .environmentObject(mailStore)
                .environmentObject(reminders)
                .environmentObject(notifications)
                .environmentObject(ai)
                .environmentObject(keyEvents)
                .preferredColorScheme(preferences.preferredColorScheme)
        }

        Settings {
            SettingsView()
                .environmentObject(preferences)
                .environmentObject(networkMonitor)
                .environmentObject(mailStore)
                .environmentObject(reminders)
                .environmentObject(notifications)
                .environmentObject(ai)
        }
    }
}
