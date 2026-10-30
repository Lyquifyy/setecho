import Foundation
import Testing
@testable import Setecho

/// RepCounter must count the series in backend/tests/fixtures/reps/ exactly as reps.py does.
private final class RepFixtureAnchor {}

private struct RepFixture: Decodable {
    var name: String
    var notes: String
    var t: [Double]
    var y: [Double?]
    var expectedReps: Int?
    var expectedVelocityLossPct: Double?
}

private func fixtures() throws -> [RepFixture] {
    let bundle = Bundle(for: RepFixtureAnchor.self)
    let urls = try #require(bundle.urls(forResourcesWithExtension: "json", subdirectory: "reps"))
    let decoder = JSONDecoder()
    return try urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
        .map { try decoder.decode(RepFixture.self, from: Data(contentsOf: $0)) }
}

@Test func sharedFixturesCountLikeTheBackend() throws {
    let all = try fixtures()
    #expect(all.count >= 10)
    for f in all {
        let result = RepCounter.count(t: f.t, y: f.y)
        #expect(result.reps == f.expectedReps, Comment(rawValue: "\(f.name): \(f.notes)"))
        if let expected = f.expectedReps {
            #expect(result.trackFound && result.repTimes.count == expected, Comment(rawValue: f.name))
        } else {
            #expect(!result.trackFound, Comment(rawValue: f.name))
        }
    }
}

@Test func velocityLossMatchesTheBackendOnTheSlowingSet() throws {
    let all = try fixtures()
    let slowing = try #require(all.first { $0.name == "slowing_8" })
    let result = RepCounter.count(t: slowing.t, y: slowing.y)
    #expect(result.reps == 8 && result.repSpeeds.count == 8)
    #expect(result.repSpeeds == result.repSpeeds.sorted(by: >))
    let expected = try #require(slowing.expectedVelocityLossPct)
    #expect(abs((result.velocityLossPct ?? 0) - expected) <= 3)
    let clean = try #require(all.first { $0.name == "clean_8" })
    #expect(RepCounter.count(t: clean.t, y: clean.y).velocityLossPct == 0)
    let single = try #require(all.first { $0.name == "single_rep" })
    #expect(RepCounter.count(t: single.t, y: single.y).velocityLossPct == nil)
    #expect(RepCounter.velocityLoss([1, 0.9, 0.5, 0.5]) == 50 && RepCounter.velocityLoss([1, 0.9, 1.2, 1.3]) == 0)
    #expect(RepCounter.velocityLoss([0, 0, 0.5]) == nil)
}

@Test func confidenceMatchesTheBackendRule() {
    #expect(RepCounter.confidence(trackShare: 1, repTimes: []) == 0)
    #expect(abs(RepCounter.confidence(trackShare: 0.9, repTimes: [1]) - 0.45) < 1e-9)
    #expect(abs(RepCounter.confidence(trackShare: 1, repTimes: [1, 2, 3]) - 1) < 1e-9)
    #expect(abs(RepCounter.confidence(trackShare: 0.85, repTimes: [1, 2, 3]) - 0.85) < 1e-9)
}

@Test func smoothingKeepsTheEdgesAndUsesTheFixedKernel() {
    let line: [Double] = [0, 1, 2, 3, 4, 5, 6]
    #expect(zip(RepCounter.smooth(line), line).allSatisfy { abs($0 - $1) < 1e-12 })
    let spike: [Double] = [0, 0, 0, 1, 0, 0, 0]
    let s = RepCounter.smooth(spike)
    #expect(abs(s[3] - 17.0 / 35) < 1e-12 && abs(s[2] - 12.0 / 35) < 1e-12 && s[1] == 0 && s[0] == 0)
}

@Test func gapFillBridgesShortGapsAndHoldsLongOnes() {
    let t = (0..<10).map { Double($0) / 10 }
    let y: [Double?] = [0, 1, nil, nil, 4, nil, nil, nil, nil, nil]
    let filled = RepCounter.fillGaps(t: t, y: y, maxGap: 0.35)
    #expect(abs(filled[2] - 2) < 1e-9 && abs(filled[3] - 3) < 1e-9)
    #expect(filled[5...].allSatisfy { $0 == 4 })
    let y2: [Double?] = [nil, nil, 2, nil, nil, nil, nil, nil, nil, 9]
    let filled2 = RepCounter.fillGaps(t: t, y: y2, maxGap: 0.35)
    #expect(filled2[0] == 2 && filled2[3...8].allSatisfy { $0 == 2 })
}

@Test func findPeaksMatchesScipyOnPlateausDistanceAndProminence() {
    // A plateau counts once, at its middle.
    #expect(RepCounter.findPeaks([0, 1, 1, 1, 0], distance: 1, prominence: 0.5) == [2])
    // Two peaks closer than `distance`: the higher one survives.
    #expect(RepCounter.findPeaks([0, 2, 1, 3, 0], distance: 3, prominence: 0.5) == [3])
    // A shallow bump between two big peaks has no prominence.
    #expect(RepCounter.findPeaks([0, 5, 4, 4.2, 4, 5, 0], distance: 1, prominence: 1) == [1, 5])
    #expect(RepCounter.prominence(of: 3, in: [0, 5, 4, 4.2, 4, 5, 0]) == 4.2 - 4)
}

@Test func jointSeriesPicksTheJointThatMovesMost() {
    var series = JointSeries()
    let fps = 15.0
    var t = 0.0
    while t < 24 {
        let rep = t > 1 && t < 21 ? 0.15 * (1 - cos(2 * .pi * (t - 1) / 2.5)) / 2 : 0
        series.add(JointSeries.Sample(t: t, joints: [
            "left_wrist": 0.55 - rep, "right_wrist": 0.55 - rep,
            "left_hip": 0.4 + 0.002 * sin(t * 5), "right_hip": 0.4,
            "left_knee": 0.25, "right_knee": 0.25, "left_elbow": 0.5 - rep * 0.3, "right_elbow": 0.5 - rep * 0.3,
        ]))
        t += 1 / fps
    }
    let result = series.phoneCount(from: 0, to: 24)
    #expect(result?.reps == 8)
    #expect(series.isOnDuty(now: 24))
    // Nothing moved: no phone count, and the set logs the plan.
    var still = JointSeries()
    for i in 0..<150 { still.add(JointSeries.Sample(t: Double(i) / fps, joints: ["left_wrist": 0.5, "right_wrist": 0.5])) }
    #expect(still.phoneCount(from: 0, to: 10) == nil)
    #expect(!still.isOnDuty(now: 10))   // two joints is not a body in frame
}

/// Oct 29: a cable flye sweeps the hands together and apart at nearly one height. The wrist gap
/// carries the reps; no joint's height moves enough.
@Test func jointSeriesCountsAFlyeFromTheWristGap() {
    var series = JointSeries()
    let fps = 15.0
    var t = 0.0
    while t < 24 {
        let rep = t > 1 && t < 21 ? (1 - cos(2 * .pi * (t - 1) / 2.5)) / 2 : 0
        let half = 0.25 - 0.18 * rep   // 0.25 out from the centre, in to 0.07
        series.add(JointSeries.Sample(t: t, joints: [
            "left_wrist": 0.6 + 0.01 * rep, "right_wrist": 0.6 + 0.01 * rep,
            "left_hip": 0.4, "right_hip": 0.4, "left_knee": 0.25, "right_knee": 0.25,
        ], wristX: ["left_wrist": 0.5 - half, "right_wrist": 0.5 + half]))
        t += 1 / fps
    }
    #expect(series.phoneCount(from: 0, to: 24)?.reps == 8)
}

/// Push-ups: the hands stay planted; the shoulders and head carry the reps.
@Test func jointSeriesCountsPushUpsFromTheShoulders() {
    var series = JointSeries()
    let fps = 15.0
    var t = 0.0
    while t < 22 {
        let dip = t > 1 && t < 21 ? 0.12 * (1 - cos(2 * .pi * (t - 1) / 2)) / 2 : 0
        series.add(JointSeries.Sample(t: t, joints: [
            "left_wrist": 0.12, "right_wrist": 0.12, "left_elbow": 0.2 - dip * 0.4, "right_elbow": 0.2 - dip * 0.4,
            "left_shoulder": 0.30 - dip, "right_shoulder": 0.30 - dip, "nose": 0.32 - dip,
            "left_hip": 0.25 - dip * 0.6, "right_hip": 0.25 - dip * 0.6, "left_ankle": 0.1, "right_ankle": 0.1,
        ]))
        t += 1 / fps
    }
    #expect(series.phoneCount(from: 0, to: 22)?.reps == 10)
}

@Test func jointSeriesNeedsTrackingOnMostFrames() {
    var series = JointSeries()
    let fps = 15.0
    var t = 0.0
    var i = 0
    while t < 20 {
        let rep = 0.15 * (1 - cos(2 * .pi * t / 2.5)) / 2
        var joints: [String: Double] = [:]
        if i % 3 != 0 { joints["left_wrist"] = 0.55 - rep }   // a third of frames lost
        series.add(JointSeries.Sample(t: t, joints: joints))
        t += 1 / fps
        i += 1
    }
    #expect(series.phoneCount(from: 0, to: 20) == nil)
}
