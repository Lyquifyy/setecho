import Foundation

/// Bring your history (HANDOFF.md §9): the backend reads Liftoff's CSV and Garmin's zips by code,
/// and Muse Spark matches the exercise names, names only, to his plan.
extension APIClient {
    /// One picked file, as read from Files.
    struct HistoryFile: Sendable {
        var filename: String
        var data: Data
    }

    func importHistory(_ files: [HistoryFile], liftoffUnit: WeightUnit, timeZone: TimeZone = .current) async throws -> HistoryImportResult {
        var parts: [Multipart.Part] = files.map {
            let mime = $0.filename.lowercased().hasSuffix(".csv") ? "text/csv" : "application/zip"
            return .file(name: "files", filename: $0.filename, mime: mime, data: $0.data)
        }
        parts.append(.field(name: "liftoffUnit", value: liftoffUnit.rawValue))
        parts.append(.field(name: "timeZone", value: timeZone.identifier))
        var request = URLRequest(url: baseURL.appendingPathComponent("/import/history"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        let body = Multipart(parts: parts)
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data
        let (data, response) = try await session.data(for: request)
        try Self.checkHistory(response, data)
        return try JSONCoding.decoder.decode(HistoryImportResult.self, from: data)
    }

    /// The names he hasn't confirmed yet, against his plan's exercises. Nothing else is sent.
    func matchHistory(names: [String], exercises: [PlannedExercise]) async throws -> [HistoryMatch] {
        struct Exercise: Encodable { let id: String; let name: String }
        struct Body: Encodable { let names: [String]; let exercises: [Exercise] }
        struct Response: Decodable { let matches: [HistoryMatch] }
        var request = URLRequest(url: baseURL.appendingPathComponent("/import/history/match"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180  // Spark took up to 73 s on 52 names
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONCoding.encoder.encode(Body(names: names, exercises: exercises.map { Exercise(id: $0.id, name: $0.name) }))
        let (data, response) = try await session.data(for: request)
        try Self.checkHistory(response, data)
        return try JSONCoding.decoder.decode(Response.self, from: data).matches
    }

    private static func checkHistory(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError(status: 0, message: "No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            struct ErrorBody: Decodable { let error: String }
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "HTTP \(http.statusCode)"
            throw APIError(status: http.statusCode, message: message)
        }
    }
}
