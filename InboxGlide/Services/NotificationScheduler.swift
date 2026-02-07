import Foundation
import UserNotifications

final class NotificationScheduler: ObservableObject {
    func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                return false
            }
        @unknown default:
            return false
        }
    }

    func setDailyReminder(enabled: Bool, hour: Int, minute: Int) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["daily-reminder"])
        guard enabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "InboxGlide"
        content.body = "Ready to glide through your inbox?"
        content.sound = .default

        var components = DateComponents()
        components.hour = hour
        components.minute = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let req = UNNotificationRequest(identifier: "daily-reminder", content: content, trigger: trigger)
        do {
            try await center.add(req)
        } catch {
            // Ignore.
        }
    }
}
