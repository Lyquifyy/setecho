import Foundation

/// The coach's own rules, applied by code (HANDOFF.md §7, Measured effort and the coach's rules).
/// Setecho never invents a load change: it compares the set's effort with his target, finds the
/// confirmed rule that matches, and computes the next load, rounded to what the athlete can load,
/// at most one step per set and never more than 10% from his planned load in a session. A back-off
/// rule is the exception: it is computed from the top set actually done. Nothing applies unconfirmed.
enum RuleEngine {
    /// What the athlete can load (Settings): barbell and dumbbell steps, machine stack steps.
    struct LoadSteps: Equatable {
        var barbell = 5.0
        var dumbbell = 5.0
        var machine = 10.0
        var cable = 10.0

        func step(for equipment: Equipment) -> Double {
            switch equipment {
            case .barbell: barbell
            case .dumbbell: dumbbell
            case .machine: machine
            case .cable: cable
            case .bodyweight: 5
            }
        }
    }

    /// One set, as the engine saw it: the load done, the count, the effort, and his target.
    struct SetFacts: Equatable {
        var exerciseId: String
        var exerciseName: String
        var equipment: Equipment
        var setIndex: Int
        var role: SetRole?
        var loadLb: Double
        var reps: Int
        var repsMin: Int?
        var repsMax: Int?
        var totalReps: Int?
        /// 10 − the spoken RPE, else the estimated reps in reserve; nil when neither is known.
        var effortRIR: Double?
        var effortIsMeasured: Bool
        /// His target in reps in reserve: the sheet's RPE/RIR, else the role target; nil when he gave none.
        var targetRIR: Double?
        /// The coach's planned load for the exercise this session (nil on his sheet).
        var plannedLoadLb: Double?
        /// Every set of this exercise so far hit the top of its range (double progression).
        var allSetsAtTopOfRange = false
    }

    static let maxSessionDriftFraction = 0.10
    /// A 20–25% back-off is the step nearest 22.5% lighter (§13).
    static func backOffFraction(minPct: Double?, maxPct: Double?) -> Double {
        ((minPct ?? 20) + (maxPct ?? 25)) / 2 / 100
    }

    static func round(_ load: Double, step: Double) -> Double {
        guard step > 0 else { return load }
        return (load / step).rounded() * step
    }

    /// The rule that matches, among the confirmed ones: his exercise-specific rule first.
    static func matchingRule(for facts: SetFacts, rules: [ProgressionRule]) -> ProgressionRule? {
        let confirmed = rules.filter(\.confirmed)
        let specific = confirmed.filter { rule in
            guard let who = rule.appliesTo?.lowercased() else { return false }
            return who == facts.exerciseName.lowercased() || who == facts.exerciseId.lowercased()
        }
        let general = confirmed.filter { $0.appliesTo == nil }
        return (specific + general).first { triggers($0, facts: facts) }
    }

    static func triggers(_ rule: ProgressionRule, facts: SetFacts) -> Bool {
        switch rule.when {
        case .aboveTarget:
            guard let effort = facts.effortRIR, let target = facts.targetRIR else { return false }
            return (target - effort) >= (rule.byRPE ?? 0.5)  // harder than his target by at least byRPE
        case .belowTarget:
            guard let effort = facts.effortRIR, let target = facts.targetRIR else { return false }
            return (effort - target) >= (rule.byRPE ?? 0.5)  // easier than his target by at least byRPE
        case .repsBelowMin:
            guard let min = facts.repsMin else { return false }
            return facts.reps < min
        case .allSetsAtTopOfRange:
            return facts.allSetsAtTopOfRange && facts.repsMax != nil
        case .afterTopSet:
            return facts.role == .top
        case .restPauseOverGoal:
            guard facts.role == .restPause, let goal = facts.totalReps else { return false }
            return facts.reps > goal
        case .topSetPastRange:
            guard facts.role == .top, let max = facts.repsMax else { return false }
            return facts.reps > max
        }
    }

    /// The suggestion his rule gives for this set, or nil when no confirmed rule matches or the
    /// rule changes reps rather than load.
    static func suggestion(for facts: SetFacts, rules: [ProgressionRule], steps: LoadSteps, setId: UUID) -> LoadSuggestion? {
        guard let rule = matchingRule(for: facts, rules: rules) else { return nil }
        let step = steps.step(for: facts.equipment)
        let from = facts.loadLb
        var to: Double
        switch rule.adjust {
        case .percent:
            to = from * (1 + (rule.amount ?? 0) / 100)
        case .pounds:
            to = from + (rule.amount ?? 0)
        case .loadSteps:
            to = from + (rule.amount ?? 1) * step
        case .reps:
            return nil  // keep the weight, change the reps: not a load suggestion
        case .backOff:
            to = from * (1 - backOffFraction(minPct: rule.minPct, maxPct: rule.maxPct))
        }
        let wanted = to
        to = Self.round(to, step: step)
        if to == from, wanted != from { to = from + (wanted > from ? step : -step) } // a small rule still moves a step
        if rule.adjust != .backOff {
            // At most one step per set, and never more than 10% from the coach's planned load.
            to = max(from - step, min(from + step, to))
            if let planned = facts.plannedLoadLb, planned > 0 {
                let low = Self.round(planned * (1 - maxSessionDriftFraction), step: step)
                let high = Self.round(planned * (1 + maxSessionDriftFraction), step: step)
                to = max(low, min(high, to))
            }
        }
        guard to != from, to > 0 else { return nil }
        return LoadSuggestion(
            id: UUID(), setId: setId, ruleId: rule.id, exerciseId: facts.exerciseId, role: rule.adjust == .backOff ? .backOff : facts.role,
            fromLb: from, toLb: to, reason: reason(for: rule, facts: facts), scope: rule.scope, decision: .pending
        )
    }

    /// "RPE 9.5 vs target 8 (measured: about 1 rep left)" · "20–25% lighter than the top set".
    static func reason(for rule: ProgressionRule, facts: SetFacts) -> String {
        switch rule.when {
        case .aboveTarget, .belowTarget:
            let effort = facts.effortRIR.map { Format.number(10 - $0) } ?? "?"
            let target = facts.targetRIR.map { Format.number(10 - $0) } ?? "?"
            let how = facts.effortIsMeasured ? "measured: \(Effort.leftText(rir: facts.effortRIR ?? 0))" : "you said"
            return "RPE \(effort) vs target \(target) (\(how))"
        case .repsBelowMin:
            return "\(facts.reps) reps, under \(facts.repsMin ?? 0)"
        case .allSetsAtTopOfRange:
            return "every set at \(facts.repsMax ?? 0)"
        case .afterTopSet:
            return "\(Format.number(rule.minPct ?? 20))–\(Format.number(rule.maxPct ?? 25))% lighter than the top set"
        case .restPauseOverGoal:
            return "\(facts.reps) total, over \(facts.totalReps ?? 0)"
        case .topSetPastRange:
            return "\(facts.reps) reps, past \(facts.repsMax ?? 0)"
        }
    }

    /// His rule in a few words, for the tag and the spoken line.
    static func ruleWords(_ rule: ProgressionRule) -> String {
        switch rule.adjust {
        case .backOff: "\(Format.number(rule.minPct ?? 20)) to \(Format.number(rule.maxPct ?? 25)) percent lighter"
        case .percent: "\(Format.number(abs(rule.amount ?? 0))) percent \(rule.amount ?? 0 < 0 ? "down" : "up")"
        case .pounds: "\(Format.number(abs(rule.amount ?? 0))) pounds \(rule.amount ?? 0 < 0 ? "down" : "up")"
        case .loadSteps: "one step up"
        case .reps: "keep the weight"
        }
    }
}
