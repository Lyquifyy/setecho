import Foundation
import Testing
@testable import Setecho

/// The effort map and its calibration, and `RuleEngine`: every trigger, rounding, the step and 10%
/// limits, double progression to the next session, the back-off load (HANDOFF.md §10).
private func rule(_ when: RuleTrigger, _ adjust: RuleAdjust, amount: Double? = nil, byRPE: Double? = nil, minPct: Double? = nil,
                  maxPct: Double? = nil, scope: RuleScope = .nextSet, appliesTo: String? = nil, confirmed: Bool = true, quote: String? = nil) -> ProgressionRule {
    ProgressionRule(id: "r-\(when.rawValue)-\(adjust.rawValue)", appliesTo: appliesTo, when: when, byRPE: byRPE, adjust: adjust, amount: amount,
                    minPct: minPct, maxPct: maxPct, scope: scope, source: "Coach's instructions", quote: quote, confirmed: confirmed)
}

private func facts(load: Double = 225, reps: Int = 8, min: Int? = 6, max: Int? = 8, role: SetRole? = nil, effort: Double? = nil, measured: Bool = true,
                   target: Double? = nil, planned: Double? = 225, total: Int? = nil, allTop: Bool = false, equipment: Equipment = .barbell) -> RuleEngine.SetFacts {
    RuleEngine.SetFacts(exerciseId: "bench", exerciseName: "Bench press", equipment: equipment, setIndex: 0, role: role, loadLb: load, reps: reps,
                        repsMin: min, repsMax: max, totalReps: total, effortRIR: effort, effortIsMeasured: measured, targetRIR: target,
                        plannedLoadLb: planned, allSetsAtTopOfRange: allTop)
}

private let steps = RuleEngine.LoadSteps()
private let setId = UUID()

@Test func effortMapFollowsTheDefaultsUntilFiveSpokenRPEs() {
    #expect(Effort.defaultRIR(velocityLossPct: 5) == 4 && Effort.defaultRIR(velocityLossPct: 15) == 3)
    #expect(Effort.defaultRIR(velocityLossPct: 25) == 2 && Effort.defaultRIR(velocityLossPct: 35) == 1 && Effort.defaultRIR(velocityLossPct: 48) == 0)
    var cal = Effort.Calibration()
    for (loss, rpe) in [(10.0, 9.0), (20.0, 9.0), (30.0, 9.5), (40.0, 10.0)] { cal.add(exerciseId: "bench", velocityLossPct: loss, rpe: rpe) }
    #expect(Effort.estimatedRIR(velocityLossPct: 25, exerciseId: "bench", calibration: cal) == 2)   // four pairs: still the default
    cal.add(exerciseId: "bench", velocityLossPct: 50, rpe: 10)
    // His own sets: a 25% slowdown is about 0.5–1 rep left for him, not 2.
    let fitted = Effort.estimatedRIR(velocityLossPct: 25, exerciseId: "bench", calibration: cal)
    #expect(fitted < 2 && fitted >= 0)
    #expect(Effort.estimatedRIR(velocityLossPct: 25, exerciseId: "row", calibration: cal) == 2)   // another exercise: the default
    #expect(Effort.leftText(rir: 1) == "~1 left" && Effort.leftText(rir: 0) == "failure" && Effort.leftText(rir: 4) == "4+ left")
    #expect(Effort.spoken(rir: 0) == "that's failure" && Effort.spoken(rir: 2) == "about 2 left by the measure")
    #expect(Effort.fit([Effort.Pair(velocityLossPct: 10, rir: 1), Effort.Pair(velocityLossPct: 10, rir: 2)]) == nil)
}

@Test func aboveAndBelowTargetApplyHisPercentOrPoundsRoundedToAStep() {
    let drop = rule(.aboveTarget, .percent, amount: -5, byRPE: 1)
    // RPE 9.5 (0.5 left) against a target of 8 (2 left): 1.5 over → drop 5% of 225 = 213.75 → 215.
    let s = RuleEngine.suggestion(for: facts(effort: 0.5, target: 2), rules: [drop], steps: steps, setId: setId)
    #expect(s?.toLb == 220 && s?.fromLb == 225 && s?.scope == .nextSet && s?.decision == .pending)   // 5% is 11 lb, capped at one step
    #expect(s?.reason == "RPE 9.5 vs target 8 (measured: ~0.5 left)")
    // Only half an RPE over: the rule needs a full one.
    #expect(RuleEngine.suggestion(for: facts(effort: 1.5, target: 2), rules: [drop], steps: steps, setId: setId) == nil)
    let add = rule(.belowTarget, .pounds, amount: 5, byRPE: 1)
    #expect(RuleEngine.suggestion(for: facts(effort: 3, target: 2), rules: [add], steps: steps, setId: setId)?.toLb == 230)
    // No effort known, or no target: nothing to compare, no suggestion.
    #expect(RuleEngine.suggestion(for: facts(effort: nil, target: 2), rules: [drop], steps: steps, setId: setId) == nil)
    #expect(RuleEngine.suggestion(for: facts(effort: 0, target: nil), rules: [drop], steps: steps, setId: setId) == nil)
}

@Test func atMostOneStepPerSetAndNeverMoreThanTenPercentFromThePlan() {
    let bigDrop = rule(.aboveTarget, .percent, amount: -20, byRPE: 1)
    #expect(RuleEngine.suggestion(for: facts(effort: 0, target: 2), rules: [bigDrop], steps: steps, setId: setId)?.toLb == 220)   // one 5 lb step
    let overrides = rule(.aboveTarget, .pounds, amount: -5, byRPE: 1)
    // Already 10% under the plan after earlier drops: the rule can go no further.
    #expect(RuleEngine.suggestion(for: facts(load: 205, effort: 0, target: 2, planned: 225), rules: [overrides], steps: steps, setId: setId) == nil)
    // Dumbbells round to 5, machines to the stack step.
    let add = rule(.belowTarget, .pounds, amount: 3, byRPE: 1)
    #expect(RuleEngine.suggestion(for: facts(load: 70, effort: 4, target: 2, planned: 70, equipment: .dumbbell), rules: [add], steps: steps, setId: setId)?.toLb == 75)
    #expect(RuleEngine.suggestion(for: facts(load: 140, effort: 4, target: 2, planned: 140, equipment: .machine), rules: [add], steps: steps, setId: setId)?.toLb == 150)
}

@Test func backOffIsTheStepNearestTwentyTwoAndAHalfPercentLighterThanTheTopSetDone() {
    let backOff = rule(.afterTopSet, .backOff, minPct: 20, maxPct: 25, quote: "Back down sets are 20-25% lighter than your top set.")
    let s = RuleEngine.suggestion(for: facts(load: 225, role: .top, planned: nil), rules: [backOff], steps: steps, setId: setId)
    #expect(s?.toLb == 175 && s?.role == .backOff)   // 225 × 0.775 = 174.4 → 175
    #expect(s?.reason == "20–25% lighter than the top set")
    #expect(RuleEngine.suggestion(for: facts(load: 70, role: .top, planned: nil, equipment: .dumbbell), rules: [backOff], steps: steps, setId: setId)?.toLb == 55)
    // Not a top set: the rule does not fire.
    #expect(RuleEngine.suggestion(for: facts(load: 225, role: .backOff, planned: nil), rules: [backOff], steps: steps, setId: setId) == nil)
    #expect(RuleEngine.backOffFraction(minPct: 20, maxPct: 25) == 0.225)
}

@Test func nextSessionRulesNeverChangeTheLoadMidSession() {
    let double = rule(.allSetsAtTopOfRange, .pounds, amount: 5, scope: .nextSession)
    let s = RuleEngine.suggestion(for: facts(reps: 8, max: 8, allTop: true), rules: [double], steps: steps, setId: setId)
    #expect(s?.scope == .nextSession && s?.toLb == 230 && s?.reason == "every set at 8")
    #expect(RuleEngine.suggestion(for: facts(reps: 7, max: 8, allTop: false), rules: [double], steps: steps, setId: setId) == nil)
    let restPause = rule(.restPauseOverGoal, .loadSteps, amount: 1, scope: .nextSession)
    #expect(RuleEngine.suggestion(for: facts(load: 90, reps: 22, role: .restPause, planned: nil, total: 20, equipment: .machine), rules: [restPause], steps: steps, setId: setId)?.toLb == 100)
    #expect(RuleEngine.suggestion(for: facts(load: 90, reps: 18, role: .restPause, planned: nil, total: 20), rules: [restPause], steps: steps, setId: setId) == nil)
    let past = rule(.topSetPastRange, .loadSteps, amount: 1, scope: .nextSession)
    #expect(RuleEngine.suggestion(for: facts(reps: 10, max: 8, role: .top), rules: [past], steps: steps, setId: setId)?.toLb == 230)
    #expect(RuleEngine.suggestion(for: facts(reps: 8, max: 8, role: .top), rules: [past], steps: steps, setId: setId) == nil)
}

@Test func nothingAppliesUnconfirmedAndSpecificRulesWinAndRepsRulesGiveNoLoad() {
    let unconfirmed = rule(.afterTopSet, .backOff, minPct: 20, maxPct: 25, confirmed: false)
    #expect(RuleEngine.suggestion(for: facts(role: .top), rules: [unconfirmed], steps: steps, setId: setId) == nil)
    let general = rule(.aboveTarget, .percent, amount: -5, byRPE: 1)
    let specific = rule(.aboveTarget, .pounds, amount: -10, byRPE: 1, appliesTo: "Bench press")
    let s = RuleEngine.suggestion(for: facts(effort: 0, target: 2), rules: [general, specific], steps: steps, setId: setId)
    #expect(s?.ruleId == specific.id && s?.toLb == 220)   // his bench rule, capped at one step
    let reps = rule(.repsBelowMin, .reps, amount: -1)
    #expect(RuleEngine.suggestion(for: facts(reps: 5, min: 6), rules: [reps], steps: steps, setId: setId) == nil)
    #expect(RuleEngine.ruleWords(general) == "5 percent down" && RuleEngine.ruleWords(unconfirmed) == "20 to 25 percent lighter")
}

@Test func videoCropWindowsComeFromTheRepTimes() {
    let w = VideoCropper.window(repTimes: [3.4, 5.9, 8.3, 10.9], clipDuration: 16)
    #expect(abs(w.start - 2.9) < 1e-9 && abs(w.end - 11.4) < 1e-9)
    let early = VideoCropper.window(repTimes: [0.2, 2.5], clipDuration: 5)
    #expect(early.start == 0 && early.end == 3.0)
    let capped = VideoCropper.window(repTimes: [1, 14.8], clipDuration: 15)
    #expect(capped.end == 15)
    // No SAM result: the set's own start and end, the pre-roll trimmed.
    let none = VideoCropper.window(repTimes: [], clipDuration: 24)
    #expect(none.start == 2.5 && none.end == 23.5)
}

@Test func twoVideosFromTwoMovementsAndNeverAVerdict() {
    let now = Date()
    func set(_ ex: String, _ index: Int, flagged: Bool, role: SetRole? = .top) -> LoggedSet {
        LoggedSet(id: UUID(), exerciseId: ex, setIndex: index, loadLb: 100, reps: 8, rpe: nil, role: role, flaggedForCoach: flagged,
                  repCount: RepCount(source: .measured, repTimes: [3, 5.5, 8]), startedAt: now, endedAt: now.addingTimeInterval(20), clipFile: "c.mov", edits: [])
    }
    let session = Session(id: UUID(), programDayId: "d1", startedAt: now, endedAt: now, sets: [
        set("bench", 0, flagged: true), set("bench", 1, flagged: true, role: .backOff), set("row", 0, flagged: true), set("curl", 0, flagged: true),
    ], notes: [])
    let picks = VideoCropper.picks(from: [session], names: { $0.capitalized })
    #expect(picks.count == 2 && Set(picks.map(\.caption)).count == 2)
    #expect(picks.map(\.caption).contains("Bench · top set"))
    #expect(picks.allSatisfy { abs($0.cropStart - 2.5) < 1e-9 && abs($0.cropEnd - 8.5) < 1e-9 })
    let unflagged = Session(id: UUID(), programDayId: "d1", startedAt: now, endedAt: now, sets: [set("bench", 0, flagged: false)], notes: [])
    #expect(VideoCropper.picks(from: [unflagged], names: { $0 }).isEmpty)
}
