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

// MARK: - Rep counting (HANDOFF.md §7): SAM is the record, the phone is the silent fallback

private func phone(_ reps: Int, confidence: Double = 0.9) -> RepCounter.Result {
    RepCounter.Result(reps: reps, repTimes: (0..<reps).map { Double($0) * 2.5 + 1 }, confidence: confidence, trackFound: true, frames: 300, trackedFrames: 300)
}

private func measured(_ reps: Int?, confidence: Double, velocityLoss: Double? = 38) -> CountResponse {
    CountResponse(reps: reps, repTimes: reps.map { r in (0..<r).map { Double($0) * 2.5 + 4 } } ?? [],
                  repSpeeds: reps.map { r in (0..<r).map { 300 - Double($0) * 10 } } ?? [], velocityLossPct: reps == nil ? nil : velocityLoss,
                  confidence: confidence, trackFound: reps != nil, frames: 300, trackedFrames: 300, prompt: "weight plate")
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Test @MainActor func tripodSetEndsWithoutACountAndWaitsForSam() {
    let engine = SessionEngine(day: upperA, weekNumber: 1)
    engine.setStarted(at: t0)
    let out = engine.setEnded(at: t0.addingTimeInterval(20), phone: phone(8), willMeasure: true)
    let set = engine.session.sets[0]
    #expect(set.reps == 8 && set.repCount.source == .phone && set.repCount.phone == 8 && set.repCount.status == .counting)
    #expect(set.repCount.isCounting)
    #expect(out.speech == "Set 1 done. Rest two thirty.")       // no number: SAM is the count of record
    #expect(out.echo == "Set 1 saved: 225 lb, counting")
    #expect(engine.pendingCounts == [SessionEngine.PendingCount(setId: set.id, endedAt: t0.addingTimeInterval(20), spoken: false)])
    #expect(engine.state == .rest(remaining: 150))
}

@Test @MainActor func samOnTimeIsLoggedAsMeasuredAndSaidWithTheNextTarget() {
    let engine = SessionEngine(day: upperA, weekNumber: 1)
    engine.setStarted(at: t0); engine.setEnded(at: t0.addingTimeInterval(20), phone: phone(8), willMeasure: true)
    let id = engine.session.sets[0].id
    let out = engine.measured(setId: id, measured(8, confidence: 0.9), now: t0.addingTimeInterval(45))
    #expect(out.speech == "8 reps, measured. Slowed 38 percent, about 1 left by the measure. Next, 225 for 8.")
    #expect(out.echo == "Set 1: 8 reps (Measured)")
    let set = engine.session.sets[0]
    #expect(set.reps == 8 && set.repCount.source == .measured && set.repCount.measured == 8 && set.repCount.status == .done)
    #expect(set.repCount.repTimes.count == 8 && set.repCount.confidence == 0.9 && set.repCount.velocityLossPct == 38)
    #expect(!set.repCount.isCounting && engine.pendingCounts.isEmpty)
    #expect(engine.countLatencies == [25] && engine.medianCountLatency == 25)
    // Nothing more to say later: the fallback never fires for a set SAM answered.
    #expect(engine.tick(now: t0.addingTimeInterval(200)) == .none)
}

@Test @MainActor func samOnTimeWithADifferentCountLogsItsNumberAndUndoReverts() {
    let engine = SessionEngine(day: upperA, weekNumber: 1)
    engine.setStarted(at: t0); engine.setEnded(at: t0.addingTimeInterval(20), phone: phone(8), willMeasure: true)
    let id = engine.session.sets[0].id
    let out = engine.measured(setId: id, measured(6, confidence: 0.8), now: t0.addingTimeInterval(40))
    #expect(out.speech == "6 reps, measured, 2 short of plan. Slowed 38 percent, about 1 left by the measure. Next, 225 for 8.")
    #expect(engine.session.sets[0].reps == 6 && engine.session.sets[0].repCount.source == .measured)
    #expect(engine.session.sets[0].edits.last?.transcript == "measured")
    let undo = engine.undo()
    #expect(undo.speech == "Undid measured count.")
    #expect(engine.session.sets[0].reps == 8 && engine.session.sets[0].repCount.source == .phone)
    #expect(engine.session.sets[0].repCount.measured == 6)   // SAM's number stays on record
}

@Test @MainActor func samLateSpeaksThePhoneCountAtSixtySecondsThenReplacesIt() {
    let engine = SessionEngine(day: upperA, weekNumber: 1)
    engine.setStarted(at: t0); engine.setEnded(at: t0.addingTimeInterval(20), phone: phone(8), willMeasure: true)
    let id = engine.session.sets[0].id
    #expect(engine.tick(now: t0.addingTimeInterval(79)) == .none)             // 59 s after the set: still silent
    let fallback = engine.tick(now: t0.addingTimeInterval(80))
    #expect(fallback.speech == "8 reps. Next, 225 for 8.")                  // the phone's count, said once
    #expect(fallback.echo == "Set 1: 8 reps (Phone)")
    #expect(engine.session.sets[0].repCount.source == .phone && engine.session.sets[0].repCount.status == .counting)
    #expect(engine.pendingCounts.first?.spoken == true)
    #expect(engine.tick(now: t0.addingTimeInterval(81)) == .none)             // never twice
    // SAM lands later with a different count: the log changes and the change is mentioned.
    let late = engine.measured(setId: id, measured(7, confidence: 0.9), now: t0.addingTimeInterval(95))
    #expect(late.speech == "Set 1 updated: 7, measured.")
    #expect(late.echo == "Set 1 updated: 7 reps (measured). Say undo to revert.")
    #expect(engine.session.sets[0].reps == 7 && engine.session.sets[0].repCount.source == .measured && engine.pendingCounts.isEmpty)
    #expect(engine.countLatencies == [75])
}

@Test @MainActor func samLateWithTheSameCountOnlyChangesTheChip() {
    let engine = SessionEngine(day: upperA, weekNumber: 1)
    engine.setStarted(at: t0); engine.setEnded(at: t0.addingTimeInterval(20), phone: phone(8), willMeasure: true)
    engine.tick(now: t0.addingTimeInterval(80))
    let out = engine.measured(setId: engine.session.sets[0].id, measured(8, confidence: 0.9), now: t0.addingTimeInterval(90))
    #expect(out == .none)
    #expect(engine.session.sets[0].repCount.source == .measured && engine.session.sets[0].repCount.status == .done)
}

@Test @MainActor func samLowConfidenceAsksAndYesLogsItAsMeasured() {
    let engine = SessionEngine(day: upperA, weekNumber: 1)
    engine.setStarted(at: t0); engine.setEnded(at: t0.addingTimeInterval(20), phone: phone(8), willMeasure: true)
    let id = engine.session.sets[0].id
    let out = engine.measured(setId: id, measured(7, confidence: 0.4), now: t0.addingTimeInterval(40))
    #expect(out.speech == "Set 1, was that 7?" && out.askBack == out.speech)
    #expect(engine.session.sets[0].reps == 8 && engine.pendingQuestion?.measured == 7)
    let yes = engine.apply(intent(.yes, transcript: "yes"))
    #expect(engine.session.sets[0].reps == 7 && engine.session.sets[0].repCount.source == .measured)
    #expect(yes.speech == "Set 1, 7 reps." && engine.pendingQuestion == nil)
    #expect(engine.undo().speech == "Undid measured count." && engine.session.sets[0].reps == 8)
}

@Test @MainActor func samLowConfidenceANumberIsTheAthletesWordAndNoKeepsThePhoneCount() {
    let engine = SessionEngine(day: upperA, weekNumber: 1)
    engine.setStarted(at: t0); engine.setEnded(at: t0.addingTimeInterval(20), phone: phone(8), willMeasure: true)
    engine.measured(setId: engine.session.sets[0].id, measured(7, confidence: 0.4), now: t0.addingTimeInterval(40))
    let answer = engine.apply(intent(.answer, 9, transcript: "nine"))
    #expect(engine.session.sets[0].reps == 9 && engine.session.sets[0].repCount.source == .spoken)
    #expect(answer.speech == "Set 1, 9 reps." && engine.pendingQuestion == nil)

    let e2 = SessionEngine(day: upperA, weekNumber: 1)
    e2.setStarted(at: t0); e2.setEnded(at: t0.addingTimeInterval(20), phone: phone(8), willMeasure: true)
    e2.measured(setId: e2.session.sets[0].id, measured(7, confidence: 0.4), now: t0.addingTimeInterval(40))
    let no = e2.apply(intent(.no, transcript: "no"))
    #expect(no.speech == "Keeping 8." && e2.pendingQuestion == nil)
    #expect(e2.session.sets[0].reps == 8 && e2.session.sets[0].repCount.source == .phone && e2.session.sets[0].repCount.measured == 7)

    let e3 = SessionEngine(day: upperA, weekNumber: 1)
    e3.setStarted(at: t0); e3.setEnded(at: t0.addingTimeInterval(20), phone: phone(8), willMeasure: true)
    e3.measured(setId: e3.session.sets[0].id, measured(7, confidence: 0.4), now: t0.addingTimeInterval(40))
    e3.apply(intent(.rpe, 9, transcript: "felt like a 9"))   // another command: the question lapses
    #expect(e3.pendingQuestion == nil && e3.session.sets[0].reps == 8 && e3.session.sets[0].rpe == 9)
    #expect(e3.tick(now: t0.addingTimeInterval(200)) == .none)   // the ask counted as the set's number
}

@Test @MainActor func whatTheAthleteSaidBeatsTheMeasuredCount() {
    let engine = SessionEngine(day: upperA, weekNumber: 1)
    engine.setStarted(at: t0)
    engine.apply(intent(.reps, 7, transcript: "that was 7"))
    let out = engine.setEnded(at: t0.addingTimeInterval(20), phone: phone(8), willMeasure: true)
    #expect(out.speech == "7 reps, 1 short of plan. Next, 225 for 8. Rest two thirty.")   // his number: said at once
    #expect(engine.session.sets[0].reps == 7 && engine.session.sets[0].repCount.source == .spoken && engine.pendingCounts.isEmpty)
    let sam = engine.measured(setId: engine.session.sets[0].id, measured(9, confidence: 0.95), now: t0.addingTimeInterval(40))
    #expect(sam == .none && engine.session.sets[0].reps == 7 && engine.session.sets[0].repCount.source == .spoken)
    #expect(engine.session.sets[0].repCount.measured == 9 && engine.session.sets[0].repCount.status == .done)
}

@Test @MainActor func thatWasNDuringRestCancelsThePendingCount() {
    let engine = SessionEngine(day: upperA, weekNumber: 1)
    engine.setStarted(at: t0); engine.setEnded(at: t0.addingTimeInterval(20), phone: phone(8), willMeasure: true)
    engine.apply(intent(.reps, 6, transcript: "that was 6"))
    #expect(engine.session.sets[0].reps == 6 && engine.session.sets[0].repCount.source == .spoken && engine.pendingCounts.isEmpty)
    #expect(engine.tick(now: t0.addingTimeInterval(200)) == .none)
    #expect(engine.measured(setId: engine.session.sets[0].id, measured(8, confidence: 0.9), now: t0.addingTimeInterval(50)) == .none)
    #expect(engine.session.sets[0].reps == 6)
}

@Test @MainActor func samFailureSpeaksThePhoneCountAtOnce() {
    let engine = SessionEngine(day: upperA, weekNumber: 1)
    engine.setStarted(at: t0); engine.setEnded(at: t0.addingTimeInterval(20), phone: phone(8), willMeasure: true)
    let id = engine.session.sets[0].id
    let out = engine.countFailed(setId: id)
    #expect(out.speech == "8 reps. Next, 225 for 8.")
    #expect(engine.session.sets[0].repCount.status == .failed && engine.session.sets[0].repCount.source == .phone && engine.pendingCounts.isEmpty)
    #expect(engine.countFailed(setId: id) == .none)   // once
    engine.attachClip(setId: id, file: "set-1.mov")
    #expect(engine.session.sets[0].clipFile == "set-1.mov")
}

@Test @MainActor func noTrackSpeaksThePhoneCountAndMarksTheCountFailed() {
    let engine = SessionEngine(day: upperA, weekNumber: 1)
    engine.setStarted(at: t0); engine.setEnded(at: t0.addingTimeInterval(20), phone: phone(8), willMeasure: true)
    let out = engine.measured(setId: engine.session.sets[0].id, measured(nil, confidence: 0), now: t0.addingTimeInterval(40))
    #expect(out.speech == "8 reps. Next, 225 for 8.")
    #expect(engine.session.sets[0].reps == 8 && engine.session.sets[0].repCount.status == .failed && engine.session.sets[0].repCount.source == .phone)
}

@Test @MainActor func noPhoneCountLogsThePlanAndTheFallbackSaysOnlyTheNextTarget() {
    let engine = SessionEngine(day: upperA, weekNumber: 1)
    engine.setStarted(at: t0)
    let out = engine.setEnded(at: t0.addingTimeInterval(20), phone: nil, willMeasure: true)
    #expect(out.speech == "Set 1 done. Rest two thirty.")
    #expect(engine.session.sets[0].reps == 8 && engine.session.sets[0].repCount.source == .plan && engine.session.sets[0].repCount.status == .counting)
    let fallback = engine.tick(now: t0.addingTimeInterval(80))
    #expect(fallback.speech == "Next, 225 for 8." && fallback.echo == "Set 1: 8 reps (Plan)")
    let sam = engine.measured(setId: engine.session.sets[0].id, measured(7, confidence: 0.9), now: t0.addingTimeInterval(90))
    #expect(sam.speech == "Set 1 updated: 7, measured." && engine.session.sets[0].repCount.source == .measured)
}

@Test @MainActor func voiceOnlySetKeepsTheFullSetEndLine() {
    let engine = SessionEngine(day: upperA, weekNumber: 1)
    engine.setStarted(at: t0)
    let out = engine.setEnded(at: t0.addingTimeInterval(20), phone: phone(6))
    #expect(out.speech == "6 reps, 2 short of plan. Next, 225 for 8. Rest two thirty.")
    #expect(engine.session.sets[0].repCount.status == .done && engine.pendingCounts.isEmpty)
    engine.skipRest(); engine.setStarted(at: t0.addingTimeInterval(200))
    let plan = engine.setEnded(at: t0.addingTimeInterval(220), phone: nil)
    #expect(plan.speech == "Set 2 done. Next, 225 for 8. Rest two thirty.")
}

@Test @MainActor func samArrivingDuringTheNextSetLandsAtTheNextRestOnlyIfItMatters() {
    let engine = SessionEngine(day: upperA, weekNumber: 1)
    engine.setStarted(at: t0); engine.setEnded(at: t0.addingTimeInterval(20), phone: phone(8), willMeasure: true)
    let first = engine.session.sets[0].id
    engine.skipRest()
    engine.setStarted(at: t0.addingTimeInterval(50))
    #expect(engine.tick(now: t0.addingTimeInterval(100)) == .none)   // never speaks during a set
    let held = engine.measured(setId: first, measured(7, confidence: 0.9), now: t0.addingTimeInterval(55))
    #expect(held == .none && engine.session.sets[0].reps == 8 && engine.heldMeasurements.count == 1)
    let out = engine.setEnded(at: t0.addingTimeInterval(70), phone: phone(8), willMeasure: true)
    #expect(engine.session.sets[0].reps == 7 && engine.session.sets[0].repCount.source == .measured && engine.heldMeasurements.isEmpty)
    #expect(out.speech == "Set 2 done. Rest two thirty. Set 1: 7, measured.")   // nothing had been said about set 1
    #expect(engine.pendingCounts.map(\.setId) == [engine.session.sets[1].id])

    // Set 2's SAM count arrives during set 3 with the same number: the chip changes, nothing is said.
    let second = engine.session.sets[1].id
    engine.skipRest(); engine.setStarted(at: t0.addingTimeInterval(100))
    engine.measured(setId: second, measured(8, confidence: 0.9), now: t0.addingTimeInterval(105))
    let third = engine.setEnded(at: t0.addingTimeInterval(120), phone: phone(8), willMeasure: true)
    #expect(third.speech == "Set 3 done. Rest two thirty. Set 2: 8, measured.")   // never said before, so said once
    #expect(engine.session.sets[1].repCount.source == .measured)
    // Set 3's count comes with the next exercise's target.
    let sam3 = engine.measured(setId: engine.session.sets[2].id, measured(8, confidence: 0.9), now: t0.addingTimeInterval(140))
    #expect(sam3.speech == "8 reps, measured. Slowed 38 percent, about 1 left by the measure. Next exercise, Barbell row, 165 for 8–10.")
}

@Test @MainActor func fallbackSpokenCountThenSamDuringTheNextSetIsMentionedOnlyIfChanged() {
    let engine = SessionEngine(day: upperA, weekNumber: 1)
    engine.setStarted(at: t0); engine.setEnded(at: t0.addingTimeInterval(20), phone: phone(8), willMeasure: true)
    let first = engine.session.sets[0].id
    engine.tick(now: t0.addingTimeInterval(80))                       // "8 reps" spoken at 60 s
    engine.skipRest(); engine.setStarted(at: t0.addingTimeInterval(100))
    engine.measured(setId: first, measured(7, confidence: 0.9), now: t0.addingTimeInterval(110))
    let out = engine.setEnded(at: t0.addingTimeInterval(120), phone: phone(8), willMeasure: true)
    #expect(out.speech == "Set 2 done. Rest two thirty. Set 1 updated: 7, measured.")
    #expect(engine.session.sets[0].reps == 7)
}

@Test @MainActor func uploadFailureDuringTheNextSetIsSpokenAtTheNextRest() {
    let engine = SessionEngine(day: upperA, weekNumber: 1)
    engine.setStarted(at: t0); engine.setEnded(at: t0.addingTimeInterval(20), phone: phone(8), willMeasure: true)
    let first = engine.session.sets[0].id
    engine.skipRest(); engine.setStarted(at: t0.addingTimeInterval(30))
    #expect(engine.countFailed(setId: first) == .none)   // mid-set: wait
    #expect(engine.session.sets[0].repCount.status == .failed)
    engine.setEnded(at: t0.addingTimeInterval(50), phone: phone(8), willMeasure: true)
    let out = engine.tick(now: t0.addingTimeInterval(51))
    #expect(out.speech == "Set 1: 8." && engine.pendingCounts.count == 1)   // set 2 still pending
}

@Test @MainActor func lastSetOfTheSessionIsCountedAfterTheEnd() {
    let shortDay = ProgramDay(id: "d", name: "D", exercises: [PlannedExercise(id: "e", name: "E", sets: [set(5, 100)], restSeconds: nil, notes: nil)])
    let engine = SessionEngine(day: shortDay, weekNumber: 1)
    engine.setStarted(at: t0)
    let out = engine.setEnded(at: t0.addingTimeInterval(20), phone: phone(5), willMeasure: true)
    #expect(out.speech == "Set 1 done. That's the session." && engine.state == .ended)
    let sam = engine.measured(setId: engine.session.sets[0].id, measured(5, confidence: 0.9), now: t0.addingTimeInterval(40))
    #expect(sam.speech == "5 reps, measured. Slowed 38 percent, about 1 left by the measure." && engine.session.sets[0].repCount.source == .measured)
}

@Test @MainActor func undoingALoggedSetDropsItsPendingCount() {
    let engine = SessionEngine(day: upperA, weekNumber: 1)
    engine.setStarted(at: t0); engine.setEnded(at: t0.addingTimeInterval(20), phone: phone(8), willMeasure: true)
    engine.undo()
    #expect(engine.session.sets.isEmpty && engine.pendingCounts.isEmpty)
    #expect(engine.tick(now: t0.addingTimeInterval(200)) == .none)
}

@Test func countResponseDecodesWithoutTheSpeedFields() throws {
    let old = Data("{\"reps\":8,\"repTimes\":[1,2],\"confidence\":0.9,\"trackFound\":true,\"frames\":300,\"trackedFrames\":300,\"prompt\":\"weight plate\"}".utf8)
    let r = try JSONCoding.decoder.decode(CountResponse.self, from: old)
    #expect(r.reps == 8 && r.repSpeeds.isEmpty && r.velocityLossPct == nil)
    let new = Data("{\"reps\":3,\"repTimes\":[1,2,3],\"repSpeeds\":[300,280,150],\"velocityLossPct\":28.3,\"confidence\":0.9,\"trackFound\":true,\"frames\":300,\"trackedFrames\":300,\"prompt\":\"dumbbell\"}".utf8)
    let r2 = try JSONCoding.decoder.decode(CountResponse.self, from: new)
    #expect(r2.repSpeeds == [300, 280, 150] && r2.velocityLossPct == 28.3)
    let ctx = try JSONCoding.encoder.encode(CountContext(exerciseId: "e", equipment: .barbell, plannedReps: 8, phoneReps: 8, setRole: "top"))
    #expect(String(decoding: ctx, as: UTF8.self).contains("\"setRole\" : \"top\""))
}

// MARK: - Coach cues (HANDOFF.md §7, Coach voice cues)

private func cue(_ exerciseId: String) -> VoiceCue {
    VoiceCue(id: "cue-\(exerciseId)", replyId: UUID(), exerciseId: exerciseId, text: "Pause at the bottom.", audioFile: nil, startSec: nil, endSec: nil, approved: true, lastPlayedAt: nil)
}

@Test @MainActor func cuePlaysInReadyBeforeTheFirstSetOnceAndNeverDuringASet() {
    let engine = SessionEngine(day: upperA, weekNumber: 1)
    engine.cues = ["bench": cue("bench"), "row": cue("row")]
    let due = engine.cueDue()
    #expect(due?.exerciseId == "bench")
    engine.cuePlayed(due!)
    #expect(engine.cueDue() == nil)                       // once
    engine.setStarted()
    #expect(engine.cueDue() == nil)                       // never during a set
    engine.setEnded(phone: nil)
    engine.skipRest()
    #expect(engine.cueDue() == nil)                       // bench already has a set logged
    for _ in 0..<2 { engine.setStarted(); engine.setEnded(); engine.skipRest() }
    #expect(engine.currentExercise?.id == "row" && engine.cueDue()?.exerciseId == "row")
    engine.cuePlayed(engine.cueDue()!)
    #expect(engine.lastEcho == "Coach · Barbell row")
    // "Say that again" replays the last cue, but not mid-set.
    #expect(engine.cueToReplay()?.exerciseId == "row")
    #expect(engine.apply(intent(.replayCue)).echo == "Replaying the coach's cue")
    engine.setStarted()
    #expect(engine.cueToReplay() == nil)
}

@Test @MainActor func unapprovedCueNeverPlays() {
    let engine = SessionEngine(day: upperA, weekNumber: 1)
    var c = cue("bench")
    c.approved = false
    engine.cues = ["bench": c]
    #expect(engine.cueDue() == nil)
    #expect(engine.apply(intent(.replayCue)).speech == "No cue to replay.")
}

// MARK: - His real sheet (HANDOFF.md §7): warm-ups, timed sets, rest-pause sets, add-ons

private func planned(_ reps: Int?, min: Int? = nil, max: Int? = nil, seconds: Int? = nil, total: Int? = nil, role: SetRole? = nil) -> PlannedSet {
    PlannedSet(reps: reps, repsMin: min, repsMax: max, loadLb: nil, rpe: nil, rir: nil, seconds: seconds, totalReps: total, role: role)
}

private let day1 = ProgramDay(id: "d1", name: "Day 1", exercises: [
    PlannedExercise(id: "bike", name: "Stationary Bike", sets: [planned(nil, seconds: 300)], restSeconds: nil, notes: nil),
    PlannedExercise(id: "incline", name: "Incline DB Press", sets: [planned(nil, min: 6, max: 8, role: .top), planned(nil, min: 6, max: 8, role: .backOff)], restSeconds: 180, restMinSeconds: 90, notes: nil),
    PlannedExercise(id: "pec", name: "Pec Deck", sets: [planned(nil, total: 20, role: .restPause)], restSeconds: 180, notes: nil),
])
private let abs = AddOn(id: "addon_abs", name: "Abs", exercises: [
    PlannedExercise(id: "raises", name: "Hanging Leg Raises", sets: [planned(12), planned(12)], restSeconds: nil, notes: nil),
    PlannedExercise(id: "plank", name: "Plank", sets: [planned(nil, seconds: 60), planned(nil, seconds: 60)], restSeconds: nil, notes: nil),
], perWeek: 2, timing: .withSession, quote: "Complete this 2x per week:")
private let vacuums = AddOn(id: "addon_vac", name: "Stomach Vacuums", exercises: [
    PlannedExercise(id: "vac", name: "Stomach Vacuums", sets: Array(repeating: planned(nil, seconds: 20), count: 4), restSeconds: nil, notes: nil),
], perWeek: 4, timing: .onWaking, quote: "Complete these 4x per week upon waking:")
private let hisWarmups = WarmupRule(minSets: 1, maxSets: 3, maxReps: 8, quote: "1-3 warm up sets of no more than 6-8 reps", confirmed: true)

private func easy(_ reps: Int, slowdown: Double = 5) -> RepCounter.Result {
    var r = phone(reps)
    r.velocityLossPct = slowdown
    return r
}

@Test @MainActor func aTimedSetIsACountdownThatLogsItsSeconds() {
    let engine = SessionEngine(day: day1, weekNumber: 1, warmups: hisWarmups)
    #expect(engine.currentSetIsTimed && engine.targetRepsText == "5 min" && !engine.warmupMode)
    let go = engine.setStarted(at: t0)
    #expect(engine.state == .hold(remaining: 300) && go.echo == "Stationary Bike · five minutes")
    #expect(engine.tickHold(at: t0.addingTimeInterval(1)) == .none && engine.state == .hold(remaining: 299))
    for _ in 0..<288 { engine.tickHold() }
    #expect(engine.tickHold().speech == "10 seconds." && engine.state == .hold(remaining: 10))
    for _ in 0..<9 { engine.tickHold() }
    let time = engine.tickHold(at: t0.addingTimeInterval(300))
    #expect(time.speech == "Time. Next exercise, Incline DB Press, 6–8 reps. Warm-ups first. Weight for the top set? Rest thirty seconds.")
    let set = engine.session.sets[0]
    #expect(set.seconds == 300 && set.reps == 0 && set.exerciseId == "bike" && set.repCount.status == .done)
    #expect(engine.state == .rest(remaining: 30) && engine.currentExercise?.id == "incline" && engine.warmupMode)
}

@Test @MainActor func doneEndsAHoldEarlyAndLogsHowLongItRan() {
    let engine = SessionEngine(day: nil, addOns: [vacuums], weekNumber: 1)
    #expect(engine.title == "Stomach Vacuums" && engine.session.programDayId == nil && engine.session.addOnIds == ["addon_vac"])
    engine.apply(intent(.starting))
    for _ in 0..<8 { engine.tickHold() }
    let out = engine.apply(intent(.endSet, transcript: "done"))
    #expect(out.speech == "Eight seconds logged. Next, 20 s. Rest thirty seconds.")
    #expect(engine.session.sets[0].seconds == 8 && engine.setNumber == 2)
    // The whole morning session: four holds, hands-free, no camera.
    engine.skipRest()
    for n in 1...3 {
        engine.apply(intent(.starting))
        for _ in 0..<20 { engine.tickHold() }
        if n < 3 { engine.skipRest() }
    }
    #expect(engine.state == .ended && engine.session.sets.count == 4 && engine.session.sets.last?.seconds == 20)
}

@Test @MainActor func warmupModeLogsEasyShortSetsAsWarmupsThatNeverCount() {
    let engine = SessionEngine(day: day1, weekNumber: 1, warmups: hisWarmups)
    engine.apply(intent(.skipSet)) // past the bike
    #expect(engine.currentExercise?.id == "incline" && engine.warmupMode && engine.setNumber == 1)
    engine.setStarted(at: t0)
    let w1 = engine.setEnded(at: t0.addingTimeInterval(15), phone: easy(6), willMeasure: true)
    #expect(w1.speech == "Warm-up 1. Rest three minutes.")
    #expect(engine.session.sets[0].role == .warmup && engine.session.sets[0].repCount.status == .done && engine.pendingCounts.isEmpty)
    #expect(engine.setNumber == 1 && engine.warmupCount == 1 && engine.session.workingSets.isEmpty)
    #expect(!engine.shouldUpload(setId: engine.session.sets[0].id))
    engine.skipRest()
    engine.setStarted(at: t0.addingTimeInterval(100))
    // Eight reps with a real slowdown: the top set, measured.
    let top = engine.setEnded(at: t0.addingTimeInterval(130), phone: easy(8, slowdown: 35), willMeasure: true)
    #expect(top.speech == "Set 1 done. Rest three minutes.")
    #expect(engine.session.sets[1].role == .top && engine.session.sets[1].repCount.status == .counting && !engine.warmupMode)
    #expect(engine.setNumber == 2 && engine.currentPlannedSet?.role == .backOff)
    // Nine reps is never a warm-up, whatever the slowdown; the plan's reps (no count) never are either.
    #expect(!SessionEngine.looksLikeWarmup(reps: 9, source: .phone, phone: easy(9), maxReps: 8))
    #expect(!SessionEngine.looksLikeWarmup(reps: 8, source: .plan, phone: nil, maxReps: 8))
    #expect(SessionEngine.looksLikeWarmup(reps: 5, source: .spoken, phone: nil, maxReps: 8))
}

@Test @MainActor func topSetAndThatWasAWarmupFixTheClassificationEitherWayWithUndo() {
    let engine = SessionEngine(day: day1, weekNumber: 1, warmups: hisWarmups)
    engine.apply(intent(.skipSet))
    // "Top set" before the set: the next set is the top set whatever the count.
    let next = engine.apply(intent(.topSet, transcript: "top set"))
    #expect(next.speech == "Top set next." && !engine.warmupMode)
    engine.setStarted(at: t0)
    engine.setEnded(at: t0.addingTimeInterval(20), phone: easy(5), willMeasure: true)
    #expect(engine.session.sets[0].role == .top && engine.setNumber == 2)
    // "That was a warm-up": the set becomes a warm-up, the counter moves back, SAM is not waited for.
    let fix = engine.apply(intent(.warmup, transcript: "that was a warm-up"))
    #expect(fix.speech == "Warm-up. Set 1 is next." && engine.session.sets[0].isWarmup && engine.setNumber == 1 && engine.warmupMode)
    #expect(engine.pendingCounts.isEmpty && engine.session.sets[0].repCount.status == .done)
    // "That was my top set": back to the working set, and its clip goes to SAM now.
    let back = engine.apply(intent(.topSet, transcript: "that was my top set"))
    #expect(back.speech == "Set 1 logged." && engine.session.sets[0].role == .top && engine.setNumber == 2)
    #expect(engine.setsNeedingUpload() == [engine.session.sets[0].id] && engine.session.sets[0].repCount.status == .counting)
    engine.undo()
    #expect(engine.session.sets[0].isWarmup && engine.setNumber == 1)
    // "Top set" during a set forces a working set.
    engine.setStarted(at: t0.addingTimeInterval(200))
    engine.apply(intent(.topSet, transcript: "top set"))
    engine.setEnded(at: t0.addingTimeInterval(215), phone: easy(4), willMeasure: true)
    #expect(engine.session.sets[1].role == .top)
}

@Test @MainActor func withoutHisWarmupRuleEverySetIsAWorkingSet() {
    let engine = SessionEngine(day: day1, weekNumber: 1)
    engine.apply(intent(.skipSet))
    #expect(!engine.warmupMode)
    engine.setStarted(at: t0)
    engine.setEnded(at: t0.addingTimeInterval(15), phone: easy(6), willMeasure: true)
    #expect(engine.session.sets[0].role == .top && engine.setNumber == 2)
    let unconfirmed = SessionEngine(day: day1, weekNumber: 1, warmups: WarmupRule(minSets: 1, maxSets: 3, maxReps: 8, quote: nil, confirmed: false))
    unconfirmed.apply(intent(.skipSet))
    #expect(!unconfirmed.warmupMode)
}

@Test @MainActor func aRestPauseSetCountsItsTotalAndSendsItsRole() {
    let engine = SessionEngine(day: day1, weekNumber: 1)
    engine.apply(intent(.nextExercise)); engine.apply(intent(.nextExercise))
    #expect(engine.currentExercise?.id == "pec" && engine.currentSetIsRestPause && engine.targetRepsText == "20 total")
    engine.setStarted(at: t0)
    engine.setEnded(at: t0.addingTimeInterval(90), phone: phone(22), willMeasure: true)
    #expect(engine.session.sets[0].role == .restPause)
    let sam = engine.measured(setId: engine.session.sets[0].id, measured(22, confidence: 0.9, velocityLoss: nil), now: t0.addingTimeInterval(120))
    #expect(sam.speech == "Rest-pause: 22 total, measured.")
    #expect(engine.session.sets[0].repCount.velocityLossPct == nil && engine.state == .ended)
}

@Test @MainActor func addOnsJoinAfterTheLastLiftUnderTheirOwnName() {
    let engine = SessionEngine(day: day1, addOns: [abs], weekNumber: 1)
    #expect(engine.exercises.count == 5 && engine.exercises[3].section == "Abs" && engine.session.addOnIds == ["addon_abs"])
    engine.apply(intent(.nextExercise)); engine.apply(intent(.nextExercise))
    engine.setStarted(at: t0)
    let out = engine.setEnded(at: t0.addingTimeInterval(60), phone: phone(20))
    #expect(out.speech == "20 total. Next, Abs. Hanging Leg Raises, 12 reps. Rest three minutes.")
    #expect(engine.currentEntry?.section == "Abs" && engine.currentExercise?.id == "raises")
}

@Test @MainActor func addAbsAndSkipAbsChangeTodayOnly() {
    let engine = SessionEngine(day: day1, availableAddOns: [abs], weekNumber: 1)
    #expect(engine.exercises.count == 3)
    let added = engine.apply(intent(.addAddOn, text: "abs", transcript: "add abs"))
    #expect(added.speech == "Adding abs today." && engine.exercises.count == 5 && engine.session.addOnIds == ["addon_abs"])
    #expect(engine.apply(intent(.addAddOn, text: "abs")).speech == "Abs is already in today's session.")
    let skipped = engine.apply(intent(.skipAddOn, text: "abs", transcript: "skip abs"))
    #expect(skipped.speech == "Skipping abs today." && engine.exercises.count == 3 && engine.session.addOnIds.isEmpty)
    #expect(engine.apply(intent(.addAddOn, text: "calves")).speech == "No add-on called calves.")
    engine.undo()
    #expect(engine.exercises.count == 5 && engine.session.addOnIds == ["addon_abs"])
    // "Add abs" once the day's lifts are done reopens the session.
    let done = SessionEngine(day: day1, availableAddOns: [abs], weekNumber: 1)
    for _ in 0..<3 { done.apply(intent(.nextExercise)) }
    #expect(done.state == .ended)
    done.apply(intent(.addAddOn, text: "abs"))
    #expect(done.state == .ready && done.currentExercise?.id == "raises" && done.session.endedAt == nil)
}

@Test @MainActor func changeDayAndFlagThat() {
    let engine = SessionEngine(day: day1, weekNumber: 1)
    let change = engine.apply(intent(.changeDay, 5, transcript: "I'm doing day 5 today"))
    #expect(change.echo == "Switching to Day 5. Say undo to revert." && engine.requestedDayNumber == 5)
    engine.apply(intent(.skipSet))
    engine.setStarted(at: t0); engine.setEnded(at: t0.addingTimeInterval(20), phone: phone(8))
    #expect(engine.apply(intent(.changeDay, 2)).speech == "Too late to change the day.")
    let flag = engine.apply(intent(.flagSet, transcript: "flag that"))
    #expect(flag.speech == "Flagged for Thursday." && engine.session.sets[0].flaggedForCoach)
    engine.undo()
    #expect(!engine.session.sets[0].flaggedForCoach)
}

@Test @MainActor func dayLevelRestRangeGetsAQuietCueAtItsBottom() {
    let engine = SessionEngine(day: day1, weekNumber: 1)
    engine.apply(intent(.skipSet))
    engine.setStarted(at: t0); engine.setEnded(at: t0.addingTimeInterval(20), phone: phone(8))
    #expect(engine.state == .rest(remaining: 180))
    var cue: SessionEngine.Outcome = .none
    for _ in 0..<90 { cue = engine.tickRest() }
    #expect(cue.speech == "Ready when you are." && engine.state == .rest(remaining: 90))
}

@Test func plannedSetAndExerciseTextForTheRealSheet() {
    #expect(planned(nil, seconds: 20).repsText == "20 s" && planned(nil, seconds: 300).repsText == "5 min")
    #expect(planned(nil, total: 20, role: .restPause).repsText == "20 total")
    #expect(day1.exercises[1].summary == "2 × 6–8 · top + back-off")
    #expect(day1.exercises[2].summary == "1 × 20 total · rest-pause")
    #expect(vacuums.exercises[0].summary == "4 × 20 s")
    #expect(day1.exercises[0].hasWarmups == false && day1.exercises[1].hasWarmups)
}

// MARK: - Measured effort and his rules (HANDOFF.md §7)

private let failureTargets = [RoleTarget(role: .top, rir: 0, source: "Coach's instructions", quote: "to failure", confirmed: true),
                              RoleTarget(role: .backOff, rir: 0, source: "Coach's instructions", quote: "to failure", confirmed: true)]
private let backOffRule = ProgressionRule(id: "rule_1", appliesTo: nil, when: .afterTopSet, byRPE: nil, adjust: .backOff, amount: nil, minPct: 20, maxPct: 25,
                                          scope: .nextSet, source: "Coach's instructions", quote: "Back down sets are 20-25% lighter than your top set. Beat the logbook every week.", confirmed: true)
private let topRest = RestRule(after: .top, minSeconds: 180, maxSeconds: 240, quote: "Rest 3-4 minutes after a top set", confirmed: true)

@Test @MainActor func aTopSetGetsItsMeasuredLineAgainstHisFailureTargetAndABackOffFromHisRule() {
    let engine = SessionEngine(day: day1, weekNumber: 1, rules: [backOffRule], roleTargets: failureTargets, restRules: [topRest],
                               lastSets: ["incline|top": LastSet(loadLb: 80, reps: 9)])
    engine.apply(intent(.skipSet))
    #expect(engine.targetLoadLb == 80)   // no planned load: last time's for the same exercise and role
    #expect(engine.logbookLine(for: engine.currentExercise!) == "Last time 80 for 9. Beat the logbook.")
    engine.setStarted(at: t0)
    engine.setEnded(at: t0.addingTimeInterval(30), phone: phone(11), willMeasure: true)
    #expect(engine.state == .rest(remaining: 240))   // his 3–4 minutes after a top set
    let out = engine.measured(setId: engine.session.sets[0].id, measured(11, confidence: 0.9, velocityLoss: 46), now: t0.addingTimeInterval(60))
    #expect(out.speech == "Top set: 11 reps, measured. Slowed 46 percent, that's failure. Back-off at 60, his rule: 20–25% lighter than the top set. Say 'go with it' or a weight.")
    #expect(engine.session.sets[0].repCount.estimatedRIR == 0)
    #expect(engine.pendingSuggestion?.toLb == 60 && engine.pendingSuggestion?.role == .backOff && engine.session.suggestions.count == 1)
    #expect(out.spotterFacts?.target == "failure" && out.spotterFacts?.suggestionLb == 60 && out.spotterFacts?.isPR == true)
    #expect(out.spotterReplaceable == "Top set: 11 reps, measured. Slowed 46 percent, that's failure.")
    // "Go with it": the back-off set's target is his rule's load, logged as accepted.
    let go = engine.apply(intent(.acceptSuggestion, transcript: "go with it"))
    #expect(go.speech == "60 it is." && engine.targetLoadLb == 60 && engine.session.suggestions[0].decision == .accepted && engine.pendingSuggestion == nil)
    // The quiet cue three minutes into the 4:00 rest, with a minute left.
    var cue: SessionEngine.Outcome = .none
    for _ in 0..<180 { cue = engine.tickRest() }
    #expect(cue.speech == "Ready when you are." && engine.state == .rest(remaining: 60))
}

@Test @MainActor func keepItAndAWeightOfHisOwnAndNoAnswerAreAllLogged() {
    let engine = SessionEngine(day: day1, weekNumber: 1, rules: [backOffRule], roleTargets: failureTargets, lastSets: ["incline|top": LastSet(loadLb: 80, reps: 9)])
    engine.apply(intent(.skipSet))
    engine.setStarted(at: t0); engine.setEnded(at: t0.addingTimeInterval(30), phone: phone(10), willMeasure: true)
    engine.measured(setId: engine.session.sets[0].id, measured(10, confidence: 0.9, velocityLoss: 40), now: t0.addingTimeInterval(60))
    let keep = engine.apply(intent(.keepLoad, transcript: "keep it"))
    #expect(keep.speech == "Keeping 80." && engine.session.suggestions[0].decision == .kept && engine.targetLoadLb == 80)
    // A weight of his own while a suggestion is pending: his number, and the suggestion is kept, not taken.
    let e2 = SessionEngine(day: day1, weekNumber: 1, rules: [backOffRule], roleTargets: failureTargets, lastSets: ["incline|top": LastSet(loadLb: 80, reps: 9)])
    e2.apply(intent(.skipSet))
    e2.setStarted(at: t0); e2.setEnded(at: t0.addingTimeInterval(30), phone: phone(10), willMeasure: true)
    e2.measured(setId: e2.session.sets[0].id, measured(10, confidence: 0.9, velocityLoss: 40), now: t0.addingTimeInterval(60))
    e2.apply(intent(.setLoad, 65, transcript: "sixty five"))
    #expect(e2.targetLoadLb == 65 && e2.session.suggestions[0].decision == .kept)
    // No answer: the next set starts, the suggestion is kept.
    let e3 = SessionEngine(day: day1, weekNumber: 1, rules: [backOffRule], roleTargets: failureTargets, lastSets: ["incline|top": LastSet(loadLb: 80, reps: 9)])
    e3.apply(intent(.skipSet))
    e3.setStarted(at: t0); e3.setEnded(at: t0.addingTimeInterval(30), phone: phone(10), willMeasure: true)
    e3.measured(setId: e3.session.sets[0].id, measured(10, confidence: 0.9, velocityLoss: 40), now: t0.addingTimeInterval(60))
    e3.skipRest(); e3.setStarted(at: t0.addingTimeInterval(300)); e3.setEnded(at: t0.addingTimeInterval(330), phone: phone(8))
    #expect(e3.session.suggestions[0].decision == .kept && e3.pendingSuggestion == nil)
}

@Test @MainActor func nothingIsSuggestedWithoutAConfirmedRuleButTheEffortIsStillSaid() {
    var unconfirmed = backOffRule
    unconfirmed.confirmed = false
    let engine = SessionEngine(day: day1, weekNumber: 1, rules: [unconfirmed], roleTargets: failureTargets, lastSets: ["incline|top": LastSet(loadLb: 80, reps: 9)])
    engine.apply(intent(.skipSet))
    engine.setStarted(at: t0); engine.setEnded(at: t0.addingTimeInterval(30), phone: phone(8), willMeasure: true)
    let out = engine.measured(setId: engine.session.sets[0].id, measured(8, confidence: 0.9, velocityLoss: 25), now: t0.addingTimeInterval(60))
    #expect(out.speech == "Top set: 8 reps, measured. Slowed 25 percent, about 2 left by the measure. His target is failure. Next, 6–8 reps.")
    #expect(engine.pendingSuggestion == nil && engine.session.suggestions.isEmpty && engine.session.sets[0].repCount.estimatedRIR == 2)
    // The switch off: effort still measured, nothing suggested.
    let off = SessionEngine(day: day1, weekNumber: 1, rules: [backOffRule], roleTargets: failureTargets, lastSets: ["incline|top": LastSet(loadLb: 80, reps: 9)], suggestionsEnabled: false)
    off.apply(intent(.skipSet))
    off.setStarted(at: t0); off.setEnded(at: t0.addingTimeInterval(30), phone: phone(8), willMeasure: true)
    off.measured(setId: off.session.sets[0].id, measured(8, confidence: 0.9, velocityLoss: 46), now: t0.addingTimeInterval(60))
    #expect(off.pendingSuggestion == nil && off.session.sets[0].repCount.estimatedRIR == 0)
}

@Test @MainActor func aSpokenRPEWinsAndFeedsTheCalibration() {
    let engine = SessionEngine(day: day1, weekNumber: 1, rules: [backOffRule], roleTargets: failureTargets, lastSets: ["incline|top": LastSet(loadLb: 80, reps: 9)])
    engine.apply(intent(.skipSet))
    engine.setStarted(at: t0); engine.setEnded(at: t0.addingTimeInterval(30), phone: phone(8), willMeasure: true)
    engine.measured(setId: engine.session.sets[0].id, measured(8, confidence: 0.9, velocityLoss: 25), now: t0.addingTimeInterval(60))
    engine.apply(intent(.rpe, 9, transcript: "felt like a 9"))
    #expect(engine.calibrationSamples.count == 1 && engine.calibrationSamples[0].velocityLossPct == 25 && engine.calibrationSamples[0].rpe == 9)
    #expect(engine.session.sets[0].rpe == 9 && engine.session.sets[0].repCount.estimatedRIR == 2)   // the measure stays on record
}

@Test @MainActor func aSheetWithNoLoadAndNoHistoryAsksForTheWeight() {
    let engine = SessionEngine(day: day1, weekNumber: 1)
    engine.apply(intent(.skipSet))
    #expect(engine.needsLoad && engine.targetLoadLb == nil)
    let out = engine.apply(intent(.answer, 70, transcript: "seventy"))
    #expect(out.speech == "Load 70." && engine.targetLoadLb == 70 && !engine.needsLoad)
    // A next-session step accepted last time is the starting load now.
    let stepped = SessionEngine(day: day1, weekNumber: 1, lastSets: ["incline|top": LastSet(loadLb: 80, reps: 9)], nextSessionLoads: ["incline|top": 85])
    stepped.apply(intent(.skipSet))
    #expect(stepped.targetLoadLb == 85)
}

@Test @MainActor func aVoiceOnlySetGetsItsEffortAndSuggestionAtOnce() {
    let rpeRule = ProgressionRule(id: "r", appliesTo: nil, when: .aboveTarget, byRPE: 1, adjust: .percent, amount: -5, minPct: nil, maxPct: nil,
                                  scope: .nextSet, source: "Sheet note", quote: "if RPE is over 9, drop 5%", confirmed: true)
    let engine = SessionEngine(day: upperA, weekNumber: 1, rules: [rpeRule])
    engine.setStarted(at: t0)
    engine.apply(intent(.reps, 8, transcript: "that was 8"))
    engine.setEnded(at: t0.addingTimeInterval(30), phone: nil)
    engine.apply(intent(.rpe, 9.5, transcript: "felt like a 9 and a half"))
    #expect(engine.pendingSuggestion == nil)   // the RPE came after the set: the next voice-only set carries it
    engine.skipRest(); engine.setStarted(at: t0.addingTimeInterval(200))
    engine.apply(intent(.reps, 8, transcript: "that was 8"))
    let out = engine.setEnded(at: t0.addingTimeInterval(230), phone: nil)
    #expect(out.speech?.contains("8 reps.") == true)
}
