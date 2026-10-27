import Foundation
import Testing
@testable import Setecho

private let cal = Calendar(identifier: .gregorian)

private func date(_ day: Int, hour: Int = 9) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
}

@Test func nextDueIsThursdayOnOrAfterToday() {
    let schedule = CheckInSchedule()
    // Oct 26 2026 is a Monday; Oct 29 a Thursday.
    #expect(schedule.nextDue(from: date(26), calendar: cal) == date(29, hour: 0))
    #expect(schedule.nextDue(from: date(29), calendar: cal) == date(29, hour: 0))
    #expect(schedule.nextDue(from: date(30), calendar: cal) == cal.date(from: DateComponents(year: 2026, month: 11, day: 5))!)
}

@Test func weekCoveredEndsTheDayBeforeDue() {
    let week = CheckInSchedule().week(endingBefore: date(29, hour: 0), calendar: cal)
    #expect(week.start == date(22, hour: 0) && week.end == date(29, hour: 0))
}

@Test func wrapUpIsDueFromWednesdayEvening() {
    let schedule = CheckInSchedule()
    #expect(!schedule.isWrapUpDue(on: date(27), calendar: cal))           // Tuesday
    #expect(!schedule.isWrapUpDue(on: date(28, hour: 12), calendar: cal)) // Wednesday noon
    #expect(schedule.isWrapUpDue(on: date(28, hour: 19), calendar: cal))  // Wednesday 7 PM
    #expect(schedule.isWrapUpDue(on: date(29, hour: 8), calendar: cal))   // Thursday morning
}
