import SwiftUI
import Testing
@testable import Setecho

/// The redesigned session screen's states, rendered light and dark at iPhone size (DESIGN.md
/// Session). Run with TEST_RUNNER_HUD_SHOTS=<folder> to write the PNGs for review; without it the
/// test still renders every state, so a broken one fails here.
@Test @MainActor func everySessionScreenStateRendersLightAndDark() throws {
    let folder = ProcessInfo.processInfo.environment["HUD_SHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    for (name, model) in SessionHUDModel.gallery {
        for scheme in [ColorScheme.light, .dark] {
            let view = SessionHUD(model: model)
                .frame(width: 402, height: 874)
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.uiImage, "\(name) \(scheme)")
            #expect(image.size.width == 402 && image.size.height == 874)
            if let folder, let png = image.pngData() {
                try png.write(to: folder.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }
}
