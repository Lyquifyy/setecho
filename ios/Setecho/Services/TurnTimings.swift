import Foundation
import Observation

/// Stage timings for every check-in turn (HANDOFF.md §9, block 1): end of speech, upload,
/// transcribe, Spark, validator, first audio. Kept for the Probes screen (live and medians) and
/// written to the debug JSON. Numbers only; never the words.
@MainActor
@Observable
final class TurnTimings {
    static let shared = TurnTimings()

    struct Turn: Codable, Equatable, Identifiable {
        var id = UUID()
        var at: Date
        /// Seconds from the end of speech to the request leaving the phone.
        var upload: Double
        /// Backend stages, as /checkin/turn reports them.
        var transcribe: Double
        var spark: Double
        var validate: Double
        /// Seconds from the end of speech to the response arriving.
        var roundTrip: Double
        /// Seconds from the end of speech to the first audio of the reply; nil until spoken.
        var firstAudio: Double?
        var fastPath: Bool
        var intent: String
    }

    private(set) var turns: [Turn] = []

    /// The natural voice, as the Probes screen reports it: whether the backend has one, and what
    /// happened to each line (cached MP3, live stream, or the system voice with the reason).
    enum VoiceLine { case cached, live, fallback(String) }
    private(set) var voiceConfigured: Bool?
    private(set) var voiceProvider: String?
    private(set) var voiceStatusFailure: String?
    private(set) var voiceCached = 0
    private(set) var voiceLive = 0
    private(set) var voiceFallbacks = 0
    private(set) var voiceLastFallback: String?
    /// Turns that came back unclear, and why (Oct 28: he had to say answers twice).
    private(set) var unclearCount = 0
    private(set) var unclearReasons: [String: Int] = [:]

    /// Every utterance the phone heard and what became of it.
    enum Heard: String { case turn, queued, tooShort, noWords }
    private(set) var heardCounts: [String: Int] = [:]

    func heard(_ kind: Heard) { heardCounts[kind.rawValue, default: 0] += 1 }

    func unclear(_ reason: String?) {
        unclearCount += 1
        unclearReasons[reason ?? "unknown", default: 0] += 1
    }

    /// Seconds from opening Check-in morning to each stage (voice ready, intro, draft, first question).
    private(set) var openStages: [(name: String, seconds: Double)] = []
    private var openedAt: Date?

    func opened(at: Date = .now) {
        openedAt = at
        openStages = []
    }

    func stage(_ name: String, at: Date = .now) {
        guard let openedAt else { return }
        openStages.append((name, at.timeIntervalSince(openedAt)))
    }

    func voice(configured: Bool, provider: String?, failure: String?) {
        voiceConfigured = configured
        voiceProvider = provider
        voiceStatusFailure = failure
    }

    func voiceLine(_ line: VoiceLine) {
        switch line {
        case .cached: voiceCached += 1
        case .live: voiceLive += 1
        case .fallback(let reason):
            voiceFallbacks += 1
            voiceLastFallback = reason
        }
    }
    private var pending: (endOfSpeech: Date, sent: Date?, turn: Turn?)?

    func endOfSpeech(at: Date = .now) { pending = (at, nil, nil) }
    func sent(at: Date = .now) { pending?.sent = at }

    func received(_ response: TurnResponse, at: Date = .now) {
        guard let p = pending else { return }
        // With the realtime stream, "upload" is the wait for the final transcript after the end of speech.
        let turn = Turn(
            at: p.endOfSpeech, upload: max(0, (p.sent ?? at).timeIntervalSince(p.endOfSpeech)),
            transcribe: response.timings["transcribe"] ?? 0, spark: response.timings["spark"] ?? 0,
            validate: response.timings["validate"] ?? 0, roundTrip: at.timeIntervalSince(p.endOfSpeech),
            firstAudio: nil, fastPath: response.fastPath, intent: response.intent.rawValue
        )
        pending = (p.endOfSpeech, p.sent, turn)
    }

    func firstAudio(at: Date = .now) {
        guard let p = pending, var turn = p.turn else { return }
        turn.firstAudio = at.timeIntervalSince(p.endOfSpeech)
        turns.append(turn)
        pending = nil
        if turns.count > 200 { turns.removeFirst() }
    }

    func median(_ key: KeyPath<Turn, Double>, fastPath: Bool? = nil) -> Double? {
        let values = turns.filter { fastPath == nil || $0.fastPath == fastPath }.map { $0[keyPath: key] }.sorted()
        guard !values.isEmpty else { return nil }
        return values.count % 2 == 1 ? values[values.count / 2] : (values[values.count / 2 - 1] + values[values.count / 2]) / 2
    }

    func medianFirstAudio(fastPath: Bool? = nil) -> Double? {
        let values = turns.filter { fastPath == nil || $0.fastPath == fastPath }.compactMap(\.firstAudio).sorted()
        guard !values.isEmpty else { return nil }
        return values.count % 2 == 1 ? values[values.count / 2] : (values[values.count / 2 - 1] + values[values.count / 2]) / 2
    }

    /// The debug JSON beside the check-in's media: numbers only.
    func write(to directory: URL, name: String) {
        guard let data = try? JSONCoding.encoder.encode(turns) else { return }
        try? data.write(to: directory.appendingPathComponent("turn-timings-\(name).json"))
    }
}
