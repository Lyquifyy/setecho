import Foundation
import Observation

/// The few things only the athlete knows (HANDOFF.md §7 table): the assigned cardio protocol,
/// the show date, which weekdays the program schedules lifting, and the collage layout.
@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    var cardioProtocol: String { didSet { defaults.set(cardioProtocol, forKey: "cardioProtocol") } }
    /// yyyy-MM-dd, or empty when not in prep.
    var showDate: String { didSet { defaults.set(showDate, forKey: "showDate") } }
    /// Calendar weekdays (1 = Sunday … 7 = Saturday) the program schedules lifting on.
    var trainingWeekdays: Set<Int> { didSet { defaults.set(Array(trainingWeekdays).sorted(), forKey: "trainingWeekdays") } }
    var collageLayout: PhotoAlign.CollageLayout { didSet { defaults.set(collageLayout.rawValue, forKey: "collageLayout") } }
    var useSevenDayAverageWeight: Bool { didSet { defaults.set(useSevenDayAverageWeight, forKey: "useSevenDayAverageWeight") } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        cardioProtocol = defaults.string(forKey: "cardioProtocol") ?? ""
        showDate = defaults.string(forKey: "showDate") ?? ""
        trainingWeekdays = Set(defaults.array(forKey: "trainingWeekdays") as? [Int] ?? [])
        collageLayout = PhotoAlign.CollageLayout(rawValue: defaults.string(forKey: "collageLayout") ?? "") ?? .grid2x2
        useSevenDayAverageWeight = defaults.bool(forKey: "useSevenDayAverageWeight")
    }

    var showDateOrNil: String? { showDate.trimmingCharacters(in: .whitespaces).isEmpty ? nil : showDate }
}
