import Foundation

/// What the phone tells /sets/count about the set.
struct CountContext: Codable, Equatable {
    var exerciseId: String
    var equipment: Equipment
    var plannedReps: Int?
    var phoneReps: Int?
    /// warmup, top, backOff or restPause (a rest-pause set gets no velocity loss); nil for a straight set.
    var setRole: String?
    /// [x, y, w, h], normalized, top-left origin, in the upright (portrait) frame: his station.
    /// The backend crops the clip to it before SAM, so other people's bars and plates aren't tracked.
    var cropBox: [Double]?
    /// "front" or "back": which way the sensor's frames turn to stand upright.
    var camera: String?
}

/// /sets/count response (HANDOFF.md §5).
struct CountResponse: Codable, Equatable {
    var reps: Int?
    var repTimes: [Double]
    /// Mean lifting speed per rep, px/s at 720p (step 8).
    var repSpeeds: [Double]
    /// How much the last two reps slowed against the first two, 0–100; nil under 3 reps or on a rest-pause set (step 9).
    var velocityLossPct: Double?
    var confidence: Double
    var trackFound: Bool
    var frames: Int
    var trackedFrames: Int
    var prompt: String

    init(reps: Int?, repTimes: [Double], repSpeeds: [Double] = [], velocityLossPct: Double? = nil, confidence: Double,
         trackFound: Bool, frames: Int, trackedFrames: Int, prompt: String) {
        self.reps = reps
        self.repTimes = repTimes
        self.repSpeeds = repSpeeds
        self.velocityLossPct = velocityLossPct
        self.confidence = confidence
        self.trackFound = trackFound
        self.frames = frames
        self.trackedFrames = trackedFrames
        self.prompt = prompt
    }

    private enum CodingKeys: String, CodingKey {
        case reps, repTimes, repSpeeds, velocityLossPct, confidence, trackFound, frames, trackedFrames, prompt
    }

    /// A backend from before step 8 sends no speeds; the count still lands.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reps = try c.decodeIfPresent(Int.self, forKey: .reps)
        repTimes = try c.decode([Double].self, forKey: .repTimes)
        repSpeeds = try c.decodeIfPresent([Double].self, forKey: .repSpeeds) ?? []
        velocityLossPct = try c.decodeIfPresent(Double.self, forKey: .velocityLossPct)
        confidence = try c.decode(Double.self, forKey: .confidence)
        trackFound = try c.decode(Bool.self, forKey: .trackFound)
        frames = try c.decode(Int.self, forKey: .frames)
        trackedFrames = try c.decode(Int.self, forKey: .trackedFrames)
        prompt = try c.decode(String.self, forKey: .prompt)
    }
}

extension APIClient {
    /// One set's small silent clip -> SAM's rep count and how much the reps slowed. The clip is
    /// 720p at 15 fps; the backend forwards it to Meta, deletes it there, and keeps nothing.
    func countSet(mp4: Data, context: CountContext) async throws -> CountResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("/sets/count"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        let contextJSON = String(decoding: try JSONCoding.encoder.encode(context), as: UTF8.self)
        let body = Multipart(parts: [
            .file(name: "video", filename: "set.mp4", mime: "video/mp4", data: mp4),
            .field(name: "context", value: contextJSON),
        ])
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError(status: 0, message: "No HTTP response") }
        struct ErrorBody: Decodable { let error: String }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "HTTP \(http.statusCode)"
            throw APIError(status: http.statusCode, message: message)
        }
        // The backend streams newlines while SAM works, then one JSON line: the count, or {"error"}
        // when the clip could not be counted (already a 200: the stream had started).
        let payload = Data(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        if let failure = try? JSONDecoder().decode(ErrorBody.self, from: payload) {
            throw APIError(status: 422, message: failure.error)
        }
        return try JSONCoding.decoder.decode(CountResponse.self, from: payload)
    }
}
