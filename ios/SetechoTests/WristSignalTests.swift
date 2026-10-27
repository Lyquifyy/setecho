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
