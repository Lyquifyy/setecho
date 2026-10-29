import AVFoundation
import Foundation
import Observation

/// Developer → Hearing → "Test music with each mic setting" (Oct 28 gym test: with the AirPods mic on
/// and music playing, restoring the music failed with '!int', "can't interrupt others"). With his
/// music playing, it runs the session's lower-and-restore under three configurations, the mic open
/// the whole time as in a session: the phone mic only, plus the AirPods mic (HFP), plus iOS 26's
/// high-quality recording. Each step records the options iOS applied, whether his music was still
/// playing, and any error, so the one that makes the session non-mixable is found on the device.
@MainActor
@Observable
final class AudioMixingProbe {
    struct Row: Identifiable, Equatable {
        let id = UUID()
        var setup: String
        var step: String
        var applied: [String]
        var musicPlaying: Bool
        var error: String?
    }

    private(set) var rows: [Row] = []
    private(set) var running = false

    private let session = AVAudioSession.sharedInstance()

    static let setups: [(String, AVAudioSession.CategoryOptions)] = [
        ("Phone mic only", [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker]),
        ("AirPods mic", [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker, .allowBluetoothHFP]),
        ("AirPods mic, high quality", [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker, .allowBluetoothHFP, .bluetoothHighQualityRecording]),
    ]

    func run() async {
        guard !running else { return }
        running = true
        rows = []
        defer { running = false }
        for (name, base) in Self.setups {
            let engine = AVAudioEngine()
            await step(name, "set up and activate") {
                try self.session.setCategory(.playAndRecord, mode: .default, options: base)
                try self.session.setActive(true)
            }
            // The mic open, as in a session: HFP and high-quality recording only engage while recording.
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 2048, format: input.outputFormat(forBus: 0)) { _, _ in }
            try? engine.start()
            try? await Task.sleep(for: .seconds(1))
            await step(name, "lower the music") {
                try self.session.setCategory(.playAndRecord, mode: .default, options: base.union(.duckOthers))
                try self.session.setActive(true)
            }
            try? await Task.sleep(for: .seconds(1.5))
            await step(name, "restore, no reactivation") {
                try self.session.setCategory(.playAndRecord, mode: .default, options: base)
            }
            try? await Task.sleep(for: .seconds(1))
            await step(name, "lower again") {
                try self.session.setCategory(.playAndRecord, mode: .default, options: base.union(.duckOthers))
                try self.session.setActive(true)
            }
            try? await Task.sleep(for: .seconds(1.5))
            await step(name, "restore with reactivation (the old way)") {
                try self.session.setCategory(.playAndRecord, mode: .default, options: base)
                try self.session.setActive(true)
            }
            try? await Task.sleep(for: .seconds(1))
            input.removeTap(onBus: 0)
            engine.stop()
        }
        // Back to the app's own configuration.
        try? AirPodsMic.shared.apply(to: session, ducking: false)
    }

    private func step(_ setup: String, _ name: String, _ action: () throws -> Void) async {
        var error: String?
        do { try action() } catch let e { error = AudioService.describe(e) }
        rows.append(Row(setup: setup, step: name, applied: AirPodsMic.describe(session.categoryOptions),
                        musicPlaying: session.isOtherAudioPlaying, error: error))
    }

    /// One line per step for the Developer screen.
    var summary: [String] {
        rows.map { row in
            "\(row.setup) · \(row.step): \(row.error ?? "ok") · music \(row.musicPlaying ? "playing" : "NOT playing")"
        }
    }
}
