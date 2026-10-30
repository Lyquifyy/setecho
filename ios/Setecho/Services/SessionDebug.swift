import Foundation

/// One session's tuning record (HANDOFF.md §7, Set detection; §9 P5). Beside the session's media:
/// the detector's series (`SetDetector`) and every /sets/count answer with its latency. Settings →
/// Developer → Session data bundles both with the logged session and its plan day into one JSON file for
/// `backend/private/sessions/` (gitignored), with every utterance heard: its transcript, intent and
/// latencies, so the session VAD and the classifier are tuned from a real gym. No video or audio.
enum SessionDebug {
    /// One /sets/count attempt for a set: SAM's answer, or why there was none.
    struct CountAttempt: Codable, Equatable {
        var setId: UUID
        var attempt: Int
        var at: Date
        /// Seconds from the set's end to this answer.
        var secondsAfterSetEnd: Double?
        var response: CountResponse?
        var error: String?
        /// Where the time went: set end to the count clip written, the clip's size, and the request
        /// (upload, SAM, the math) as the phone timed it. The backend's own split is in `response.timings`.
        var clipReadySeconds: Double?
        var clipBytes: Int?
        var requestSeconds: Double?
    }

    /// One utterance heard in a session: when, how long, what it was read as, what was said back,
    /// and the seconds from the end of speech to the intent and to the first audio.
    struct UtteranceRecord: Codable, Equatable {
        var at: Date
        var seconds: Double
        var state: String
        var transcript: String?
        var intent: String?
        var number: Double?
        var classifiedBy: String?
        /// Seconds from the end of speech to the transcript (realtime stream or file mode).
        var toTranscript: Double?
        var toIntent: Double?
        var toFirstAudio: Double?
        var spoken: String?
        /// Why it went no further: "too short", "too long (noise)", or the request's error.
        var error: String?
        /// "utterance", or "nearMiss": crossed the stream trigger (6 dB) but never the threshold,
        /// so "never detected" is told apart from "misheard" (HANDOFF.md §7, Log the misses).
        var kind: String?
        /// The loudest moment over the room's floor, and the seconds above the threshold.
        var levelAboveFloorDB: Double?
        var speechSeconds: Double?
        /// "AirPods mic", "Phone mic", …, and whether Apple's voice processing was on.
        var input: String?
        var voiceProcessing: Bool?
        /// The conversation turn: what it did, the reply, whether it was meant for Setecho.
        var actions: [String]?
        var reply: String?
        var addressed: Bool?
        /// He spoke over a line and it stopped.
        var bargedIn: Bool?
    }

    /// One audio-session step (lowering or restoring the music, a configure, a route change): the
    /// options asked for and the options iOS actually applied, the route, whether other audio
    /// (his music) was playing, and the error by its four-character code. Never on screen.
    struct AudioEvent: Codable, Equatable {
        var at: Date
        var step: String
        var requested: [String]
        var applied: [String]
        var route: String
        var otherAudioPlaying: Bool
        var error: String?
    }

    static func audioFile(sessionId: UUID) -> String { "audio-\(sessionId.uuidString.prefix(8)).json" }

    static func append(_ event: AudioEvent, sessionId: UUID, in directory: URL) {
        let url = directory.appendingPathComponent(audioFile(sessionId: sessionId))
        var all = (try? Data(contentsOf: url)).flatMap { try? JSONCoding.decoder.decode([AudioEvent].self, from: $0) } ?? []
        all.append(event)
        if let data = try? JSONCoding.encoder.encode(all) { try? data.write(to: url) }
    }

    static func detectorFile(sessionId: UUID) -> String { "wrist-\(sessionId.uuidString.prefix(8)).json" }
    static func utterancesFile(sessionId: UUID) -> String { "utterances-\(sessionId.uuidString.prefix(8)).json" }

    static func append(_ utterance: UtteranceRecord, sessionId: UUID, in directory: URL) {
        let url = directory.appendingPathComponent(utterancesFile(sessionId: sessionId))
        var all = (try? Data(contentsOf: url)).flatMap { try? JSONCoding.decoder.decode([UtteranceRecord].self, from: $0) } ?? []
        all.append(utterance)
        if let data = try? JSONCoding.encoder.encode(all) { try? data.write(to: url) }
    }
    static func countsFile(sessionId: UUID) -> String { "counts-\(sessionId.uuidString.prefix(8)).json" }

    static func append(_ attempt: CountAttempt, sessionId: UUID, in directory: URL) {
        let url = directory.appendingPathComponent(countsFile(sessionId: sessionId))
        var all = (try? Data(contentsOf: url)).flatMap { try? JSONCoding.decoder.decode([CountAttempt].self, from: $0) } ?? []
        all.append(attempt)
        if let data = try? JSONCoding.encoder.encode(all) { try? data.write(to: url) }
    }

    /// The export: `setecho-session-2026-10-28-1a2b3c4d.json` in the temporary folder, ready to share.
    /// Sessions from before this record existed carry what they have (the log, and the wrist series's last 10 minutes).
    @MainActor
    static func export(session: Session, store: Store) throws -> URL {
        let directory = store.mediaDirectory
        func object(_ data: Data?) -> Any { data.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull() }
        let day = session.programDayId.flatMap { store.currentProgram?.day(id: $0)?.day }
        let info = Bundle.main.infoDictionary
        let json: [String: Any] = [
            "app": ["version": info?["CFBundleShortVersionString"] ?? NSNull(), "build": info?["CFBundleVersion"] ?? NSNull()],
            "exportedAt": Date.now.formatted(.iso8601),
            "session": object(try JSONCoding.encoder.encode(session)),
            "day": object(day.flatMap { try? JSONCoding.encoder.encode($0) }),
            "addOns": object(try? JSONCoding.encoder.encode(session.addOnIds.compactMap { store.currentProgram?.addOn(id: $0) })),
            "detector": object(try? Data(contentsOf: directory.appendingPathComponent(detectorFile(sessionId: session.id)))),
            "counts": object(try? Data(contentsOf: directory.appendingPathComponent(countsFile(sessionId: session.id)))),
            "utterances": object(try? Data(contentsOf: directory.appendingPathComponent(utterancesFile(sessionId: session.id)))),
            "audio": object(try? Data(contentsOf: directory.appendingPathComponent(audioFile(sessionId: session.id)))),
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        let date = session.startedAt.formatted(.iso8601.year().month().day())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("setecho-session-\(date)-\(session.id.uuidString.prefix(8)).json")
        try data.write(to: url)
        return url
    }
}
