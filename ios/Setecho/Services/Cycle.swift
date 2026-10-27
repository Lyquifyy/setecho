import Foundation

/// Which cycle day is today (HANDOFF.md §7, Which day is today). Pure functions over the plan and
/// the log, so every rule is unit-tested: a rest day passes with the calendar, a training day moves
/// on once its session is complete, a missed training day waits, and the cycle wraps.
enum Cycle {
    /// The cycle day after `dayId`, wrapping at the end (the last week wraps to week 1).
    static func next(after dayId: String, in program: Program) -> ProgramDay? {
        let days = program.cycleDays
        guard !days.isEmpty else { return nil }
        guard let i = days.firstIndex(where: { $0.id == dayId }) else { return days.first }
        return days[(i + 1) % days.count]
    }

    /// A complete session with sets for this day, started on or after the day the cursor arrived.
    static func isDone(dayId: String, since: Date, sessions: [Session], calendar: Calendar = .current) -> Bool {
        let from = calendar.startOfDay(for: since)
        return sessions.contains { $0.programDayId == dayId && $0.isComplete && !$0.workingSets.isEmpty && $0.startedAt >= from }
    }

    /// The first cursor: the cycle day after the last completed session, since that session's day;
    /// with no session yet, the first day, since today (HANDOFF.md §4, Migrations).
    static func seed(program: Program, sessions: [Session], today: Date = .now, calendar: Calendar = .current) -> CycleCursor? {
        guard let first = program.cycleDays.first else { return nil }
        let done = sessions
            .filter { $0.isComplete && !$0.workingSets.isEmpty && $0.programDayId.map { id in program.cycleDays.contains { $0.id == id } } == true }
            .max { $0.startedAt < $1.startedAt }
        guard let done, let dayId = done.programDayId, let following = next(after: dayId, in: program) else {
            return CycleCursor(dayId: first.id, since: calendar.startOfDay(for: today))
        }
        return CycleCursor(dayId: following.id, since: calendar.startOfDay(for: done.startedAt))
    }

    /// The cursor on the first launch of a calendar day. A rest day passes with each calendar day;
    /// a training day moves on once it is done; a missed training day waits where it is.
    static func advanced(_ cursor: CycleCursor, program: Program, sessions: [Session], today: Date = .now, calendar: Calendar = .current) -> CycleCursor {
        var cursor = cursor
        let startToday = calendar.startOfDay(for: today)
        var since = calendar.startOfDay(for: cursor.since)
        var elapsed = calendar.dateComponents([.day], from: since, to: startToday).day ?? 0
        var guardSteps = program.cycleDays.count * 4
        while elapsed > 0, guardSteps > 0 {
            guardSteps -= 1
            guard let day = program.cycleDays.first(where: { $0.id == cursor.dayId }) else {
                return CycleCursor(dayId: program.cycleDays.first?.id ?? cursor.dayId, since: startToday)
            }
            if day.isRest {
                since = calendar.date(byAdding: .day, value: 1, to: since) ?? startToday
                elapsed -= 1
                cursor = CycleCursor(dayId: next(after: day.id, in: program)?.id ?? day.id, since: since)
            } else if isDone(dayId: day.id, since: cursor.since, sessions: sessions, calendar: calendar) {
                // Done: the next day starts showing today, whatever days passed in between.
                cursor = CycleCursor(dayId: next(after: day.id, in: program)?.id ?? day.id, since: startToday)
                elapsed = 0
            } else {
                break // a missed training day waits for the athlete
            }
        }
        return cursor
    }

    /// "Change day" or "I'm doing Day 5 today": the cursor moves by hand and starts today.
    static func changed(to dayId: String, today: Date = .now, calendar: Calendar = .current) -> CycleCursor {
        CycleCursor(dayId: dayId, since: calendar.startOfDay(for: today))
    }
}

/// Which days an add-on joins, and whether it is due today (HANDOFF.md §7, Two workouts in one day).
enum AddOnPlanner {
    /// Proposed days, confirmed once on Import: a with-session add-on is spread over the training
    /// days as evenly as the cycle allows (2× in a 5-day cycle: the 2nd and 4th); an on-waking one
    /// over the whole cycle, rest days included.
    static func proposedDays(for addOn: AddOn, in program: Program) -> [String] {
        let pool = addOn.timing == .withSession ? program.trainingDays : program.cycleDays
        guard !pool.isEmpty else { return [] }
        let count = min(max(addOn.perWeek, 1), pool.count)
        var ids: [String] = []
        for i in 0..<count {
            let index = Int(((Double(i) + 0.5) * Double(pool.count) / Double(count)).rounded(.down))
            let id = pool[min(index, pool.count - 1)].id
            if !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    /// Sessions in [from, to) that carried the add-on and logged a set of it.
    static func doneCount(addOnId: String, sessions: [Session], from: Date, to: Date) -> Int {
        sessions.filter { $0.addOnIds.contains(addOnId) && $0.startedAt >= from && $0.startedAt < to && !$0.workingSets.isEmpty }.count
    }

    struct Due: Equatable {
        var addOn: AddOn
        /// How many times it has been done this check-in week.
        var done: Int
        /// It joins today only because the week is running out.
        var catchUp: Bool
    }

    /// Whether the add-on is due today: one of its chosen days with something still owed this week,
    /// or catch-up when fewer days are left in the week than it still needs.
    static func due(_ addOn: AddOn, dayId: String?, chosenDays: [String], sessions: [Session], today: Date,
                    week: (start: Date, end: Date), calendar: Calendar = .current) -> Due? {
        let done = doneCount(addOnId: addOn.id, sessions: sessions, from: week.start, to: week.end)
        let remaining = addOn.perWeek - done
        guard remaining > 0 else { return nil }
        let doneToday = sessions.contains { $0.addOnIds.contains(addOn.id) && calendar.isDate($0.startedAt, inSameDayAs: today) && !$0.workingSets.isEmpty }
        guard !doneToday else { return nil }
        if let dayId, chosenDays.contains(dayId) { return Due(addOn: addOn, done: done, catchUp: false) }
        let startToday = calendar.startOfDay(for: today)
        let daysLeft = max(0, calendar.dateComponents([.day], from: startToday, to: calendar.startOfDay(for: week.end)).day ?? 0)
        return daysLeft < remaining ? Due(addOn: addOn, done: done, catchUp: true) : nil
    }
}
