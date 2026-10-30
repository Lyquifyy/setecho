import Foundation
import Testing
@testable import Setecho

/// Feed a wrist trajectory at ~15 fps and collect the events.
private func run(_ y: (Double) -> Double, seconds: Double, fps: Double = 15, into signal: inout WristSignal) -> [WristSignal.Event] {
    var events: [WristSignal.Event] = []
    var t = signal.series.last.map { $0.t + 1 / fps } ?? 0
    let end = t + seconds
    while t < end {
        if let e = signal.add(y: y(t), at: t) { events.append(e) }
        t += 1 / fps
    }
    return events
}

@Test func benchPressRepsStartASetAndStillnessEndsIt() {
    var signal = WristSignal()
    // Quiet: wrists resting, tiny jitter.
    var events = run({ 0.55 + 0.004 * sin($0 * 7) }, seconds: 3, into: &signal)
    #expect(events.isEmpty && !signal.isActive)
    // Reps: a 3 s cycle of 0.15 amplitude.
    events = run({ 0.55 + 0.15 * sin($0 * 2 * .pi / 3) }, seconds: 6, into: &signal)
    #expect(signal.isActive)
    guard case .start(let startAt, let realStart)? = events.first else { Issue.record("no start event"); return }
    #expect(startAt > 3 && startAt < 6)   // within the first rep or two
    #expect(realStart <= startAt && realStart > 2.5 && realStart < 4)   // the bar was last at rest around 3 s
    // Rack it: still for 5 s.
    let endEvents = run({ 0.55 + 0.004 * sin($0 * 7) }, seconds: 5, into: &signal)
    guard case .end(let endAt, let stillSince)? = endEvents.first else { Issue.record("no end event"); return }
    #expect(!signal.isActive)
    #expect(abs(endAt - stillSince - 4) < 0.1)   // detected 4 s after the bar stopped
    #expect(stillSince > 8.5 && stillSince < 10)
}

@Test func walkingPastWithoutReversalsDoesNotStartASet() {
    var signal = WristSignal()
    _ = run({ _ in 0.5 }, seconds: 2, into: &signal)
    // A slow monotonic drift of 0.2 over 2 s: big range, no reversal.
    let events = run({ 0.5 + 0.1 * ($0 - 2) }, seconds: 2, into: &signal)
    #expect(events.isEmpty && !signal.isActive)
}

@Test func smallFidgetingStaysBelowTheStartRange() {
    var signal = WristSignal()
    let events = run({ 0.5 + 0.03 * sin($0 * 4) }, seconds: 6, into: &signal)
    #expect(events.isEmpty)
}

@Test func medianSmoothingIgnoresASingleBadFrame() {
    var signal = WristSignal()
    _ = run({ _ in 0.5 }, seconds: 2, into: &signal)
    _ = signal.add(y: 0.9, at: 2.1)   // one wild pose estimate
    let events = run({ _ in 0.5 }, seconds: 2, into: &signal)
    #expect(events.isEmpty && !signal.isActive)
    #expect(signal.series.last!.smoothed == 0.5)
}

@Test func resetDropsTheActiveState() {
    var signal = WristSignal()
    _ = run({ 0.55 + 0.15 * sin($0 * 2 * .pi / 3) }, seconds: 6, into: &signal)
    #expect(signal.isActive)
    signal.reset()
    #expect(!signal.isActive)
}

@Test func debugRowsAndTrim() {
    var signal = WristSignal()
    _ = run({ _ in 0.5 }, seconds: 10, into: &signal)
    #expect(signal.debugRows.first?.count == 3)
    signal.trim(olderThan: 2, now: 10)
    #expect(signal.series.allSatisfy { $0.t >= 8 })
}

/// Feed both wrists at ~15 fps and collect the events.
private func runWrists(_ wrists: (Double) -> (left: (x: Double, y: Double), right: (x: Double, y: Double)), from start: Double, seconds: Double,
                       fps: Double = 15, into signal: inout WristSignal) -> [WristSignal.Event] {
    var events: [WristSignal.Event] = []
    var t = start
    while t < start + seconds {
        let w = wrists(t)
        let readings = WristSignal.readings(joints: ["left_wrist": w.left.y, "right_wrist": w.right.y],
                                            wristX: ["left_wrist": w.left.x, "right_wrist": w.right.x])
        if let e = signal.add(readings, at: t) { events.append(e) }
        t += 1 / fps
    }
    return events
}

private func atRest(_ t: Double) -> (left: (x: Double, y: Double), right: (x: Double, y: Double)) {
    ((0.25 + 0.003 * sin(t * 7), 0.6), (0.75, 0.6 + 0.003 * sin(t * 5)))
}

/// Oct 29: the camera started none of his cable flye sets. The hands sweep together and apart at
/// one height, so the mean y never moves; the wrist gap does.
@Test func aFlyeStartsFromTheWristGapAndStillnessEndsIt() {
    var signal = WristSignal()
    var events = runWrists(atRest, from: 0, seconds: 3, into: &signal)
    #expect(events.isEmpty)
    // Reps: each hand from 0.25 out to 0.07 from the centre, every 2.5 s, with no change in height.
    events = runWrists({ t in
        let half = 0.25 - 0.18 * (1 - cos(2 * .pi * (t - 3) / 2.5)) / 2
        return ((0.5 - half, 0.6), (0.5 + half, 0.6))
    }, from: 3, seconds: 10, into: &signal)
    guard case .start(let startAt, let realStart)? = events.first else { Issue.record("no start event"); return }
    #expect(signal.activeChannel == .gap)
    #expect(startAt > 3 && startAt < 6 && realStart > 2 && realStart <= startAt)
    let endEvents = runWrists(atRest, from: 13, seconds: 6, into: &signal)
    guard case .end(_, let stillSince)? = endEvents.first else { Issue.record("no end event"); return }
    #expect(!signal.isActive && stillSince > 12.5 && stillSince < 14.5)
}

/// A one-arm pulldown moves the mean only half as far: the working wrist starts the set.
@Test func oneArmStartsTheSetFromItsOwnWrist() {
    var signal = WristSignal()
    _ = runWrists(atRest, from: 0, seconds: 3, into: &signal)
    let events = runWrists({ t in
        ((0.25, 0.6 - 0.12 * (1 - cos(2 * .pi * (t - 3) / 2.5)) / 2), (0.75, 0.6))
    }, from: 3, seconds: 6, into: &signal)
    guard case .start? = events.first else { Issue.record("no start event"); return }
    #expect(signal.activeChannel == .leftWrist)
}

/// Alternating arms: the left stops and the right takes over; the set stays open until both rest.
@Test func theSetStaysOpenWhileEitherHandWorks() {
    var signal = WristSignal()
    _ = runWrists(atRest, from: 0, seconds: 3, into: &signal)
    let pull = { (t: Double) in 0.6 - 0.12 * (1 - cos(2 * .pi * (t - 3) / 2.5)) / 2 }
    var events = runWrists({ t in ((0.25, pull(t)), (0.75, 0.6)) }, from: 3, seconds: 10, into: &signal)
    #expect(signal.isActive)
    events = runWrists({ t in ((0.25, 0.6), (0.75, pull(t))) }, from: 13, seconds: 10, into: &signal)
    #expect(events.isEmpty && signal.isActive)
    events = runWrists(atRest, from: 23, seconds: 6, into: &signal)
    guard case .end(_, let stillSince)? = events.first else { Issue.record("no end event"); return }
    #expect(stillSince > 22.5 && stillSince < 24.5)
}

@Test func readingsFromTheJointsSeen() {
    let both = WristSignal.readings(joints: ["left_wrist": 0.5, "right_wrist": 0.7, "left_shoulder": 0.8, "right_shoulder": 0.9,
                                             "nose": 0.95, "neck": 0.85, "root": 0.4],
                                    wristX: ["left_wrist": 0.3, "right_wrist": 0.8])
    #expect(both[.wrists] == 0.6 && both[.leftWrist] == 0.5 && both[.rightWrist] == 0.7)
    #expect(abs(both[.gap]! - 0.5) < 1e-9 && abs(both[.shoulders]! - 0.85) < 1e-9)
    #expect(both[.head] == 0.95 && both[.hips] == 0.4)   // the nose before the neck; root when no hips
    let one = WristSignal.readings(joints: ["right_wrist": 0.7, "neck": 0.85, "left_hip": 0.4, "root": 0.45], wristX: ["right_wrist": 0.8])
    #expect(one[.wrists] == 0.7 && one[.gap] == nil && one[.leftWrist] == nil && one[.shoulders] == nil)
    #expect(one[.head] == 0.85 && one[.hips] == 0.4)
    #expect(WristSignal.readings(joints: ["left_wrist": 0.5, "right_wrist": 0.7], wristX: ["right_wrist": 0.8])[.gap] == nil)
    #expect(WristSignal.readings(joints: [:]).isEmpty)
}

/// A push-up seen from the side: the hands stay planted, the shoulders and head go down and up.
@Test func aPushUpStartsFromTheShouldersAndHoldingStillEndsIt() {
    var signal = WristSignal()
    let plank = { (t: Double, dip: Double) -> [WristSignal.Channel: Double] in
        WristSignal.readings(joints: ["left_wrist": 0.12 + 0.002 * sin(t * 7), "right_wrist": 0.12,
                                      "left_shoulder": 0.30 - dip, "right_shoulder": 0.30 - dip, "nose": 0.32 - dip,
                                      "left_hip": 0.25 - dip * 0.6, "right_hip": 0.25 - dip * 0.6],
                             wristX: ["left_wrist": 0.3, "right_wrist": 0.32])
    }
    var events: [WristSignal.Event] = []
    var t = 0.0
    while t < 3 { if let e = signal.add(plank(t, 0), at: t) { events.append(e) }; t += 1 / 15 }
    #expect(events.isEmpty)
    while t < 13 {
        if let e = signal.add(plank(t, 0.12 * (1 - cos(2 * .pi * (t - 3) / 2)) / 2), at: t) { events.append(e) }
        t += 1 / 15
    }
    guard case .start(let startAt, _)? = events.first else { Issue.record("no start event"); return }
    #expect(startAt > 3 && startAt < 6)
    #expect([.shoulders, .head, .hips].contains(signal.activeChannel))
    events = []
    while t < 19 { if let e = signal.add(plank(t, 0), at: t) { events.append(e) }; t += 1 / 15 }
    guard case .end(_, let stillSince)? = events.first else { Issue.record("no end event"); return }
    #expect(stillSince > 12.5 && stillSince < 14.5)
}

/// Oct 29, his home shoulder press: the first 8 s after "go", as the camera saw his wrists (seconds
/// after the arm, mean y). His hands likely left the top of the picture, so they showed in about a
/// third of the frames, and a 5-sample median erased the reps. The 3-sample median starts the set.
@Test func aShoulderPressSeenInAThirdOfTheFramesStartsTheSet() {
    let seen: [(Double, Double)] = [
        (1.067, 0.568), (1.333, 0.487), (1.467, 0.486), (1.733, 0.438), (1.867, 0.423), (2.667, 0.559), (2.8, 0.562),
        (3.333, 0.482), (3.467, 0.483), (3.867, 0.482), (4.0, 0.48), (4.134, 0.485), (5.067, 0.49), (5.6, 0.451),
        (6.934, 0.482), (7.6, 0.477), (7.734, 0.493), (7.867, 0.486),
    ]
    func firstStart(_ config: WristSignal.Config) -> Double? {
        var signal = WristSignal(config: config)
        for (t, y) in seen { if case .start(let at, _)? = signal.add(y: y, at: t) { return at } }
        return nil
    }
    #expect(firstStart(WristSignal.Config()) == 2.8)
    var before = WristSignal.Config()
    before.medianWindow = 5
    #expect(firstStart(before) == nil)
}
