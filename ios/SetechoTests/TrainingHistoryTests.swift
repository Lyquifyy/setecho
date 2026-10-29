import Foundation
import Testing
@testable import Setecho

/// Bring your history (HANDOFF.md §9): Liftoff and Garmin sessions as `/import/history` returns them,
/// the same-day choice, and Last time from them beneath the app's own log. Every session here is made
/// up; none is the athlete's.

private let chicago = TimeZone(identifier: "America/Chicago")!

private var calendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = chicago
    return c
}

private func at(_ m: Int, _ d: Int, _ h: Int = 16) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: m, day: d, hour: h))!
}

private func set(_ order: Int, _ lb: Double, _ reps: Int?, _ role: SetRole? = nil) -> ImportedSet {
    ImportedSet(order: order, loadLb: lb, reps: reps, seconds: nil, distance: nil, role: role)
}

private func session(_ id: String, _ source: HistorySource, _ date: Date, _ exercises: [ImportedExercise]) -> ImportedSession {
    ImportedSession(id: id, source: source, startedAt: date, name: nil, exercises: exercises)
}

private func planned(_ id: String, _ name: String, _ equipment: Equipment, roles: [SetRole?]) -> PlannedExercise {
    PlannedExercise(id: id, name: name, sets: roles.map { PlannedSet(reps: nil, repsMin: 6, repsMax: 9, loadLb: nil, rpe: nil, rir: nil, role: $0) },
                    equipment: equipment, restSeconds: nil, notes: nil)
}

private let smith = planned("d1_smith_close_grip", "Smith close-grip bench", .barbell, roles: [.top, .backOff])
private let fly = planned("d1_cable_fly", "Cable fly", .cable, roles: [nil, nil, nil])

private let liftoffSep = session("liftoff:2026-09-30 16:00:00", .liftoff, at(9, 30), [
    ImportedExercise(name: "Close Grip Bench Press", note: "Elbows in", sets: [set(0, 205, 8, .top), set(1, 175, 11, .backOff)]),
    ImportedExercise(name: "Cable Fly", note: nil, sets: [set(0, 32.5, 12, .top), set(1, 27.5, 11, .backOff)]),
])
private let garminOct = session("garmin:1", .garmin, at(10, 5), [
    ImportedExercise(name: "Close Grip Barbell Bench Press", note: nil, sets: [set(0, 225, 9, .top), set(1, 185, 6, .backOff)]),
])
private let liftoffSameDay = session("liftoff:2026-10-05 17:00:00", .liftoff, at(10, 5, 17), [
    ImportedExercise(name: "Close Grip Bench Press", note: nil, sets: [set(0, 215, 7, .top)]),
])

@Test func decodesTheBackendsJSON() throws {
    let json = """
    {"sessions": [{"id": "garmin:1", "source": "garmin", "startedAt": "2026-10-05T21:00:00Z", "name": "Day 1 Workout",
      "exercises": [{"name": "Smith Machine Bench Press", "note": null,
        "sets": [{"order": 0, "loadLb": 225.0, "reps": 8, "seconds": null, "distance": null, "role": "top"},
                 {"order": 1, "loadLb": 185.0, "reps": 11, "seconds": null, "distance": null, "role": "backOff"}]},
        {"name": "Plank", "note": null, "sets": [{"order": 0, "loadLb": 0, "reps": null, "seconds": 45, "distance": null, "role": null}]}]}],
     "leftOut": [{"source": "garmin", "startedAt": "2026-10-05T21:00:00Z", "exercise": "Dumbbell Lateral Raise", "sets": 1, "reason": "noReps"}]}
    """
    let result = try JSONCoding.decoder.decode(HistoryImportResult.self, from: Data(json.utf8))
    let exercise = try #require(result.sessions.first?.exercises.first)
    #expect(exercise.topSet == set(0, 225, 8, .top) && exercise.firstBackOff == set(1, 185, 11, .backOff))
    #expect(result.sessions[0].exercises[1].isLifting == false && result.sessions[0].exercises[1].topSet == nil)
    #expect(result.leftOut.first?.reason == .noReps)
}

@Test func namesOnceInTheOrderFirstSeen() {
    #expect(TrainingHistory.names(in: [garminOct, liftoffSep]) == ["Close Grip Bench Press", "Cable Fly", "Close Grip Barbell Bench Press"])
}

@Test func aDayInBothAsksAndKeepsOne() {
    let all = [liftoffSep, garminOct, liftoffSameDay]
    #expect(TrainingHistory.sameDays(in: all, calendar: calendar) == ["2026-10-05"])
    // Garmin until he picks; then his pick. Other days are untouched.
    #expect(TrainingHistory.kept(all, choices: [:], calendar: calendar).map(\.id) == [liftoffSep.id, garminOct.id])
    #expect(TrainingHistory.kept(all, choices: ["2026-10-05": .liftoff], calendar: calendar).map(\.id) == [liftoffSep.id, liftoffSameDay.id])
}

@Test func lastTimeIsTheLatestTopSetAcrossEveryMatchedName() throws {
    var history = TrainingHistory()
    history.sessions = [liftoffSep, garminOct]
    history.matches = ["Close Grip Bench Press": smith.id, "Close Grip Barbell Bench Press": smith.id, "Cable Fly": fly.id]
    let last = try #require(TrainingHistory.lastTop(names: history.names(for: smith.id), in: history.sessions))
    #expect(last.session.id == garminOct.id && last.set.loadLb == 225 && last.set.reps == 9)

    let sets = history.lastSets(for: [smith, fly], steps: RuleEngine.LoadSteps(barbell: 5, dumbbell: 5, machine: 10, cable: 2.5))
    #expect(sets["d1_smith_close_grip|top"] == LastSet(loadLb: 225, reps: 9, source: "Garmin", date: at(10, 5)))
    #expect(sets["d1_smith_close_grip|backOff"] == LastSet(loadLb: 185, reps: 6, source: "Garmin", date: at(10, 5)))
    // Straight sets read the plain key; Liftoff's 32.5 stays 32.5 on 2.5 lb steps, the back-off isn't planned.
    #expect(sets["d1_cable_fly|"] == LastSet(loadLb: 32.5, reps: 12, source: "Liftoff", date: at(9, 30)))
    #expect(sets["d1_cable_fly|backOff"] == nil)
    // Shown rounded to his load steps: 10 lb cable steps make 32.5 read 30.
    let coarse = history.lastSets(for: [fly], steps: RuleEngine.LoadSteps(barbell: 5, dumbbell: 5, machine: 10, cable: 10))
    #expect(coarse["d1_cable_fly|"]?.loadLb == 30)
}

@Test func anUnmatchedNameIsHistoryOnly() {
    var history = TrainingHistory()
    history.sessions = [liftoffSep]
    history.ownNames = ["Close Grip Bench Press"]
    #expect(history.lastSets(for: [smith], steps: .init()).isEmpty)
    #expect(history.isConfirmed("Close Grip Bench Press") && !history.isConfirmed("Cable Fly"))
}

@Test func oldFilesDecodeWithDefaults() throws {
    let history = try JSONCoding.decoder.decode(TrainingHistory.self, from: Data(#"{"sessions": []}"#.utf8))
    #expect(history.matches.isEmpty && history.ownNames.isEmpty && history.liftoffUnit == .lb && history.lastImportAt == nil)
}

@MainActor
@Test func storeKeepsTheImportAndTheNewerLastTimeWins() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = Store(root: root)
    store.saveProgram(Program(name: "P", weeks: [ProgramWeek(number: 1, days: [ProgramDay(id: "d1", name: "Day 1", exercises: [smith])])],
                              importedAt: .now, flags: []))
    store.mergeHistory([liftoffSep, garminOct], matches: ["Close Grip Bench Press": smith.id, "Close Grip Barbell Bench Press": smith.id,
                                                          "Cable Fly": nil], liftoffUnit: .lb)
    #expect(store.lastSets["d1_smith_close_grip|top"]?.loadLb == 225)
    #expect(store.lastSets["d1_smith_close_grip|top"]?.source == "Garmin")

    // An older paper-logbook entry stays beneath it; a newer one wins.
    store.addLogbook(LogbookEntry(id: UUID(), exerciseId: smith.id, role: .top, loadLb: 215, reps: 8, date: at(10, 1)))
    #expect(store.lastSets["d1_smith_close_grip|top"]?.loadLb == 225)
    store.addLogbook(LogbookEntry(id: UUID(), exerciseId: smith.id, role: .top, loadLb: 230, reps: 6, date: at(10, 7)))
    #expect(store.lastSets["d1_smith_close_grip|top"] == LastSet(loadLb: 230, reps: 6, source: "Logbook", date: at(10, 7)))

    // Remembered: the matches, the name kept as its own, and the sessions, after a relaunch.
    let reopened = Store(root: root)
    #expect(reopened.history.sessions.map(\.id) == [liftoffSep.id, garminOct.id])
    #expect(reopened.history.matches["Close Grip Barbell Bench Press"] == smith.id && reopened.history.ownNames == ["Cable Fly"])

    // A newer export of the same session replaces it; a name matched later leaves the own-name list.
    var corrected = garminOct
    corrected.exercises[0].sets[0].reps = 10
    reopened.mergeHistory([corrected], matches: ["Cable Fly": smith.id], liftoffUnit: .kg)
    #expect(reopened.history.sessions.count == 2 && reopened.history.sessions[1].exercises[0].sets[0].reps == 10)
    #expect(reopened.history.ownNames.isEmpty && reopened.history.liftoffUnit == .kg)

    reopened.clearHistory()
    #expect(reopened.history == TrainingHistory())
}
