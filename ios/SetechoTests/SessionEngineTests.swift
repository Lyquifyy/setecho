import Foundation
import Testing
@testable import Setecho

private func set(_ reps: Int?, _ load: Double?, rpe: Double? = nil, min: Int? = nil, max: Int? = nil) -> PlannedSet {
    PlannedSet(reps: reps, repsMin: min, repsMax: max, loadLb: load, rpe: rpe, rir: nil)
}

private let upperA = ProgramDay(id: "w1_upper_a", name: "Upper A", exercises: [
    PlannedExercise(id: "bench", name: "Bench press", sets: [set(8, 225), set(8, 225), set(8, 225)], restSeconds: 150, notes: nil),
    PlannedExercise(id: "row", name: "Barbell row", sets: [set(nil, 165, min: 8, max: 10), set(nil, 165, min: 8, max: 10)], restSeconds: 120, notes: nil),
])

private func intent(_ kind: VoiceIntent.Kind, _ number: Double? = nil, text: String? = nil, confidence: Double = 0.95, transcript: String = "") -> VoiceCommandResponse {
    VoiceCommandResponse(transcript: transcript, intent: VoiceIntent(intent: kind, number: number, text: text, fieldId: nil, confidence: confidence), sessionId: nil)
}

@Test @MainActor func setIsLoggedFromThePlanWithTheCallout() {
    let engine = SessionEngine(day: upperA, weekNumber: 1)
    #expect(engine.state == .ready && engine.targetLoadLb == 225 && engine.setNumber == 1)
    engine.setStarted()
    #expect(engine.state == .recording)
    let outcome = engine.setEnded()
    #expect(engine.session.sets.count == 1)
    #expect(engine.session.sets[0].loadLb == 225 && engine.session.sets[0].reps == 8 && engine.session.sets[0].exerciseId == "bench")
    #expect(outcome.speech == "Set 1 done. Next, 225 for 8. Rest two thirty.")
    #expect(engine.state == .rest(remaining: 150))
    #expect(engine.setNumber == 2)
}

@Test @MainActor func voiceOverridesLoadRepsAndRpe() {
    let engine = SessionEngine(day: upperA, weekNumber: 1)
    engine.apply(intent(.setLoad, 215, transcript: "drop to 215"))
    #expect(engine.targetLoadLb == 215)
    engine.setStarted()
    engine.apply(intent(.reps, 7, transcript: "that was 7"))   // during the set: applies when it ends
    engine.setEnded()
    #expect(engine.session.sets[0].loadLb == 215 && engine.session.sets[0].reps == 7)
    let rpe = engine.apply(intent(.rpe, 9, transcript: "felt like a 9"))
    #expect(engine.session.sets[0].rpe == 9)
    #expect(rpe.speech == "RPE 9 on set 1.")
    #expect(engine.session.sets[0].edits.last?.field == "rpe")
    // The override sticks for the next set of the same exercise, and "add 5" builds on it.
    engine.apply(intent(.loadDelta, 5, transcript: "add 5"))
    #expect(engine.targetLoadLb == 220)
    engine.skipRest()
    engine.setStarted()
    engine.setEnded()
    #expect(engine.session.sets[1].loadLb == 220 && engine.session.sets[1].reps == 8)
}

@Test @MainActor func repsCorrectionAfterTheSetEditsTheLastSet() {
    let engine = SessionEngine(day: upperA, weekNumber: 1)
    engine.setStarted()
    engine.setEnded()
    engine.apply(intent(.reps, 6, transcript: "that was 6"))
    #expect(engine.session.sets[0].reps == 6)
    #expect(engine.session.sets[0].edits.last == SetEdit(at: engine.session.sets[0].edits.last!.at, field: "reps", from: "8", to: "6", transcript: "that was 6"))
}

@Test @MainActor func undoRevertsTheLastActionAndSaysSo() {
    let engine = SessionEngine(day: upperA, weekNumber: 1)
    engine.setStarted()
    engine.setEnded()
    engine.apply(intent(.rpe, 9))
    var out = engine.undo()
    #expect(engine.session.sets[0].rpe == nil && out.speech == "Undid RPE 9.")
    out = engine.undo()
    #expect(engine.session.sets.isEmpty && out.speech == "Undid set 1.")
    #expect(engine.state == .ready && engine.setNumber == 1)
    out = engine.undo()
    #expect(out.speech == "Nothing to undo.")
}

@Test @MainActor func lowConfidenceAsksBackAndChangesNothing() {
    let engine = SessionEngine(day: upperA, weekNumber: 1)
    let out = engine.apply(intent(.setLoad, 215, confidence: 0.4, transcript: "drop to 215"))
    #expect(out.speech == "Did you say drop to 215?")
    #expect(engine.targetLoadLb == 225 && engine.undoStack.isEmpty)
    let unknown = engine.apply(intent(.unknown, confidence: 0.9, transcript: "mumble"))
    #expect(unknown.askBack == "Did you say mumble?")
}

@Test @MainActor func restCountsDownThenReady() {
    let engine = SessionEngine(day: upperA, weekNumber: 1, defaultRestSeconds: 3)
    let shortDay = ProgramDay(id: "d", name: "D", exercises: [PlannedExercise(id: "e", name: "E", sets: [set(5, 100), set(5, 100)], restSeconds: nil, notes: nil)])
    let e2 = SessionEngine(day: shortDay, weekNumber: 1, defaultRestSeconds: 3)
    e2.setStarted(); e2.setEnded()
    #expect(e2.state == .rest(remaining: 3))
    e2.tickRest(); e2.tickRest()
    #expect(e2.state == .rest(remaining: 1))
    let out = e2.tickRest()
    #expect(e2.state == .ready && out.speech == "Go.")
    _ = engine
}

@Test @MainActor func skipAndNextExerciseMoveTheTarget() {
    let engine = SessionEngine(day: upperA, weekNumber: 1)
    engine.apply(intent(.skipSet))
    #expect(engine.setNumber == 2 && engine.currentExercise?.id == "bench")
    let out = engine.apply(intent(.nextExercise))
    #expect(engine.currentExercise?.id == "row" && engine.setNumber == 1)
    #expect(out.speech == "Next exercise, Barbell row, 165 for 8–10.")
    engine.undo()
    #expect(engine.currentExercise?.id == "bench" && engine.setNumber == 2)
}

@Test @MainActor func lastSetOfExerciseAnnouncesTheNextOneAndTheSessionEnds() {
    let engine = SessionEngine(day: upperA, weekNumber: 1)
    for _ in 0..<3 { engine.setStarted(); engine.setEnded(); engine.skipRest() }
    #expect(engine.lastCallout == "Set 3 done. Next exercise, Barbell row, 165 for 8–10. Rest two thirty.")
    #expect(engine.restSeconds == 120)
    engine.setStarted(); engine.setEnded(); engine.skipRest()
    engine.setStarted()
    let out = engine.setEnded()
    #expect(out.speech == "Set 2 done. That's the session.")
    #expect(engine.state == .ended && engine.session.endedAt != nil && engine.session.sets.count == 5)
}

@Test @MainActor func notesAndPauseAndEndSession() {
    let engine = SessionEngine(day: upperA, weekNumber: 1)
    let note = engine.apply(intent(.note, text: "digestion's been off", transcript: "note for check-in: digestion's been off"))
    #expect(engine.session.notes.first?.transcript == "digestion's been off" && note.speech == "Noted.")
    engine.apply(intent(.pause))
    #expect(engine.state == .paused)
    #expect(engine.setStarted().echo == nil) // nothing records while paused
    engine.apply(intent(.resume))
    #expect(engine.state == .ready)
    engine.setStarted()
    engine.apply(intent(.endSession))
    #expect(engine.state == .ended && engine.session.sets.count == 1 && engine.session.endedAt != nil)
}

@Test func calloutTimeWords() {
    #expect(Callout.spoken(seconds: 150) == "two thirty")
    #expect(Callout.spoken(seconds: 90) == "one thirty")
    #expect(Callout.spoken(seconds: 120) == "two minutes")
    #expect(Callout.spoken(seconds: 60) == "one minute")
    #expect(Callout.spoken(seconds: 45) == "forty five seconds")
    #expect(Callout.spoken(seconds: 185) == "three oh five")
}

@Test @MainActor func contextForTheBackendTracksTheTarget() {
    let engine = SessionEngine(day: upperA, weekNumber: 1)
    engine.apply(intent(.setLoad, 215))
    let ctx = engine.context
    #expect(ctx == SessionContext(state: "ready", exerciseName: "Bench press", setIndex: 1, setCount: 3, plannedLoadLb: 215, plannedReps: 8))
}
