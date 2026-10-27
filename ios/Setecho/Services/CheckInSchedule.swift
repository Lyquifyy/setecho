import Foundation

/// When the check-in is due. Decided Oct 26: Thursday morning, with the wrap-up reminder the
/// evening before (HANDOFF.md §13).
struct CheckInSchedule: Equatable {
    /// Calendar weekday, 1 = Sunday … 7 = Saturday. Thursday is 5.
    var dueWeekday = 5

    /// The next due day on or after `date`, at the start of that day.
    func nextDue(from date: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: today)
        let ahead = (dueWeekday - weekday + 7) % 7
        return calendar.date(byAdding: .day, value: ahead, to: today) ?? today
    }

    /// The week a check-in due on `due` covers: the seven days ending the day before.
    func week(endingBefore due: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let end = calendar.startOfDay(for: due)
        let start = calendar.date(byAdding: .day, value: -7, to: end) ?? end
        return (start, end)
    }

    /// The wrap-up is due from the evening before the due day until the due day itself.
    func isWrapUpDue(on date: Date, calendar: Calendar = .current) -> Bool {
        let due = nextDue(from: date, calendar: calendar)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: due).day ?? 99
        return days == 0 || (days == 1 && calendar.component(.hour, from: date) >= 19)
    }
}
