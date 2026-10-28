import Foundation
import Testing
@testable import Setecho

/// The cycle cursor and add-on days (HANDOFF.md §7): a simulated week shows the right day each
/// morning, a missed day waits, rest days pass with the calendar, abs join the chosen days, and
/// the vacuums catch up when the week runs out.
private let cal = Calendar(identifier: .gregorian)

private func date(_ day: Int, hour: Int = 9) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
}

private func lift(_ id: String) -> PlannedExercise {
    PlannedExercise(id: id, name: id, sets: [PlannedSet(reps: 8, repsMin: nil, repsMax: nil, loadLb: nil, rpe: nil, rir: nil)], restSeconds: nil, notes: nil)
}

private let cycle = Program(
    name: "Cycle",
    weeks: [ProgramWeek(number: 1, days: [
        ProgramDay(id: "d1", name: "Day 1", exercises: [lift("a")]),
        ProgramDay(id: "d2", name: "Day 2", exercises: [lift("b")]),
        ProgramDay(id: "d3", name: "Day 3", exercises: [lift("c")]),
        ProgramDay(id: "r1", name: "Rest", exercises: [], kind: .rest, cardio: "25 minutes of fasted LISS"),
        ProgramDay(id: "d5", name: "Day 5", exercises: [lift("d")]),
        ProgramDay(id: "d6", name: "Day 6", exercises: [lift("e")]),
        ProgramDay(id: "r2", name: "Rest 2", exercises: [], kind: .rest, cardio: "25 minutes of fasted LISS"),
    ])],
    addOns: [
        AddOn(id: "vac", name: "Stomach vacuums", exercises: [lift("v")], perWeek: 4, timing: .onWaking, quote: "Complete these 4x per week upon waking:"),
        AddOn(id: "abs", name: "Abs", exercises: [lift("x")], perWeek: 2, timing: .withSession, quote: "Complete this 2x per week:"),
    ],
    importedAt: date(26), flags: []
)

private func session(_ dayId: String?, on day: Int, addOns: [String] = [], empty: Bool = false) -> Session {
    let start = date(day, hour: 17)
    let set = LoggedSet(id: UUID(), exerciseId: "a", setIndex: 0, loadLb: 100, reps: 8, rpe: nil, startedAt: start, endedAt: start.addingTimeInterval(30), clipFile: nil, edits: [])
    return Session(id: UUID(), programDayId: dayId, startedAt: start, endedAt: start.addingTimeInterval(3600), sets: empty ? [] : [set], notes: [], addOnIds: addOns)
}

@Test func seedIsTheFirstDayWithoutSessionsAndTheDayAfterTheLastOneWithThem() {
    #expect(Cycle.seed(program: cycle, sessions: [], today: date(26), calendar: cal) == CycleCursor(dayId: "d1", since: date(26, hour: 0)))
    let seeded = Cycle.seed(program: cycle, sessions: [session("d1", on: 24), session("d2", on: 25)], today: date(26), calendar: cal)
    #expect(seeded == CycleCursor(dayId: "d3", since: date(25, hour: 0)))
    // A session with nothing logged does not count; the last day wraps to the first.
    #expect(Cycle.seed(program: cycle, sessions: [session("r2", on: 24, empty: true), session("d6", on: 23)], today: date(26), calendar: cal)?.dayId == "r2")
    #expect(Cycle.next(after: "r2", in: cycle)?.id == "d1")
}

@Test func aSimulatedWeekShowsTheRightDayEachMorning() {
    // Mon Oct 26: Day 1. Done that evening → Tue shows Day 2.
    var cursor = CycleCursor(dayId: "d1", since: date(26, hour: 0))
    var sessions = [session("d1", on: 26)]
    #expect(Cycle.advanced(cursor, program: cycle, sessions: sessions, today: date(26, hour: 20), calendar: cal) == cursor) // same day: no move
    cursor = Cycle.advanced(cursor, program: cycle, sessions: sessions, today: date(27), calendar: cal)
    #expect(cursor == CycleCursor(dayId: "d2", since: date(27, hour: 0)))
    // Tue missed: Wed still shows Day 2.
    cursor = Cycle.advanced(cursor, program: cycle, sessions: sessions, today: date(28), calendar: cal)
    #expect(cursor.dayId == "d2" && cursor.since == date(27, hour: 0))
    // Wed Day 2 done, Thu Day 3 done → Fri shows Rest; Sat shows Day 5 (the rest day passed with the calendar).
    sessions += [session("d2", on: 28), session("d3", on: 29)]
    cursor = Cycle.advanced(cursor, program: cycle, sessions: sessions, today: date(29), calendar: cal)
    #expect(cursor.dayId == "d3")
    cursor = Cycle.advanced(cursor, program: cycle, sessions: sessions, today: date(30), calendar: cal)
    #expect(cursor == CycleCursor(dayId: "r1", since: date(30, hour: 0)))
    cursor = Cycle.advanced(cursor, program: cycle, sessions: sessions, today: date(31), calendar: cal)
    #expect(cursor == CycleCursor(dayId: "d5", since: date(31, hour: 0)))
    // Not opened for three days over a rest day: the rest day passed, Day 5 waits.
    let later = Cycle.advanced(CycleCursor(dayId: "r1", since: date(30, hour: 0)), program: cycle, sessions: sessions, today: cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9))!, calendar: cal)
    #expect(later.dayId == "d5" && later.since == date(31, hour: 0))
}

@Test func twoRestDaysInARowPassOneCalendarDayEach() {
    let twoRests = Program(name: "R", weeks: [ProgramWeek(number: 1, days: [
        ProgramDay(id: "d1", name: "Day 1", exercises: [lift("a")]),
        ProgramDay(id: "r1", name: "Rest", exercises: [], kind: .rest),
        ProgramDay(id: "r2", name: "Rest 2", exercises: [], kind: .rest),
    ])], importedAt: date(26), flags: [])
    let cursor = CycleCursor(dayId: "r1", since: date(26, hour: 0))
    #expect(Cycle.advanced(cursor, program: twoRests, sessions: [], today: date(27), calendar: cal).dayId == "r2")
    #expect(Cycle.advanced(cursor, program: twoRests, sessions: [], today: date(28), calendar: cal) == CycleCursor(dayId: "d1", since: date(28, hour: 0)))
    #expect(Cycle.advanced(cursor, program: twoRests, sessions: [], today: date(29), calendar: cal).dayId == "d1") // Day 1 waits
}

@Test func changeDayMovesTheCursorByHandAndADoneDayNeedsASessionSinceTheCursorArrived() {
    #expect(Cycle.changed(to: "d5", today: date(27), calendar: cal) == CycleCursor(dayId: "d5", since: date(27, hour: 0), manual: true))
    // An old Day 5 session from last cycle does not make this Day 5 done.
    #expect(!Cycle.isDone(dayId: "d5", since: date(27), sessions: [session("d5", on: 20)], calendar: cal))
    #expect(Cycle.isDone(dayId: "d5", since: date(27), sessions: [session("d5", on: 27)], calendar: cal))
    #expect(!Cycle.isDone(dayId: "d5", since: date(27), sessions: [session("d5", on: 27, empty: true)], calendar: cal))
}

@Test func addOnDaysAreProposedEvenlyAndConfirmedOnce() {
    #expect(AddOnPlanner.proposedDays(for: cycle.addOns[1], in: cycle) == ["d2", "d5"])        // abs: 2× over 5 training days
    #expect(AddOnPlanner.proposedDays(for: cycle.addOns[0], in: cycle) == ["d1", "d3", "d5", "r2"]) // vacuums: 4× over the whole cycle
}

@Test func absJoinTheChosenDaysAndCatchUpWhenTheWeekRunsOut() {
    let abs = cycle.addOns[1]
    let week = (start: date(23, hour: 0), end: date(30, hour: 0)) // the check-in week ending before Thu Oct 30... (synthetic)
    // Mon Oct 26 is Day 2 (chosen): due, not catch-up.
    #expect(AddOnPlanner.due(abs, dayId: "d2", chosenDays: ["d2", "d5"], sessions: [], today: date(26), week: week, calendar: cal)
            == AddOnPlanner.Due(addOn: abs, done: 0, catchUp: false))
    // Tue Oct 27 is Day 3 (not chosen), 3 days left, 2 still owed: not due.
    #expect(AddOnPlanner.due(abs, dayId: "d3", chosenDays: ["d2", "d5"], sessions: [], today: date(27), week: week, calendar: cal) == nil)
    // Wed Oct 28, nothing done yet, 2 days left for 2 owed: still fine. Thu Oct 29, 1 day left for 2 owed: catch-up.
    #expect(AddOnPlanner.due(abs, dayId: "d3", chosenDays: ["d2", "d5"], sessions: [], today: date(28), week: week, calendar: cal) == nil)
    let catchUp = AddOnPlanner.due(abs, dayId: "d3", chosenDays: ["d2", "d5"], sessions: [], today: date(29), week: week, calendar: cal)
    #expect(catchUp == AddOnPlanner.Due(addOn: abs, done: 0, catchUp: true))
    // Done twice this week: never due again, even on a chosen day.
    let done = [session("d2", on: 26, addOns: ["abs"]), session("d3", on: 27, addOns: ["abs"])]
    #expect(AddOnPlanner.due(abs, dayId: "d5", chosenDays: ["d2", "d5"], sessions: done, today: date(28), week: week, calendar: cal) == nil)
    // Done once today already: not again today.
    #expect(AddOnPlanner.due(abs, dayId: "d2", chosenDays: ["d2", "d5"], sessions: [session("d2", on: 26, addOns: ["abs"])], today: date(26, hour: 20), week: week, calendar: cal) == nil)
    #expect(AddOnPlanner.doneCount(addOnId: "abs", sessions: done, from: week.start, to: week.end) == 2)
}

@Test func morningVacuumsCountTheirOwnSessions() {
    let vac = cycle.addOns[0]
    let week = (start: date(23, hour: 0), end: date(30, hour: 0))
    let morning = Session(id: UUID(), programDayId: nil, startedAt: date(26, hour: 7), endedAt: date(26, hour: 7).addingTimeInterval(200),
                          sets: [LoggedSet(id: UUID(), exerciseId: "v", setIndex: 0, loadLb: 0, reps: 0, rpe: nil, seconds: 20, startedAt: date(26, hour: 7), endedAt: date(26, hour: 7), clipFile: nil, edits: [])],
                          notes: [], addOnIds: ["vac"])
    #expect(AddOnPlanner.due(vac, dayId: "d1", chosenDays: ["d1", "d3", "d5", "r2"], sessions: [morning], today: date(26, hour: 8), week: week, calendar: cal) == nil)
    #expect(AddOnPlanner.due(vac, dayId: "d3", chosenDays: ["d1", "d3", "d5", "r2"], sessions: [morning], today: date(27), week: week, calendar: cal)?.done == 1)
}

@Test @MainActor func storeSeedsAndAdvancesTheCursorAndChangesDay() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cycle-\(UUID().uuidString)")
    let store = Store(root: root)
    // A five-day cycle keeps the split rules: the first day, then on once it is done.
    let five = Program(name: "5", weeks: [ProgramWeek(number: 1, days: Array(cycle.cycleDays.prefix(5)))], importedAt: date(26), flags: [])
    store.saveProgram(five)
    #expect(store.plan?.cycle?.dayId == "d1" && store.todayDay?.day.id == "d1")
    store.changeDay(to: "d5", now: date(26))
    #expect(store.todayDay?.day.name == "Day 5")
    store.upsert(session: session("d5", on: 26))
    store.refreshCycle(now: date(27))
    #expect(store.todayDay?.day.name == "Day 1")   // wraps after the last day
    #expect(store.plan?.version == 1) // bookkeeping never makes a new plan version
    // The seven-day cycle follows the weekday from the moment it is saved.
    store.saveProgram(cycle)
    let expected = Cycle.weekdayCursor(program: cycle, today: .now, firstWeekday: Settings.shared.cycleFirstWeekday)?.dayId
    #expect(store.plan?.cycle?.dayId == expected)
    let reopened = Store(root: root)
    #expect(reopened.todayDay?.day.id == expected)
}

@Test @MainActor func storeSavesHisRulesAsANewVersionAndConfirmsInPlace() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rules-\(UUID().uuidString)")
    let store = Store(root: root)
    store.saveProgram(cycle)
    let rule = ProgressionRule(id: "rule_1", appliesTo: nil, when: .afterTopSet, byRPE: nil, adjust: .backOff, amount: nil, minPct: 20, maxPct: 25,
                               scope: .nextSet, source: "Coach's instructions", quote: "Back down sets are 20-25% lighter than your top set.", confirmed: false)
    let imported = RulesImport(rules: [rule], roleTargets: [RoleTarget(role: .top, rir: 0, source: "Coach's instructions", quote: "to failure", confirmed: false)],
                               restRules: [RestRule(after: .top, minSeconds: 180, maxSeconds: 240, quote: "3-4 minutes", confirmed: false)],
                               warmups: WarmupRule(minSets: 1, maxSets: 3, maxReps: 8, quote: "1-3 warm up sets", confirmed: false),
                               checkInSchedule: CheckInCadence(everyWeeks: 2, weekday: 5, dueBy: "09:00", timeZone: "America/Chicago", quote: "every other week", confirmed: false),
                               quietDays: [1], flags: [])
    store.saveRules(imported)
    #expect(store.plan?.version == 2 && store.plan?.rules.count == 1 && store.plan?.quietDays == [1])
    #expect(store.plan?.rules[0].confirmed == false)
    store.mutatePlan { $0.rules[0].confirmed = true; $0.warmups?.confirmed = true }
    #expect(store.plan?.version == 2 && store.plan?.rules[0].confirmed == true && store.plan?.warmups?.confirmed == true)
    store.saveRules(imported) // pasted again: his instructions replace the earlier ones
    #expect(store.plan?.version == 3 && store.plan?.rules.count == 1 && store.plan?.rules[0].confirmed == false)
    let reopened = Store(root: root)
    #expect(reopened.plan?.checkInSchedule?.weekday == 5 && reopened.plan?.cycle?.dayId == Cycle.weekdayCursor(program: cycle, today: .now, firstWeekday: Settings.shared.cycleFirstWeekday)?.dayId)
}


@Test func aSevenDayCycleFollowsTheDayOfTheWeek() {
    // Mon Oct 26 2026 → Day 1; Tue → Day 2 (legs, not chest); Thu → Rest; Sun → Rest 2.
    #expect(Cycle.followsWeekday(cycle))
    #expect(Cycle.weekdayCursor(program: cycle, today: date(26), calendar: cal)?.dayId == "d1")
    #expect(Cycle.weekdayCursor(program: cycle, today: date(27), calendar: cal)?.dayId == "d2")
    #expect(Cycle.weekdayCursor(program: cycle, today: date(29), calendar: cal)?.dayId == "r1")
    #expect(Cycle.weekdayCursor(program: cycle, today: cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9))!, calendar: cal)?.dayId == "r2")
    // Day 1 on Sunday instead: Tue is Day 3.
    #expect(Cycle.weekdayCursor(program: cycle, today: date(27), firstWeekday: 1, calendar: cal)?.dayId == "d3")
    // A missed day never carries over: Tuesday is Day 2 whatever happened Monday.
    let stale = CycleCursor(dayId: "d1", since: date(26, hour: 0))
    #expect(Cycle.current(stale, program: cycle, sessions: [], today: date(27), calendar: cal)?.dayId == "d2")
    // "Change day" holds for that calendar day only.
    let changed = Cycle.changed(to: "d5", today: date(27), calendar: cal)
    #expect(changed.manual && Cycle.current(changed, program: cycle, sessions: [], today: date(27, hour: 20), calendar: cal)?.dayId == "d5")
    #expect(Cycle.current(changed, program: cycle, sessions: [], today: date(28), calendar: cal)?.dayId == "d3")
    // A cycle that is not seven days keeps the split rules.
    let five = Program(name: "5", weeks: [ProgramWeek(number: 1, days: Array(cycle.cycleDays.prefix(5)))], importedAt: date(26), flags: [])
    #expect(!Cycle.followsWeekday(five) && Cycle.weekdayCursor(program: five, today: date(27), calendar: cal) == nil)
    #expect(Cycle.current(nil, program: five, sessions: [], today: date(27), calendar: cal)?.dayId == "d1")
}
