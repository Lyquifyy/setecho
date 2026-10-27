import Foundation

// The coach's program, from the spreadsheet (HANDOFF.md §4). Field names match the backend's JSON.

struct Program: Codable, Equatable {
    var name: String
    var weeks: [ProgramWeek]
    var importedAt: Date
    var flags: [ImportFlag]
}

struct ProgramWeek: Codable, Equatable {
    var number: Int
    var days: [ProgramDay]
}

struct ProgramDay: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var exercises: [PlannedExercise]
}

struct PlannedExercise: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var sets: [PlannedSet]
    /// What the athlete moves; decides what the camera tracks for the measured rep count.
    var equipment: Equipment
    var restSeconds: Int?
    var notes: String?

    init(id: String, name: String, sets: [PlannedSet], equipment: Equipment? = nil, restSeconds: Int?, notes: String?) {
        self.id = id
        self.name = name
        self.sets = sets
        self.equipment = equipment ?? Equipment.infer(from: name)
        self.restSeconds = restSeconds
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey { case id, name, sets, equipment, restSeconds, notes }

    /// Programs imported before `equipment` existed decode with it inferred from the name.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        sets = try c.decode([PlannedSet].self, forKey: .sets)
        equipment = try c.decodeIfPresent(Equipment.self, forKey: .equipment) ?? Equipment.infer(from: name)
        restSeconds = try c.decodeIfPresent(Int.self, forKey: .restSeconds)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
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

/// "6-8 reps" is repsMin 6, repsMax 8 with reps nil.
struct PlannedSet: Codable, Equatable {
    var reps: Int?
    var repsMin: Int?
    var repsMax: Int?
    var loadLb: Double?
    var rpe: Double?
    var rir: Int?
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
    /// "8", "6–8", or "AMRAP"-style unknowns as "?".
    var repsText: String {
        if let reps { return "\(reps)" }
        if let repsMin, let repsMax { return "\(repsMin)–\(repsMax)" }
        return "?"
    }

    /// "225 × 8" for the HUD, or just the reps when the sheet gives no load.
    var targetText: String {
        if let loadLb { return "\(Format.number(loadLb)) × \(repsText)" }
        return "× \(repsText)"
    }

    var intensityText: String? {
        if let rpe { return "RPE \(Format.number(rpe))" }
        if let rir { return "RIR \(rir)" }
        return nil
    }
}

extension PlannedExercise {
    /// "4 × 8 · 185 lb · RPE 8", straight from the sheet. Uses the first set when sets are uniform.
    var summary: String {
        guard let first = sets.first else { return "No sets" }
        let uniform = sets.allSatisfy { $0 == first }
        var parts = [uniform ? "\(sets.count) × \(first.repsText)" : "\(sets.count) sets"]
        if uniform, let load = first.loadLb { parts.append(Format.load(load)) }
        if uniform, let intensity = first.intensityText { parts.append(intensity) }
        return parts.joined(separator: " · ")
    }

    var restText: String? {
        restSeconds.map { "Rest \(Format.duration(TimeInterval($0)))" }
    }
}
