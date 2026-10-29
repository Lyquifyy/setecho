import SwiftUI
import Testing
import UIKit
@testable import Setecho

/// Every screen of the app, rendered at iPhone size from synthetic data (ScreenFixtures), for design
/// review side by side. Run with TEST_RUNNER_SCREEN_SHOTS=<folder> (`make screens`) to write the PNGs
/// and a manifest the contact sheet reads; without it the test still renders every screen, so one
/// that crashes or comes out blank fails here.
///
/// Unlike the HUD renders (ImageRenderer), these host each screen in a real window and snapshot it,
/// so scroll views, tab bars, toggles, text fields and sheets render as they do on the phone. Sheets
/// are presented over Today like the app presents them. The status bar is drawn in afterwards
/// (a window snapshot doesn't include it) on screens that show one.
@Suite(.serialized) @MainActor struct ScreenRenderTests {
    @Test func everyScreenRenders() async throws {
        ScreenFixtures.prepareSettings()
        let folder = ProcessInfo.processInfo.environment["SCREEN_SHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let only = ProcessInfo.processInfo.environment["SCREEN_ONLY"].map { $0.split(separator: ",").map(String.init) }
        var manifest: [[String: String]] = []
        for shot in try ScreenShots.all() where only.map({ names in names.contains { shot.name.contains($0) } }) ?? true {
            let image = try await ScreenSnapshot.capture(shot)
            #expect(image.size.width > 0, "\(shot.name)")
            #expect(!ScreenSnapshot.isBlank(image), "\(shot.name) rendered blank")
            if let folder, let png = image.pngData() {
                try png.write(to: folder.appendingPathComponent("\(shot.name).png"))
                manifest.append(["file": "\(shot.name).png", "group": shot.group, "title": shot.title, "tall": shot.tall ? "1" : "0"])
            }
        }
        if let folder {
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: folder.appendingPathComponent("manifest.json"))
        }
    }
}

/// One screen to render.
struct ScreenShot {
    enum Presentation { case screen, sheet }

    /// File name, ordered for the contact sheet: "03-today-reply".
    let name: String
    /// The contact sheet's section: "Today", "Check-in".
    let group: String
    /// The caption under the frame: "Coach reply waiting".
    let title: String
    var store: ScreenFixtures.Variant = .trainingDay
    var presentation: Presentation = .screen
    /// The whole scroll, not just the first screenful (stitched from screenfuls).
    var tall = false
    var statusBar = true
    /// How long to let it lay out, run its tasks and finish any first animation.
    var settle: Duration = .milliseconds(900)
    let view: @MainActor (Store) -> AnyView
}

@MainActor
enum ScreenShots {
    /// The tab screens as RootView shows them: inside the TabView, under its tab bar.
    /// RootView itself isn't used: its tasks start check-in morning on the due day and drain the share inbox.
    struct TabChrome<Content: View>: View {
        let tab: AppRouter.Tab
        @ViewBuilder let content: Content

        var body: some View {
            TabView(selection: .constant(tab)) {
                Tab("Today", systemImage: "calendar", value: AppRouter.Tab.today) { slot(.today) }
                Tab("History", systemImage: "list.bullet.rectangle", value: AppRouter.Tab.history) { slot(.history) }
                Tab("Check-in", systemImage: "checklist", value: AppRouter.Tab.checkIn) { slot(.checkIn) }
            }
            .tint(Theme.cobalt)
        }

        @ViewBuilder private func slot(_ which: AppRouter.Tab) -> some View {
            if which == tab { NavigationStack { content } } else { Color.clear }
        }
    }

    /// What every sheet sits on: Today, as the app opens.
    static func sheetBackground(_ store: Store) -> AnyView {
        AnyView(TabChrome(tab: .today) { TodayView() }.environment(store))
    }

    private static func wrap(_ store: Store, _ view: some View) -> AnyView {
        AnyView(view.environment(store).preferredColorScheme(.light))
    }

    static func all() throws -> [ScreenShot] {
        var shots: [ScreenShot] = []
        func add(_ shot: ScreenShot) { shots.append(shot) }

        // MARK: Today
        add(.init(name: "01-today-training", group: "Today", title: "Training day", view: { s in wrap(s, TabChrome(tab: .today) { TodayView() }) }))
        add(.init(name: "01b-today-training-full", group: "Today", title: "Training day · full scroll", tall: true,
                  view: { s in wrap(s, TabChrome(tab: .today) { TodayView() }) }))
        add(.init(name: "02-today-reply", group: "Today", title: "Coach reply + MacroFactor waiting", store: .replyWaiting,
                  view: { s in wrap(s, TabChrome(tab: .today) { TodayView() }) }))
        add(.init(name: "03-today-as-today", group: "Today", title: "Today's real date (rest day / check-in)", store: .asToday,
                  view: { s in wrap(s, TabChrome(tab: .today) { TodayView() }) }))
        add(.init(name: "04-today-first-run", group: "Today", title: "First run, nothing imported", store: .firstRun,
                  view: { s in wrap(s, TabChrome(tab: .today) { TodayView() }) }))

        // MARK: Check-in tab
        add(.init(name: "10-checkin-all", group: "Check-in", title: "All fields",
                  view: { s in wrap(s, TabChrome(tab: .checkIn) { CheckInView(store: s) }) }))
        add(.init(name: "10b-checkin-all-full", group: "Check-in", title: "All fields · full scroll", tall: true,
                  view: { s in wrap(s, TabChrome(tab: .checkIn) { CheckInView(store: s) }) }))
        add(.init(name: "11-checkin-todo", group: "Check-in", title: "To do · full scroll", tall: true,
                  view: { s in wrap(s, TabChrome(tab: .checkIn) { CheckInView(store: s, filter: .toDo) }) }))
        add(.init(name: "12-checkin-ready", group: "Check-in", title: "Ready · full scroll", tall: true,
                  view: { s in wrap(s, TabChrome(tab: .checkIn) { CheckInView(store: s, filter: .ready) }) }))
        add(.init(name: "13-review-send", group: "Check-in", title: "Review and send", tall: true, settle: .seconds(4),
                  view: { s in wrap(s, NavigationStack { ReviewSendView(coordinator: CheckInCoordinator(store: s)) }) }))

        // MARK: Check-in morning and wrap-up (the conversation layout, as the models draw it)
        for (i, state) in MorningStates.all.enumerated() {
            add(.init(name: "2\(i)-morning-\(state.key)", group: "Check-in morning", title: state.title, statusBar: false,
                      view: { s in wrap(s, state.view) }))
        }

        // MARK: Session
        add(.init(name: "30-session-intro", group: "Session", title: "How a session works", tall: true,
                  view: { s in wrap(s, SessionIntroView(onStart: {})) }))
        add(.init(name: "31-voice-guide", group: "Session", title: "What you can say", presentation: .sheet,
                  view: { s in wrap(s, VoiceGuideView()) }))
        for (name, model) in SessionHUDModel.gallery {
            add(.init(name: "3\(Self.hudIndex(name))-hud-\(name)", group: "Session HUD", title: Self.hudTitle(name), statusBar: false,
                      view: { s in wrap(s, SessionHUD(model: model).environment(\.sessionCameraFeed, Self.cameraFeed)) }))
        }

        // MARK: History
        add(.init(name: "40-history-sessions", group: "History", title: "Sessions",
                  view: { s in wrap(s, TabChrome(tab: .history) { HistoryView() }) }))
        add(.init(name: "40b-history-sessions-full", group: "History", title: "Sessions · full scroll", tall: true,
                  view: { s in wrap(s, TabChrome(tab: .history) { HistoryView() }) }))
        add(.init(name: "41-history-checkins", group: "History", title: "Check-ins",
                  view: { s in wrap(s, TabChrome(tab: .history) { HistoryView(section: .checkIns) }) }))
        add(.init(name: "42-history-photos", group: "History", title: "Photos",
                  view: { s in wrap(s, TabChrome(tab: .history) { HistoryView(section: .photos) }) }))
        add(.init(name: "43-history-plan", group: "History", title: "Plan",
                  view: { s in wrap(s, TabChrome(tab: .history) { HistoryView(section: .plan) }) }))

        // MARK: Photos
        add(.init(name: "50-photos-review", group: "Photos", title: "Photo session · review", settle: .milliseconds(1500),
                  view: { s in wrap(s, PhotoSessionView(store: s, existing: s.photoSets.max { $0.takenAt < $1.takenAt })) }))
        add(.init(name: "51-photo-viewer", group: "Photos", title: "Photo viewer", statusBar: false, settle: .milliseconds(1500),
                  view: { s in
                      guard let set = s.photoSets.max(by: { $0.takenAt < $1.takenAt }) else { return AnyView(EmptyView()) }
                      return wrap(s, PhotoViewer(viewing: PhotoViewing(photoSet: set)))
                  }))

        // MARK: Coach
        add(.init(name: "60-coach-reply", group: "Coach", title: "Coach reply · review changes", store: .replyWaiting, presentation: .sheet,
                  view: { s in wrap(s, CoachReplyView(reply: s.pendingReply!)) }))
        add(.init(name: "60b-coach-reply-full", group: "Coach", title: "Coach reply · full scroll", store: .replyWaiting, tall: true,
                  view: { s in wrap(s, CoachReplyView(reply: s.pendingReply!)) }))
        add(.init(name: "61-add-coach-reply", group: "Coach", title: "Add coach reply", presentation: .sheet,
                  view: { s in wrap(s, AddCoachReplyView()) }))
        add(.init(name: "62-chat-import", group: "Coach", title: "Import WhatsApp chat", presentation: .sheet,
                  view: { s in wrap(s, ChatImportView()) }))
        add(.init(name: "63-history-import", group: "Coach", title: "Import Liftoff and Garmin", presentation: .sheet,
                  view: { s in wrap(s, HistoryImportView()) }))

        // MARK: Import
        add(.init(name: "70-import-step1", group: "Import", title: "Step 1 · program", store: .firstRun, presentation: .sheet,
                  view: { s in wrap(s, ImportFlow()) }))
        add(.init(name: "71-import-program-review", group: "Import", title: "Program review", tall: true,
                  view: { s in wrap(s, NavigationStack { ProgramReviewView(model: try! ImportModels.program(), onSave: {}) }) }))
        add(.init(name: "72-import-form-review", group: "Import", title: "Form review", tall: true,
                  view: { s in wrap(s, NavigationStack { FormReviewView(model: try! ImportModels.form(), onSave: {}) }) }))
        add(.init(name: "73-import-rules-review", group: "Import", title: "Rules review", tall: true,
                  view: { s in wrap(s, NavigationStack { RulesReviewView(model: try! ImportModels.rules(), onSave: {}) }) }))

        // MARK: Settings and the rest of the More menu
        add(.init(name: "80-settings", group: "Settings", title: "Settings", presentation: .sheet,
                  view: { s in wrap(s, NavigationStack { SettingsView() }.tint(Theme.cobalt)) }))
        add(.init(name: "80b-settings-full", group: "Settings", title: "Settings · full scroll", tall: true,
                  view: { s in wrap(s, NavigationStack { SettingsView() }.tint(Theme.cobalt)) }))
        add(.init(name: "81-connections", group: "Settings", title: "Connections", presentation: .sheet, settle: .seconds(2),
                  view: { s in wrap(s, ConnectionsView(healthSources: ["Garmin Connect", "MacroFactor", "Withings"])) }))
        add(.init(name: "82-developer", group: "Settings", title: "Developer tools", tall: true,
                  view: { s in wrap(s, NavigationStack { DeveloperView(onClose: {}) }) }))
        return shots
    }

    // MARK: HUD

    /// A sample frame in the camera card when TEST_RUNNER_HUD_CAMERA is given, as the HUD renders take it.
    static let cameraFeed: AnyView? = ProcessInfo.processInfo.environment["HUD_CAMERA"]
        .flatMap { UIImage(contentsOfFile: $0) }
        .map { AnyView(Image(uiImage: $0).resizable().scaledToFill()) }

    static func hudIndex(_ name: String) -> String {
        ["1-ready": "2", "1b-ready-long-day": "2b", "2-armed": "3", "3-recording": "4", "4-rest": "5", "4b-rest-overtime": "6", "5-hold": "7", "6-pocket": "8", "7-session-end": "9"][name] ?? "9"
    }

    static func hudTitle(_ name: String) -> String {
        ["1-ready": "Ready", "1b-ready-long-day": "Ready · a six-lift day", "2-armed": "Armed", "3-recording": "Recording", "4-rest": "Rest", "4b-rest-overtime": "Rest's up",
         "5-hold": "Hold", "6-pocket": "Pocket", "7-session-end": "Session end"][name] ?? name
    }
}

/// The import review steps, filled the way the backend fills them.
@MainActor
enum ImportModels {
    static func program() throws -> ImportModel {
        let model = ImportModel(kind: .program)
        let program = try ScreenFixtures.program()
        model.program = program
        model.addOnDays = program.addOns.map { AddOnDays(addOnId: $0.id, dayIds: AddOnPlanner.proposedDays(for: $0, in: program)) }
        return model
    }

    static func form() throws -> ImportModel {
        let model = ImportModel(kind: .form)
        let template = try ScreenFixtures.template()
        model.formImport = FormImport(template: template, targets: CheckInTemplate.parsedTargets(template), cardioProtocol: "25 minutes of fasted LISS, 2× a week")
        return model
    }

    static func rules() throws -> ImportModel {
        let model = ImportModel(kind: .rules)
        model.rules = try ScreenFixtures.rules()
        return model
    }
}

/// Check-in morning's states, drawn with ConversationScreen and the footers CheckInMorningView and
/// WrapUpView give it. The live views start the mic and the voice on appear, so the renders build the
/// same layout from fixed transcripts instead (as ConversationScreen's preview does).
@MainActor
enum MorningStates {
    struct Morning {
        let key: String
        let title: String
        let view: AnyView
    }

    static let steps = CheckInMorningStep.allCases.map { StepTrack.Step(id: $0.wire, title: $0.title) }

    static var all: [Morning] {
        let opening: [ConversationEntry] = [
            .setecho("Morning, Zander. It's your Thursday check-in. We'll do your weight, glucose and photos, then your coach's questions."),
            .setecho("Withings has you at 180.8 this morning, down 0.8 from last week. Should I use that?"),
        ]
        let weighed = opening + [
            .athlete("Yeah, go with that."),
            .answer(label: "Current body weight", value: "180.8 lb", source: "Withings"),
            .setecho("Okay, 180.8. And your fasted glucose?"),
            .athlete("Ninety one."),
            .answer(label: "Fasted blood glucose", value: "91", source: "You said"),
            .setecho("Got it. Photos next. Stand the phone up facing you and step back until I can see all of you."),
        ]
        let questions = weighed + [
            .note("4 photos taken"),
            .setecho("Now, your coach's questions. Energy this week, 1 to 10?"),
            .athlete("Probably a seven, dipped a bit Tuesday after legs."),
        ]
        let summary: [ConversationEntry] = questions + [
            .answer(label: "Energy levels", value: "7, dipped Tuesday after legs", source: "You said"),
            .summary([
                SummarySection(title: "From you this morning", rows: [
                    SummaryRow(label: "Current body weight", value: "180.8 lb"), SummaryRow(label: "Fasted blood glucose", value: "91"),
                    SummaryRow(label: "Energy levels", value: "7, dipped Tuesday after legs"), SummaryRow(label: "Notes on recovery", value: "Good, left elbow a little cranky"),
                    SummaryRow(label: "Waist", value: "31.5 in"),
                ]),
                SummarySection(title: "From Apple Health and your log", rows: [
                    SummaryRow(label: "Accuracy on plan", value: "86%"), SummaryRow(label: "Average daily steps", value: "9,842"),
                    SummaryRow(label: "Training consistency", value: "5 of 5 sessions"),
                ]),
                SummarySection(title: "Photos", rows: [SummaryRow(label: "Check-in photos", value: "4 photos, front first")]),
            ]),
            .setecho("23 of 23 ready: 11 from you this morning, 8 from Apple Health and your log, and your 4 photos. Ready to send?"),
        ]
        let hold = HoldButton(title: "Hold to stop") {}
        func morning(_ entries: [ConversationEntry], step: Int, phase: VoicePhase, level: Double = 0, notice: String? = nil, done: Bool = false) -> AnyView {
            AnyView(ConversationScreen(eyebrow: "Thursday check-in", steps: steps, currentStep: done ? steps.count : step, entries: entries,
                                       phase: phase, level: level, notice: notice, voiceName: "Ava (Premium)") {
                if done {
                    Button("Open to send") {}.buttonStyle(.setechoPrimary)
                    HStack {
                        LinkButton(title: "Read it back", chevron: .none, hud: true) {}
                        Spacer()
                        LinkButton(title: "Start over", chevron: .none, hud: true) {}
                        Spacer()
                        LinkButton(title: "Done for now", chevron: .none, hud: true) {}
                    }
                } else {
                    hold
                }
            })
        }
        let wrapEntries: [ConversationEntry] = [
            .setecho("Four left. Hunger this week, 1 to 10?"),
            .athlete("Six, maybe a seven at night."),
            .answer(label: "Notes on appetite", value: "6, maybe 7 at night", source: "You said"),
            .setecho("Waist, bicep, thigh?"),
        ]
        return [
            Morning(key: "weight-listening", title: "Weight · listening", view: morning(opening, step: 0, phase: .listening, level: 0.35)),
            Morning(key: "glucose-speaking", title: "Glucose answered · speaking", view: morning(weighed, step: 2, phase: .speaking)),
            Morning(key: "question-thinking", title: "A question · thinking", view: morning(questions, step: 3, phase: .thinking)),
            Morning(key: "paused", title: "Paused · take your time", view: morning(questions, step: 3, phase: .paused,
                                                                                   notice: "AirPods mic unavailable, using the iPhone mic")),
            Morning(key: "done-summary", title: "Done · summary", view: morning(summary, step: 4, phase: .listening, level: 0.1, done: true)),
            Morning(key: "wrapup", title: "Wrap-up · 6 of 9", view: AnyView(
                ConversationScreen(eyebrow: "Wrap-up · 6 of 9", entries: wrapEntries, phase: .listening, level: 0.25, voiceName: "Ava (Premium)") {
                    Text("Say skip, go back, or say that again").font(.hudLabel).secondaryText().multilineTextAlignment(.center)
                    HoldButton(title: "Hold to stop") {}
                })),
        ]
    }
}

/// Hosts a screen in its own window over the app, lets it settle, and snapshots the window.
@MainActor
enum ScreenSnapshot {
    struct NoScene: Error {}

    static func capture(_ shot: ScreenShot) async throws -> UIImage {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { throw NoScene() }
        let store = try ScreenFixtures.store(shot.store)

        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.windowLevel = .alert + 1
        window.overrideUserInterfaceStyle = .light
        let root: UIViewController
        switch shot.presentation {
        case .screen: root = UIHostingController(rootView: shot.view(store))
        case .sheet: root = UIHostingController(rootView: ScreenShots.sheetBackground(store))
        }
        window.rootViewController = root
        window.makeKeyAndVisible()
        if shot.presentation == .sheet {
            try await Task.sleep(for: .milliseconds(300))
            let sheet = UIHostingController(rootView: shot.view(store))
            sheet.modalPresentationStyle = .pageSheet
            root.present(sheet, animated: false)
        }
        try await Task.sleep(for: shot.settle)

        let image = if shot.tall, let scroll = mainScrollView(in: window) {
            try await stitched(window, scroll: scroll, statusBar: shot.statusBar)
        } else {
            snapshot(window, statusBar: shot.statusBar)
        }

        if root.presentedViewController != nil { root.dismiss(animated: false) }
        window.isHidden = true
        window.rootViewController = nil
        try await Task.sleep(for: .milliseconds(150))
        return image
    }

    private static func snapshot(_ window: UIWindow, statusBar: Bool) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { ctx in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            if statusBar { drawStatusBar(in: ctx.cgContext, width: window.bounds.width) }
        }
    }

    /// The whole scroll as one picture. A window taller than about 2,700 pt draws black (8,192 px at
    /// the simulator's 3×), so the window stays phone-sized: the scroll view steps down a screenful
    /// at a time and the strips between its insets are stacked, with the top of the first screen
    /// (the header) above them and the foot of the last (the footer, the tab bar) below.
    private static func stitched(_ window: UIWindow, scroll: UIScrollView, statusBar: Bool) async throws -> UIImage {
        let bounds = window.bounds
        let frame = scroll.convert(scroll.bounds, to: window)
        let inset = scroll.adjustedContentInset
        let top = max(0, frame.minY + inset.top)
        let bottom = min(bounds.height, frame.maxY - inset.bottom)
        let visible = bottom - top
        let first = -inset.top
        let last = max(first, scroll.contentSize.height + inset.bottom - scroll.bounds.height)
        guard visible > 100, last > first else { return snapshot(window, statusBar: statusBar) }

        var strips: [(offset: CGFloat, image: UIImage)] = []
        var offset = first
        while true {
            scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            try await Task.sleep(for: .milliseconds(300))
            strips.append((offset, snapshot(window, statusBar: false)))
            if offset >= last { break }
            offset = min(last, offset + visible)
        }
        scroll.setContentOffset(CGPoint(x: 0, y: first), animated: false)

        let size = CGSize(width: bounds.width, height: top + (last - first) + visible + (bounds.height - bottom))
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(2, 16_000 / size.height)
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            func paste(_ image: UIImage, from: CGFloat, to: CGFloat, at y: CGFloat) {
                cg.saveGState()
                cg.clip(to: CGRect(x: 0, y: y, width: bounds.width, height: to - from))
                image.draw(at: CGPoint(x: 0, y: y - from))
                cg.restoreGState()
            }
            for strip in strips { paste(strip.image, from: top, to: bottom, at: top + strip.offset - first) }
            paste(strips[0].image, from: 0, to: top, at: 0)
            paste(strips[strips.count - 1].image, from: bottom, to: bounds.height, at: size.height - (bounds.height - bottom))
            if statusBar { drawStatusBar(in: cg, width: bounds.width) }
        }
    }

    /// The screen's own scroll: the tallest one across the width of the screen.
    private static func mainScrollView(in window: UIWindow) -> UIScrollView? {
        func scrollViews(_ view: UIView) -> [UIScrollView] {
            ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
        return scrollViews(window)
            .filter { !$0.isHidden && $0.window != nil && $0.bounds.width > window.bounds.width * 0.8 && $0.contentSize.height > 0 }
            .max { $0.contentSize.height < $1.contentSize.height }
    }

    /// The iPhone 17 Pro status bar, so spacing under the clock reads as it does on the phone.
    private static func drawStatusBar(in cg: CGContext, width: CGFloat) {
        let navy = UIColor(red: 0x17 / 255, green: 0x1D / 255, blue: 0x36 / 255, alpha: 1)
        let time = NSAttributedString(string: "9:41", attributes: [.font: UIFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: navy])
        let timeSize = time.size()
        time.draw(at: CGPoint(x: 78 - timeSize.width / 2, y: 31 - timeSize.height / 2))
        let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        var x = width - 28
        for name in ["battery.100percent", "wifi", "cellularbars"] {
            guard let symbol = UIImage(systemName: name, withConfiguration: config)?.withTintColor(navy, renderingMode: .alwaysOriginal) else { continue }
            let w = name.hasPrefix("battery") ? symbol.size.width * 1.15 : symbol.size.width
            x -= w
            symbol.draw(in: CGRect(x: x, y: 31 - symbol.size.height / 2, width: w, height: symbol.size.height))
            x -= 6
        }
        // The Dynamic Island.
        UIColor.black.setFill()
        UIBezierPath(roundedRect: CGRect(x: width / 2 - 63, y: 11, width: 126, height: 37), cornerRadius: 18.5).fill()
    }

    /// One flat colour from edge to edge: a screen that drew nothing.
    static func isBlank(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        let bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
        let first = (bytes[0], bytes[1], bytes[2])
        for y in stride(from: 0, to: cg.height, by: 17) {
            for x in stride(from: 0, to: cg.width, by: 13) {
                let o = y * bpr + x * bpp
                if (bytes[o], bytes[o + 1], bytes[o + 2]) != first { return false }
            }
        }
        return true
    }
}
