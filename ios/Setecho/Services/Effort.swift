import Foundation

/// Measured effort (HANDOFF.md §7, Measured effort and the coach's rules): velocity loss mapped to
/// estimated reps in reserve. The starting map is §13's; after five spoken RPEs on an exercise the
/// map is fitted to the athlete's own sets. Always labelled "estimated". A spoken RPE wins.
enum Effort {
    struct Pair: Codable, Equatable {
        var velocityLossPct: Double
        /// 10 − the RPE the athlete said.
        var rir: Double
    }

    /// Per-exercise pairs of (velocity loss, 10 − RPE), kept in the Store.
    struct Calibration: Codable, Equatable {
        var pairs: [String: [Pair]] = [:]

        mutating func add(exerciseId: String, velocityLossPct: Double, rpe: Double) {
            pairs[exerciseId, default: []].append(Pair(velocityLossPct: velocityLossPct, rir: max(0, 10 - rpe)))
        }
    }

    static let minPairsForFit = 5

    /// §13: under 10% → 4+, 10–20 → 3, 20–30 → 2, 30–40 → 1, over 40 → 0.
    static func defaultRIR(velocityLossPct loss: Double) -> Double {
        switch loss {
        case ..<10: 4
        case ..<20: 3
        case ..<30: 2
        case ..<40: 1
        default: 0
        }
    }

    /// The athlete's own map once there are enough pairs: a least-squares line through them,
    /// clamped to 0…4 and rounded to a half rep. Else the default map.
    static func estimatedRIR(velocityLossPct loss: Double, exerciseId: String, calibration: Calibration) -> Double {
        let pairs = calibration.pairs[exerciseId] ?? []
        guard pairs.count >= minPairsForFit, let fit = fit(pairs) else { return defaultRIR(velocityLossPct: loss) }
        let value = fit.intercept + fit.slope * loss
        return (max(0, min(4, value)) * 2).rounded() / 2
    }

    /// Ordinary least squares, rir = intercept + slope × loss. Nil when the losses are all the same.
    static func fit(_ pairs: [Pair]) -> (intercept: Double, slope: Double)? {
        let n = Double(pairs.count)
        let meanX = pairs.map(\.velocityLossPct).reduce(0, +) / n
        let meanY = pairs.map(\.rir).reduce(0, +) / n
        let sxx = pairs.map { ($0.velocityLossPct - meanX) * ($0.velocityLossPct - meanX) }.reduce(0, +)
        guard sxx > 0 else { return nil }
        let sxy = pairs.map { ($0.velocityLossPct - meanX) * ($0.rir - meanY) }.reduce(0, +)
        let slope = sxy / sxx
        return (meanY - slope * meanX, slope)
    }

    /// "~1 left", "4+ left", "failure", as the `EffortLine` shows it.
    static func leftText(rir: Double) -> String {
        if rir <= 0 { return "failure" }
        if rir >= 4 { return "4+ left" }
        let n = rir == rir.rounded() ? "\(Int(rir))" : "\(rir)"
        return "~\(n) left"
    }

    /// Spoken, against his target: "that's failure" / "about 2 left by the measure".
    static func spoken(rir: Double) -> String {
        if rir <= 0 { return "that's failure" }
        if rir >= 4 { return "plenty left by the measure" }
        let n = Int(rir.rounded())
        return "about \(n) left by the measure"
    }
}
