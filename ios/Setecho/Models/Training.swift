import Foundation

// Training log (HANDOFF.md §4). Everything lives on the phone.

struct Session: Codable, Equatable, Identifiable {
    var id: UUID
    /// Nil for a session that is only an add-on (the morning vacuums).
    var programDayId: String?
    var startedAt: Date
    var endedAt: Date?
    var sets: [LoggedSet]
    var notes: [VoiceNote]
    /// The add-ons this session carried, by id.
    var addOnIds: [String]

    init(id: UUID, programDayId: String?, startedAt: Date, endedAt: Date?, sets: [LoggedSet], notes: [VoiceNote], addOnIds: [String] = []) {
        self.id = id
        self.programDayId = programDayId
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.sets = sets
        self.notes = notes
        self.addOnIds = addOnIds
    }

    private enum CodingKeys: String, CodingKey { case id, programDayId, startedAt, endedAt, sets, notes, addOnIds }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        programDayId = try c.decodeIfPresent(String.self, forKey: .programDayId)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        sets = try c.decode([LoggedSet].self, forKey: .sets)
        notes = try c.decodeIfPresent([VoiceNote].self, forKey: .notes) ?? []
        addOnIds = try c.decodeIfPresent([String].self, forKey: .addOnIds) ?? []
    }
}

struct LoggedSet: Codable, Equatable, Identifiable {
    var id: UUID
    var exerciseId: String
    var setIndex: Int
    var loadLb: Double
    /// The number in the log. `repCount.source` says where it came from.
    var reps: Int
    var rpe: Double?
    /// A timed set: how long it ran (holds, the bike).
    var seconds: Int?
    /// .warmup, .top, .backOff, .restPause; nil = a straight set.
    var role: SetRole?
    /// "Flag that": a candidate for the check-in's two videos.
    var flaggedForCoach: Bool
    var repCount: RepCount
    var startedAt: Date
    var endedAt: Date
    /// Local MOV trimmed to the set.
    var clipFile: String?
    /// Audit trail for spoken corrections: "that was 7 reps".
    var edits: [SetEdit]

    init(id: UUID, exerciseId: String, setIndex: Int, loadLb: Double, reps: Int, rpe: Double?, seconds: Int? = nil,
         role: SetRole? = nil, flaggedForCoach: Bool = false, repCount: RepCount = RepCount(source: .plan),
         startedAt: Date, endedAt: Date, clipFile: String?, edits: [SetEdit]) {
        self.id = id
        self.exerciseId = exerciseId
        self.setIndex = setIndex
        self.loadLb = loadLb
        self.reps = reps
        self.rpe = rpe
        self.seconds = seconds
        self.role = role
        self.flaggedForCoach = flaggedForCoach
        self.repCount = repCount
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.clipFile = clipFile
        self.edits = edits
    }

    private enum CodingKeys: String, CodingKey {
        case id, exerciseId, setIndex, loadLb, reps, rpe, seconds, role, flaggedForCoach, repCount, startedAt, endedAt, clipFile, edits
    }

    /// A warm-up never counts anywhere (HANDOFF.md §7, Warm-up sets).
    var isWarmup: Bool { role == .warmup }

    /// Sets logged before rep counting existed decode as counted from the plan (HANDOFF.md §4, Migrations).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        exerciseId = try c.decode(String.self, forKey: .exerciseId)
        setIndex = try c.decode(Int.self, forKey: .setIndex)
        loadLb = try c.decode(Double.self, forKey: .loadLb)
        reps = try c.decode(Int.self, forKey: .reps)
        rpe = try c.decodeIfPresent(Double.self, forKey: .rpe)
        seconds = try c.decodeIfPresent(Int.self, forKey: .seconds)
        role = try c.decodeIfPresent(SetRole.self, forKey: .role)
        flaggedForCoach = try c.decodeIfPresent(Bool.self, forKey: .flaggedForCoach) ?? false
        repCount = try c.decodeIfPresent(RepCount.self, forKey: .repCount) ?? RepCount(source: .plan)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decode(Date.self, forKey: .endedAt)
        clipFile = try c.decodeIfPresent(String.self, forKey: .clipFile)
        edits = try c.decodeIfPresent([SetEdit].self, forKey: .edits) ?? []
    }
}

/// Where a set's rep count came from, and every count that was available (HANDOFF.md §4).
struct RepCount: Codable, Equatable {
    /// Which number `LoggedSet.reps` holds.
    var source: RepSource
    /// Wrist count from the watch app (P4), with its confidence.
    var watch: Int?
    var watchConfidence: Double?
    /// Instant count from body pose, at set end.
    var phone: Int?
    /// SAM's count from /sets/count, with its confidence (0-1; under 0.6 is low).
    var measured: Int?
    var confidence: Double?
    /// Seconds from the clip's start, one per measured rep.
    var repTimes: [Double]
    /// How much the reps slowed, 0–100 (SAM; the phone's pose signal as the fallback).
    var velocityLossPct: Double?
    /// Reps in reserve estimated from `velocityLossPct`; always shown as "estimated" (P4).
    var estimatedRIR: Double?
    var status: CountStatus

    init(source: RepSource, watch: Int? = nil, watchConfidence: Double? = nil, phone: Int? = nil,
         measured: Int? = nil, confidence: Double? = nil, repTimes: [Double] = [], velocityLossPct: Double? = nil,
         estimatedRIR: Double? = nil, status: CountStatus = .done) {
        self.source = source
        self.watch = watch
        self.watchConfidence = watchConfidence
        self.phone = phone
        self.measured = measured
        self.confidence = confidence
        self.repTimes = repTimes
        self.velocityLossPct = velocityLossPct
        self.estimatedRIR = estimatedRIR
        self.status = status
    }

    /// SAM's count is trusted on its own above this confidence (HANDOFF.md §7, Rep counting).
    static let confidentThreshold = 0.6
    var measuredIsConfident: Bool { (confidence ?? 0) >= Self.confidentThreshold }
}

enum RepSource: String, Codable {
    case plan, watch, phone, measured, spoken

    /// The `SourceChip` text (DESIGN.md Components).
    var chipText: String {
        switch self {
        case .plan: "Plan"
        case .watch: "Watch"
        case .phone: "Phone"
        case .measured: "Measured"
        case .spoken: "You said"
        }
    }
}

enum CountStatus: String, Codable {
    /// The clip is on its way to /sets/count: SAM is the count of record, so nothing is spoken yet.
    case counting
    case done
    /// Offline or no track: the phone count stands.
    case failed
}

extension RepCount {
    /// SAM's answer is still pending and the athlete has not overridden it: the HUD shows "Counting".
    var isCounting: Bool { status == .counting && source != .spoken && source != .measured }
}

struct SetEdit: Codable, Equatable {
    var at: Date
    var field: String
    var from: String
    var to: String
    var transcript: String
}

struct VoiceNote: Codable, Equatable, Identifiable {
    var id: UUID
    var at: Date
    var transcript: String
    var targetFieldId: String?
}

extension Session {
    var isComplete: Bool { endedAt != nil }
    /// The sets that count: everything but warm-ups.
    var workingSets: [LoggedSet] { sets.filter { !$0.isWarmup } }
}
