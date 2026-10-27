import Foundation

// The week's numbers, computed on the phone from Apple Health and the log, sent to the backend
// as plain numbers so every check-in answer can cite them (HANDOFF.md §5).
// Calendar dates travel as "yyyy-MM-dd" strings, the backend's shape.

struct WeekFacts: Codable, Equatable {
    var weekStart: String
    var weekEnd: String
    var daily: [DayFacts]
    var targets: MacroTargets
    var showDate: String?
    var lastCheckInWeightLb: Double?
    /// Metric -> the app that wrote it to Apple Health, e.g. "weight": "Withings".
    var sources: [String: String]
    /// The coach's assigned cardio, from Settings. Text only; the LISS numbers come from Health.
    var cardioProtocol: String? = nil
}

struct DayFacts: Codable, Equatable {
    var date: String
    var isTrainingDay: Bool
    var kcal: Double?
    var proteinG: Double?
    var carbsG: Double?
    var fatG: Double?
    var steps: Double?
    var sleepHours: Double?
    var weighInLb: Double?
    var liss: [LissSession]
}

struct LissSession: Codable, Equatable {
    var type: String
    var minutes: Int
}

struct MacroTargets: Codable, Equatable {
    var training: Macros
    var rest: Macros

    func forDay(training isTraining: Bool) -> Macros { isTraining ? training : rest }
}

struct Macros: Codable, Equatable {
    var kcal: Double
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
}

/// "yyyy-MM-dd" in the device's calendar, the only way a calendar day is written on the wire.
enum DayKey {
    static func string(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(_ string: String, calendar: Calendar = .current) -> Date? {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
