import SwiftUI

struct NotificationsSettingsView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var notifications: NotificationScheduler

    var body: some View {
        Form {
            Section("Daily Reminder") {
                Toggle("Enable daily reminder", isOn: $preferences.dailyReminderEnabled)
                    .onChange(of: preferences.dailyReminderEnabled) { _, _ in
                        Task { await applySchedule() }
                    }

                HStack {
                    Stepper("Hour: \(preferences.dailyReminderHour)", value: $preferences.dailyReminderHour, in: 0...23)
                        .onChange(of: preferences.dailyReminderHour) { _, _ in
                            Task { await applySchedule() }
                        }
                }
                HStack {
                    Stepper("Minute: \(preferences.dailyReminderMinute)", value: $preferences.dailyReminderMinute, in: 0...59, step: 5)
                        .onChange(of: preferences.dailyReminderMinute) { _, _ in
                            Task { await applySchedule() }
                        }
                }

                Text("Disabled by default. Notifications are opt-in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Notifications")
        .task {
            _ = await notifications.requestAuthorizationIfNeeded()
            await applySchedule()
        }
    }

    private func applySchedule() async {
        let allowed = await notifications.requestAuthorizationIfNeeded()
        guard allowed else { return }
        await notifications.setDailyReminder(
            enabled: preferences.dailyReminderEnabled,
            hour: preferences.dailyReminderHour,
            minute: preferences.dailyReminderMinute
        )
    }
}
