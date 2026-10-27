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
    /// The reply that produced this version; nil for an import.
    var replyId: UUID?
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
