import AVFoundation
import CryptoKit
import Foundation

/// The one voice (HANDOFF.md §7, The spotter voice). Every model the app calls at runtime is Meta's
/// (the organizers' rule, Oct 28), so lines are spoken by Apple's on-device speech, made as human as
/// it gets: Ava (Premium) or his pick in Settings, numbers as words, lines written the way people
/// talk, and never the same line twice in a row (`SpokenText`). The fixed lines are
/// rendered to files with `AVSpeechSynthesizer.write` when a flow starts and play at once; anything
/// else is spoken live. Both go out through `VoiceOutput` (his warmth and clarity, light compression). What happened to each line is counted on `TurnTimings`.
@MainActor
final class SystemSpeaker: Speaker {
    private let audio: AudioService
    private let cacheDirectory: URL
    /// Lines waiting to render, in order, and the one rendering now. One at a time: two dozen
    /// synthesizers writing at once compete for the Premium voice, and the next line due goes first.
    private var renderQueue: [String] = []
    private var renderingNow: String?
    private var renderLoop: Task<Void, Never>?
    private var lastLine: String?

    /// A line still rendering is waited for this long before it is spoken live.
    static let renderWaitMilliseconds = 600

    init(audio: AudioService, cacheDirectory: URL) {
        self.audio = audio
        self.cacheDirectory = cacheDirectory
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    private var voice: AVSpeechSynthesisVoice? { AudioService.preferredVoice() }

    /// The file name covers the words, the voice, the rate and pitch and how lines are built: a change
    /// renders afresh. Warmth and clarity are applied as it plays, so they need no new file.
    static func key(for text: String, voice: String, tone: VoiceTone) -> String {
        let seed = "prosody2|\(voice)|\(tone.clamped.rate)|\(tone.clamped.pitch)|\(text)"
        return SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24).description
    }

    private func fileURL(for text: String) -> URL {
        cacheDirectory.appendingPathComponent("\(Self.key(for: text, voice: voice?.identifier ?? "default", tone: AudioService.currentTone)).caf")
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
                let tone = AudioService.currentTone
                _ = await Task.detached(priority: .userInitiated) {
                    await SpokenText.render(line, voice: voice, tone: tone, to: url)
                }.value
                self.renderingNow = nil
            }
            self?.renderLoop = nil
        }
    }

    /// Cut whatever is playing (the app went to the background, or the flow was cancelled).
    func stop() {
        renderQueue.removeAll()
        audio.stopSpeaking()
    }

    func speak(_ text: String) async {
        let line = SpokenText.varied(text, after: lastLine)
        lastLine = line
        if isPending(line) { await warm([line], within: .milliseconds(Self.renderWaitMilliseconds)) }
        // On Apple's speech session a line is spoken live, so his music lowers under it.
        if !audio.speaksOnItsOwnSession, let file = cachedAudio(for: line) {
            await audio.duck()
            do {
                try await audio.output.play(file: file, tone: AudioService.currentTone)
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
