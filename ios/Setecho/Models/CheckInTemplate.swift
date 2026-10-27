import Foundation

// The coach's check-in form as a template (HANDOFF.md §4). Field names match the backend's JSON.

struct CheckInTemplate: Codable, Equatable {
    var fields: [FieldSpec]
    var carriedBlocks: [CarriedBlock]
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
        case .weeksToShow: "Settings"
        case .planAccuracy: "MacroFactor + training log"
        case .nutritionConsistency: "MacroFactor via Apple Health"
        case .trainingConsistency: "Training log"
        case .cardioProtocol: "Settings + Garmin"
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

extension CheckInTemplate {
    var orderedFields: [FieldSpec] { fields.sorted { $0.order < $1.order } }
    var voiceFieldCount: Int { fields.filter { $0.source.type == .voice }.count }
    var dataFieldCount: Int { fields.filter { [.data, .drafted, .calculated].contains($0.source.type) }.count }
}
