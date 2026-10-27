import Foundation

/// Set detection from the wrist signal (HANDOFF.md §7): the mean y of both wrists, normalized,
/// smoothed with a 5-sample median. A set starts when the signal's range over the last 2 s exceeds
/// 0.08 with at least one direction reversal, and ends when the range stays under 0.03 for 4 s.
/// Pure and synchronous, fed with real video timestamps (iPhone video has a variable frame rate).
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
    }

    enum Event: Equatable {
        case start(at: Double)
        /// `stillSince` is when the bar stopped moving: the set's real end, 4 s before detection.
        case end(at: Double, stillSince: Double)
    }

    struct Sample: Equatable {
        var t: Double
        var raw: Double
        var smoothed: Double
    }

    let config: Config
    private(set) var isActive = false
    private(set) var series: [Sample] = []
    private var recentRaw: [Double] = []
    private var activeSince: Double?

    init(config: Config = Config()) {
        self.config = config
    }

    /// Add one wrist reading (normalized y, 0…1) at time `t` seconds. Returns a start or end event.
    mutating func add(y: Double, at t: Double) -> Event? {
        recentRaw.append(y)
        if recentRaw.count > config.medianWindow { recentRaw.removeFirst() }
        let smoothed = recentRaw.sorted()[recentRaw.count / 2]
        series.append(Sample(t: t, raw: y, smoothed: smoothed))

        if isActive {
            let window = series.filter { $0.t >= t - config.endSeconds }
            guard let first = window.first, t - first.t >= config.endSeconds - 0.05 else { return nil }
            if range(of: window) < config.endRange {
                isActive = false
                activeSince = nil
                return .end(at: t, stillSince: t - config.endSeconds)
            }
            return nil
        }

        let window = series.filter { $0.t >= t - config.startWindowSeconds }
        guard window.count >= 3 else { return nil }
        if range(of: window) > config.startRange, reversals(in: window) >= config.minReversals {
            isActive = true
            activeSince = t
            return .start(at: t)
        }
        return nil
    }

    /// Drop samples older than `seconds` so a long session stays small.
    mutating func trim(olderThan seconds: Double, now t: Double) {
        series.removeAll { $0.t < t - seconds }
    }

    private func range(of window: [Sample]) -> Double {
        let ys = window.map(\.smoothed)
        return (ys.max() ?? 0) - (ys.min() ?? 0)
    }

    /// Direction changes in the smoothed signal, ignoring moves below the hysteresis.
    private func reversals(in window: [Sample]) -> Int {
        var count = 0
        var direction = 0.0
        var anchor = window[0].smoothed
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

    /// For the debug JSON export: [t, raw, smoothed] rows.
    var debugRows: [[Double]] { series.map { [$0.t, $0.raw, $0.smoothed] } }
}
