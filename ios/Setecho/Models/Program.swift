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
    var restSeconds: Int?
    var notes: String?
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
