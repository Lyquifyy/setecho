import Foundation
import Testing
@testable import Setecho

private let targets = MacroTargets(
    training: Macros(kcal: 2400, proteinG: 200, carbsG: 250, fatG: 65),
    rest: Macros(kcal: 2100, proteinG: 200, carbsG: 175, fatG: 65)
)

private func day(
    _ date: String, training: Bool, kcal: Double? = nil, p: Double? = nil, c: Double? = nil, f: Double? = nil,
    steps: Double? = nil, sleep: Double? = nil, weight: Double? = nil, liss: [LissSession] = []
) -> DayFacts {
    DayFacts(date: date, isTrainingDay: training, kcal: kcal, proteinG: p, carbsG: c, fatG: f,
             steps: steps, sleepHours: sleep, weighInLb: weight, liss: liss)
}

private func week(_ days: [DayFacts]) -> WeekFacts {
    WeekFacts(weekStart: "2026-10-23", weekEnd: "2026-10-29", daily: days, targets: targets,
              showDate: nil, lastCheckInWeightLb: nil, sources: [:])
}

@Test func onPlanUsesTheDayTypesTargetAndTolerances() {
    // Training day: within 5% kcal and 10 g of each macro.
    #expect(Adherence.isOnPlan(day("d", training: true, kcal: 2500, p: 209, c: 241, f: 74), targets: targets) == true)
    // 2521 is more than 5% over 2400.
    #expect(Adherence.isOnPlan(day("d", training: true, kcal: 2521, p: 200, c: 250, f: 65), targets: targets) == false)
    // Protein 11 g off.
    #expect(Adherence.isOnPlan(day("d", training: true, kcal: 2400, p: 189, c: 250, f: 65), targets: targets) == false)
    // Same intake judged against the rest-day target fails on carbs.
    #expect(Adherence.isOnPlan(day("d", training: false, kcal: 2100, p: 200, c: 250, f: 65), targets: targets) == false)
    #expect(Adherence.isOnPlan(day("d", training: false, kcal: 2100, p: 200, c: 180, f: 60), targets: targets) == true)
    // Nothing logged is neither.
    #expect(Adherence.isOnPlan(day("d", training: true), targets: targets) == nil)
}

@Test func daysOnPlanCountsOnlyLoggedDays() {
    let facts = week([
        day("2026-10-23", training: true, kcal: 2400, p: 200, c: 250, f: 65),
        day("2026-10-24", training: false, kcal: 2100, p: 200, c: 175, f: 65),
        day("2026-10-25", training: false, kcal: 2600, p: 200, c: 175, f: 65),
        day("2026-10-26", training: true),
    ])
    let result = Adherence.daysOnPlan(facts)
    #expect(result.onPlan == 2 && result.logged == 3)
}

/// Oct 30, 4:18 PM: "0 of 2 days on macros" judged the afternoon's half-logged food against the day's
/// targets. Only a completed day counts, in the count and in the denominator; today joins once it is over.
@Test func todaysFoodWaitsUntilTheDayIsOver() {
    let cal = Calendar(identifier: .gregorian)
    let thursday = cal.date(from: DateComponents(year: 2026, month: 10, day: 29))!
    let friday = cal.date(from: DateComponents(year: 2026, month: 10, day: 30))!
    let week = HealthService.Week(
        days: [
            HealthService.DayReading(date: thursday, kcal: 2400, proteinG: 200, carbsG: 250, fatG: 65, steps: 9800, sleepHours: 7.5, weighInLb: 181.2),
            HealthService.DayReading(date: friday, kcal: 1240, proteinG: 110, carbsG: 120, fatG: 30, steps: 5890, sleepHours: 7.2, weighInLb: 180.8),
        ],
        sources: [:]
    )
    func build(now: Date) -> WeekFacts {
        WeekFacts.build(week: week, weekStart: thursday, weekEnd: friday, targets: targets, sessions: [],
                        scheduledWeekdays: [5], showDate: nil, lastCheckInWeightLb: nil, now: now, calendar: cal)
    }
    // Friday at 4:18 PM: Friday's food is half logged, so it is neither on nor off plan.
    let afternoon = build(now: cal.date(bySettingHour: 16, minute: 18, second: 0, of: friday)!)
    #expect(afternoon.daily[1].kcal == nil && afternoon.daily[1].proteinG == nil && afternoon.daily[1].carbsG == nil && afternoon.daily[1].fatG == nil)
    #expect(Adherence.isOnPlan(afternoon.daily[1], targets: targets) == nil)
    #expect(Adherence.daysOnPlan(afternoon) == (onPlan: 1, logged: 1))
    // The rest of Friday still counts: the weigh-in, last night's sleep and the steps so far.
    #expect(afternoon.daily[1].weighInLb == 180.8 && afternoon.daily[1].sleepHours == 7.2 && afternoon.daily[1].steps == 5890)
    #expect(afternoon.daily[0].kcal == 2400 && Adherence.isOnPlan(afternoon.daily[0], targets: targets) == true)
    // Saturday morning (check-in morning, say): Friday is over and is judged as logged.
    let nextMorning = build(now: cal.date(byAdding: .hour, value: 7, to: cal.date(byAdding: .day, value: 1, to: friday)!)!)
    #expect(nextMorning.daily[1].kcal == 1240 && Adherence.isOnPlan(nextMorning.daily[1], targets: targets) == false)
    #expect(Adherence.daysOnPlan(nextMorning) == (onPlan: 1, logged: 2))
}

@Test func stepsAverageRoundsToHundreds() {
    let facts = week([
        day("a", training: true, steps: 10412), day("b", training: false, steps: 9950), day("c", training: true),
    ])
    #expect(Adherence.averageSteps(facts) == 10200)
    #expect(Adherence.averageSteps(week([day("a", training: true)])) == nil)
}

@Test func sleepAverageToOneDecimal() {
    let facts = week([day("a", training: true, sleep: 7.25), day("b", training: true, sleep: 7.6)])
    #expect(Adherence.averageSleepHours(facts) == 7.4)
}

@Test func lastRefeedIsTheLatestDayWellOverTarget() {
    let facts = week([
        day("2026-10-23", training: true, kcal: 2900),   // 20.8% over 2400
        day("2026-10-24", training: false, kcal: 2500),  // 19% over 2100: not a refeed
        day("2026-10-25", training: false, kcal: 2600),  // 23.8% over
        day("2026-10-26", training: true, kcal: 2400),
    ])
    #expect(Adherence.lastRefeedDate(facts) == "2026-10-25")
    #expect(Adherence.lastRefeedDate(week([day("a", training: true, kcal: 2400)])) == nil)
}

@Test func currentWeightIsTheLastWeighInOrTheAverage() {
    let facts = week([
        day("a", training: true, weight: 181.6), day("b", training: true), day("c", training: true, weight: 181.2),
    ])
    #expect(Adherence.currentWeight(facts) == 181.2)
    #expect(Adherence.currentWeight(facts, sevenDayAverage: true) == 181.4)
}

@Test func lissTotals() {
    let facts = week([
        day("a", training: true, liss: [LissSession(type: "walking", minutes: 25)]),
        day("b", training: false, liss: [LissSession(type: "walking", minutes: 26)]),
    ])
    let liss = Adherence.liss(facts)
    #expect(liss.sessions == 2 && liss.minutes == 51)
}

@Test func weeksToShow() {
    let cal = Calendar(identifier: .gregorian)
    let today = cal.date(from: DateComponents(year: 2026, month: 10, day: 27))!
    #expect(Adherence.weeksToShow(showDate: "2027-01-23", today: today, calendar: cal) == 12)
    #expect(Adherence.weeksToShow(showDate: "2026-10-30", today: today, calendar: cal) == 0)
    #expect(Adherence.weeksToShow(showDate: nil, today: today, calendar: cal) == nil)
}

@Test func trainingDayFromSessionOrSchedule() {
    let cal = Calendar(identifier: .gregorian)
    let monday = cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 9))!
    let tuesday = cal.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 9))!
    let session = Session(id: UUID(), programDayId: "w1_upper_a", startedAt: tuesday, endedAt: tuesday,
                          sets: [], notes: [])
    // Monday = weekday 2 is scheduled; Tuesday has a session.
    #expect(Adherence.isTrainingDay(monday, sessions: [], scheduledWeekdays: [2], calendar: cal))
    #expect(Adherence.isTrainingDay(tuesday, sessions: [session], scheduledWeekdays: [2], calendar: cal))
    #expect(!Adherence.isTrainingDay(tuesday, sessions: [], scheduledWeekdays: [2], calendar: cal))
}

@Test func personalRecordsNeedHistory() {
    let now = Date()
    func set(_ ex: String, _ load: Double, _ reps: Int) -> LoggedSet {
        LoggedSet(id: UUID(), exerciseId: ex, setIndex: 0, loadLb: load, reps: reps, rpe: nil,
                  startedAt: now, endedAt: now, clipFile: nil, edits: [])
    }
    func session(_ sets: [LoggedSet]) -> Session {
        Session(id: UUID(), programDayId: "d", startedAt: now, endedAt: now, sets: sets, notes: [])
    }
    let earlier = [session([set("bench", 185, 8), set("bench", 185, 8), set("row", 165, 10)])]
    let thisWeek = [session([set("bench", 190, 8), set("bench", 185, 9), set("row", 165, 10), set("ohp", 95, 10)])]
    let prs = Adherence.personalRecords(thisWeek: thisWeek, earlier: earlier)
    #expect(prs.map { ($0.exerciseId, $0.loadLb, $0.reps) }.map { "\($0.0) \($0.1) \($0.2)" } == ["bench 190.0 8", "bench 185.0 9"])
    #expect(Adherence.personalRecords(thisWeek: thisWeek, earlier: []).isEmpty)
}
