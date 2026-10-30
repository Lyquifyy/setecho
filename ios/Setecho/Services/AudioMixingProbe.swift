import AVFoundation
import Foundation
import Observation

/// Developer → Hearing → "Test music with the AirPods mic" (Oct 28–29: with the AirPods mic and his
/// music, the music paused at a session start and at every line). With his music playing: a session
/// start one piece at a time (audio, mic, camera, a spoken line), then a line on Apple's speech session
/// both ways (one synthesizer kept for every line, and a fresh one released after each), each followed
/// by 6 quiet seconds so he can hear whether his music comes back up. Each step records whether his
/// music was still playing and which mic listened. About 40 seconds.
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

    func run() async {
        guard !running else { return }
        running = true
        rows = []
        defer { running = false }
        await sessionStart()
    }

    /// A session start, one piece at a time, as SessionCoordinator does it: where his music stops.
    private func sessionStart() async {
        let setup = "Session start"
        let musicBefore = session.isOtherAudioPlaying
        await step(setup, "before anything") {}
        let audio = AudioService()
        audio.wantsVoiceProcessing = Settings.shared.voiceProcessing
        await step(setup, "audio set up") { audio.configure() }
        try? await Task.sleep(for: .seconds(1))
        // Oct 29: his music paused right here, as the AirPods became the mic. Does it carry on once
        // he presses play again? Up to 15 s for him to, then the rest of the start with it playing.
        if musicBefore { await waitForMusic(setup) }
        await step(setup, "mic open") { audio.startListening() }
        try? await Task.sleep(for: .seconds(2))
        let camera = SetDetector(mediaDirectory: FileManager.default.temporaryDirectory, sessionId: UUID())
        if await SetDetector.requestCamera() {
            await step(setup, "camera on") { camera.start() }
            try? await Task.sleep(for: .seconds(2.5))
        }
        await audio.speak("Testing your music, one, two, three.")   // the way his setting picks
        await step(setup, "a line spoken") {}
        try? await Task.sleep(for: .seconds(1.5))
        await step(setup, "1.5 s later") {}
        await loweringTests()
        camera.stop()
        audio.stopListening()
        try? await Task.sleep(for: .seconds(1))
    }

    /// With the AirPods recording at high quality and his music on: a line on Apple's speech session,
    /// which lowers his music for the line by itself, then 6 quiet seconds. He listens: did the music
    /// dip under the line, and come back up after? Kept: one synthesizer for every line. Released:
    /// a fresh one per line, let go when it ends, so its session has to end too.
    private func loweringTests() async {
        let setup = "Lowering"
        guard AirPodsMic.shared.isRecordingHighQuality(session) else {
            await step(setup, "skipped: the AirPods aren't recording at high quality") {}
            return
        }
        let voice = AudioService.preferredVoice()
        let tone = AudioService.currentTone
        let kept = OwnSessionSpeaker(freshPerLine: false)
        for (name, speaker) in [("Kept", kept), ("Released", OwnSessionSpeaker(freshPerLine: true))] {
            await waitForMusic(setup)
            await step(setup, "\(name): before the line") {}
            await speaker.speak(SpokenText.utterance("\(name). Your music should dip under this line.", voice: voice, tone: tone))
            await step(setup, "\(name): line done. Listen: does your music come back up?") {}
            try? await Task.sleep(for: .seconds(6))
            await step(setup, "\(name): 6 s later") {}
        }
    }

    /// His music paused: up to 15 s for him to press play.
    private func waitForMusic(_ setup: String) async {
        guard !session.isOtherAudioPlaying else { return }
        await step(setup, "your music paused: press play now") {}
        for _ in 0..<30 where !session.isOtherAudioPlaying { try? await Task.sleep(for: .milliseconds(500)) }
        await step(setup, "after you pressed play") {}
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
