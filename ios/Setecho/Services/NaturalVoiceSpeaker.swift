import AVFoundation
import CryptoKit
import Foundation
import Observation

/// The natural voice (HANDOFF.md §9, block 1): a live line streams from /voice/speak as PCM 24 kHz
/// and plays chunk by chunk as it arrives; the fixed lines are pre-generated as MP3 when Check-in
/// morning or the wrap-up starts and cached by a text hash. If no audio arrives within 700 ms the
/// line falls back to the system voice. The service receives only the text; numbers become words
/// on the backend. What happened to each line is counted on `TurnTimings` for the Probes screen.
@MainActor
@Observable
final class NaturalVoiceSpeaker: Speaker {
    static let fallbackMilliseconds = 700
    static let sampleRate = 24_000.0
    private(set) var isConfigured = false
    private(set) var lastFallbackReason: String?

    private let api: APIClient
    private let fallback: AudioService
    private let cacheDirectory: URL
    /// Cache fetches under way, by line, so a line about to be spoken can wait for its own fetch.
    private var inFlight: [String: Task<Void, Never>] = [:]
    private let pcmPlayer = PCMStreamPlayer(sampleRate: sampleRate)

    init(api: APIClient, fallback: AudioService, cacheDirectory: URL) {
        self.api = api
        self.fallback = fallback
        self.cacheDirectory = cacheDirectory
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// Ask the backend whether a voice is configured, twice if the first ask fails on the way; the
    /// system voice carries on if not. One dropped request must not silence the voice for a whole flow.
    func prepare() async {
        var status: APIClient.SpeakStatus?
        var failure: String?
        for _ in 0..<2 where status == nil {
            do { status = try await api.speakStatus() } catch { failure = error.localizedDescription }
        }
        isConfigured = status?.configured ?? false
        TurnTimings.shared.voice(configured: isConfigured, provider: status?.provider, failure: status == nil ? failure : nil)
    }

    static func key(for text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24).description
    }

    private func cacheURL(for text: String) -> URL { cacheDirectory.appendingPathComponent("\(Self.key(for: text)).mp3") }

    /// The cached audio for a line, if the natural voice has it (filming mode copies it as received).
    func cachedAudio(for text: String) -> URL? {
        guard isConfigured else { return nil }
        let url = cacheURL(for: text)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Generate the fixed lines as MP3 in the background so they play at once.
    func pregenerate(_ lines: [String]) {
        guard isConfigured else { return }
        for line in lines { startCache(line) }
    }

    /// Start the fixed lines and wait, up to `limit`, for them to land: the opening line should be
    /// cached before it is due, not racing the live deadline on a cold connection.
    func warm(_ lines: [String], within limit: Duration = .seconds(1.5)) async {
        guard isConfigured else { return }
        for line in lines { startCache(line) }
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline, lines.contains(where: { inFlight[$0] != nil }) {
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    private func startCache(_ line: String) {
        guard inFlight[line] == nil, cachedAudio(for: line) == nil else { return }
        let url = cacheURL(for: line)
        inFlight[line] = Task { [api] in
            if let data = try? await api.speak(text: line, mode: "cache", firstByteWithin: nil, onChunk: nil) {
                try? data.write(to: url, options: .atomic)
            }
        }
        Task { [weak self] in
            await self?.inFlight[line]?.value
            self?.inFlight[line] = nil
        }
    }

    func speak(_ text: String) async {
        guard isConfigured else {
            await fallback.speak(text)
            return
        }
        // A line whose cache fetch is still landing waits for it (within the live budget) rather than
        // asking for the same audio twice.
        if inFlight[text] != nil { await warm([text], within: .milliseconds(Self.fallbackMilliseconds)) }
        if let cached = cachedAudio(for: text) {
            TurnTimings.shared.voiceLine(.cached)
            await fallback.play(file: cached)
            return
        }
        // Live: PCM chunks play as they arrive; the first must land within 700 ms.
        await fallback.duck()
        pcmPlayer.begin()
        do {
            _ = try await api.speak(text: text, mode: "live", firstByteWithin: .milliseconds(Self.fallbackMilliseconds)) { [pcmPlayer] chunk in
                pcmPlayer.enqueue(chunk)
            }
            await pcmPlayer.finish()
            await fallback.restore()
            TurnTimings.shared.voiceLine(.live)
        } catch {
            pcmPlayer.cancel()
            await fallback.restore()
            lastFallbackReason = error.localizedDescription
            TurnTimings.shared.voiceLine(.fallback(error.localizedDescription))
            await fallback.speak(text)
        }
    }
}

/// Plays PCM16 mono chunks as they arrive, through its own engine, with no gap between chunks.
@MainActor
final class PCMStreamPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var pending = Data()
    private var scheduled = 0
    private var played = 0
    private var ended = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(sampleRate: Double) {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    func begin() {
        pending.removeAll()
        scheduled = 0
        played = 0
        ended = false
        if !engine.isRunning { try? engine.start() }
        node.play()
    }

    /// Raw PCM16 little-endian bytes; an odd trailing byte waits for the next chunk.
    func enqueue(_ chunk: Data) {
        pending.append(chunk)
        let frames = pending.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pending.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { buffer.floatChannelData![0][i] = Float(samples[i]) / 32768 }
        }
        pending.removeFirst(frames * 2)
        scheduled += 1
        node.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in self?.bufferDone() }
        }
    }

    private func bufferDone() {
        played += 1
        if ended, played >= scheduled, let waiter {
            self.waiter = nil
            waiter.resume()
        }
    }

    /// No more chunks: wait for the last scheduled buffer to play out.
    func finish() async {
        ended = true
        if played >= scheduled { return }
        await withCheckedContinuation { waiter = $0 }
        node.stop()
    }

    func cancel() {
        ended = true
        node.stop()
        waiter?.resume()
        waiter = nil
    }
}

extension APIClient {
    struct SpeakStatus: Codable { var provider: String?; var configured: Bool; var format: String }

    func speakStatus() async throws -> SpeakStatus {
        var request = URLRequest(url: baseURL.appendingPathComponent("/voice/speak/status"))
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        try Self.checkResponse(response, data)
        return try JSONCoding.decoder.decode(SpeakStatus.self, from: data)
    }

    /// The line's audio, streamed. `mode` is live (PCM 24 kHz) or cache (MP3). `firstByteWithin`
    /// turns a slow start into an error so the caller can fall back; `onChunk` gets each chunk as
    /// it lands (about 4 KB each), and the whole is returned at the end.
    func speak(text: String, mode: String, firstByteWithin deadline: Duration?, onChunk: (@MainActor (Data) -> Void)?) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent("/voice/speak"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONCoding.encoder.encode(["text": text, "mode": mode])
        let started = ContinuousClock.now
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "no natural voice")
        }
        var data = Data()
        var chunk = Data()
        var first = true
        for try await byte in bytes {
            if first {
                first = false
                if let deadline, ContinuousClock.now - started > deadline {
                    throw APIError(status: 0, message: "first audio after \(deadline)")
                }
            }
            chunk.append(byte)
            if chunk.count >= 4096 {
                data.append(chunk)
                if let onChunk { await onChunk(chunk) }
                chunk = Data()
            }
        }
        if !chunk.isEmpty {
            data.append(chunk)
            if let onChunk { await onChunk(chunk) }
        }
        guard !data.isEmpty else { throw APIError(status: 0, message: "empty audio") }
        return data
    }
}
