import AVFoundation
import Foundation
import Observation

/// Developer → Hearing → "Test music with each mic setting" (Oct 28 gym test: with the AirPods mic on
/// and music playing, restoring the music failed with '!int', "can't interrupt others"). With his
/// music playing, it runs the session's lower-and-restore under three configurations, the mic open
/// the whole time as in a session: the phone mic only, iOS 26's high-quality recording alone (the
/// app's AirPods setting), and the old call-quality HFP last, as it can stop his music (Oct 29). Each
/// step records the options iOS applied, the mic that listened, whether his music was still playing,
/// and any error, so the one that makes the session non-mixable is found on the device. First, a
/// session start step by step (Oct 29: the music still stopped there with the mic at full quality):
/// the app's own audio with the mic open, then the camera, then a spoken line.
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
        await sessionStart()
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
            let format = input.outputFormat(forBus: 0)
            if format.sampleRate > 0, format.channelCount > 0 {
                // @Sendable so the closure is not main-actor isolated: the tap runs on the realtime
                // audio thread, and a main-actor tap crashed this test on the first buffer (Oct 29).
                input.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable _, _ in }
                try? engine.start()
            } else {
                rows.append(Row(setup: name, step: "open the mic", applied: [], musicPlaying: session.isOtherAudioPlaying,
                                mic: "no mic", error: "the input has no format"))
            }
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

    /// A session start, one piece at a time, as SessionCoordinator does it: where his music stops.
    private func sessionStart() async {
        let setup = "Session start"
        await step(setup, "before anything") {}
        let audio = AudioService()
        audio.wantsVoiceProcessing = Settings.shared.voiceProcessing
        await step(setup, "audio set up") { audio.configure() }
        try? await Task.sleep(for: .seconds(1))
        await step(setup, "mic open") { audio.startListening() }
        try? await Task.sleep(for: .seconds(2))
        let camera = SetDetector(mediaDirectory: FileManager.default.temporaryDirectory, sessionId: UUID())
        if await SetDetector.requestCamera() {
            await step(setup, "camera on") { camera.start() }
            try? await Task.sleep(for: .seconds(2.5))
        }
        await audio.speak("Testing your music, one, two, three.")
        await step(setup, "a line spoken") {}
        try? await Task.sleep(for: .seconds(1.5))
        await step(setup, "1.5 s later") {}
        camera.stop()
        audio.stopListening()
        try? await Task.sleep(for: .seconds(1))
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
