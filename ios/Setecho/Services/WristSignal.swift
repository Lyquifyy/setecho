import Foundation

/// Set detection from the body's movement (HANDOFF.md §7). Seven channels, each normalized and
/// smoothed with a 5-sample median: the mean y of both wrists, each wrist's y (one-arm lifts), the
/// gap between the wrists across the frame (flyes, whose hands sweep sideways and barely change
/// height: Oct 29, the camera started none of his cable flye sets), and the height of the
/// shoulders, the head and the hips (push-ups, sit-ups and squats, where the hands stay planted or
/// ride along). A set starts when any channel's range over the last 2 s exceeds 0.08 with at least
/// one direction reversal, and ends when every channel's range stays under 0.03 for 4 s. Pure and
/// synchronous, fed with real video timestamps (iPhone video has a variable frame rate).
struct WristSignal {
    struct Config: Equatable {
        var medianWindow = 5
        var startWindowSeconds = 2.0
        var startRange = 0.08
        var minReversals = 1
        /// Movement smaller than this between samples is jitter, not a reversal.
        var reversalHysteresis = 0.01
        var endRange = 0.03
        var endSeconds = 4.0
        /// How long the signal must have been still to mark the set's real start.
        var stillBeforeStartSeconds = 1.0
    }

    enum Channel: String, CaseIterable {
        /// The mean height of the wrists seen: presses, rows, squats.
        case wrists
        /// One wrist's height: a one-arm lift moves only half the mean.
        case leftWrist = "left_wrist"
        case rightWrist = "right_wrist"
        /// |left x − right x|: flyes and anything that brings the hands together and apart.
        case gap = "wrist_gap"
        /// The body itself, for lifts whose hands don't travel: push-ups, sit-ups, squats.
        case shoulders
        /// The nose, or the neck when the face is turned away.
        case head
        /// The hips, or Vision's root point between them.
        case hips
    }

    enum Event: Equatable {
        /// `realStart` is the last moment before detection when the signal was still for 1 s:
        /// the set's real start, so the clip and the count include the first rep.
        case start(at: Double, realStart: Double)
        /// `stillSince` is when the bar stopped moving: the set's real end, 4 s before detection.
        case end(at: Double, stillSince: Double)
    }

    struct Sample: Equatable {
        var t: Double
        var raw: Double
        var smoothed: Double
    }

    /// One channel's series and its median window.
    private struct Track {
        var series: [Sample] = []
        var recentRaw: [Double] = []

        mutating func add(_ value: Double, at t: Double, medianWindow: Int) {
            recentRaw.append(value)
            if recentRaw.count > medianWindow { recentRaw.removeFirst() }
            series.append(Sample(t: t, raw: value, smoothed: recentRaw.sorted()[recentRaw.count / 2]))
        }

        /// The samples at or after `t0`, newest last.
        func since(_ t0: Double) -> ArraySlice<Sample> {
            let first = series.lastIndex { $0.t < t0 }.map { $0 + 1 } ?? series.startIndex
            return series[first...]
        }
    }

    let config: Config
    private(set) var isActive = false
    /// The channel that started the set under way, for the debug record.
    private(set) var activeChannel: Channel?
    private var tracks: [Channel: Track] = [:]

    init(config: Config = Config()) {
        self.config = config
    }

    /// The mean-wrists channel, as the HUD and the debug record show it.
    var series: [Sample] { tracks[.wrists]?.series ?? [] }

    /// Each channel's reading from one pose frame: joint heights by name (as `JointSeries` keeps
    /// them) and the wrists' x. Normalized, in the upright frame; a channel with nothing seen is absent.
    static func readings(joints: [String: Double], wristX: [String: Double] = [:]) -> [Channel: Double] {
        var readings: [Channel: Double] = [:]
        func mean(_ names: String...) -> Double? {
            let ys = names.compactMap { joints[$0] }
            return ys.isEmpty ? nil : ys.reduce(0, +) / Double(ys.count)
        }
        readings[.wrists] = mean("left_wrist", "right_wrist")
        readings[.leftWrist] = joints["left_wrist"]
        readings[.rightWrist] = joints["right_wrist"]
        if joints["left_wrist"] != nil, joints["right_wrist"] != nil, let lx = wristX["left_wrist"], let rx = wristX["right_wrist"] {
            readings[.gap] = abs(lx - rx)
        }
        readings[.shoulders] = mean("left_shoulder", "right_shoulder")
        readings[.head] = joints["nose"] ?? joints["neck"]
        readings[.hips] = mean("left_hip", "right_hip") ?? joints["root"]
        return readings
    }

    /// Add one wrist height (normalized y, 0…1) at time `t` seconds, as the mean-wrists channel.
    mutating func add(y: Double, at t: Double) -> Event? {
        add([.wrists: y], at: t)
    }

    /// Add one pose frame's readings at time `t` seconds. Returns a start or end event.
    mutating func add(_ readings: [Channel: Double], at t: Double) -> Event? {
        for (channel, value) in readings {
            tracks[channel, default: Track()].add(value, at: t, medianWindow: config.medianWindow)
        }

        if isActive {
            // Still means every hand: one arm of an alternating lift keeps the set open.
            var stillLongEnough = false
            for track in tracks.values {
                let window = track.since(t - config.endSeconds)
                guard let first = window.first else { continue }
                if range(of: window) >= config.endRange { return nil }
                if t - first.t >= config.endSeconds - 0.05 { stillLongEnough = true }
            }
            guard stillLongEnough else { return nil }
            isActive = false
            activeChannel = nil
            return .end(at: t, stillSince: t - config.endSeconds)
        }

        for channel in Channel.allCases where readings[channel] != nil {
            guard let track = tracks[channel] else { continue }
            let window = track.since(t - config.startWindowSeconds)
            guard window.count >= 3 else { continue }
            if range(of: window) > config.startRange, reversals(in: window) >= config.minReversals {
                isActive = true
                activeChannel = channel
                return .start(at: t, realStart: lastStillMoment(in: track.series, before: t) ?? window[window.startIndex].t)
            }
        }
        return nil
    }

    /// Drop the active state without an event (the set was ended by voice or the session stopped).
    mutating func reset() {
        isActive = false
        activeChannel = nil
    }

    /// The latest time before `t` at which the preceding `stillBeforeStartSeconds` had a range
    /// under `endRange`: where the bar was last at rest.
    private func lastStillMoment(in series: [Sample], before t: Double) -> Double? {
        let still = config.stillBeforeStartSeconds
        for (i, sample) in series.enumerated().reversed() where sample.t <= t {
            var window: [Sample] = []
            var j = i
            while j >= 0, series[j].t >= sample.t - still {
                window.append(series[j])
                j -= 1
            }
            guard let oldest = window.last, sample.t - oldest.t >= still - 0.1, window.count >= 3 else { continue }
            if range(of: window[...]) < config.endRange { return sample.t }
        }
        return nil
    }

    /// Forget the series: the person followed changed, so the history isn't his.
    mutating func clearHistory() {
        tracks.removeAll()
        reset()
    }

    /// Drop samples older than `seconds` so a long session stays small.
    mutating func trim(olderThan seconds: Double, now t: Double) {
        for channel in Array(tracks.keys) {
            tracks[channel]?.series.removeAll { $0.t < t - seconds }
        }
    }

    private func range(of window: ArraySlice<Sample>) -> Double {
        let ys = window.map(\.smoothed)
        return (ys.max() ?? 0) - (ys.min() ?? 0)
    }

    /// Direction changes in the smoothed signal, ignoring moves below the hysteresis.
    private func reversals(in window: ArraySlice<Sample>) -> Int {
        var count = 0
        var direction = 0.0
        var anchor = window[window.startIndex].smoothed
        for s in window.dropFirst() {
            let delta = s.smoothed - anchor
            guard abs(delta) >= config.reversalHysteresis else { continue }
            let d = delta > 0 ? 1.0 : -1.0
            if direction != 0, d != direction { count += 1 }
            direction = d
            anchor = s.smoothed
        }
        return count
    }

    /// For the debug JSON export: [t, raw, smoothed] rows of the mean-wrists channel.
    var debugRows: [[Double]] { series.map { [$0.t, $0.raw, $0.smoothed] } }
}
