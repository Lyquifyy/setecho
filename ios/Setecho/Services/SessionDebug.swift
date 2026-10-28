import Foundation

/// One session's tuning record (HANDOFF.md §7, Set detection; §9 P5). Beside the session's media:
/// the detector's series (`SetDetector`) and every /sets/count answer with its latency. Settings →
/// Developer → Session data bundles both with the logged session and its plan day into one JSON file for
/// `backend/private/sessions/`. Numbers only: no video, audio or words.
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
    }

    static func detectorFile(sessionId: UUID) -> String { "wrist-\(sessionId.uuidString.prefix(8)).json" }
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
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        let date = session.startedAt.formatted(.iso8601.year().month().day())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("setecho-session-\(date)-\(session.id.uuidString.prefix(8)).json")
        try data.write(to: url)
        return url
    }
}
