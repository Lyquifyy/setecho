import Foundation
import Testing
@testable import Setecho

/// He drives, Setecho follows (HANDOFF.md §7): the plan moves only when a set he armed ends, he
/// logs one by voice, or he says so. Nothing moves on a timer, on the camera alone, or on a guess.
/// From the Oct 28 gym test: "it felt like it was skipping past things and moving on its own."

private func set(_ reps: Int, _ load: Double, role: SetRole? = nil) -> PlannedSet {
    PlannedSet(reps: reps, repsMin: nil, repsMax: nil, loadLb: load, rpe: nil, rir: nil, role: role)
}

private let day = ProgramDay(id: "d5", name: "Day 5", exercises: [
    PlannedExercise(id: "incline", name: "Incline press", sets: [set(8, 145, role: .top), set(10, 115, role: .backOff)], restSeconds: 120, notes: nil),
    PlannedExercise(id: "flyes", name: "Cable flyes", sets: [set(12, 30), set(12, 30)], restSeconds: 90, notes: nil),
    PlannedExercise(id: "dips", name: "Dips", sets: [set(10, 0)], equipment: .bodyweight, restSeconds: 90, notes: nil),
])

private let warmups = WarmupRule(minSets: 1, maxSets: 3, maxReps: 8, quote: "1-3 warm up sets", confirmed: true)

private func say(_ kind: VoiceIntent.Kind, _ transcript: String = "", number: Double? = nil, text: String? = nil,
                 topic: VoiceIntent.Topic? = nil) -> VoiceCommandResponse {
    VoiceCommandResponse(transcript: transcript, intent: VoiceIntent(intent: kind, number: number, text: text, topic: topic, confidence: 0.95),
                         classifiedBy: "rules")
}

/// Sets by voice, three minutes apart (a "done, N" within 20 s of the last set is about that set).
@MainActor
private var clock = Date(timeIntervalSince1970: 1_800_000_000)

@MainActor
@discardableResult
private func logSet(_ engine: SessionEngine, reps: Int) -> SessionEngine.Outcome {
    clock = clock.addingTimeInterval(180)
    return engine.apply(say(.endSet, "done, \(reps)", number: Double(reps)), now: clock)
}

@Test @MainActor func theEndOfARestChangesNothingAndCountsOvertime() {
    let engine = SessionEngine(day: day, weekNumber: 1)
    logSet(engine, reps: 8)
    #expect(engine.state == .rest(remaining: 120))
    var spoken: [String] = []
    var sounds: [SessionEngine.Sound] = []
    for _ in 0..<160 {
        let o = engine.tickRest()
        if let s = o.speech { spoken.append(s) }
        if let s = o.sound { sounds.append(s) }
    }
    #expect(engine.state == .rest(remaining: -40))          // +0:40 overtime, still resting
    #expect(engine.currentExercise?.id == "incline" && engine.setNumber == 2)
    #expect(spoken == ["Rest's up."] && sounds == [.restUp])
    // The next rest's end is the bell alone: "Rest's up." is said once a session.
    logSet(engine, reps: 10)
    var again: [String] = []
    for _ in 0..<95 { if let s = engine.tickRest().speech { again.append(s) } }
    #expect(again.isEmpty)
    #expect(engine.whereAmI == "Cable flyes, set 1 of 2.")
}

@Test @MainActor func holdsStartOnHisGo() {
    let plank = ProgramDay(id: "abs", name: "Abs", exercises: [
        PlannedExercise(id: "plank", name: "Plank", sets: [PlannedSet(reps: nil, repsMin: nil, repsMax: nil, loadLb: nil, rpe: nil, rir: nil, seconds: 30),
                                                           PlannedSet(reps: nil, repsMin: nil, repsMax: nil, loadLb: nil, rpe: nil, rir: nil, seconds: 30)],
                        restSeconds: 30, notes: nil),
    ])
    let engine = SessionEngine(day: plank, weekNumber: 1, autoHolds: false)
    #expect(engine.beginLeadInIfDue() == .none)
    #expect(engine.intro.hasSuffix("Say go."))
    let go = engine.apply(say(.starting, "go"))
    #expect(go.speech == "Three." && engine.state == .leadIn(remaining: 3))
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(engine.tickLeadIn(at: t0).speech == "Two.")
    #expect(engine.tickLeadIn(at: t0).speech == "One.")
    #expect(engine.tickLeadIn(at: t0).speech == "Hold.")
    #expect(engine.state == .hold(remaining: 30))
    _ = engine.tickHold(at: t0.addingTimeInterval(30))
    // The rest runs out: no lead-in by itself.
    for _ in 0..<40 { engine.tickRest() }
    #expect(engine.state == .rest(remaining: -10))
}

@Test @MainActor func aFinishedExerciseNamesTheNextAndNothingOfItStartsUntilHeMoves() {
    let engine = SessionEngine(day: day, weekNumber: 1, warmups: warmups)
    engine.apply(say(.topSet, "top set"))
    logSet(engine, reps: 9)
    let last = logSet(engine, reps: 11)
    #expect(last.speech?.contains("Incline press done. Cable flyes next.") == true)
    #expect(engine.currentExercise?.id == "flyes" && !engine.exerciseEntered && !engine.warmupMode)
    // He arms a set of flyes: now it's entered, and his warm-ups apply.
    engine.cameraOnDuty = true
    let armed = engine.apply(say(.starting, "go"))
    #expect(engine.exerciseEntered && engine.warmupMode)
    #expect(armed.speech == "Warm-ups first." && armed.sound == SessionEngine.Sound.armed)
}

@Test @MainActor func oneMoreSetAddsToTheExerciseJustFinished() {
    let engine = SessionEngine(day: day, weekNumber: 1)
    logSet(engine, reps: 8)
    logSet(engine, reps: 10)
    #expect(engine.currentExercise?.id == "flyes")
    let more = engine.apply(say(.addSet, "one more set"))
    #expect(more.speech == "One more set of incline press. Set 3.")
    #expect(engine.currentExercise?.id == "incline" && engine.setNumber == 3 && engine.setCount == 3)
    engine.apply(say(.undo, "undo"))
    #expect(engine.currentExercise?.id == "flyes" && engine.exercises[0].exercise.sets.count == 2)
}

@Test @MainActor func goBackRedoesTheLastSetsSlot() {
    let engine = SessionEngine(day: day, weekNumber: 1)
    logSet(engine, reps: 8)
    #expect(engine.setNumber == 2)
    let back = engine.apply(say(.goTo, "go back", text: "back"))
    #expect(back.speech == "Back to incline press, set 1.")
    #expect(engine.setNumber == 1 && engine.session.sets.count == 1)
}

@Test @MainActor func movingAnExerciseUpReordersTodayAndReachesTheCoach() {
    let engine = SessionEngine(day: day, weekNumber: 1)
    let move = engine.apply(say(.goTo, "I'm on dips now", text: "Dips"))
    #expect(move.speech == "Dips now. Set 1 of 1.")
    #expect(engine.exercises.map(\.exercise.id) == ["dips", "incline", "flyes"])
    #expect(engine.session.deviations.map(\.kind) == [.reorder])
    #expect(engine.session.deviations.first?.reason == "moved ahead of incline press")
    logSet(engine, reps: 10)
    // Then incline, which waited right behind it.
    #expect(engine.currentExercise?.id == "incline")
    engine.apply(say(.undo, "undo")) // the set
    engine.apply(say(.undo, "undo")) // the move
    #expect(engine.exercises.map(\.exercise.id) == ["incline", "flyes", "dips"] && engine.session.deviations.isEmpty)
}

@Test @MainActor func thatsItForAnExerciseLeavesItsSetsUnlogged() {
    let engine = SessionEngine(day: day, weekNumber: 1)
    logSet(engine, reps: 8)
    let end = engine.apply(say(.endExercise, "that's it for incline"))
    #expect(end.speech == "Incline press done. Cable flyes next.")
    #expect(engine.session.sets.count == 1 && engine.currentExercise?.id == "flyes")
    #expect(engine.session.deviations.isEmpty) // a set of it was done: no skip
    engine.apply(say(.undo, "undo"))
    #expect(engine.currentExercise?.id == "incline" && engine.setNumber == 2)
}

@Test @MainActor func whereAmISaysTheExerciseTheSetAndItsRole() {
    let engine = SessionEngine(day: day, weekNumber: 1)
    logSet(engine, reps: 8)
    let answer = engine.apply(say(.question, "where am I?", topic: .whereAmI))
    #expect(answer.speech == "Incline press, set 2 of 2, back-off.")
}

@Test @MainActor func aLateCountHeNeverHeardANumberForUpdatesTheScreenSilently() {
    let engine = SessionEngine(day: day, weekNumber: 1)
    engine.cameraOnDuty = true
    engine.setStarted()
    engine.setEnded(willMeasure: true) // set 1, SAM counting, no number said
    let first = engine.session.sets[0].id
    engine.skipRest()
    engine.setStarted() // the next set begins before SAM answers
    let held = engine.measured(setId: first, CountResponse(reps: 8, repTimes: [], confidence: 0.9, trackFound: true, frames: 100, trackedFrames: 100, prompt: "weight plate"))
    #expect(held == .none)
    let ended = engine.setEnded(willMeasure: true)
    #expect(ended.speech?.contains("Set 1") != true)
    #expect(engine.session.sets[0].repCount.source == .measured)
}

@Test @MainActor func anAutomaticWarmUpIsSaidAndUndoMakesItAWorkingSet() {
    let engine = SessionEngine(day: day, weekNumber: 1, warmups: warmups)
    let warm = engine.apply(say(.endSet, "done, 6", number: 6))
    #expect(warm.speech?.hasPrefix("Warm-up one, logged.") == true)
    #expect(engine.session.sets[0].isWarmup)
    engine.apply(say(.undo, "undo"))
    #expect(!engine.session.sets[0].isWarmup && engine.setNumber == 2)
}

// MARK: Oct 30: the extra set, and "what do I got for the rest of this lift?"

private func range(_ min: Int, _ max: Int, _ load: Double) -> PlannedSet {
    PlannedSet(reps: nil, repsMin: min, repsMax: max, loadLb: load, rpe: nil, rir: nil)
}

private let shoulders = ProgramDay(id: "d5", name: "Day 5", exercises: [
    PlannedExercise(id: "laterals", name: "Cable lateral raises", sets: [range(12, 15, 12.5), range(12, 15, 12.5)], restSeconds: 90, notes: nil),
    PlannedExercise(id: "pushdowns", name: "Triceps pushdowns", sets: Array(repeating: range(10, 12, 27.5), count: 4), restSeconds: 90, notes: nil),
])

@Test @MainActor func anExtraSetLoggedOnTheNextLiftMovesBackWhenHeSaysSo() {
    let engine = SessionEngine(day: shoulders, weekNumber: 1)
    logSet(engine, reps: 15)
    logSet(engine, reps: 13)
    logSet(engine, reps: 12) // his third set of laterals, logged as pushdowns set 1
    #expect(engine.session.sets.last?.exerciseId == "pushdowns" && engine.setNumber == 2)
    let moved = engine.apply(say(.addSet, "that was another set of laterals", text: "laterals"), now: clock)
    #expect(moved.speech == "Moved it: set 3 of cable lateral raises, 12.5 for 12. Triceps pushdowns is still up.")
    let set = engine.session.sets.last
    #expect(set?.exerciseId == "laterals" && set?.setIndex == 2 && set?.loadLb == 12.5 && set?.reps == 12)
    #expect(engine.currentExercise?.id == "pushdowns" && engine.setNumber == 1 && !engine.exerciseEntered)
    #expect(engine.exercises[0].exercise.sets.count == 3)
    engine.apply(say(.undo, "undo"))
    #expect(engine.session.sets.last?.exerciseId == "pushdowns" && engine.session.sets.last?.loadLb == 27.5)
    #expect(engine.exercises[0].exercise.sets.count == 2 && engine.setNumber == 2)
}

@Test @MainActor func oneMoreSetOfANamedLiftIsOneToComeAndMovesNothing() {
    let engine = SessionEngine(day: shoulders, weekNumber: 1)
    logSet(engine, reps: 15)
    logSet(engine, reps: 13)
    logSet(engine, reps: 12)
    let more = engine.apply(say(.addSet, "let's do one more set of laterals", text: "laterals"), now: clock)
    #expect(more.speech == "One more set of cable lateral raises. Set 3.")
    #expect(engine.session.sets.last?.exerciseId == "pushdowns")
    #expect(engine.currentExercise?.id == "laterals" && engine.setNumber == 3)
}

@Test @MainActor func midSetThisIsAnotherSetOfLateralsLogsItThere() {
    let engine = SessionEngine(day: shoulders, weekNumber: 1)
    logSet(engine, reps: 15)
    logSet(engine, reps: 13)
    engine.setStarted(at: clock)
    let heard = engine.apply(say(.addSet, "this is an extra set of laterals", text: "laterals"), now: clock)
    #expect(heard.speech == "Got it, set 3 of cable lateral raises.")
    #expect(engine.state == .recording)
    engine.apply(say(.endSet, "done, 12", number: 12), now: clock.addingTimeInterval(40))
    let set = engine.session.sets.last
    #expect(set?.exerciseId == "laterals" && set?.setIndex == 2 && set?.loadLb == 12.5 && set?.reps == 12)
    #expect(engine.currentExercise?.id == "pushdowns" && engine.setNumber == 1)
}

@Test @MainActor func theRestOfThisLiftIsItsSetsAtTheirLoadsThenWhatsNext() {
    let engine = SessionEngine(day: shoulders, weekNumber: 1)
    #expect(engine.setsLeftLine == "Two more, 12.5 for 12–15. Then triceps pushdowns.")
    engine.setStarted(at: clock)
    #expect(engine.setsLeftLine == "One more after this, 12.5 for 12–15. Then triceps pushdowns.")
    let next = engine.apply(say(.question, "what weight for my next set", topic: .load), now: clock)
    #expect(next.speech == "Next set's 12.5 for 12–15.")
    engine.apply(say(.endSet, "done, 15", number: 15), now: clock.addingTimeInterval(40))
    logSet(engine, reps: 13)
    #expect(engine.setsLeftLine == "That's all the cable lateral raises. Triceps pushdowns next, four sets, 27.5 for 10–12.")
    engine.setStarted(at: clock)
    for _ in 0..<2 {
        clock = clock.addingTimeInterval(180)
        engine.apply(say(.endSet, "done, 12", number: 12), now: clock)
        engine.setStarted(at: clock)
    }
    #expect(engine.setNumber == 3)
    #expect(engine.setsLeftLine == "One more after this, 27.5 for 10–12. Then that's the session.")
}
