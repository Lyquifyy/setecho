import Foundation

/// What the phone tells /sets/count about the set.
struct CountContext: Codable, Equatable {
    var exerciseId: String
    var equipment: Equipment
    var plannedReps: Int?
    var phoneReps: Int?
}

/// /sets/count response (HANDOFF.md §5).
struct CountResponse: Codable, Equatable {
    var reps: Int?
    var repTimes: [Double]
    var confidence: Double
    var trackFound: Bool
    var frames: Int
    var trackedFrames: Int
    var prompt: String
}

extension APIClient {
    /// One set's small silent clip -> SAM's rep count. The clip is 720p at 10 fps; the backend
    /// forwards it to Meta, deletes it there, and keeps nothing.
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
