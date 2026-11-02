import XCTest

/// The demo video's Setup footage (design/handoff-nov1-setup-recording.md): the real import flow on the
/// simulator, against the live backend, with the synthetic coach's three files pasted in and every
/// screen held long enough to read. `ios/scripts/record_setup.sh` runs it and records one clip per step.
///
/// The host and the test keep in step through marker files in `SETUP_MARKERS` (set with
/// TEST_RUNNER_SETUP_MARKERS): the test writes `clip-N.start`, waits for the host's `clip-N.recording`,
/// drives the step, writes `clip-N.end` and waits for `clip-N.stopped`. Without the variable it runs the
/// flow with the same pauses and no recording, which is a fine smoke test of the flow itself.
///
/// The text is put on the device pasteboard and pasted through the field's own Paste, so it reads as a
/// paste on screen, not as typing. Nothing in the app changes for the recording: a parse that fails or a
/// review that shows an error fails the test, so the step gets reshot rather than kept.
@MainActor
final class SetupRecordingTests: XCTestCase {
    private var app: XCUIApplication!
    private var markers: URL?

    override func setUpWithError() throws {
        continueAfterFailure = false
        markers = ProcessInfo.processInfo.environment["SETUP_MARKERS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let markers { try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true) }
        app = XCUIApplication()
    }

    func testRecordSetupFlow() throws {
        let program = try fixture("synthetic_program", "csv")
        let form = try fixture("synthetic_form", "txt")
        let rules = try fixture("synthetic_rules_email", "txt")

        // A system alert mid-flow (notifications, a paste permission) is answered so the flow goes on;
        // it would still be in the footage, so the host log notes it.
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow Paste", "Allow", "OK"] where alert.buttons[label].exists {
                NSLog("SetupRecording: system alert answered with \(label): \(alert.label)")
                alert.buttons[label].tap()
                return true
            }
            return false
        }

        app.launch()
        let setUp = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Set up with your coach")).firstMatch
        XCTAssertTrue(setUp.waitForExistence(timeout: 20), "Today should open on the first run")
        hold(1.5) // the brand reveal is over

        // 1. The program: first-run Today, the setup button, paste, parse, the review held and scrolled.
        beginClip(1)
        hold(2.5)
        setUp.tap()
        try waitForScreen("Coach's program")
        hold(1.5)
        try paste(program, into: "Program text")
        hold(1.2)
        tapFooter("Read spreadsheet")
        try waitForReview(step: 1)
        hold(3)
        scrollSlowly(secondsPerScreenful: 2.2)
        hold(1.5)
        endClip(1)

        // 2. The form: save the program, paste the form, parse, the review field by field.
        beginClip(2)
        hold(1)
        tapFooter("Save program")
        try waitForScreen("Check-in form")
        hold(1.5)
        try paste(form, into: "Check-in form")
        hold(1.2)
        tapFooter("Read form")
        try waitForReview(step: 2)
        hold(3)
        scrollSlowly(secondsPerScreenful: 2)
        hold(1.5)
        endClip(2)

        // 3. The rules: save the form, paste his email, parse, each rule card held about 2 s.
        beginClip(3)
        hold(1)
        tapFooter("Save check-in form")
        try waitForScreen("His instructions")
        hold(1.5)
        try paste(rules, into: "Coach’s instructions")
        hold(1.2)
        tapFooter("Read his rules")
        try waitForReview(step: 3)
        hold(3)
        scrollCardByCard(headers: ["Adjusting loads", "How hard, and the rest", "Check-ins", "When a machine’s taken", "Left out"], hold: 2)
        hold(1.5)
        endClip(3)

        // 4. Today with the imported plan.
        beginClip(4)
        hold(1)
        tapFooter("Save his rules")
        let start = app.buttons["Start session"]
        let rest = app.staticTexts["Rest day"]
        XCTAssertTrue(waitForAny([start, rest], timeout: 20), "Today should show the imported plan")
        XCTAssertFalse(setUp.exists, "The setup button should be gone once the plan is in")
        hold(3.5)
        endClip(4)
    }

    // MARK: - Driving the flow

    private func fixture(_ name: String, _ ext: String) throws -> String {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: ext, subdirectory: "import")
                                ?? bundle.url(forResource: name, withExtension: ext), "\(name).\(ext) in the test bundle")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The input step's title, under the brand header.
    private func waitForScreen(_ title: String) throws {
        let header = app.staticTexts[title]
        XCTAssertTrue(header.waitForExistence(timeout: 15), "\(title) should be on screen")
    }

    /// Puts the text on the device pasteboard and pastes it through the field's edit menu.
    private func paste(_ text: String, into label: String) throws {
        UIPasteboard.general.string = text
        let editor = app.textViews[label].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "\(label) field")
        editor.tap()
        hold(1)
        editor.press(forDuration: 1.1)
        let pasteItem = app.menuItems["Paste"]
        if !pasteItem.waitForExistence(timeout: 3) {
            // A focused, empty field shows the menu on a second tap.
            editor.tap()
            XCTAssertTrue(pasteItem.waitForExistence(timeout: 3), "the edit menu's Paste for \(label)")
        }
        pasteItem.tap()
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let landed = NSPredicate(format: "value CONTAINS %@", String(firstLine.prefix(24)))
        let filled = expectation(for: landed, evaluatedWith: editor)
        wait(for: [filled], timeout: 10)
    }

    private func tapFooter(_ title: String) {
        let button = app.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "\(title) button")
        XCTAssertTrue(button.isEnabled, "\(title) should be enabled")
        button.tap()
    }

    /// The parse: waits for the review's eyebrow, and fails on the input screen's error card.
    private func waitForReview(step: Int) throws {
        let eyebrow = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "step \(step) of 3")).firstMatch
        let failed = app.staticTexts["Couldn't read it"]
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            if eyebrow.exists { return }
            if failed.exists {
                let detail = app.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " | ")
                XCTFail("Step \(step) came back with an error: \(detail)")
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("Step \(step): no review after 240 s")
    }

    private func waitForAny(_ elements: [XCUIElement], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if elements.contains(where: { $0.exists }) { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

    private func hold(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    // MARK: - Scrolling at a readable pace

    private var window: XCUIElement { app.windows.firstMatch }
    /// Below the brand header, above the footer bar: where a drag can start and end.
    private var dragTop: CGFloat { window.frame.minY + 150 }
    private var dragBottom: CGFloat { window.frame.maxY - 170 }

    /// A slow drag of `points` upward (content moves up), held at the end so nothing flings.
    /// It runs in the page's right-hand gutter: a drag that starts on a rule row or a button can
    /// read as a tap on it, and the left edge is the navigation stack's back swipe.
    private func drag(by points: CGFloat, velocity: CGFloat = 280) {
        var remaining = points
        while remaining > 4 {
            let span = min(remaining, dragBottom - dragTop)
            let x = window.frame.maxX - 8
            let from = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: dragBottom))
            let to = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: dragBottom - span))
            from.press(forDuration: 0.15, thenDragTo: to, withVelocity: XCUIGestureVelocity(velocity), thenHoldForDuration: 0.35)
            remaining -= span
        }
    }

    /// Scrolls the review in screenfuls until its last text is on screen, pausing to read each one.
    private func scrollSlowly(secondsPerScreenful: TimeInterval, maxScreenfuls: Int = 12) {
        guard let bottom = lowestText() else { return }
        var count = 0
        while !bottom.isHittable, count < maxScreenfuls {
            drag(by: (dragBottom - dragTop) * 0.9)
            hold(secondsPerScreenful)
            count += 1
        }
    }

    /// Brings each card header in turn to the top of the content, holding on each card.
    private func scrollCardByCard(headers: [String], hold seconds: TimeInterval) {
        for header in headers {
            let element = app.staticTexts[header].firstMatch
            guard element.exists else { continue }
            let offset = element.frame.minY - dragTop
            if offset > 24 {
                drag(by: offset)
            }
            hold(seconds)
            if lowestText()?.isHittable == true { break }
        }
        if let bottom = lowestText(), !bottom.isHittable {
            scrollSlowly(secondsPerScreenful: seconds)
        }
    }

    /// The text furthest down the content, on screen or not: where the scroll ends.
    private func lowestText() -> XCUIElement? {
        let texts = app.scrollViews.firstMatch.staticTexts.allElementsBoundByIndex
        return texts.max { $0.frame.maxY < $1.frame.maxY }
    }

    // MARK: - Markers for the host's recorder

    private func beginClip(_ n: Int) {
        guard let markers else { return }
        touch(markers.appendingPathComponent("clip-\(n).start"))
        waitFor(markers.appendingPathComponent("clip-\(n).recording"), what: "the recorder for clip \(n)")
    }

    private func endClip(_ n: Int) {
        guard let markers else { return }
        touch(markers.appendingPathComponent("clip-\(n).end"))
        waitFor(markers.appendingPathComponent("clip-\(n).stopped"), what: "clip \(n) to stop")
    }

    private func touch(_ url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    private func waitFor(_ url: URL, what: String, timeout: TimeInterval = 60) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("Waited \(Int(timeout)) s for \(what)")
    }
}
