import Foundation

/// When the check-in is due (HANDOFF.md §7, Check-in, Cadence): his email's cadence once confirmed
/// (every other week, Thursday, by 9:00 AM), else the Oct 26 default of every Thursday morning.
/// The check-in covers the period since the last sent check-in, so on a two-week cadence the
/// facts hold 14 days and every average spans them.
struct CheckInSchedule: Equatable {
    /// Calendar weekday, 1 = Sunday … 7 = Saturday. Thursday is 5.
    var dueWeekday = 5
    var everyWeeks = 1
    /// "09:00"
    var dueBy = "09:00"
    /// When the last check-in went out; the next one is at least a full cadence after it.
    var lastSentAt: Date?

    init(dueWeekday: Int = 5, everyWeeks: Int = 1, dueBy: String = "09:00", lastSentAt: Date? = nil) {
        self.dueWeekday = dueWeekday
        self.everyWeeks = max(1, everyWeeks)
        self.dueBy = dueBy
        self.lastSentAt = lastSentAt
    }

    /// From the plan: his confirmed due day and deadline. Check-ins are weekly (decided Oct 27):
    /// an "every other week" in his email is not applied.
    init(plan: PlanState?, lastSentAt: Date? = nil) {
        if let cadence = plan?.checkInSchedule, cadence.confirmed {
            self.init(dueWeekday: cadence.weekday, everyWeeks: 1, dueBy: cadence.dueBy, lastSentAt: lastSentAt)
        } else {
            self.init(lastSentAt: lastSentAt)
        }
    }

    /// The next due day on or after `date`, at the start of that day. On a two-week cadence the
    /// due day is the first weekday at least a full cadence after the last check-in went out.
    func nextDue(from date: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: today)
        let ahead = (dueWeekday - weekday + 7) % 7
        var due = calendar.date(byAdding: .day, value: ahead, to: today) ?? today
        if everyWeeks > 1, let last = lastSentAt {
            let earliest = calendar.date(byAdding: .day, value: 7 * everyWeeks - 3, to: calendar.startOfDay(for: last)) ?? due
            while due < earliest, let later = calendar.date(byAdding: .day, value: 7, to: due) { due = later }
        }
        return due
    }

    /// The period a check-in due on `due` covers: since the last sent check-in, else a full cadence,
    /// ending the day before.
    func week(endingBefore due: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let end = calendar.startOfDay(for: due)
        let cadence = calendar.date(byAdding: .day, value: -7 * everyWeeks, to: end) ?? end
        if let last = lastSentAt {
            let since = calendar.startOfDay(for: last)
            let floor = calendar.date(byAdding: .day, value: -28, to: end) ?? cadence
            if since < end { return (max(since, floor), end) }
        }
        return (cadence, end)
    }

    /// Check-in morning: the due day itself, before the deadline has long passed.
    func isCheckInMorning(on date: Date, calendar: Calendar = .current) -> Bool {
        let due = nextDue(from: date, calendar: calendar)
        return calendar.isDate(date, inSameDayAs: due)
    }

    /// The deadline on the due day ("09:00" → 9 AM that day).
    func deadline(on due: Date, calendar: Calendar = .current) -> Date {
        let parts = dueBy.split(separator: ":").compactMap { Int($0) }
        let hour = parts.first ?? 9
        let minute = parts.count > 1 ? parts[1] : 0
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: calendar.startOfDay(for: due)) ?? due
    }

    /// The wrap-up is due from the evening before the due day until the due day itself.
    func isWrapUpDue(on date: Date, calendar: Calendar = .current) -> Bool {
        let due = nextDue(from: date, calendar: calendar)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: due).day ?? 99
        return days == 0 || (days == 1 && calendar.component(.hour, from: date) >= 19)
    }

    /// The reminder the evening before: 7 PM.
    func reminderTime(before due: Date, calendar: Calendar = .current) -> Date? {
        guard let eve = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: due)) else { return nil }
        return calendar.date(bySettingHour: 19, minute: 0, second: 0, of: eve)
    }
}
