import SwiftUI
import Testing
@testable import Setecho

/// The redesigned session screen's states, rendered at iPhone size (DESIGN.md Session; light only). Run with TEST_RUNNER_HUD_SHOTS=<folder> to write the PNGs for review; without it the
/// test still renders every state, so a broken one fails here.
@Test @MainActor func everySessionScreenStateRenders() throws {
    let folder = ProcessInfo.processInfo.environment["HUD_SHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    for (name, model) in SessionHUDModel.gallery {
        // A sample frame in the camera card when one is given (TEST_RUNNER_HUD_CAMERA), else the placeholder.
        let frame = ProcessInfo.processInfo.environment["HUD_CAMERA"].flatMap { UIImage(contentsOfFile: $0) }
        let feed = frame.map { AnyView(Image(uiImage: $0).resizable().scaledToFill()) }
        let renderer = ImageRenderer(content: SessionHUD(model: model).environment(\.sessionCameraFeed, feed).frame(width: 402, height: 874))
        renderer.scale = 2
        let image = try #require(renderer.uiImage, "\(name)")
        #expect(image.size.width == 402 && image.size.height == 874)
        if let folder, let png = image.pngData() {
            try png.write(to: folder.appendingPathComponent("\(name).png"))
        }
    }
}

/// Nothing on the session screen may lay it out wider than the phone (Oct 29: a 19-set day pushed
/// the whole screen past both edges). Every state, plus a day longer than any he trains, at the
/// narrowest phone this ships to and the iPhone 17 Pro.
@Test @MainActor func sessionScreenNeverOutgrowsThePhone() {
    var crowded = SessionHUDModel.readyCrowded
    crowded.progress = (1...8).map { .init(name: "Lift number \($0)", dots: Array(repeating: .upcoming, count: 5)) }
    crowded.micLabel = "A very long Bluetooth headset name"
    crowded.exercise = "Single-arm cable lateral raise with a pause"
    let states = SessionHUDModel.gallery.map(\.1) + [crowded]
    for width in [375.0, 402.0] {
        for model in states {
            let host = UIHostingController(rootView: SessionHUD(model: model))
            let size = host.sizeThatFits(in: CGSize(width: width, height: 874))
            #expect(size.width <= width + 0.5, "\(model.phase.name) laid out \(size.width) pt wide on a \(width) pt phone")
        }
    }
}
