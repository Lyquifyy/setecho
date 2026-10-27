import Foundation

/// The instant rep count on the phone (HANDOFF.md §7, Rep counting). A line-for-line mirror of
/// steps 3-5 of backend/app/reps.py: bridge short tracking gaps, smooth with Savitzky-Golay
/// (window 5, order 2), take the rest position as the median of the first and last 0.5 s, and
/// count the peaks of |y - rest| with prominence of at least 35% of the 95th percentile, at
/// least 0.8 s apart. Both run on tests/fixtures/reps/ and must give the same counts.
///
/// The constants here and in reps.py change together.
enum RepCounter {
    static let minTrackShare = 0.80
    static let gapFillSeconds = 0.5
    static let smoothKernel: [Double] = [-3, 12, 17, 12, -3].map { $0 / 35 }
    static let restWindowSeconds = 0.5
    static let prominenceFraction = 0.35
    static let minRepIntervalSeconds = 0.8
    /// Motion smaller than this (normalized, 0…1 of the frame) is jitter, never a rep.
    static let minAmplitudeNormalized = 0.05
    static let lowConfidence = 0.6

    struct Result: Equatable {
        var reps: Int?
        var repTimes: [Double]
        var confidence: Double
        var trackFound: Bool
        var frames: Int
        var trackedFrames: Int
    }

    /// `y` is the position along the direction of motion; nil where tracking dropped.
    static func count(t: [Double], y: [Double?], minAmplitude: Double = minAmplitudeNormalized) -> Result {
        let frames = t.count
        let tracked = y.filter { $0 != nil }.count
        let share = frames > 0 ? Double(tracked) / Double(frames) : 0
        guard frames > 0, share >= minTrackShare else {
            return Result(reps: nil, repTimes: [], confidence: 0, trackFound: false, frames: frames, trackedFrames: tracked)
        }
        let peaks = peakIndices(t: t, y: y, minAmplitude: minAmplitude)
        let times = peaks.map { round((t[$0] - t[0]) * 1000) / 1000 }
        let confidence = (confidence(trackShare: share, repTimes: times) * 1000).rounded() / 1000
        return Result(reps: peaks.count, repTimes: times, confidence: confidence, trackFound: true, frames: frames, trackedFrames: tracked)
    }

    // MARK: Steps 3–5

    static func peakIndices(t: [Double], y: [Double?], minAmplitude: Double) -> [Int] {
        guard t.count >= 3, y.contains(where: { $0 != nil }) else { return [] }
        let filled = fillGaps(t: t, y: y)
        let smoothed = smooth(filled)
        let rest = restPosition(t: t, y: smoothed)
        let d = smoothed.map { abs($0 - rest) }
        let scale = percentile(d, 95)
        guard scale > 0, scale >= minAmplitude else { return [] }
        let dt = t.count > 1 ? median(zip(t.dropFirst(), t).map { $0 - $1 }) : 1
        let distance = dt > 0 ? max(1, Int((minRepIntervalSeconds / dt).rounded())) : 1
        let peaks = findPeaks(d, distance: distance, prominence: prominenceFraction * scale)
        // `distance` is in samples; with a variable frame rate, enforce the 0.8 s in real time too.
        var kept: [Int] = []
        for p in peaks.sorted(by: { d[$0] > d[$1] }) where kept.allSatisfy({ abs(t[p] - t[$0]) >= minRepIntervalSeconds }) {
            kept.append(p)
        }
        return kept.sorted()
    }

    /// Linear interpolation across gaps of at most `gapFillSeconds`; longer gaps and untracked
    /// edges hold the nearest tracked value, so a dropout never becomes a peak.
    static func fillGaps(t: [Double], y: [Double?], maxGap: Double = gapFillSeconds) -> [Double] {
        let tracked = y.indices.filter { y[$0] != nil }
        guard let first = tracked.first, let last = tracked.last else { return y.map { $0 ?? 0 } }
        var out = y.map { $0 ?? .nan }
        for i in 0..<first { out[i] = y[first]! }
        for i in (last + 1)..<y.count { out[i] = y[last]! }
        for (a, b) in zip(tracked, tracked.dropFirst()) where b - a > 1 {
            let gap = t[b] - t[a]
            for i in (a + 1)..<b {
                out[i] = gap <= maxGap ? y[a]! + (t[i] - t[a]) / gap * (y[b]! - y[a]!) : y[a]!
            }
        }
        return out
    }

    /// Savitzky-Golay on the interior; the two samples at each edge are kept as they are.
    static func smooth(_ y: [Double]) -> [Double] {
        let window = smoothKernel.count
        guard y.count >= window else { return y }
        let half = window / 2
        var out = y
        for i in half..<(y.count - half) {
            var acc = 0.0
            for k in 0..<window { acc += smoothKernel[k] * y[i - half + k] }
            out[i] = acc
        }
        return out
    }

    static func restPosition(t: [Double], y: [Double], window: Double = restWindowSeconds) -> Double {
        let head = zip(t, y).filter { $0.0 <= t[0] + window }.map(\.1)
        let tail = zip(t, y).filter { $0.0 >= t[t.count - 1] - window }.map(\.1)
        return median(head + tail)
    }

    /// scipy.signal.find_peaks with `distance` and `prominence`, in its order: local maxima
    /// (a plateau counts once, at its middle), the distance filter by height, then prominence.
    static func findPeaks(_ x: [Double], distance: Int, prominence: Double) -> [Int] {
        var maxima: [Int] = []
        var i = 1
        while i < x.count - 1 {
            if x[i - 1] < x[i] {
                var ahead = i + 1
                while ahead < x.count && x[ahead] == x[i] { ahead += 1 }
                if ahead < x.count && x[ahead] < x[i] {
                    maxima.append((i + ahead - 1) / 2)
                }
                i = ahead
            } else {
                i += 1
            }
        }
        // Distance: keep the highest, drop neighbours closer than `distance` samples.
        var keep = [Bool](repeating: true, count: maxima.count)
        for j in maxima.indices.sorted(by: { x[maxima[$0]] > x[maxima[$1]] }) where keep[j] {
            var k = j - 1
            while k >= 0 && maxima[j] - maxima[k] < distance { keep[k] = false; k -= 1 }
            k = j + 1
            while k < maxima.count && maxima[k] - maxima[j] < distance { keep[k] = false; k += 1 }
        }
        let spaced = maxima.indices.filter { keep[$0] }.map { maxima[$0] }
        return spaced.filter { self.prominence(of: $0, in: x) >= prominence }
    }

    /// scipy's prominence: the peak's height above the higher of the two valleys between it
    /// and the next higher sample (or the edge) on each side.
    static func prominence(of peak: Int, in x: [Double]) -> Double {
        let h = x[peak]
        var left = h
        var i = peak - 1
        while i >= 0 && x[i] <= h { left = min(left, x[i]); i -= 1 }
        var right = h
        i = peak + 1
        while i < x.count && x[i] <= h { right = min(right, x[i]); i += 1 }
        return h - max(left, right)
    }

    /// Step 6: tracked share × (1 − CV of the rep intervals). No reps: 0. One rep: halfway.
    static func confidence(trackShare: Double, repTimes: [Double]) -> Double {
        guard !repTimes.isEmpty else { return 0 }
        let cv: Double
        if repTimes.count < 2 {
            cv = 0.5
        } else {
            let intervals = zip(repTimes.dropFirst(), repTimes).map { $0 - $1 }
            let mean = intervals.reduce(0, +) / Double(intervals.count)
            let variance = intervals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(intervals.count)
            cv = mean > 0 ? variance.squareRoot() / mean : 1
        }
        return min(1, max(0, trackShare * (1 - min(1, cv))))
    }

    // MARK: Small statistics (NumPy's definitions)

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// NumPy's default (linear interpolation between order statistics).
    static func percentile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        let rank = q / 100 * Double(s.count - 1)
        let lo = Int(rank.rounded(.down))
        let hi = min(lo + 1, s.count - 1)
        return s[lo] + (rank - Double(lo)) * (s[hi] - s[lo])
    }
}

/// The body-pose joints over a set, and the one that moved most (HANDOFF.md §7, Rep counting).
/// Fed every processed frame; asked at set end for the window's count.
struct JointSeries {
    struct Sample: Equatable {
        var t: Double
        /// Normalized y per joint, only for joints seen with confidence above 0.3.
        var joints: [String: Double]
    }

    /// Joints that can carry a rep: wrists, elbows, hips, knees, ankles.
    static let joints = ["left_wrist", "right_wrist", "left_elbow", "right_elbow", "left_hip", "right_hip",
                         "left_knee", "right_knee", "left_ankle", "right_ankle"]
    /// A joint that moves less than this over the set is not the one doing the rep.
    static let minRange = 0.05
    /// Tracking must hold on at least this share of the set's frames.
    static let minTrackedShare = 0.80

    private(set) var samples: [Sample] = []

    mutating func add(_ sample: Sample) {
        samples.append(sample)
    }

    mutating func trim(olderThan seconds: Double, now t: Double) {
        samples.removeAll { $0.t < t - seconds }
    }

    /// Frames with at least `minJoints` joints seen, in the last `seconds`: the camera is on duty
    /// when that is at least half of them (HANDOFF.md §7, Session inputs).
    func isOnDuty(now t: Double, seconds: Double = 10, minJoints: Int = 6) -> Bool {
        let recent = samples.filter { $0.t >= t - seconds }
        guard !recent.isEmpty else { return false }
        let good = recent.filter { $0.joints.count >= minJoints }.count
        return Double(good) >= Double(recent.count) / 2
    }

    /// The count over [from, to]: the joint whose smoothed y has the largest range, counted like
    /// the backend. Nil when no joint moved enough or tracking dropped for over 20% of the set.
    func phoneCount(from: Double, to: Double) -> RepCounter.Result? {
        let window = samples.filter { $0.t >= from && $0.t <= to }
        guard window.count >= 3 else { return nil }
        let t = window.map(\.t)
        var best: (joint: String, range: Double, y: [Double?])?
        for joint in Self.joints {
            let y = window.map { $0.joints[joint] }
            let tracked = y.filter { $0 != nil }.count
            guard Double(tracked) / Double(y.count) >= Self.minTrackedShare else { continue }
            let smoothed = RepCounter.smooth(RepCounter.fillGaps(t: t, y: y))
            let range = (smoothed.max() ?? 0) - (smoothed.min() ?? 0)
            if range > Self.minRange, range > (best?.range ?? 0) {
                best = (joint, range, y)
            }
        }
        guard let best else { return nil }
        let result = RepCounter.count(t: t, y: best.y)
        return result.trackFound ? result : nil
    }
}
