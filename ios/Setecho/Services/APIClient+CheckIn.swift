import Foundation

extension APIClient {
    func checkInDraft(_ request: DraftRequest) async throws -> CheckInDraft {
        try await postJSON("/checkin/draft", body: request, timeout: 180)
    }

    func checkInRender(template: CheckInTemplate, draft: CheckInDraft) async throws -> String {
        let response: RenderResponse = try await postJSON("/checkin/render", body: RenderRequest(template: template, draft: draft), timeout: 30)
        return response.text
    }

    /// One spoken answer for one to three fields (the tape measurements are one question).
    func checkInAnswer(wav: Data, fields: [FieldSpec], styleExamples: [String], askedOn: Date) async throws -> AnswerResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("/checkin/answer"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        let body = Multipart(parts: [
            .file(name: "audio", filename: "answer.wav", mime: "audio/wav", data: wav),
            .field(name: "fields", value: String(decoding: try JSONCoding.encoder.encode(fields), as: UTF8.self)),
            .field(name: "styleExamples", value: String(decoding: try JSONCoding.encoder.encode(styleExamples), as: UTF8.self)),
            .field(name: "askedOn", value: DayKey.string(askedOn)),
        ])
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data
        let (data, response) = try await session.data(for: request)
        try Self.checkResponse(response, data)
        return try JSONCoding.decoder.decode(AnswerResponse.self, from: data)
    }

    private func postJSON<Body: Encodable, T: Decodable>(_ path: String, body: Body, timeout: TimeInterval) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONCoding.encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        try Self.checkResponse(response, data)
        return try JSONCoding.decoder.decode(T.self, from: data)
    }

    static func checkResponse(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError(status: 0, message: "No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            struct ErrorBody: Decodable { let error: String }
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "HTTP \(http.statusCode)"
            throw APIError(status: http.statusCode, message: message)
        }
    }
}
