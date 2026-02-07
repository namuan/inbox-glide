import EventKit
import Foundation

final class RemindersService: ObservableObject {
    private let store = EKEventStore()

    func createReminder(title: String, notes: String?) async throws {
        let granted = try await store.requestFullAccessToReminders()
        guard granted else {
            throw NSError(domain: "InboxGlide.Reminders", code: 1, userInfo: [NSLocalizedDescriptionKey: "Reminders access not granted."])
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = store.defaultCalendarForNewReminders()

        try store.save(reminder, commit: true)
    }
}
