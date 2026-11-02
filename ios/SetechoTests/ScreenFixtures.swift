import SwiftUI
import UIKit
@testable import Setecho

/// The stores the screen renders (ScreenRenderTests) read: the sample coach's made-up athlete
/// (`SampleCoach`, the one source of made-up data, Resources/Sample), seeded once per variant into a
/// fresh folder. Every number is made up (PRODUCT.md, Evidence on hand); nothing here is his.
@MainActor
enum ScreenFixtures {
    /// Which store a shot reads.
    enum Variant: Hashable {
        /// A training day (Day 1, abs joining), mid-week, the check-in filling itself.
        case trainingDay
        /// The same week with a coach reply to review and a MacroFactor line to update.
        case replyWaiting
        /// Today as the calendar has it, unforced (Thursday: a rest day and check-in morning).
        case asToday
        /// First run: nothing imported yet.
        case firstRun

        var scenario: SampleCoach.Scenario? {
            switch self {
            case .trainingDay: .trainingDay
            case .replyWaiting: .replyWaiting
            case .asToday: .asToday
            case .firstRun: nil
            }
        }
    }

    static func program() throws -> Program { try SampleCoach.program() }
    static func template() throws -> CheckInTemplate { try SampleCoach.template() }
    static func rules() throws -> RulesImport { try SampleCoach.rules() }

    private static var stores: [Variant: Store] = [:]

    /// One store per variant, built once per run in a fresh folder.
    static func store(_ variant: Variant) throws -> Store {
        if let store = stores[variant] { return store }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("screens-\(variant)-\(UUID().uuidString)")
        let store = Store(root: root)
        if let scenario = variant.scenario { try SampleCoach.seed(into: store, scenario: scenario) }
        stores[variant] = store
        return store
    }

    /// The app's own settings, set once: his first name for the greetings, the defaults otherwise.
    static func prepareSettings() {
        let settings = Settings.shared
        settings.athleteFirstName = "Zander"
        settings.hasSeenSessionIntro = true
        settings.developerTools = false
        settings.sampleMode = false
    }

    static func pendingReply(in store: Store) -> CoachReply? { store.pendingReply }

    // MARK: Photos

    static func photoThumbnails(_ set: PhotoSet, in store: Store) -> [Pose: UIImage] {
        var result: [Pose: UIImage] = [:]
        for photo in set.poses {
            if let data = try? Data(contentsOf: store.mediaDirectory.appendingPathComponent(photo.file)), let image = UIImage(data: data) {
                result[photo.pose] = image
            }
        }
        return result
    }

    static func collage(_ set: PhotoSet, in store: Store) -> UIImage {
        (try? Data(contentsOf: store.mediaDirectory.appendingPathComponent(set.collageFile))).flatMap(UIImage.init(data:)) ?? UIImage()
    }
}
