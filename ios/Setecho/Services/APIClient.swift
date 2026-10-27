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

    func importForm(_ source: ImportSource) async throws -> CheckInTemplate {
        try await post("/import/form", parts: parts(for: source))
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
