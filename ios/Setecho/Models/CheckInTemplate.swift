import Foundation

// The coach's check-in form as a template (HANDOFF.md §4). Field names match the backend's JSON.

struct CheckInTemplate: Codable, Equatable {
    var fields: [FieldSpec]
    var carriedBlocks: [CarriedBlock]
    /// A heading the coach puts before the questions ("Overview:"), sent verbatim.
    var questionnaireHeading: String?

    init(fields: [FieldSpec], carriedBlocks: [CarriedBlock], questionnaireHeading: String? = nil) {
        self.fields = fields
        self.carriedBlocks = carriedBlocks
        self.questionnaireHeading = questionnaireHeading
    }
}

/// Macro targets, supplements: the coach's own text, copied verbatim into every check-in.
struct CarriedBlock: Codable, Equatable {
    var title: String
    var text: String
}

struct FieldSpec: Codable, Equatable, Identifiable {
    var id: String
    var label: String
    var prompt: String?
    var kind: FieldKind
    var source: FieldSource
    var order: Int
}

enum FieldKind: String, Codable {
    case number, scale10, percent, date, text, measurement, photo
}

/// Every number the app can fill without asking.
enum DataKey: String, Codable, CaseIterable {
    case weeksToShow, planAccuracy, nutritionConsistency, trainingConsistency, cardioProtocol
    case performanceNotes, lastRefeedDate, avgDailySteps, lastCheckInWeight, currentWeight, sleepDuration

    /// Where the number comes from, as shown on a SourceChip before any real sample exists.
    var sourceName: String {
        switch self {
        case .weeksToShow: "Show date"
        case .planAccuracy: "MacroFactor + training log"
        case .nutritionConsistency: "MacroFactor via Apple Health"
        case .trainingConsistency: "Training log"
        case .cardioProtocol: "Coach's plan"
        case .performanceNotes: "Training log"
        case .lastRefeedDate: "MacroFactor via Apple Health"
        case .avgDailySteps: "Garmin via Apple Health"
        case .lastCheckInWeight: "Last check-in"
        case .currentWeight: "Withings via Apple Health"
        case .sleepDuration: "Garmin via Apple Health"
        }
    }
}

/// Encoded as {"type": "data", "key": "avgDailySteps"}, the backend's shape.
struct FieldSource: Codable, Equatable {
    enum SourceType: String, Codable {
        case data, drafted, voice, photo, calculated
    }

    var type: SourceType
    var key: DataKey?

    /// The Import review's "how it'll be answered" column.
    var howAnswered: String {
        switch type {
        case .data, .calculated: "Data"
        case .drafted: "Drafted"
        case .voice: "Voice"
        case .photo: "Photos"
        }
    }

    var sourceName: String? {
        switch type {
        case .voice: "You, in the wrap-up"
        case .photo: "Photo session"
        case .data, .drafted, .calculated: key?.sourceName
        }
    }

    var needsConfirmation: Bool { type == .drafted }
}

extension FieldSpec {
    /// A measurement taken with a tape, in inches: not a body weight, and not a glucose reading a
    /// coach's form files under measurements (Oct 28: glucose went out as "91 in"). The same rule
    /// as the backend's `is_tape`.
    var isTape: Bool {
        let lower = label.lowercased()
        return kind == .measurement && !lower.contains("weight") && !["glucose", "blood", "sugar"].contains { lower.contains($0) }
    }
}

extension CheckInTemplate {
    var orderedFields: [FieldSpec] { fields.sorted { $0.order < $1.order } }
    var voiceFieldCount: Int { fields.filter { $0.source.type == .voice }.count }
    var dataFieldCount: Int { fields.filter { [.data, .drafted, .calculated].contains($0.source.type) }.count }
}

extension CheckInTemplate {
    /// Macro targets read from the coach's carried "Nutrition" block, else zeros (every day then
    /// reads as off plan). The seeding function for the first PlanState; after that the plan owns them.
    static func parsedTargets(_ template: CheckInTemplate) -> MacroTargets {
        let text = template.carriedBlocks.map(\.text).joined(separator: "\n")
        func macros(after heading: String) -> Macros? {
            guard let range = text.range(of: heading, options: .caseInsensitive) else { return nil }
            let tail = text[range.upperBound...]
            func value(_ label: String) -> Double? {
                guard let r = tail.range(of: label, options: .caseInsensitive) else { return nil }
                let rest = tail[r.upperBound...].prefix(30)
                let digits = rest.drop { !$0.isNumber }.prefix { $0.isNumber || $0 == "." }
                return Double(digits)
            }
            guard let kcal = value("Calories"), let p = value("Protein"), let c = value("Carb"), let f = value("Fat") else { return nil }
            return Macros(kcal: kcal, proteinG: p, carbsG: c, fatG: f)
        }
        let zero = Macros(kcal: 0, proteinG: 0, carbsG: 0, fatG: 0)
        return MacroTargets(training: macros(after: "Training Days") ?? zero, rest: macros(after: "Non-Training Days") ?? macros(after: "Rest Days") ?? zero)
    }
}
