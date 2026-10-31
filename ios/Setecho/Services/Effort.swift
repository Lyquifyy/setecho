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

    /// Written for the coach's notes, the same words as spoken: "failure" / "about 2 left" / "4+ left".
    static func written(rir: Double) -> String {
        if rir <= 0 { return "failure" }
        if rir >= 4 { return "4+ left" }
        return "about \(Int(rir.rounded())) left"
    }

    // MARK: Measured top sets in the check-in (HANDOFF.md §7, Measured effort, In the check-in)

    /// One lift's best measured top set this period, for his notes field. Every number is the log's;
    /// the effort words are the spotter's. No verdict, nothing from a model.
    struct TopSetNote: Identifiable, Equatable {
        /// The set's id, so an untick on Review and send keys on the set.
        var id: UUID
        var exerciseName: String
        var at: Date
        var line: String
    }

    /// "Smith close-grip press 225 × 9, slowed 46%, failure": load through `Format` (DESIGN.md rule 7),
    /// the logged reps, the slowdown as a whole percent, then the effort words.
    static func topSetLine(name: String, loadLb: Double, reps: Int, velocityLossPct: Double, rir: Double) -> String {
        "\(name) \(Format.number(loadLb)) × \(reps), slowed \(Format.percent(velocityLossPct)), \(written(rir: rir))"
    }

    /// The period's best measured top set per lift: `role == .top`, SAM's count and slowdown both
    /// present, warm-ups never. Best is the heaviest, then the most reps. A swapped set counts as the
    /// variant done (`doneAs`). One note per lift, in the order the lifts were first done.
    static func measuredTopSets(in sessions: [Session], names: (String) -> String, calibration: Calibration = Calibration()) -> [TopSetNote] {
        var order: [String] = []
        var best: [String: LoggedSet] = [:]
        for session in sessions.sorted(by: { $0.startedAt < $1.startedAt }) {
            for set in session.sets.sorted(by: { $0.startedAt < $1.startedAt }) {
                guard set.role == .top, !set.isWarmup, let measured = set.repCount.measured, set.repCount.velocityLossPct != nil,
                      // SAM's slowdown is of the reps it counted: a rejected track (its count neither the record
                      // nor within a rep of it) measured nothing about his set.
                      set.repCount.source == .measured || abs(measured - set.reps) <= 1 else { continue }
                let key = set.exerciseId + "|" + (set.doneAs ?? "")
                if best[key] == nil { order.append(key) }
                if let current = best[key], (current.loadLb, current.reps) >= (set.loadLb, set.reps) { continue }
                best[key] = set
            }
        }
        return order.compactMap { key in
            guard let set = best[key], let loss = set.repCount.velocityLossPct else { return nil }
            let rir = set.repCount.estimatedRIR ?? estimatedRIR(velocityLossPct: loss, exerciseId: set.exerciseId, calibration: calibration)
            let name = set.doneAs ?? names(set.exerciseId)
            return TopSetNote(id: set.id, exerciseName: name, at: set.startedAt,
                              line: topSetLine(name: name, loadLb: set.loadLb, reps: set.reps, velocityLossPct: loss, rir: rir))
        }
    }
}
