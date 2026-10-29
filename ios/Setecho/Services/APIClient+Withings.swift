import Foundation

/// The Withings sign-in, as the phone keeps it in the Keychain. The access token lasts 3 hours;
/// Withings rotates the refresh token on every refresh, so the newest one is always the one saved.
struct WithingsTokens: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

/// One weigh-in straight from Withings, already in pounds (the backend decodes value × 10^unit kg).
struct WithingsWeighIn: Codable, Equatable, Sendable {
    var at: Date
    var lb: Double
}

/// The backend's Withings endpoints (HANDOFF.md §9, Withings direct). A protocol so the service
/// can be tested without the network.
protocol WithingsAPI: Sendable {
    func withingsAuthorizeURL(state: String) async throws -> URL
    func withingsToken(code: String) async throws -> WithingsTokens
    func withingsToken(refreshToken: String) async throws -> WithingsTokens
    func withingsWeights(accessToken: String, lastUpdate: Date) async throws -> [WithingsWeighIn]
}

extension APIClient: WithingsAPI {
    func withingsAuthorizeURL(state: String) async throws -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("/withings/authorize"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "state", value: state)]
        guard let url = components?.url else { throw APIError(status: 0, message: "Bad Withings sign-in URL") }
        struct Body: Decodable { let url: URL }
        let (data, response) = try await session.data(from: url)
        try Self.checkWithings(response, data)
        return try JSONCoding.decoder.decode(Body.self, from: data).url
    }

    func withingsToken(code: String) async throws -> WithingsTokens {
        try await withingsPost("/withings/token", ["code": code])
    }

    func withingsToken(refreshToken: String) async throws -> WithingsTokens {
        try await withingsPost("/withings/token", ["refreshToken": refreshToken])
    }

    func withingsWeights(accessToken: String, lastUpdate: Date) async throws -> [WithingsWeighIn] {
        struct Body: Encodable { let accessToken: String; let lastUpdate: Date }
        return try await withingsPost("/withings/weights", Body(accessToken: accessToken, lastUpdate: lastUpdate))
    }

    private func withingsPost<Body: Encodable, T: Decodable>(_ path: String, _ body: Body) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONCoding.encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        try Self.checkWithings(response, data)
        return try JSONCoding.decoder.decode(T.self, from: data)
    }

    /// 401 means Withings refused the sign-in; 503 that the server has no Withings secrets yet.
    private static func checkWithings(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError(status: 0, message: "No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            struct ErrorBody: Decodable { let error: String }
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "HTTP \(http.statusCode)"
            throw APIError(status: http.statusCode, message: message)
        }
    }
}
