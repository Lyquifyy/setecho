import AVFoundation
import Foundation
import Observation

/// Developer → Hearing → "Test music with each mic setting" (Oct 28 gym test: with the AirPods mic on
/// and music playing, restoring the music failed with '!int', "can't interrupt others"). With his
/// music playing, it runs the session's lower-and-restore under three configurations, the mic open
/// the whole time as in a session: the phone mic only, iOS 26's high-quality recording alone (the
/// app's AirPods setting), and the old call-quality HFP last, as it can stop his music (Oct 29). Each
/// step records the options iOS applied, the mic that listened, whether his music was still playing,
/// and any error, so the one that makes the session non-mixable is found on the device.
@MainActor
@Observable
final class AudioMixingProbe {
    struct Row: Identifiable, Equatable {
        let id = UUID()
        var setup: String
        var step: String
        var applied: [String]
        var musicPlaying: Bool
        var mic: String
        var error: String?
    }

    private(set) var rows: [Row] = []
    private(set) var running = false

    private let session = AVAudioSession.sharedInstance()

    static let setups: [(String, AVAudioSession.CategoryOptions)] = [
        ("Phone mic only", [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker]),
        ("AirPods mic, high quality", [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker, .bluetoothHighQualityRecording]),
        ("AirPods mic, call quality (old)", [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker, .allowBluetoothHFP, .bluetoothHighQualityRecording]),
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
                let highQuality = base.contains(.bluetoothHighQualityRecording)
                    ? self.session.availableInputs?.first { $0.bluetoothMicrophoneExtension?.highQualityRecording.isSupported == true } : nil
                try? self.session.setPreferredInput(highQuality)
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
        // Back to the app's own configuration, and the input it would choose.
        try? AirPodsMic.shared.apply(to: session, ducking: false)
        try? session.setPreferredInput(AirPodsMic.shared.preferredInput(in: session))
    }

    private func step(_ setup: String, _ name: String, _ action: () throws -> Void) async {
        var error: String?
        do { try action() } catch let e { error = AudioService.describe(e) }
        let input = session.currentRoute.inputs.first
        let highQuality = input?.bluetoothMicrophoneExtension?.highQualityRecording.isEnabled == true
        rows.append(Row(setup: setup, step: name, applied: AirPodsMic.describe(session.categoryOptions),
                        musicPlaying: session.isOtherAudioPlaying,
                        mic: "\(input?.portName ?? "no mic")\(highQuality ? " · high quality" : "")", error: error))
    }

    /// One line per step for the Developer screen.
    var summary: [String] {
        rows.map { row in
            "\(row.setup) · \(row.step): \(row.error ?? "ok") · music \(row.musicPlaying ? "playing" : "NOT playing") · \(row.mic)"
        }
    }
}
