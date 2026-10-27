import Foundation
import UserNotifications

/// Local notifications (HANDOFF.md §13): "Tomorrow's check-in: say 'Hey Siri, start my Setecho
/// check-in' when you're up" the evening before, and "Your check-in is waiting" when a paused
/// Check-in morning has been silent for ten minutes.
enum Reminders {
    static let eveReminderId = "checkin-eve"
    static let waitingId = "checkin-waiting"

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Schedule the reminder for the evening before the next due day. Replaces any earlier one.
    static func scheduleEveReminder(schedule: CheckInSchedule, now: Date = .now) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [eveReminderId])
        let due = schedule.nextDue(from: now)
        guard let at = schedule.reminderTime(before: due), at > now else { return }
        let content = UNMutableNotificationContent()
        content.title = "Tomorrow's check-in"
        content.body = "Say \"Hey Siri, start my Setecho check-in\" when you're up."
        content.sound = .default
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        center.add(UNNotificationRequest(identifier: eveReminderId, content: content, trigger: trigger), withCompletionHandler: nil)
    }

    /// After ten minutes of silence during a pause: one notification, then listening stops.
    static func notifyCheckInWaiting() {
        let content = UNMutableNotificationContent()
        content.title = "Your check-in is waiting"
        content.body = "Say \"I'm back\" or open Setecho."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: waitingId, content: content, trigger: nil), withCompletionHandler: nil)
    }

    static func clearWaiting() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [waitingId])
    }
}
