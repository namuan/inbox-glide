import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        AppLogger.shared.info(
            "Application received open URL event.",
            category: "AppLifecycle",
            metadata: ["urlCount": "\(urls.count)"]
        )
        for url in urls {
            AppLogger.shared.debug(
                "Forwarding incoming URL to OAuth redirect notification.",
                category: "AppLifecycle",
                metadata: ["url": url.absoluteString]
            )
            NotificationCenter.default.post(name: .inboxGlideDidReceiveOAuthRedirect, object: url)
        }
    }
}

@main
struct InboxGlideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var preferences: PreferencesStore
    @StateObject private var networkMonitor: NetworkMonitor
    @StateObject private var mailStore: MailStore
    @StateObject private var gmailAuth: GmailAuthStore
    @StateObject private var reminders: RemindersService
    @StateObject private var notifications: NotificationScheduler
    @StateObject private var ai: AIReplyService
    @StateObject private var summaries: EmailSummaryService
    @StateObject private var keyEvents: KeyEventMonitor

    init() {
        AppLogger.shared.info("InboxGlide app initializing.", category: "AppLifecycle")
        let prefs = PreferencesStore()
        let network = NetworkMonitor()
        let secureStore = SecureStore(appName: "InboxGlide")
        let gmailAuthStore = GmailAuthStore()
        let store = MailStore(
            preferences: prefs,
            networkMonitor: network,
            secureStore: secureStore,
            gmailAuthStore: gmailAuthStore
        )

        _preferences = StateObject(wrappedValue: prefs)
        _networkMonitor = StateObject(wrappedValue: network)
        _mailStore = StateObject(wrappedValue: store)
        _gmailAuth = StateObject(wrappedValue: gmailAuthStore)
        _reminders = StateObject(wrappedValue: RemindersService())
        _notifications = StateObject(wrappedValue: NotificationScheduler())
        _ai = StateObject(wrappedValue: AIReplyService())
        _summaries = StateObject(wrappedValue: EmailSummaryService())
        _keyEvents = StateObject(wrappedValue: KeyEventMonitor())

        AppLogger.shared.info(
            "Core stores/services initialized.",
            category: "AppLifecycle",
            metadata: ["logFile": AppLogger.shared.currentLogFilePath ?? "unavailable"]
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(preferences)
                .environmentObject(networkMonitor)
                .environmentObject(mailStore)
                .environmentObject(gmailAuth)
                .environmentObject(reminders)
                .environmentObject(notifications)
                .environmentObject(ai)
                .environmentObject(summaries)
                .environmentObject(keyEvents)
                .preferredColorScheme(preferences.preferredColorScheme)
        }

        Settings {
            SettingsView()
                .environmentObject(preferences)
                .environmentObject(networkMonitor)
                .environmentObject(mailStore)
                .environmentObject(gmailAuth)
                .environmentObject(reminders)
                .environmentObject(notifications)
                .environmentObject(ai)
                .environmentObject(summaries)
        }
    }
}
