import Foundation

/// Bring your history: the sets he logged before Setecho, from Liftoff's CSV and Garmin's FIT files,
/// read by the backend (`/import/history`) and kept on the phone. They give Today's "Last time" line
/// and a starting load from the first session. Imported sets carry no effort and never count as
/// measured; a set logged in the app wins over them.
struct TrainingHistory: Codable, Equatable {
    var sessions: [ImportedSession] = []
    /// Every name he confirmed that is one of his plan's exercises: name → exercise id.
    var matches: [String: String] = [:]
    /// Names he confirmed as none of them: kept as history under their own name.
    var ownNames: Set<String> = []
    /// "Liftoff weights are in pounds?", asked once.
    var liftoffUnit: WeightUnit = .lb
    var lastImportAt: Date?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try c.decodeIfPresent([ImportedSession].self, forKey: .sessions) ?? []
        matches = try c.decodeIfPresent([String: String].self, forKey: .matches) ?? [:]
        ownNames = try c.decodeIfPresent(Set<String>.self, forKey: .ownNames) ?? []
        liftoffUnit = try c.decodeIfPresent(WeightUnit.self, forKey: .liftoffUnit) ?? .lb
        lastImportAt = try c.decodeIfPresent(Date.self, forKey: .lastImportAt)
    }

    /// A name he already answered for: matched to a plan exercise, or kept as its own.
    func isConfirmed(_ name: String) -> Bool { matches[name] != nil || ownNames.contains(name) }
}

enum WeightUnit: String, Codable, CaseIterable { case lb, kg }

enum HistorySource: String, Codable, CaseIterable {
    case liftoff, garmin

    var label: String {
        switch self {
        case .liftoff: "Liftoff"
        case .garmin: "Garmin"
        }
    }
}

struct ImportedSession: Codable, Equatable, Identifiable {
    /// "liftoff:<its Date>" or "garmin:<activityId>": a newer export of the same session replaces it.
    var id: String
    var source: HistorySource
    var startedAt: Date
    /// Garmin's workout name ("Day 1 Workout"); Liftoff's export has none.
    var name: String?
    var exercises: [ImportedExercise]
}

struct ImportedExercise: Codable, Equatable {
    /// The name as the app wrote it: Liftoff's, or Garmin's exercise ("Smith Machine Bench Press").
    var name: String
    /// Liftoff's note, once per exercise. Never sent to Spark, never part of Last time.
    var note: String?
    var sets: [ImportedSet]

    /// The heaviest set, as the backend picked it: Last time.
    var topSet: ImportedSet? { sets.first { $0.role == .top && ($0.reps ?? 0) > 0 && $0.loadLb > 0 } }
    var firstBackOff: ImportedSet? { sets.first { $0.role == .backOff && ($0.reps ?? 0) > 0 } }
    /// A lift, not a hold or cardio.
    var isLifting: Bool { sets.contains { ($0.reps ?? 0) > 0 } }
}

struct ImportedSet: Codable, Equatable {
    var order: Int
    /// Liftoff keeps its decimals; Garmin's kg come back as the pounds he entered. Shown as is.
    var loadLb: Double
    var reps: Int?
    /// A hold or cardio: how long, and Liftoff's distance as exported.
    var seconds: Double?
    var distance: Double?
    /// .top for the heaviest set, .backOff for a lighter one after it, nil otherwise.
    var role: SetRole?
}

/// What `/import/history` returns: the sessions, and the sets it left out with why.
struct HistoryImportResult: Codable, Equatable {
    var sessions: [ImportedSession]
    var leftOut: [LeftOutSets]
}

struct LeftOutSets: Codable, Equatable {
    enum Reason: String, Codable { case noReps, empty }
    var source: HistorySource
    var startedAt: Date
    var exercise: String
    var sets: Int
    var reason: Reason
}

/// One name's answer from `/import/history/match`.
struct HistoryMatch: Codable, Equatable {
    var name: String
    var exerciseId: String?
}

extension TrainingHistory {
    /// Every exercise name in these sessions, once, in the order first seen.
    static func names(in sessions: [ImportedSession]) -> [String] {
        var seen = Set<String>()
        return sessions.sorted { $0.startedAt < $1.startedAt }.flatMap(\.exercises).map(\.name).filter { seen.insert($0).inserted }
    }

    /// Calendar days that have a session from both Liftoff and Garmin: he picks which to keep.
    static func sameDays(in sessions: [ImportedSession], calendar: Calendar = .current) -> [String] {
        let byDay = Dictionary(grouping: sessions) { DayKey.string($0.startedAt, calendar: calendar) }
        return byDay.filter { Set($0.value.map(\.source)).count > 1 }.keys.sorted()
    }

    /// The sessions kept: on a day in both, only the source he picked (Garmin when he hasn't).
    static func kept(_ sessions: [ImportedSession], choices: [String: HistorySource], calendar: Calendar = .current) -> [ImportedSession] {
        let conflicts = Set(sameDays(in: sessions, calendar: calendar))
        return sessions.filter { session in
            let day = DayKey.string(session.startedAt, calendar: calendar)
            guard conflicts.contains(day) else { return true }
            return session.source == (choices[day] ?? .garmin)
        }
    }

    /// The latest top set among these names: what Last time will say, and where it came from.
    static func lastTop(names: Set<String>, in sessions: [ImportedSession]) -> (session: ImportedSession, exercise: ImportedExercise, set: ImportedSet)? {
        for session in sessions.sorted(by: { $0.startedAt > $1.startedAt }) {
            for exercise in session.exercises where names.contains(exercise.name) {
                if let top = exercise.topSet { return (session, exercise, top) }
            }
        }
        return nil
    }

    /// The names matched to one plan exercise.
    func names(for exerciseId: String) -> Set<String> {
        Set(matches.filter { $0.value == exerciseId }.keys)
    }

    /// Last time per "exerciseId|role" from the imported sessions, for every plan exercise with a
    /// matched name: the latest top set under the key Today reads (the first planned set's role), and
    /// its back-off set for a planned back-off. Loads are exactly what he lifted, never rounded to his
    /// load steps: on a 10 lb machine step, 225 would be said as 230 (Oct 29, his Smith close-grip).
    func lastSets(for exercises: [PlannedExercise]) -> [String: LastSet] {
        var out: [String: LastSet] = [:]
        for exercise in exercises {
            let names = names(for: exercise.id)
            guard !names.isEmpty, let last = Self.lastTop(names: names, in: sessions), let reps = last.set.reps else { continue }
            let source = last.session.source.label
            let firstRole = exercise.sets.first?.role
            let top = LastSet(loadLb: last.set.loadLb, reps: reps, source: source, date: last.session.startedAt)
            out["\(exercise.id)|\(firstRole?.rawValue ?? "")"] = top
            if exercise.sets.contains(where: { $0.role == .backOff }), let backOff = last.exercise.firstBackOff, let r = backOff.reps {
                out["\(exercise.id)|\(SetRole.backOff.rawValue)"] = LastSet(loadLb: backOff.loadLb, reps: r, source: source, date: last.session.startedAt)
            }
        }
        return out
    }
}
