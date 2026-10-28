import CoreGraphics
import Foundation
import Testing
@testable import Setecho

/// Sets start on his word, and the camera follows only him (HANDOFF.md §7). Oct 28 gym test: other
/// people moving were recorded as his sets.

private func set(_ reps: Int, _ load: Double) -> PlannedSet {
    PlannedSet(reps: reps, repsMin: nil, repsMax: nil, loadLb: load, rpe: nil, rir: nil)
}

private let day = ProgramDay(id: "d1", name: "Day 1", exercises: [
    PlannedExercise(id: "bench", name: "Bench press", sets: [set(8, 225), set(8, 225)], restSeconds: 150, notes: nil),
])

private func go(_ transcript: String = "go") -> VoiceCommandResponse {
    VoiceCommandResponse(transcript: transcript, intent: VoiceIntent(intent: .starting, confidence: 0.95), classifiedBy: "rules")
}

@MainActor
private func tripodEngine() -> SessionEngine {
    let engine = SessionEngine(day: day, weekNumber: 1)
    engine.cameraOnDuty = true
    engine.usesArming = true
    return engine
}

@Test @MainActor func movementBeforeHeArmsStartsNothing() {
    let engine = tripodEngine()
    #expect(engine.cameraStarted() == .none)
    #expect(engine.state == .ready && engine.session.sets.isEmpty)
}

@Test @MainActor func goArmsAndHisMovementStartsTheSet() {
    let engine = tripodEngine()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let armed = engine.apply(go(), now: t0)
    #expect(engine.isArmed && engine.state == .ready)
    #expect(armed.speech == nil && armed.echo != nil) // the chime and the HUD, nothing spoken
    engine.cameraStarted(at: t0.addingTimeInterval(4))
    #expect(engine.state == .recording && !engine.isArmed)
    engine.setEnded(at: t0.addingTimeInterval(40))
    #expect(engine.session.sets.count == 1)
    // The next set needs its own "go".
    engine.skipRest()
    #expect(engine.cameraStarted(at: t0.addingTimeInterval(200)) == .none)
}

@Test @MainActor func anArmWithNoMovementLapsesSilentlyAfterTwentySeconds() {
    let engine = tripodEngine()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    engine.apply(go("here we go"), now: t0)
    engine.tickArm(at: t0.addingTimeInterval(19))
    #expect(engine.isArmed)
    engine.tickArm(at: t0.addingTimeInterval(20))
    #expect(!engine.isArmed)
    #expect(engine.cameraStarted(at: t0.addingTimeInterval(25)) == .none)
    #expect(engine.state == .ready)
}

@Test @MainActor func forgetToArmAndDoneNineStillLogsTheSet() {
    let engine = tripodEngine()
    let done = VoiceCommandResponse(transcript: "done, 9", intent: VoiceIntent(intent: .endSet, number: 9, confidence: 0.95), classifiedBy: "rules")
    engine.apply(done)
    #expect(engine.session.sets.count == 1 && engine.session.sets[0].reps == 9)
    #expect(engine.session.sets[0].repCount.source == .spoken)
}

@Test @MainActor func inAPocketGoStartsTheSetAtOnce() {
    let engine = SessionEngine(day: day, weekNumber: 1)
    engine.apply(go())
    #expect(engine.state == .recording)
}

@Test @MainActor func cameraStartsSetsLetsAnyMovementStartOne() {
    let engine = tripodEngine()
    engine.cameraStartsSets = true
    engine.cameraStarted()
    #expect(engine.state == .recording)
}

@Test @MainActor func theFirstSessionsEndEachRestWithSayGo() {
    let engine = tripodEngine()
    engine.armReminder = true
    engine.apply(go())
    engine.cameraStarted()
    engine.setEnded()
    var said: [String] = []
    for _ in 0..<150 { if let s = engine.tickRest().speech { said.append(s) } }
    #expect(said.last == "Say go when you lift.")
    #expect(engine.intro.hasSuffix("Say go when you lift."))
}

// MARK: Lock-on

private func body(x: Double, y: Double = 0.3, w: Double = 0.3, h: Double = 0.5, wrist: Double) -> BodyTracker.Body {
    BodyTracker.Body(box: CGRect(x: x, y: y, width: w, height: h), joints: ["left_wrist": wrist, "right_wrist": wrist])
}

@Test func heIsTheLargestBodyNearestTheCentre() {
    var tracker = BodyTracker()
    let him = body(x: 0.35, w: 0.3, h: 0.6, wrist: 0.5)
    let farAway = body(x: 0.0, y: 0.1, w: 0.15, h: 0.3, wrist: 0.5)
    let (picked, _) = tracker.lock([farAway, him], at: 0)
    #expect(picked == him)
}

@Test func withTwoBodiesTheOtherPersonMovingStartsNothing() {
    // The pipeline SetDetector runs: the tracker picks the body, its wrists feed the signal.
    var tracker = BodyTracker()
    var signal = WristSignal()
    var starts: [Double] = []
    _ = tracker.lock([body(x: 0.35, w: 0.3, h: 0.6, wrist: 0.5), body(x: 0.0, w: 0.2, h: 0.4, wrist: 0.5)], at: 0)
    var t = 0.0
    // 6 s: the other person curls (wrist swinging), he stands still.
    while t < 6 {
        let other = 0.5 + 0.2 * sin(t * 3)
        let picked = tracker.follow([body(x: 0.0, w: 0.2, h: 0.4, wrist: other), body(x: 0.36, w: 0.3, h: 0.6, wrist: 0.5)], at: t)
        if let y = picked?.joints["left_wrist"], case .start(_, let s) = signal.add(y: y, at: t) { starts.append(s) }
        t += 1.0 / 15
    }
    #expect(starts.isEmpty)
    // Then he lifts: only his set starts.
    while t < 10 {
        let his = 0.5 + 0.2 * sin(t * 3)
        let picked = tracker.follow([body(x: 0.0, w: 0.2, h: 0.4, wrist: 0.5), body(x: 0.35, w: 0.3, h: 0.6, wrist: his)], at: t)
        if let y = picked?.joints["left_wrist"], case .start(_, let s) = signal.add(y: y, at: t) { starts.append(s) }
        t += 1.0 / 15
    }
    #expect(starts.count == 1 && starts[0] >= 5.9)
}

@Test func theLockFollowsHimAsHeMovesAndIgnoresAPasserBy() {
    var tracker = BodyTracker()
    _ = tracker.lock([body(x: 0.35, wrist: 0.5)], at: 0)
    // He shifts a little each frame; someone walks through the frame on the far side.
    var x = 0.35
    for i in 1...30 {
        x += 0.005
        let passer = body(x: 0.95 - Double(i) * 0.02, y: 0.2, w: 0.2, h: 0.5, wrist: 0.1)
        let picked = tracker.follow([passer, body(x: x, wrist: 0.5)], at: Double(i) / 15)
        #expect(picked?.joints["left_wrist"] == 0.5)
    }
}

@Test func theCountClipIsCutToHisStationWithRoomForTheBar() {
    let boxes = [CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3), CGRect(x: 0.42, y: 0.32, width: 0.2, height: 0.3)]
    let crop = BodyTracker.cropBox(boxes)!
    #expect(crop.minX < 0.3 && crop.maxX > 0.7)        // half his size each side for the plates
    #expect(crop.contains(CGRect(x: 0.4, y: 0.3, width: 0.22, height: 0.32)))
    // A body filling the frame: no crop at all.
    #expect(BodyTracker.cropBox([CGRect(x: 0.1, y: 0.05, width: 0.8, height: 0.9)]) == nil)
}
