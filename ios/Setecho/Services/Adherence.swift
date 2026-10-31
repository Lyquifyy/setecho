import Foundation

/// The deterministic check-in numbers (HANDOFF.md §7). Pure functions over WeekFacts and the log,
/// so they are unit-tested with synthetic samples. The model never produces any of these.
enum Adherence {
    struct MacroTolerance: Equatable {
        /// kcal within ±5% of the day type's target.
        var kcalFraction = 0.05
        /// Protein, carbs and fat each within ±10 g.
        var grams = 10.0
    }

    /// True when kcal, protein, carbs and fat are all within tolerance of the day type's target.
    /// Nil when the day has no nutrition logged, so it is neither on nor off plan.
    static func isOnPlan(_ day: DayFacts, targets: MacroTargets, tolerance: MacroTolerance = .init()) -> Bool? {
        guard let kcal = day.kcal, let protein = day.proteinG, let carbs = day.carbsG, let fat = day.fatG else {
            return nil
        }
        let target = targets.forDay(training: day.isTrainingDay)
        return abs(kcal - target.kcal) <= target.kcal * tolerance.kcalFraction
            && abs(protein - target.proteinG) <= tolerance.grams
            && abs(carbs - target.carbsG) <= tolerance.grams
            && abs(fat - target.fatG) <= tolerance.grams
    }

    /// "7 of 7 days": days on plan over days with nutrition logged. The day in progress arrives with no
    /// nutrition (`WeekFacts.build`), so it is in neither count until it is over.
    static func daysOnPlan(_ facts: WeekFacts, tolerance: MacroTolerance = .init()) -> (onPlan: Int, logged: Int) {
        let verdicts = facts.daily.compactMap { isOnPlan($0, targets: facts.targets, tolerance: tolerance) }
        return (verdicts.filter { $0 }.count, verdicts.count)
    }

    /// The 7-day mean of logged days, rounded to the nearest 100. Nil with no steps at all.
    static func averageSteps(_ facts: WeekFacts) -> Int? {
        let values = facts.daily.compactMap(\.steps)
        guard !values.isEmpty else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        return Int((mean / 100).rounded() * 100)
    }

    /// Mean hours asleep over nights with sleep data, to one decimal. Nil with none.
    static func averageSleepHours(_ facts: WeekFacts) -> Double? {
        let values = facts.daily.compactMap(\.sleepHours)
        guard !values.isEmpty else { return nil }
        return ((values.reduce(0, +) / Double(values.count)) * 10).rounded() / 10
    }

    /// Drafted: the latest day with kcal above that day's target by more than 20%. Always confirmed by the athlete.
    static func lastRefeedDate(_ facts: WeekFacts, overshoot: Double = 0.20) -> String? {
        facts.daily
            .filter { day in
                guard let kcal = day.kcal else { return false }
                return kcal > facts.targets.forDay(training: day.isTrainingDay).kcal * (1 + overshoot)
            }
            .map(\.date)
            .max()
    }

    /// Check-in morning weigh-in (the last logged), or the 7-day average when `sevenDayAverage` is set.
    static func currentWeight(_ facts: WeekFacts, sevenDayAverage: Bool = false) -> Double? {
        let values = facts.daily.compactMap(\.weighInLb)
        guard !values.isEmpty else { return nil }
        if sevenDayAverage {
            return ((values.reduce(0, +) / Double(values.count)) * 10).rounded() / 10
        }
        return values.last
    }

    /// Logged LISS: session count and total minutes.
    static func liss(_ facts: WeekFacts) -> (sessions: Int, minutes: Int) {
        let all = facts.daily.flatMap(\.liss)
        return (all.count, all.reduce(0) { $0 + $1.minutes })
    }

    /// Whole weeks from today to the show date, else nil ("N/A" on the form).
    static func weeksToShow(showDate: String?, today: Date, calendar: Calendar = .current) -> Int? {
        guard let showDate, let show = DayKey.date(showDate, calendar: calendar) else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: today), to: show).day ?? 0
        return max(0, days / 7)
    }

    /// A day is a training day if a Setecho session happened that day, or the program schedules
    /// lifting on that weekday (`scheduledWeekdays` uses Calendar's 1 = Sunday … 7 = Saturday).
    static func isTrainingDay(
        _ date: Date, sessions: [Session], scheduledWeekdays: Set<Int>, calendar: Calendar = .current
    ) -> Bool {
        if sessions.contains(where: { calendar.isDate($0.startedAt, inSameDayAs: date) }) { return true }
        return scheduledWeekdays.contains(calendar.component(.weekday, from: date))
    }

    /// Sessions done against scheduled, for "Training consistency".
    static func sessionsDone(_ sessions: [Session], weekStart: Date, weekEnd: Date) -> Int {
        sessions.filter { $0.isComplete && $0.startedAt >= weekStart && $0.startedAt < weekEnd }.count
    }

    /// PRs this week: a set heavier, or the same load for more reps, than the best earlier set of that
    /// exercise logged in Setecho. With no earlier history, there are no PRs; nothing is guessed.
    static func personalRecords(thisWeek: [Session], earlier: [Session]) -> [LoggedSet] {
        let earlierSets = earlier.flatMap(\.sets)
        guard !earlierSets.isEmpty else { return [] }
        let bestBefore = Dictionary(grouping: earlierSets, by: \.exerciseId).mapValues { sets in
            sets.map { ($0.loadLb, $0.reps) }
        }
        return thisWeek.flatMap(\.sets).filter { set in
            guard let history = bestBefore[set.exerciseId] else { return false }
            let heavier = set.loadLb > (history.map(\.0).max() ?? 0)
            let moreReps = history.contains { $0.0 == set.loadLb } && set.reps > (history.filter { $0.0 == set.loadLb }.map(\.1).max() ?? 0)
            return heavier || moreReps
        }
    }
}
