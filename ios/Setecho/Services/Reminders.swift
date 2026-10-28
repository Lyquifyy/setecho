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

    static let deadlineId = "checkin-deadline"
    /// Not sent by 8:40 AM Central on the due day: one notification, and Review and send opens.
    static let deadlineGuard = (hour: 8, minute: 40)

    static func scheduleDeadlineGuard(schedule: CheckInSchedule, now: Date = .now) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [deadlineId])
        let due = schedule.nextDue(from: now)
        guard let at = Calendar.current.date(bySettingHour: deadlineGuard.hour, minute: deadlineGuard.minute, second: 0, of: due), at > now else { return }
        let content = UNMutableNotificationContent()
        content.title = "Check-in due at \(schedule.dueBy)"
        content.body = "Open Setecho to send what's ready. Anything missing can be typed."
        content.sound = .default
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
        center.add(UNNotificationRequest(identifier: deadlineId, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)), withCompletionHandler: nil)
    }

    /// True on the due day once the guard time has passed.
    static func deadlinePassed(schedule: CheckInSchedule, now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard schedule.isCheckInMorning(on: now, calendar: calendar) else { return false }
        let guardTime = calendar.date(bySettingHour: deadlineGuard.hour, minute: deadlineGuard.minute, second: 0, of: now) ?? now
        return now >= guardTime
    }

    static let morningId = "checkin-morning"

    /// The wake-time notification on the due day ("06:30" → 6:30 AM): opening the app from it
    /// starts Check-in morning with no tap (MorningStart). Replaces any earlier one.
    static func scheduleMorningStart(schedule: CheckInSchedule, wakeTime: String, now: Date = .now, calendar: Calendar = .current) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [morningId])
        let parts = wakeTime.split(separator: ":").compactMap { Int($0) }
        guard let hour = parts.first, (0...23).contains(hour) else { return }
        let minute = parts.count > 1 ? min(max(parts[1], 0), 59) : 0
        let due = schedule.nextDue(from: now, calendar: calendar)
        guard let at = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: due), at > now else { return }
        let content = UNMutableNotificationContent()
        content.title = "Your \(due.formatted(.dateTime.weekday(.wide))) check-in"
        content.body = "Open Setecho and it starts. Or say \"Hey Siri, start my Setecho check-in\"."
        content.sound = .default
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: at)
        center.add(UNNotificationRequest(identifier: morningId, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)),
                   withCompletionHandler: nil)
    }

    static func clearWaiting() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [waitingId])
    }
}

extension Notification.Name {
    /// Posted when the app comes to the foreground past the deadline guard with the check-in unsent.
    static let checkInDeadline = Notification.Name("setecho.checkInDeadline")
}

/// Check-in morning starts itself (Oct 27 rehearsal): the first time the app is in front on the
/// due morning, before the deadline guard, with nothing sent that day, the flow opens with no tap.
/// Once per day, so closing it does not bring it straight back.
enum MorningStart {
    static func shouldStart(schedule: CheckInSchedule, lastSentAt: Date?, lastStartedDay: String,
                            now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard schedule.isCheckInMorning(on: now, calendar: calendar) else { return false }
        guard !Reminders.deadlinePassed(schedule: schedule, now: now, calendar: calendar) else { return false }
        if let lastSentAt, calendar.isDate(lastSentAt, inSameDayAs: now) { return false }
        return lastStartedDay != DayKey.string(now, calendar: calendar)
    }
}
