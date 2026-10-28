import AVFoundation
import CryptoKit
import Foundation
import Observation

/// The natural voice (HANDOFF.md §9, block 1): lines fetched from /voice/speak as MP3 and played
/// as they arrive, cached on the phone by a text hash, with the fixed lines pre-generated when
/// Check-in morning starts. If no audio arrives within 700 ms the line falls back to the system
/// voice. The service receives only the text being spoken.
@MainActor
@Observable
final class NaturalVoiceSpeaker: Speaker {
    static let fallbackMilliseconds = 700
    private(set) var isConfigured = false
    private(set) var lastFallbackReason: String?

    private let api: APIClient
    private let fallback: AudioService
    private let cacheDirectory: URL
    private var player: AVAudioPlayer?
    private var inFlight: Set<String> = []

    init(api: APIClient, fallback: AudioService, cacheDirectory: URL) {
        self.api = api
        self.fallback = fallback
        self.cacheDirectory = cacheDirectory
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// Ask the backend once whether a voice is configured; the system voice carries on if not.
    func prepare() async {
        isConfigured = (try? await api.speakStatus())?.configured ?? false
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

    /// Generate the fixed lines in the background so they play at once.
    func pregenerate(_ lines: [String]) {
        guard isConfigured else { return }
        for line in lines where !FileManager.default.fileExists(atPath: cacheURL(for: line).path) && !inFlight.contains(line) {
            inFlight.insert(line)
            Task { [weak self] in
                guard let self else { return }
                _ = try? await self.fetch(line, deadline: nil)
                self.inFlight.remove(line)
            }
        }
    }

    /// Fetch one line's audio to the cache. With a deadline, the first byte must arrive in time.
    private func fetch(_ text: String, deadline: Duration?) async throws -> URL {
        let url = cacheURL(for: text)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let data = try await api.speak(text: text, firstByteWithin: deadline)
        try data.write(to: url, options: .atomic)
        return url
    }

    func speak(_ text: String) async {
        guard isConfigured else {
            await fallback.speak(text)
            return
        }
        let url: URL
        do {
            url = try await fetch(text, deadline: .milliseconds(Self.fallbackMilliseconds))
        } catch {
            lastFallbackReason = error.localizedDescription
            await fallback.speak(text)
            return
        }
        await fallback.play(file: url)
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

    /// The line as MP3, streamed. `firstByteWithin` turns a slow start into an error so the caller
    /// can fall back; the rest of the bytes may take as long as they take.
    func speak(text: String, firstByteWithin deadline: Duration?) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent("/voice/speak"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONCoding.encoder.encode(["text": text])
        let started = ContinuousClock.now
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "no natural voice")
        }
        var data = Data()
        var first = true
        for try await byte in bytes {
            if first {
                first = false
                if let deadline, ContinuousClock.now - started > deadline {
                    throw APIError(status: 0, message: "first audio after \(deadline)")
                }
            }
            data.append(byte)
        }
        guard !data.isEmpty else { throw APIError(status: 0, message: "empty audio") }
        return data
    }
}
