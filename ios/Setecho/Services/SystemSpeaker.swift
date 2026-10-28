import AVFoundation
import CryptoKit
import Foundation

/// The one voice (HANDOFF.md §7, The spotter voice). Every model the app calls at runtime is Meta's
/// (the organizers' rule, Oct 28), so lines are spoken by Apple's on-device speech, made as human as
/// it gets: Ava (Premium) or his pick in Settings, numbers as words, lines written the way people
/// talk, and never the same line twice in a row (`SpokenText`). The fixed lines are
/// rendered to files with `AVSpeechSynthesizer.write` when a flow starts and play at once through one
/// engine; anything else is spoken live. What happened to each line is counted on `TurnTimings`.
@MainActor
final class SystemSpeaker: Speaker {
    private let audio: AudioService
    private let cacheDirectory: URL
    /// Lines waiting to render, in order, and the one rendering now. One at a time: two dozen
    /// synthesizers writing at once compete for the Premium voice, and the next line due goes first.
    private var renderQueue: [String] = []
    private var renderingNow: String?
    private var renderLoop: Task<Void, Never>?
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

    /// The file name covers the words, the voice, the rate and how lines are built: a change renders afresh.
    static func key(for text: String, voice: String, rate: Double) -> String {
        let seed = "plain|\(voice)|\(rate)|\(text)"
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
        enqueue(SpokenText.withAlternates(lines), first: false)
    }

    /// Move the lines to the front and wait, up to `limit`, for them to land: the opening line
    /// should be ready before it is due.
    func warm(_ lines: [String], within limit: Duration = .seconds(1.5)) async {
        enqueue(lines, first: true)
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline, lines.contains(where: isPending) {
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    private func isPending(_ line: String) -> Bool { renderingNow == line || renderQueue.contains(line) }

    private func enqueue(_ lines: [String], first: Bool) {
        let wanted = lines.filter { cachedAudio(for: $0) == nil && renderingNow != $0 }
        renderQueue.removeAll { wanted.contains($0) }
        renderQueue = first ? wanted + renderQueue : renderQueue + wanted
        guard renderLoop == nil else { return }
        renderLoop = Task { [weak self] in
            while let self, !self.renderQueue.isEmpty {
                let line = self.renderQueue.removeFirst()
                guard self.cachedAudio(for: line) == nil else { continue }
                self.renderingNow = line
                let url = self.fileURL(for: line)
                let voice = self.voice
                let rate = Settings.shared.voiceRate
                _ = await Task.detached(priority: .userInitiated) {
                    await SpokenText.render(line, voice: voice, rate: rate, to: url)
                }.value
                self.renderingNow = nil
            }
            self?.renderLoop = nil
        }
    }

    /// Cut whatever is playing (the app went to the background, or the flow was cancelled).
    func stop() {
        renderQueue.removeAll()
        player.cancel()
        audio.stopSpeaking()
    }

    func speak(_ text: String) async {
        let line = SpokenText.varied(text, after: lastLine)
        lastLine = line
        if isPending(line) { await warm([line], within: .milliseconds(Self.renderWaitMilliseconds)) }
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
