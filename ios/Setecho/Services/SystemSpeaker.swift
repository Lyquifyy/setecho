import AVFoundation
import CryptoKit
import Foundation

/// The one voice (HANDOFF.md §7, The spotter voice). Every model the app calls at runtime is Meta's
/// (the organizers' rule, Oct 28), so lines are spoken by Apple's on-device speech, made as human as
/// it gets: his pick of the installed Premium English voice (Settings), SSML pauses between clauses,
/// numbers as words, and never the same line twice in a row (`SpokenText`). The fixed lines are
/// rendered to files with `AVSpeechSynthesizer.write` when a flow starts and play at once through one
/// engine; anything else is spoken live. What happened to each line is counted on `TurnTimings`.
@MainActor
final class SystemSpeaker: Speaker {
    private let audio: AudioService
    private let cacheDirectory: URL
    /// Renders under way, by line, so a line about to be spoken can wait a moment for its own file.
    private var rendering: [String: Task<Void, Never>] = [:]
    private let player = LinePlayer()
    private var lastLine: String?

    /// A line still rendering is waited for this long before it is spoken live.
    static let renderWaitMilliseconds = 600

    init(audio: AudioService, cacheDirectory: URL) {
        self.audio = audio
        self.cacheDirectory = cacheDirectory
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    private var voice: AVSpeechSynthesisVoice? { AudioService.preferredVoice() }

    /// The file name covers the words, the voice, the rate and the pauses: a change renders afresh.
    static func key(for text: String, voice: String, rate: Double) -> String {
        let seed = "\(voice)|\(rate)|\(SpokenText.clausePause)|\(SpokenText.sentencePause)|\(text)"
        return SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24).description
    }

    private func fileURL(for text: String) -> URL {
        cacheDirectory.appendingPathComponent("\(Self.key(for: text, voice: voice?.identifier ?? "default", rate: Settings.shared.voiceRate)).caf")
    }

    /// The rendered audio for a line, if it is ready (filming mode copies it as played).
    func cachedAudio(for text: String) -> URL? {
        let url = fileURL(for: text)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Render the fixed lines (and their alternates) in the background so they play at once.
    func prerender(_ lines: [String]) {
        for line in SpokenText.withAlternates(lines) { startRender(line) }
    }

    /// Start the lines and wait, up to `limit`, for them to land: the opening line should be ready
    /// before it is due.
    func warm(_ lines: [String], within limit: Duration = .seconds(1.5)) async {
        for line in lines { startRender(line) }
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline, lines.contains(where: { rendering[$0] != nil }) {
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    private func startRender(_ line: String) {
        guard rendering[line] == nil, cachedAudio(for: line) == nil else { return }
        let url = fileURL(for: line)
        let voice = self.voice
        let rate = Settings.shared.voiceRate
        rendering[line] = Task.detached(priority: .userInitiated) {
            _ = await SpokenText.render(line, voice: voice, rate: rate, to: url)
        }
        Task { [weak self] in
            await self?.rendering[line]?.value
            self?.rendering[line] = nil
        }
    }

    /// Cut whatever is playing (the app went to the background, or the flow was cancelled).
    func stop() {
        player.cancel()
        audio.stopSpeaking()
    }

    func speak(_ text: String) async {
        let line = SpokenText.varied(text, after: lastLine)
        lastLine = line
        if rendering[line] != nil { await warm([line], within: .milliseconds(Self.renderWaitMilliseconds)) }
        if let file = cachedAudio(for: line) {
            await audio.duck()
            do {
                try await player.play(file: file)
                await audio.restore()
                TurnTimings.shared.voiceLine(.prerendered)
                return
            } catch {
                await audio.restore()
                TurnTimings.shared.voiceLine(.failed(error.localizedDescription))
            }
        } else {
            TurnTimings.shared.voiceLine(.live)
        }
        await audio.speak(line)
    }
}

/// Plays one rendered line through its own engine: one playback path for every pre-rendered line.
/// Oct 27: an `AVAudioPlayer` started as the input engine came up was dropped, silencing the opening.
@MainActor
final class LinePlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var waiter: CheckedContinuation<Void, Never>?
    /// Bumped at every line: a completion from an earlier line is ignored.
    private var generation = 0

    init() {
        engine.attach(node)
    }

    /// Play one file to the end. A file that cannot be read throws; a playback that stalls (a route
    /// change mid-line) returns after the file's length plus a second and a half.
    func play(file url: URL) async throws {
        let file = try AVAudioFile(forReading: url)
        if format != file.processingFormat {
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            format = file.processingFormat
        }
        if !engine.isRunning { try engine.start() }
        generation += 1
        let line = generation
        let seconds = Double(file.length) / file.processingFormat.sampleRate + 1.5
        await withCheckedContinuation { continuation in
            waiter = continuation
            node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in self?.done(line) }
            }
            node.play()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                self?.done(line)
            }
        }
        node.stop()
    }

    private func done(_ line: Int) {
        guard line == generation else { return }
        waiter?.resume()
        waiter = nil
    }

    func cancel() {
        node.stop()
        done(generation)
    }
}
