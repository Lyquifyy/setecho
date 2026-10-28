import Foundation

/// The facts a rest-time line may use, computed on the phone (HANDOFF.md §5, /spotter/line).
/// Every number the spotter says must be one of these.
struct SpotterFacts: Codable, Equatable {
    var exercise: String
    var setNumber: Int
    var setCount: Int
    var reps: Int?
    var repSource: String?
    var loadLb: Double?
    var velocityLossPct: Double?
    var estimatedRIR: Double?
    var target: String?
    var suggestionLb: Double?
    var suggestionRule: String?
    var isPR: Bool = false
    var streak: Int?
    var lastTimeLoadLb: Double?
    var lastTimeReps: Int?
    var sessionSets: Int?
    var role: String?
}

struct SpotterLineRequest: Codable {
    var moment: String
    var facts: SpotterFacts
    var recent: [String]
    var styleHints: [String]
}

struct SpotterLineResponse: Codable, Equatable {
    var text: String
    var ok: Bool
}

/// Last time's set for an exercise and role, from the log.
struct LastSet: Equatable {
    var loadLb: Double
    var reps: Int
}

extension APIClient {
    /// One rest-time line from the facts; `ok` false means speak the template instead.
    func spotterLine(_ request: SpotterLineRequest, timeout: TimeInterval = 4) async throws -> SpotterLineResponse {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("/spotter/line"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONCoding.encoder.encode(request)
        let (data, response) = try await session.data(for: urlRequest)
        try Self.checkResponse(response, data)
        return try JSONCoding.decoder.decode(SpotterLineResponse.self, from: data)
    }
}

/// One voice everywhere (HANDOFF.md §7, The spotter voice): `SystemSpeaker`, Apple's on-device
/// speech with his chosen Premium voice. No voice service: every runtime model is Meta's.
protocol Speaker: AnyObject {
    func speak(_ text: String) async
}
