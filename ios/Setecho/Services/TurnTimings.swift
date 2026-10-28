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
    private var pending: (endOfSpeech: Date, sent: Date?, turn: Turn?)?

    func endOfSpeech(at: Date = .now) { pending = (at, nil, nil) }
    func sent(at: Date = .now) { pending?.sent = at }

    func received(_ response: TurnResponse, at: Date = .now) {
        guard let p = pending else { return }
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
