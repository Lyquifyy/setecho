import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Setecho

/// The live session as the session screen shows it (`SessionHUDModel(engine:live:)`).

private func set(_ reps: Int, _ load: Double, role: SetRole? = nil) -> PlannedSet {
    PlannedSet(reps: reps, repsMin: nil, repsMax: nil, loadLb: load, rpe: nil, rir: nil, role: role)
}

private let day = ProgramDay(id: "d5", name: "Day 5", exercises: [
    PlannedExercise(id: "incline", name: "Incline DB press", sets: [set(8, 80, role: .top), set(10, 65, role: .backOff)], restSeconds: 180, notes: nil),
    PlannedExercise(id: "flyes", name: "Cable incline flyes", sets: [set(12, 30), set(12, 30)], restSeconds: 90, notes: nil),
])
private let abs = AddOn(id: "abs", name: "Abs",
                        exercises: [PlannedExercise(id: "crunch", name: "Cable crunch", sets: [set(15, 50)], restSeconds: 60, notes: nil)],
                        perWeek: 2, timing: .withSession, quote: "2x per week")
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func say(_ kind: VoiceIntent.Kind, _ transcript: String, number: Double? = nil) -> VoiceCommandResponse {
    VoiceCommandResponse(transcript: transcript, intent: VoiceIntent(intent: kind, number: number, confidence: 0.95), classifiedBy: "rules")
}

private var tripod: SessionHUDModel.Live {
    SessionHUDModel.Live(micLabel: "AirPods mic", micOnHim: true, cameraRunning: true, cameraOnDuty: true, now: t0)
}

@Test func shortNamesDropTheEquipmentAndTellTwinsApart() {
    #expect(SessionHUDModel.shortNames(["Smith close-grip press", "Incline DB press", "Cable incline flyes", "Dips"])
            == ["Close-grip", "Incline press", "Incline flyes", "Dips"])
}

@Test @MainActor func readyArmedRecordingAndRestMapFromTheEngine() {
    let engine = SessionEngine(day: day, weekNumber: 1, lastSets: ["incline|top": LastSet(loadLb: 75, reps: 9)])
    engine.cameraOnDuty = true
    engine.usesArming = true
    var m = SessionHUDModel(engine: engine, live: tripod)
    #expect(m.phase == .ready && m.camera && !m.pocket)
    #expect(m.exercise == "Incline DB press" && m.role == "Top set" && m.setLabel == "set 1 of 2")
    #expect(m.load == 80 && m.reps == "8" && m.lastTime == "Last time 75 × 9")
    #expect(m.progress.map(\.name) == ["Incline press", "Incline flyes"] && m.progress[0].dots == [.current, .upcoming])

    engine.apply(say(.starting, "go"), now: t0)
    #expect(SessionHUDModel(engine: engine, live: tripod).phase == .armed)

    engine.cameraStarted(at: t0)
    var live = tripod
    live.now = t0.addingTimeInterval(24)
    #expect(SessionHUDModel(engine: engine, live: live).phase == .recording(elapsed: 24))

    engine.setEnded(at: t0.addingTimeInterval(30))
    m = SessionHUDModel(engine: engine, live: tripod)
    #expect(m.phase == .rest(remaining: 180, total: 180))
    #expect(m.progress[0].dots == [.done, .current])
    #expect(m.result.map(\.text) == ["8 reps", "Plan"] && m.result[1].source)
    #expect(m.next == "Back-off 65 × 10")
}

@Test @MainActor func theOpenAskIsTheLineUnderTheNextSet() {
    let engine = SessionEngine(day: day, weekNumber: 1)
    engine.apply(say(.endSession, "I'm done"), now: t0)
    let m = SessionHUDModel(engine: engine, live: tripod)
    #expect(m.nextAsk?.hasPrefix("End the session?") == true)
}

@Test @MainActor func theVoiceCardShowsWhoIsTalking() {
    let engine = SessionEngine(day: day, weekNumber: 1)
    var live = tripod
    #expect(SessionHUDModel(engine: engine, live: live).voice == .idle(hints: VoiceGuide.hints(for: engine)))
    live.speakingLine = "Back-off at 65, his rule."
    live.speakingSince = t0.addingTimeInterval(-1)
    #expect(SessionHUDModel(engine: engine, live: live).voice == .speaking("Back-off at 65, his rule.", spoken: 3))
    live.hearing = true
    live.liveWords = "how long left"
    live.micLevel = 0.6
    #expect(SessionHUDModel(engine: engine, live: live).voice == .hearing("how long left", level: 0.6))
}

@Test @MainActor func inAPocketOrWithoutACameraThereIsNoCameraCard() {
    let engine = SessionEngine(day: day, weekNumber: 1)
    var live = tripod
    // On the tripod before the tracker finds him: his picture, so he can frame himself (Oct 29).
    live.cameraOnDuty = false
    let framing = SessionHUDModel(engine: engine, live: live)
    #expect(framing.camera && !framing.pocket)
    // A dark picture is a pocket.
    live.cameraDark = true
    let pocket = SessionHUDModel(engine: engine, live: live)
    #expect(pocket.pocket && !pocket.camera)
    live.cameraRunning = false
    let rehearsal = SessionHUDModel(engine: engine, live: live)
    #expect(!rehearsal.pocket && !rehearsal.camera)
}

@Test @MainActor func theFrontCameraMirrorsHisLockOn() {
    let engine = SessionEngine(day: day, weekNumber: 1)
    var live = tripod
    live.trackedBox = CGRect(x: 0.1, y: 0.3, width: 0.4, height: 0.5)
    #expect(SessionHUDModel(engine: engine, live: live).lockBox == CGRect(x: 0.1, y: 0.3, width: 0.4, height: 0.5))
    live.frontCamera = true
    let box = SessionHUDModel(engine: engine, live: live).lockBox!
    #expect(Swift.abs(box.minX - 0.5) < 1e-9 && box.width == 0.4)
}

@Test @MainActor func anAddOnIsOneEntryAfterTheDaysLifts() {
    let engine = SessionEngine(day: day, addOns: [abs], weekNumber: 1)
    let m = SessionHUDModel(engine: engine, live: tripod)
    #expect(m.progress.map(\.name) == ["Incline press", "Incline flyes", "Abs"] && m.progress[2].isAddOn)
}

@Test @MainActor func theSessionEndSumsUpTopSetsAndTheLogbookBeaten() {
    let engine = SessionEngine(day: day, weekNumber: 1, lastSets: ["incline|top": LastSet(loadLb: 80, reps: 7)])
    engine.apply(say(.endSet, "done, 9", number: 9), now: t0)
    engine.apply(say(.endExercise, "that's it for these"), now: t0.addingTimeInterval(200))
    engine.apply(say(.endExercise, "that's it for these"), now: t0.addingTimeInterval(210))
    let m = SessionHUDModel(engine: engine, live: tripod)
    #expect(m.phase == .done)
    #expect(m.summary?.lines == [.init(exercise: "Incline DB press", top: "80 × 9", beat: "Beat the logbook")])
    #expect(m.summary?.notes == ["Skipped: cable incline flyes"])
}

/// A scripted session drawn through the real mapping, for the review sheet.
@Test @MainActor func aLiveRestRendersThroughTheMapping() throws {
    let engine = SessionEngine(day: day, weekNumber: 1, lastSets: ["incline|top": LastSet(loadLb: 75, reps: 9)])
    engine.cameraOnDuty = true
    engine.setStarted(at: t0)
    engine.setEnded(at: t0.addingTimeInterval(30), willMeasure: true)
    engine.measured(setId: engine.session.sets[0].id,
                    CountResponse(reps: 9, repTimes: [], velocityLossPct: 41, confidence: 0.9, trackFound: true, frames: 300,
                                  trackedFrames: 300, prompt: "dumbbell"), now: t0.addingTimeInterval(50))
    for _ in 0..<70 { engine.tickRest() }
    var live = tripod
    live.lastLine = "9 reps, measured."
    let model = SessionHUDModel(engine: engine, live: live)
    #expect(model.result.first?.text == "9 reps" && model.result.contains { $0.text == "slowed 41%" })
    let folder = ProcessInfo.processInfo.environment["HUD_SHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    let frame = ProcessInfo.processInfo.environment["HUD_CAMERA"].flatMap { UIImage(contentsOfFile: $0) }
    let renderer = ImageRenderer(content: SessionHUD(model: model)
        .environment(\.sessionCameraFeed, frame.map { AnyView(Image(uiImage: $0).resizable().scaledToFill()) })
        .frame(width: 402, height: 874))
    renderer.scale = 2
    let image = try #require(renderer.uiImage)
    if let folder, let png = image.pngData() {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent("8-live-rest.png"))
    }
}

@Test @MainActor func theFramingCueShowsOnlyWhileTheCameraSeesHisUpperBodyBeforeASet() {
    let engine = SessionEngine(day: day, weekNumber: 1)
    let live = SessionHUDModel.Live(micLabel: "AirPods mic", micOnHim: true, cameraRunning: true, cameraOnDuty: true, upperBodyOnly: true, now: t0)
    #expect(SessionHUDModel(engine: engine, live: live).framing == "Upper body only · step back")
    var whole = live
    whole.upperBodyOnly = false
    #expect(SessionHUDModel(engine: engine, live: whole).framing == nil)
    engine.setStarted(at: t0)
    #expect(SessionHUDModel(engine: engine, live: live).framing == nil)   // never during a set
}

/// The Done stage's time line: the session's length, and the time away from the sets as
/// `pacing()` in backend/scripts/evidence.py counts it.
@Test func timeAwayIsTheGapsFarLongerThanTheSessionsUsualRest() {
    func set(_ start: Int, _ end: Int, _ exercise: String) -> (start: Date, end: Date, exerciseId: String) {
        (t0.addingTimeInterval(TimeInterval(start)), t0.addingTimeInterval(TimeInterval(end)), exercise)
    }
    // Rests of 150, 150 and 180 s (median 150 → limit max(375, 300) = 375 s): the 240 s walk to the
    // next lift is not away; the 780 s gap before the last lift is.
    let sets = [set(0, 30, "a"), set(180, 210, "a"), set(360, 390, "a"),
                set(630, 660, "b"), set(840, 870, "b"), set(1650, 1680, "c")]
    #expect(SessionHUDModel.awaySeconds(sets: sets) == 780)
    // Long rests raise the limit: 2.5 × a 200 s median is 500 s, so a 450 s gap is just rest.
    let longRests = [set(0, 30, "a"), set(230, 260, "a"), set(710, 740, "a")]
    #expect(SessionHUDModel.awaySeconds(sets: longRests) == 0)
    // Short rests never lower it under 5 min.
    let shortRests = [set(0, 30, "a"), set(90, 120, "a"), set(210, 240, "a"), set(570, 600, "b")]
    #expect(SessionHUDModel.awaySeconds(sets: shortRests) == 330)
    // No two sets of one lift: no usual rest, nothing counted as away. One set: nothing.
    #expect(SessionHUDModel.awaySeconds(sets: [set(0, 30, "a"), set(2000, 2030, "b")]) == 0)
    #expect(SessionHUDModel.awaySeconds(sets: [set(0, 30, "a")]) == 0)

    func logged(_ s: (start: Date, end: Date, exerciseId: String)) -> LoggedSet {
        LoggedSet(id: UUID(), exerciseId: s.exerciseId, setIndex: 0, loadLb: 80, reps: 8, rpe: nil,
                  startedAt: s.start, endedAt: s.end, clipFile: nil, edits: [])
    }
    let away = Session(id: UUID(), programDayId: "d5", startedAt: t0, endedAt: t0.addingTimeInterval(52 * 60), sets: sets.map(logged), notes: [])
    #expect(SessionHUDModel.timeLine(for: away) == "52 min · 13 min away")
    let straight = Session(id: UUID(), programDayId: "d5", startedAt: t0, endedAt: t0.addingTimeInterval(28 * 60 + 20), sets: longRests.map(logged), notes: [])
    #expect(SessionHUDModel.timeLine(for: straight) == "28 min")
    // Not ended yet: to the last set's end. No set: nothing to say.
    var open = away
    open.endedAt = nil
    #expect(SessionHUDModel.timeLine(for: open) == "28 min · 13 min away")
    #expect(SessionHUDModel.timeLine(for: Session(id: UUID(), programDayId: "d5", startedAt: t0, endedAt: nil, sets: [], notes: [])) == nil)
}

@Test @MainActor func theSessionEndShowsHowLongItRan() {
    let engine = SessionEngine(day: day, weekNumber: 1, now: t0)
    engine.apply(say(.endSet, "done, 9", number: 9), now: t0.addingTimeInterval(60))
    engine.apply(say(.endExercise, "that's it for these"), now: t0.addingTimeInterval(200))
    engine.apply(say(.endExercise, "that's it for these"), now: t0.addingTimeInterval(210))
    let m = SessionHUDModel(engine: engine, live: tripod)
    #expect(m.phase == .done && m.summary?.time == "4 min")
}
