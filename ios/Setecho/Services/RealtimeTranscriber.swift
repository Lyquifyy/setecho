import Foundation
import Observation

/// Realtime transcription (HANDOFF.md §9, block 1): the moment speech starts, a WebSocket to
/// /voice/stream opens and the audio goes up as it is captured (PCM16 mono 24 kHz, 80 ms frames),
/// so the words are ready when the athlete stops talking. The backend relays to Voice Transcribe
/// and holds the key. Any failure means the turn's WAV goes by file mode instead.
@MainActor
@Observable
final class RealtimeTranscriber {
    static let outRate = 24_000.0
    static let doneTimeout: Duration = .seconds(4)

    private(set) var partial: String = ""
    private(set) var isOpen = false
    private(set) var lastError: String?

    private let baseURL: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var ready = false
    private var queued: [Data] = []
    /// The answer's committed segments: Meta marks a segment final at a pause mid-answer, and the
    /// answer is all of them (Oct 28: keeping only the latest one cut answers in half).
    private var segments: [String] = []
    private var done: CheckedContinuation<String?, Never>?
    private var receiver: Task<Void, Never>?

    init(baseURL: URL = APIConfig.baseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    private var streamURL: URL? {
        var components = URLComponents(url: baseURL.appendingPathComponent("/voice/stream"), resolvingAgainstBaseURL: false)
        components?.scheme = baseURL.scheme == "http" ? "ws" : "wss"
        return components?.url
    }

    /// Open the socket and send the start frame; audio sent before "ready" waits in a queue.
    func start() {
        guard task == nil, let url = streamURL else { return }
        partial = ""
        segments = []
        ready = false
        queued.removeAll()
        lastError = nil
        let ws = session.webSocketTask(with: url)
        task = ws
        isOpen = true
        ws.resume()
        ws.send(.string(#"{"type":"start"}"#)) { [weak self] error in
            if let error { Task { @MainActor in self?.fail(error.localizedDescription) } }
        }
        receiver = Task { [weak self] in await self?.receiveLoop(ws) }
    }

    /// Live samples from the capture tap, resampled to 24 kHz Int16.
    func send(_ samples: [Float], rate: Double) {
        guard task != nil else { return }
        let pcm = Resample.toInt16Mono(samples, from: rate, to: Self.outRate)
        guard !pcm.isEmpty else { return }
        let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
        if ready { task?.send(.data(data)) { _ in } } else { queued.append(data) }
    }

    /// The athlete stopped: send the end frame and wait briefly for the final transcript.
    func end() async -> String? {
        guard let ws = task else { return nil }
        // Speech ended on a committed segment with nothing after it: the answer is complete.
        if partial.isEmpty, !segments.isEmpty {
            close()
            return text
        }
        ws.send(.string(#"{"type":"end"}"#)) { _ in }
        let result: String? = await withCheckedContinuation { continuation in
            done = continuation
            Task { [weak self] in
                try? await Task.sleep(for: Self.doneTimeout)
                await MainActor.run { self?.finish(nil) }
            }
        }
        close()
        return result
    }

    func cancel() { close() }

    private func finish(_ transcript: String?) {
        guard let continuation = done else { return }
        done = nil
        if let transcript { commit(transcript) }
        let whole = text
        continuation.resume(returning: whole.isEmpty ? nil : whole)
    }

    /// Everything said so far: the committed segments, then the segment still being heard.
    var text: String {
        let committed = segments.joined(separator: " ")
        guard !partial.isEmpty else { return committed }
        if committed.isEmpty || partial.hasPrefix(committed) { return partial }
        return committed + " " + partial
    }

    /// A final segment. A transcript that repeats what is committed is cumulative and replaces it.
    private func commit(_ transcript: String) {
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        partial = ""
        guard !t.isEmpty else { return }
        let committed = segments.joined(separator: " ")
        if !committed.isEmpty, t.hasPrefix(committed) {
            segments = [t]
        } else if segments.last != t {
            segments.append(t)
        }
    }

    private func fail(_ message: String) {
        lastError = message
        finish(nil)
        close()
    }

    private func close() {
        receiver?.cancel()
        receiver = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        isOpen = false
        ready = false
        queued.removeAll()
    }

    private func receiveLoop(_ ws: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            guard let message = try? await ws.receive() else {
                fail("stream closed")
                return
            }
            guard case .string(let text) = message, let data = text.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = event["type"] as? String
            else { continue }
            switch type {
            case "ready":
                ready = true
                for frame in queued { ws.send(.data(frame)) { _ in } }
                queued.removeAll()
            case "transcript":
                let transcript = event["transcript"] as? String ?? ""
                if event["final"] as? Bool == true { commit(transcript) } else { partial = transcript }
            case "done":
                let transcript = event["transcript"] as? String ?? ""
                finish(transcript.isEmpty ? nil : transcript)
                return
            case "error":
                fail(event["message"] as? String ?? "realtime error")
                return
            default:
                continue
            }
        }
    }
}

extension APIClient {
    /// A turn whose words the realtime stream already produced: no audio, no Transcribe call.
    func checkInTurn(transcript: String, context: TurnContext) async throws -> TurnResponse {
        struct Body: Encodable { var transcript: String; var context: TurnContext }
        var request = URLRequest(url: baseURL.appendingPathComponent("/checkin/turn/text"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONCoding.encoder.encode(Body(transcript: transcript, context: context))
        let (data, response) = try await session.data(for: request)
        try Self.checkResponse(response, data)
        return try JSONCoding.decoder.decode(TurnResponse.self, from: data)
    }
}
