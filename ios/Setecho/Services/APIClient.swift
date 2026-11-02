import Foundation

/// Talks to the Setecho backend (HANDOFF.md §5). The backend holds the Meta key; the phone never does.
struct APIClient: Sendable {
    var baseURL: URL = APIConfig.baseURL
    var session: URLSession = .shared

    /// Where the coach's material comes from on the Import screen.
    enum ImportSource: Sendable {
        case file(Data, filename: String, mime: String)
        case text(String)
        case link(String)
    }

    func importProgram(_ source: ImportSource) async throws -> Program {
        try await post("/import/program", parts: parts(for: source))
    }

    /// The form, plus the macro targets and cardio protocol read from its blocks (the first PlanState).
    func importForm(_ source: ImportSource) async throws -> FormImport {
        try await post("/import/form", parts: parts(for: source))
    }

    /// His written instructions, pasted once: the rules he states with his quotes, nothing confirmed.
    func importRules(text: String) async throws -> RulesImport {
        var request = URLRequest(url: baseURL.appendingPathComponent("/import/rules"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONCoding.encoder.encode(["text": text])
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
        return try JSONCoding.decoder.decode(RulesImport.self, from: data)
    }

    func health() async throws -> Bool {
        let (data, response) = try await session.data(from: baseURL.appendingPathComponent("health"))
        try Self.check(response, data)
        return (try? JSONCoding.decoder.decode(HealthResponse.self, from: data))?.ok ?? false
    }

    // MARK: Internals

    private struct HealthResponse: Decodable { let ok: Bool }

    private func parts(for source: ImportSource) -> [Multipart.Part] {
        switch source {
        case .file(let data, let filename, let mime): [.file(name: "file", filename: filename, mime: mime, data: data)]
        case .text(let text): [.field(name: "text", value: text)]
        case .link(let link): [.field(name: "url", value: link)]
        }
    }

    private func post<T: Decodable>(_ path: String, parts: [Multipart.Part]) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 180 // a program import takes Spark 15–25 s; leave room
        let body = Multipart(parts: parts)
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
        return try JSONCoding.decoder.decode(T.self, from: data)
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError(status: 0, message: "No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
                ?? String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw APIError(status: http.statusCode, message: message)
        }
    }

    private struct ErrorBody: Decodable { let error: String }
}

/// The backend's 422 {"error": "..."} and any other failure, as one readable message.
struct APIError: LocalizedError, Equatable {
    let status: Int
    let message: String
    var errorDescription: String? { message }

    /// The backend's spend guard said no (429 {"error": "budget"}): the phone's count or his spoken
    /// number stands, as when offline, and the session says why once (`DemoBudget`).
    var isOverBudget: Bool { status == 429 && message == DemoBudget.errorKey }
}

/// HANDOFF.md §5, the spend guard: the one spoken notice per app run when the demo budget is used up.
@MainActor
enum DemoBudget {
    nonisolated static let errorKey = "budget"
    nonisolated static let line = "Setecho's demo budget is used up for today."
    private static var said = false

    /// The line the first time, nil after.
    static func noticeOnce() -> String? {
        guard !said else { return nil }
        said = true
        return line
    }
}

/// multipart/form-data body builder.
struct Multipart {
    enum Part {
        case field(name: String, value: String)
        case file(name: String, filename: String, mime: String, data: Data)
    }

    let boundary = "setecho-\(UUID().uuidString)"
    let parts: [Part]

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    var data: Data {
        var d = Data()
        for part in parts {
            d.append("--\(boundary)\r\n")
            switch part {
            case .field(let name, let value):
                d.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
                d.append(value)
                d.append("\r\n")
            case .file(let name, let filename, let mime, let bytes):
                d.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
                d.append("Content-Type: \(mime)\r\n\r\n")
                d.append(bytes)
                d.append("\r\n")
            }
        }
        d.append("--\(boundary)--\r\n")
        return d
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}

extension Error {
    /// What the screen says when a call fails (Oct 28 polish: "A TLS error caused the secure
    /// connection to fail" meant nothing). A refused request keeps the server's words, which name the field.
    var userMessage: String {
        if let url = self as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "You're offline. Setecho will try again when you're connected."
            case .timedOut:
                return "Setecho's server took too long to answer. Try again."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .serverCertificateHasBadDate, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Couldn't reach Setecho's server. This Wi-Fi may be blocking it; try cellular."
            case .cancelled:
                return "Cancelled."
            default:
                return "Couldn't reach Setecho's server. Try again."
            }
        }
        if let api = self as? APIError, api.status >= 500 { return "Setecho's server had a problem. Try again in a moment." }
        return localizedDescription
    }
}
