import AppIntents
import Foundation

/// "Hey Siri, start my Setecho check-in": opens Check-in morning (HANDOFF.md §7). The phrase must
/// contain the app's name.
struct StartCheckInIntent: AppIntent {
    static let title: LocalizedStringResource = "Start my Setecho check-in"
    static let description = IntentDescription("Runs check-in morning hands-free: weight, glucose, photos, your coach's questions.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.tab = .today
        AppRouter.shared.showCheckInMorning = true
        return .result()
    }
}

/// "Hey Siri, start my Setecho morning": the on-waking add-on (stomach vacuums) as its own short session.
struct StartMorningIntent: AppIntent {
    static let title: LocalizedStringResource = "Start my Setecho morning"
    static let description = IntentDescription("Runs this morning's add-on hands-free, with no tripod.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.tab = .today
        AppRouter.shared.showMorningSession = true
        return .result()
    }
}

struct SetechoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartCheckInIntent(),
            phrases: ["Start my \(.applicationName) check-in", "Start my \(.applicationName) check in", "\(.applicationName) check-in"],
            shortTitle: "Start check-in",
            systemImageName: "checklist"
        )
        AppShortcut(
            intent: StartMorningIntent(),
            phrases: ["Start my \(.applicationName) morning", "\(.applicationName) morning"],
            shortTitle: "Start morning",
            systemImageName: "sunrise"
        )
    }
}
