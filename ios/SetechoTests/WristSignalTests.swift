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

/// Oct 30, his home cable flyes: the frames the pose found him in, seconds from 3 s before the set
/// (mean wrist y, head y). His arms settle after his last rep by about 19.5 s; from then he was seen
/// in about 1 frame of 10 until he said "done" at 57 s, and no 4 s window ever held enough of him to
/// end the set. The first two readings are from when he set up, still in the median when the reps
/// began, as they were.
@Test func stillnessSeenInAFewFramesEndsTheSet() {
    let setUp: [(Double, Double?, Double?)] = [(-12.8, 0.711, 0.52), (-12.667, 0.706, 0.524)]
    let seen: [(Double, Double?, Double?)] = setUp + [
        (1.867, 0.531, 0.555), (2.0, 0.512, 0.555), (2.133, 0.508, 0.553), (2.267, 0.506, 0.554), (2.4, 0.507, 0.554),
        (2.533, 0.512, 0.554), (2.667, 0.521, 0.554), (2.8, 0.534, 0.553), (2.933, 0.545, 0.553), (3.067, 0.555, 0.552),
        (4.267, 0.555, 0.555), (4.4, 0.535, 0.553), (4.534, 0.517, 0.553), (4.934, 0.501, 0.553), (5.067, 0.501, 0.553),
        (5.2, 0.501, 0.553), (5.334, 0.5, 0.553), (5.467, 0.505, 0.555), (5.734, 0.519, 0.552), (5.867, 0.527, 0.554),
        (6.0, 0.537, 0.552), (6.134, 0.544, 0.552), (6.267, 0.556, 0.552), (6.4, 0.568, 0.553), (6.534, 0.573, 0.553),
        (6.667, 0.58, 0.553), (6.8, 0.575, 0.554), (6.934, 0.574, 0.553), (7.067, 0.566, 0.557), (7.2, 0.552, 0.556),
        (7.334, 0.534, 0.554), (7.467, 0.515, 0.554), (7.6, 0.508, 0.555), (7.734, 0.502, 0.554), (7.867, 0.501, 0.555),
        (8.0, 0.502, 0.555), (8.134, 0.503, 0.553), (8.267, 0.501, 0.552), (8.4, 0.501, 0.552), (8.534, 0.502, 0.551),
        (8.667, 0.503, 0.551), (8.8, 0.51, 0.552), (8.934, 0.521, 0.552), (9.067, 0.535, 0.553), (9.467, 0.558, 0.552),
        (10.534, 0.559, 0.553), (10.667, 0.538, 0.552), (10.8, 0.52, 0.551), (10.934, 0.502, 0.553), (11.067, 0.501, 0.553),
        (11.2, 0.502, 0.553), (11.334, 0.501, 0.553), (11.467, 0.501, 0.553), (11.6, 0.501, 0.553), (11.734, 0.503, 0.552),
        (11.867, 0.505, 0.551), (12.001, 0.508, 0.55), (12.134, 0.518, 0.552), (12.267, 0.529, 0.551), (12.401, 0.536, 0.552),
        (12.534, 0.547, 0.552), (12.667, 0.555, 0.55), (12.801, 0.561, 0.548), (13.334, nil, 0.549), (13.467, nil, 0.549),
        (13.601, nil, 0.55), (13.734, 0.559, 0.549), (13.867, 0.539, 0.549), (14.134, 0.502, 0.55), (14.267, 0.501, 0.551),
        (14.401, 0.499, 0.55), (14.534, 0.501, 0.55), (14.667, 0.499, 0.55), (14.801, 0.499, 0.551), (14.934, 0.499, 0.549),
        (15.067, 0.499, 0.549), (15.201, 0.503, 0.549), (15.334, 0.506, 0.55), (15.601, 0.524, 0.55), (15.734, 0.533, 0.552),
        (15.867, 0.541, 0.551), (16.001, 0.553, 0.55), (16.134, nil, 0.55), (16.267, nil, 0.551), (16.401, nil, 0.55),
        (16.534, nil, 0.55), (16.667, nil, 0.549), (16.934, nil, 0.551), (17.067, 0.554, 0.55), (17.201, 0.536, 0.551),
        (17.334, 0.514, 0.551), (17.467, 0.501, 0.552), (17.601, 0.503, 0.551), (17.734, 0.504, 0.55), (17.867, 0.504, 0.55),
        (18.001, 0.502, 0.549), (18.134, 0.5, 0.547), (18.267, 0.503, 0.549), (18.401, 0.507, 0.549), (18.534, 0.508, 0.548),
        (18.667, 0.519, 0.55), (18.801, 0.526, 0.55), (18.934, 0.533, 0.55), (19.067, 0.54, 0.55), (19.201, 0.586, 0.55),
        (19.334, 0.553, 0.55), (19.467, 0.558, 0.551), (19.734, 0.57, 0.55), (19.868, 0.575, 0.55), (20.534, 0.584, 0.55),
        (26.268, 0.587, 0.554), (31.735, nil, 0.551), (31.868, 0.595, 0.551), (34.801, 0.59, 0.552), (34.935, 0.59, 0.553),
        (36.268, 0.591, 0.553), (36.402, 0.591, 0.553), (36.535, 0.593, 0.552), (36.935, 0.591, 0.553)
    ]
    var signal = WristSignal()
    var events: [WristSignal.Event] = []
    for (t, wrists, head) in seen.prefix(2) { _ = signal.add([.wrists: wrists!, .head: head!], at: t) }
    // Every camera frame at 7.5 Hz moves the clock on, him seen or not.
    var next = 2
    for frame in 14...(41 * 15 / 2) {
        let t = Double(frame) * 2 / 15
        var readings: [WristSignal.Channel: Double] = [:]
        if next < seen.count, seen[next].0 <= t + 0.03 {
            readings[.wrists] = seen[next].1
            readings[.head] = seen[next].2
            next += 1
        }
        if let event = signal.add(readings, at: t) { events.append(event) }
    }
    guard case .start(let startedAt, _)? = events.first, case .end(let endedAt, let stillSince)? = events.dropFirst().first else {
        Issue.record("expected a start and an end, got \(events)")
        return
    }
    #expect(startedAt < 3.5)
    #expect(endedAt > 20.5 && endedAt < 25)
    #expect(stillSince > 18.5 && stillSince < 21)
    #expect(events.count == 2)
}
