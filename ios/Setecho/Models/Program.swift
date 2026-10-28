import Foundation

// The coach's program, from the spreadsheet (HANDOFF.md §4). Field names match the backend's JSON.

struct Program: Codable, Equatable {
    var name: String
    /// The training cycle: training and rest days in the sheet's order (HANDOFF.md §7, Training cycle).
    var weeks: [ProgramWeek]
    /// Blocks the coach adds on top of days ("abs 2x per week"); never a day.
    var addOns: [AddOn]
    /// Load-adjustment rules drafted from the sheet's notes, unconfirmed (HANDOFF.md §8).
    var rules: [ProgressionRule]
    var importedAt: Date
    var flags: [ImportFlag]

    init(name: String, weeks: [ProgramWeek], addOns: [AddOn] = [], rules: [ProgressionRule] = [], importedAt: Date, flags: [ImportFlag]) {
        self.name = name
        self.weeks = weeks
        self.addOns = addOns
        self.rules = rules
        self.importedAt = importedAt
        self.flags = flags
    }

    private enum CodingKeys: String, CodingKey { case name, weeks, addOns, rules, importedAt, flags }

    /// Programs imported before add-ons existed decode with none (HANDOFF.md §4, Migrations).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        weeks = try c.decode([ProgramWeek].self, forKey: .weeks)
        addOns = try c.decodeIfPresent([AddOn].self, forKey: .addOns) ?? []
        rules = try c.decodeIfPresent([ProgressionRule].self, forKey: .rules) ?? []
        importedAt = try c.decode(Date.self, forKey: .importedAt)
        flags = try c.decodeIfPresent([ImportFlag].self, forKey: .flags) ?? []
    }
}

struct ProgramWeek: Codable, Equatable {
    var number: Int
    var days: [ProgramDay]
}

enum DayKind: String, Codable {
    case training, rest
}

struct ProgramDay: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var exercises: [PlannedExercise]
    /// A rest day has no lifts and is never a session.
    var kind: DayKind
    /// His words for the day's cardio, e.g. "25 minutes of fasted LISS".
    var cardio: String?

    init(id: String, name: String, exercises: [PlannedExercise], kind: DayKind = .training, cardio: String? = nil) {
        self.id = id
        self.name = name
        self.exercises = exercises
        self.kind = kind
        self.cardio = cardio
    }

    private enum CodingKeys: String, CodingKey { case id, name, exercises, kind, cardio }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        exercises = try c.decode([PlannedExercise].self, forKey: .exercises)
        kind = try c.decodeIfPresent(DayKind.self, forKey: .kind) ?? .training
        cardio = try c.decodeIfPresent(String.self, forKey: .cardio)
    }

    var isRest: Bool { kind == .rest }
}

enum AddOnTiming: String, Codable {
    /// Joins that day's session, after the last lift.
    case withSession
    /// Its own short morning session.
    case onWaking
}

/// A block the coach adds on top of days, outside the cycle (HANDOFF.md §7, Training cycle and add-ons).
struct AddOn: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var exercises: [PlannedExercise]
    /// "2x per week" → 2
    var perWeek: Int
    var timing: AddOnTiming
    /// His words: "Complete these 4x per week upon waking:"
    var quote: String
}

/// The coach's own "or" option for an exercise, with his words.
struct Alternate: Codable, Equatable {
    var name: String
    var quote: String
    /// "Sheet" · "Coach's reply, Oct 29"
    var source: String
}

struct PlannedExercise: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var sets: [PlannedSet]
    /// What the athlete moves; decides what the camera tracks for the measured rep count.
    var equipment: Equipment
    var restSeconds: Int?
    /// The bottom of a day-level rest range: a quiet "ready when you are" there.
    var restMinSeconds: Int?
    var notes: String?
    /// The coach's own "or" options; empty when he gave none.
    var alternates: [Alternate]

    init(id: String, name: String, sets: [PlannedSet], equipment: Equipment? = nil, restSeconds: Int?, restMinSeconds: Int? = nil,
         notes: String?, alternates: [Alternate] = []) {
        self.id = id
        self.name = name
        self.sets = sets
        self.equipment = equipment ?? Equipment.infer(from: name)
        self.restSeconds = restSeconds
        self.restMinSeconds = restMinSeconds
        self.notes = notes
        self.alternates = alternates
    }

    private enum CodingKeys: String, CodingKey { case id, name, sets, equipment, restSeconds, restMinSeconds, notes, alternates }

    /// Programs imported before `equipment` existed decode with it inferred from the name.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        sets = try c.decode([PlannedSet].self, forKey: .sets)
        equipment = try c.decodeIfPresent(Equipment.self, forKey: .equipment) ?? Equipment.infer(from: name)
        restSeconds = try c.decodeIfPresent(Int.self, forKey: .restSeconds)
        restMinSeconds = try c.decodeIfPresent(Int.self, forKey: .restMinSeconds)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        alternates = try c.decodeIfPresent([Alternate].self, forKey: .alternates) ?? []
    }

    /// Warm-ups come before a lift, never before a timed set or a pure rest-pause set (HANDOFF.md §7, Warm-up sets).
    var hasWarmups: Bool {
        guard let first = sets.first else { return false }
        return first.seconds == nil
    }
}

/// Mirrors `Equipment` in backend/app/reps.py, including the name-based fallback.
enum Equipment: String, Codable, CaseIterable {
    case barbell, dumbbell, machine, cable, bodyweight

    var label: String {
        switch self {
        case .barbell: "Barbell"
        case .dumbbell: "Dumbbell"
        case .machine: "Machine"
        case .cable: "Cable"
        case .bodyweight: "Bodyweight"
        }
    }

    private static let hints: [(Equipment, [String])] = [
        (.dumbbell, ["dumbbell", "db ", "db-", "dbs", "kettlebell", "kb "]),
        (.cable, ["cable", "pushdown", "pulldown", "lat pull", "face pull", "rope", "pressdown"]),
        (.machine, ["machine", "smith", "leg press", "hack squat", "pec deck", "leg curl", "leg extension",
                    "hip thrust machine", "chest press machine", "row machine", "seated row", "calf raise"]),
        (.bodyweight, ["pull-up", "pull up", "pullup", "chin-up", "chin up", "chinup", "push-up", "push up",
                       "pushup", "dip", "plank", "bodyweight", "hanging", "nordic", "back extension", "crunch"]),
    ]

    /// Barbell when nothing in the name says otherwise. Same rules as the backend's `infer_equipment`.
    static func infer(from name: String) -> Equipment {
        let lowered = " \(name.lowercased()) "
        for (equipment, words) in hints where words.contains(where: { lowered.contains($0) }) {
            return equipment
        }
        return .barbell
    }
}

/// The kind of set: a warm-up (phone-only), a top set, a back-off ("back down") set, or a rest-pause set.
enum SetRole: String, Codable {
    case warmup, top, backOff, restPause

    var label: String {
        switch self {
        case .warmup: "Warm-up"
        case .top: "Top set"
        case .backOff: "Back-off"
        case .restPause: "Rest-pause"
        }
    }
}

/// "6-8 reps" is repsMin 6, repsMax 8 with reps nil.
struct PlannedSet: Codable, Equatable {
    var reps: Int?
    var repsMin: Int?
    var repsMax: Int?
    var loadLb: Double?
    var rpe: Double?
    var rir: Int?
    /// A timed set: a hold ("20 seconds") or a duration ("5 minutes" = 300); reps stay nil.
    var seconds: Int?
    /// A rest-pause set's target ("20 total reps").
    var totalReps: Int?
    /// .top, .backOff, .restPause; nil = a straight set.
    var role: SetRole?

    init(reps: Int?, repsMin: Int?, repsMax: Int?, loadLb: Double?, rpe: Double?, rir: Int?,
         seconds: Int? = nil, totalReps: Int? = nil, role: SetRole? = nil) {
        self.reps = reps
        self.repsMin = repsMin
        self.repsMax = repsMax
        self.loadLb = loadLb
        self.rpe = rpe
        self.rir = rir
        self.seconds = seconds
        self.totalReps = totalReps
        self.role = role
    }

    var isTimed: Bool { seconds != nil }
    var isRestPause: Bool { role == .restPause }
}

/// A cell the model was unsure about. Shown with a yellow "Confirm" tag; never silently guessed.
struct ImportFlag: Codable, Equatable, Hashable {
    var path: String
    var message: String
}

extension Program {
    /// Every day in program order, with its week.
    var days: [(week: ProgramWeek, day: ProgramDay)] {
        weeks.flatMap { week in week.days.map { (week, $0) } }
    }

    func day(id: String) -> (week: ProgramWeek, day: ProgramDay)? {
        days.first { $0.day.id == id }
    }

    var exerciseCount: Int { weeks.flatMap(\.days).flatMap(\.exercises).count }
}

extension PlannedSet {
    /// "8", "6–8", "20 s" for a hold, "20 total" for a rest-pause set, or "?" for AMRAP-style unknowns.
    var repsText: String {
        if let seconds { return seconds >= 60 && seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds) s" }
        if role == .restPause, let totalReps { return "\(totalReps) total" }
        if let reps { return "\(reps)" }
        if let repsMin, let repsMax { return "\(repsMin)–\(repsMax)" }
        return "?"
    }

    /// "225 × 8" for the HUD, or just the reps when the sheet gives no load.
    var targetText: String {
        if let loadLb { return "\(Format.number(loadLb)) × \(repsText)" }
        return "× \(repsText)"
    }

    /// The reps the set is measured against: the plan's number, or the bottom of its range.
    var minimumReps: Int? { repsMin ?? reps }

    var intensityText: String? {
        if let rpe { return "RPE \(Format.number(rpe))" }
        if let rir { return "RIR \(rir)" }
        return nil
    }
}

extension PlannedExercise {
    /// "4 × 8 · 185 lb · RPE 8", or "2 × 6–8 · top + back-off", straight from the sheet.
    var summary: String {
        guard sets.first != nil else { return "No sets" }
        return ([setsText] + summaryDetails).joined(separator: " · ")
    }

    private var sameReps: Bool {
        guard let first = sets.first else { return true }
        return sets.allSatisfy { $0.reps == first.reps && $0.repsMin == first.repsMin && $0.repsMax == first.repsMax && $0.seconds == first.seconds }
    }

    /// The first part of `summary`: "4 × 8", or "2 sets" when the sets differ.
    var setsText: String {
        guard let first = sets.first else { return "No sets" }
        return sameReps ? "\(sets.count) × \(first.repsText)" : "\(sets.count) sets"
    }

    /// The rest of `summary`: the set roles, then the load and intensity when every set shares them.
    var summaryDetails: [String] {
        guard let first = sets.first else { return [] }
        let roles = sets.compactMap(\.role)
        let uniform = sets.allSatisfy { $0 == first }
        var parts: [String] = []
        if !roles.isEmpty {
            var names: [String] = []
            for role in roles where !names.contains(role.roleWord) { names.append(role.roleWord) }
            parts.append(names.joined(separator: " + "))
            if let total = sets.first(where: { $0.role == .restPause })?.totalReps, !sameReps { parts.append("\(total) total") }
        }
        if uniform, let load = first.loadLb { parts.append(Format.load(load)) }
        if uniform, let intensity = first.intensityText { parts.append(intensity) }
        return parts
    }

    var restText: String? {
        restSeconds.map { "Rest \(Format.duration(TimeInterval($0)))" }
    }
}

extension SetRole {
    /// The short word in an exercise summary: "top + back-off".
    var roleWord: String {
        switch self {
        case .warmup: "warm-up"
        case .top: "top"
        case .backOff: "back-off"
        case .restPause: "rest-pause"
        }
    }
}

extension Program {
    /// The cycle's days in order, every week (the last week wraps to week 1).
    var cycleDays: [ProgramDay] { weeks.flatMap(\.days) }
    var trainingDays: [ProgramDay] { cycleDays.filter { !$0.isRest } }

    func addOn(id: String) -> AddOn? { addOns.first { $0.id == id } }

    /// Every exercise the program names: the cycle's and the add-ons'.
    var allExercises: [PlannedExercise] { cycleDays.flatMap(\.exercises) + addOns.flatMap(\.exercises) }
}
