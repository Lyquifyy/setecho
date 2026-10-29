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
    live.cameraOnDuty = false
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
