import Foundation

// The plan the coach controls, versioned so an applied reply can be reverted (HANDOFF.md §4).
// Field names match the backend's JSON.

struct PlanState: Codable, Equatable {
    var version: Int
    var program: Program
    var targets: MacroTargets
    var cardioProtocol: String
    /// Macro text, supplements: the coach's words, carried into every check-in.
    var carriedBlocks: [CarriedBlock]
    /// How he wants loads adjusted. Nothing applies until confirmed.
    var rules: [ProgressionRule]
    /// The cycle day Today shows.
    var cycle: CycleCursor?
    /// Which cycle days each add-on joins: the athlete's choice.
    var addOnDays: [AddOnDays]
    /// Effort targets per set role, for sheets that give only rep ranges.
    var roleTargets: [RoleTarget]
    /// From his written instructions, confirmed.
    var checkInSchedule: CheckInCadence?
    /// Weekdays he asked not to be messaged (1 = Sunday).
    var quietDays: [Int]
    /// e.g. 3–4 min after a top set.
    var restRules: [RestRule]
    /// Warm-up sets he expects before each lift.
    var warmups: WarmupRule?
    /// The reply that produced this version; nil for an import.
    var replyId: UUID?

    init(version: Int, program: Program, targets: MacroTargets, cardioProtocol: String, carriedBlocks: [CarriedBlock],
         rules: [ProgressionRule] = [], cycle: CycleCursor? = nil, addOnDays: [AddOnDays] = [], roleTargets: [RoleTarget] = [],
         checkInSchedule: CheckInCadence? = nil, quietDays: [Int] = [], restRules: [RestRule] = [], warmups: WarmupRule? = nil,
         replyId: UUID?) {
        self.version = version
        self.program = program
        self.targets = targets
        self.cardioProtocol = cardioProtocol
        self.carriedBlocks = carriedBlocks
        self.rules = rules
        self.cycle = cycle
        self.addOnDays = addOnDays
        self.roleTargets = roleTargets
        self.checkInSchedule = checkInSchedule
        self.quietDays = quietDays
        self.restRules = restRules
        self.warmups = warmups
        self.replyId = replyId
    }

    private enum CodingKeys: String, CodingKey {
        case version, program, targets, cardioProtocol, carriedBlocks, rules, cycle, addOnDays, roleTargets
        case checkInSchedule, quietDays, restRules, warmups, replyId
    }

    /// Plans saved before the rules and the cycle existed decode with none (HANDOFF.md §4, Migrations).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        program = try c.decode(Program.self, forKey: .program)
        targets = try c.decode(MacroTargets.self, forKey: .targets)
        cardioProtocol = try c.decode(String.self, forKey: .cardioProtocol)
        carriedBlocks = try c.decode([CarriedBlock].self, forKey: .carriedBlocks)
        rules = try c.decodeIfPresent([ProgressionRule].self, forKey: .rules) ?? []
        cycle = try c.decodeIfPresent(CycleCursor.self, forKey: .cycle)
        addOnDays = try c.decodeIfPresent([AddOnDays].self, forKey: .addOnDays) ?? []
        roleTargets = try c.decodeIfPresent([RoleTarget].self, forKey: .roleTargets) ?? []
        checkInSchedule = try c.decodeIfPresent(CheckInCadence.self, forKey: .checkInSchedule)
        quietDays = try c.decodeIfPresent([Int].self, forKey: .quietDays) ?? []
        restRules = try c.decodeIfPresent([RestRule].self, forKey: .restRules) ?? []
        warmups = try c.decodeIfPresent(WarmupRule.self, forKey: .warmups)
        replyId = try c.decodeIfPresent(UUID.self, forKey: .replyId)
    }
}

/// The cycle day Today shows, and the calendar day it first showed (HANDOFF.md §7, Which day is today).
struct CycleCursor: Codable, Equatable {
    var dayId: String
    var since: Date
}

struct AddOnDays: Codable, Equatable {
    var addOnId: String
    var dayIds: [String]
}

// MARK: - The coach's rules (HANDOFF.md §4), on the wire as /import/rules sends them

enum RuleTrigger: String, Codable {
    case aboveTarget, belowTarget, repsBelowMin, allSetsAtTopOfRange, afterTopSet, restPauseOverGoal, topSetPastRange
}

enum RuleAdjust: String, Codable {
    case percent, pounds, reps, backOff, loadSteps
}

enum RuleScope: String, Codable {
    case nextSet, nextSession
}

/// Which kind of set a target or rest rule is about.
enum RoleName: String, Codable {
    case top, backOff, restPause, straight
}

struct ProgressionRule: Codable, Equatable, Identifiable {
    var id: String
    /// An exercise name as he wrote it, or nil for every exercise.
    var appliesTo: String?
    var when: RuleTrigger
    var byRPE: Double?
    var adjust: RuleAdjust
    /// Signed percent, pounds, reps or load steps; nil for a back-off rule.
    var amount: Double?
    var minPct: Double?
    var maxPct: Double?
    var scope: RuleScope
    /// "Sheet note, row 4" · "Coach's instructions" · "Athlete: confirmed with the coach"
    var source: String
    var quote: String?
    /// Nothing applies until the athlete confirms it.
    var confirmed: Bool
}

struct RoleTarget: Codable, Equatable {
    var role: RoleName
    /// 0 = to failure
    var rir: Double
    var source: String
    var quote: String?
    var confirmed: Bool
}

struct CheckInCadence: Codable, Equatable {
    var everyWeeks: Int
    /// 5 = Thursday
    var weekday: Int
    /// "09:00"
    var dueBy: String
    /// "America/Chicago"
    var timeZone: String
    var quote: String?
    var confirmed: Bool
}

struct RestRule: Codable, Equatable {
    var after: RoleName
    var minSeconds: Int
    var maxSeconds: Int
    var quote: String?
    var confirmed: Bool
}

struct WarmupRule: Codable, Equatable {
    var minSets: Int
    var maxSets: Int
    var maxReps: Int
    var quote: String?
    var confirmed: Bool
}

/// /import/rules response: his rules with his quotes, nothing confirmed.
struct RulesImport: Codable, Equatable {
    var rules: [ProgressionRule]
    var roleTargets: [RoleTarget]
    var restRules: [RestRule]
    var warmups: WarmupRule?
    var checkInSchedule: CheckInCadence?
    var quietDays: [Int]
    var flags: [ImportFlag]

    var isEmpty: Bool {
        rules.isEmpty && roleTargets.isEmpty && restRules.isEmpty && warmups == nil && checkInSchedule == nil && quietDays.isEmpty
    }
}

/// The coach's reply, a text or a voice note, with what it changes.
struct CoachReply: Codable, Equatable, Identifiable {
    var id: UUID
    var receivedAt: Date
    var kind: ReplyKind
    /// Local copy of the voice note, in the media folder.
    var audioFile: String?
    /// The text, or Voice Transcribe's transcript.
    var transcript: String
    var changes: [PlanChange]
    /// His sentences that sound like a change but match nothing in the plan.
    var unclear: [String]
    /// The PlanState version it produced, once applied.
    var appliedVersion: Int?
}

enum ReplyKind: String, Codable {
    case text, voiceNote
}

struct PlanChange: Codable, Equatable, Identifiable {
    var id: String
    var kind: ChangeKind
    /// One of the addressable paths the backend listed, e.g. "targets.training.carbsG".
    var path: String
    /// What it touches, in plain words: "Training-day carbs".
    var label: String
    var op: ChangeOp
    /// The number he said; must appear in `quote`.
    var amount: Double?
    /// The current value, filled by the backend from the plan.
    var before: String?
    /// Computed by the backend from before + op + amount; for a swap or an addition, his words for the new item.
    var after: String?
    /// His exact words, verbatim from the transcript.
    var quote: String
    /// "from Monday", as yyyy-MM-dd; nil = the next session.
    var appliesFrom: String?
    /// Set on the phone: the checkbox.
    var approved: Bool
}

enum ChangeKind: String, Codable {
    case macroTarget, cardio, exerciseSwap, exerciseAdd, exerciseRemove, sets, reps, load, rest, supplement, other

    /// The Coach reply screen groups changes by what they touch.
    var group: String {
        switch self {
        case .macroTarget: "Targets"
        case .cardio: "Cardio"
        case .supplement: "Supplements"
        case .exerciseSwap, .exerciseAdd, .exerciseRemove, .sets, .reps, .load, .rest, .other: "Training"
        }
    }
}

enum ChangeOp: String, Codable {
    case set, increase, decrease, replace, add, remove
}

/// One sentence of the coach's, about one exercise, played before it (optional, Settings).
struct VoiceCue: Codable, Equatable, Identifiable {
    var id: String
    var replyId: UUID
    /// A PlannedExercise id from the current plan.
    var exerciseId: String
    /// His words.
    var text: String
    /// m4a cut from his voice note; nil for a text reply (iOS speech reads it).
    var audioFile: String?
    /// Where it sits in the voice note.
    var startSec: Double?
    var endSec: Double?
    var approved: Bool
    var lastPlayedAt: Date?
}

// MARK: - Wire shapes

/// /import/form: the template plus the plan values read from its blocks.
struct FormImport: Codable, Equatable {
    var template: CheckInTemplate
    var targets: MacroTargets?
    var cardioProtocol: String?
}

/// /coach/reply response.
struct ReplyResponse: Codable, Equatable {
    struct Cue: Codable, Equatable {
        var id: String
        var exerciseId: String
        var text: String
        var startSec: Double?
        var endSec: Double?
    }

    var transcript: String
    var changes: [PlanChange]
    var unclear: [String]
    var cues: [Cue]
}

struct ReplyRequest: Codable {
    var text: String
    var plan: PlanState
    var cuesEnabled: Bool
    var today: String
}

extension PlanState {
    /// Version 1, seeded from the imports and the settings (HANDOFF.md §4, Migrations).
    static func seed(program: Program, template: CheckInTemplate?, targets: MacroTargets?, cardioProtocol: String) -> PlanState {
        PlanState(
            version: 1,
            program: program,
            targets: targets ?? template.map(CheckInTemplate.parsedTargets) ?? .zero,
            cardioProtocol: cardioProtocol,
            carriedBlocks: template?.carriedBlocks ?? [],
            replyId: nil
        )
    }

    func exerciseName(id: String) -> String? { program.exerciseName(id: id) }
}

extension MacroTargets {
    static let zero = MacroTargets(training: Macros(kcal: 0, proteinG: 0, carbsG: 0, fatG: 0),
                                   rest: Macros(kcal: 0, proteinG: 0, carbsG: 0, fatG: 0))
}

extension CoachReply {
    var isApplied: Bool { appliedVersion != nil }
    var approvedCount: Int { changes.filter(\.approved).count }

    /// "Coach replied · voice note 1:12" / "Coach replied · text"
    func summary(duration: TimeInterval?) -> String {
        switch kind {
        case .text: "Coach replied · text"
        case .voiceNote: "Coach replied · voice note\(duration.map { " \(Format.duration($0))" } ?? "")"
        }
    }
}

extension PlanChange {
    /// "250 g → 225 g"
    var beforeAfterText: String {
        [before, after].compactMap { $0 }.joined(separator: " → ")
    }

    var appliesFromDate: Date? { appliesFrom.flatMap { DayKey.date($0) } }
}

// MARK: - His rules in plain words (the Import review)

extension ProgressionRule {
    var text: String {
        let who = appliesTo.map { "\($0): " } ?? ""
        let trigger: String = switch when {
        case .aboveTarget: "a set lands \(Format.number(byRPE ?? 0)) RPE over his target"
        case .belowTarget: "a set lands \(Format.number(byRPE ?? 0)) RPE under his target"
        case .repsBelowMin: "a set falls short of the rep range"
        case .allSetsAtTopOfRange: "every set hits the top of the range"
        case .afterTopSet: "the top set is done"
        case .restPauseOverGoal: "a rest-pause set beats its total"
        case .topSetPastRange: "a top set goes past the top of its range"
        }
        let action: String = switch adjust {
        case .percent: "change the load \(signed(amount, unit: "%"))"
        case .pounds: "change the load \(signed(amount, unit: " lb"))"
        case .reps: "keep the load and change the reps \(signed(amount, unit: ""))"
        case .backOff: "back-off set \(Format.number(minPct ?? 0))–\(Format.number(maxPct ?? 0))% lighter than the top set"
        case .loadSteps: "go up \(Int(amount ?? 1)) load step\(amount == 1 ? "" : "s")"
        }
        let when = scope == .nextSession ? " next session" : ""
        return "\(who)When \(trigger): \(action)\(when)."
    }

    private func signed(_ value: Double?, unit: String) -> String {
        guard let value else { return "" }
        return "\(value > 0 ? "+" : "")\(Format.number(value))\(unit)"
    }
}

extension RoleName {
    var label: String {
        switch self {
        case .top: "Top sets"
        case .backOff: "Back-off sets"
        case .restPause: "Rest-pause sets"
        case .straight: "Straight sets"
        }
    }
}

extension RoleTarget {
    var text: String { rir == 0 ? "\(role.label): to failure" : "\(role.label): \(Format.number(rir)) rep\(rir == 1 ? "" : "s") in reserve" }
}

extension RestRule {
    var text: String { "Rest \(minSeconds / 60)–\(maxSeconds / 60) min after \(after.label.lowercased())" }
}

extension WarmupRule {
    var text: String { "\(minSets)–\(maxSets) warm-up sets of \(maxReps) reps or fewer before each lift" }
}

extension CheckInCadence {
    var text: String {
        let weekdays = ["", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let day = weekdays.indices.contains(weekday) ? weekdays[weekday] : "day \(weekday)"
        return "Check-in \(everyWeeks == 1 ? "every week" : everyWeeks == 2 ? "every other week" : "every \(everyWeeks) weeks"), \(day) by \(dueBy)"
    }
}
