import Foundation

extension APIClient {
    /// A pasted reply -> proposed changes, unclear sentences and cues. Nothing is applied by the backend.
    func coachReply(text: String, plan: PlanState, cuesEnabled: Bool, today: Date = .now) async throws -> ReplyResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("/coach/reply"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONCoding.encoder.encode(ReplyRequest(text: text, plan: plan, cuesEnabled: cuesEnabled, today: DayKey.string(today)))
        let (data, response) = try await session.data(for: request)
        try Self.checkResponse(response, data)
        return try JSONCoding.decoder.decode(ReplyResponse.self, from: data)
    }

    /// A voice note (WhatsApp's .opus/.ogg, or .m4a/.wav) -> the same, with the cues' times.
    func coachReply(audio: Data, filename: String, plan: PlanState, cuesEnabled: Bool, today: Date = .now) async throws -> ReplyResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("/coach/reply"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300 // a long voice note is transcribed segment by segment
        let body = Multipart(parts: [
            .file(name: "audio", filename: filename, mime: "application/octet-stream", data: audio),
            .field(name: "plan", value: String(decoding: try JSONCoding.encoder.encode(plan), as: UTF8.self)),
            .field(name: "cuesEnabled", value: cuesEnabled ? "true" : "false"),
            .field(name: "today", value: DayKey.string(today)),
        ])
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data
        let (data, response) = try await session.data(for: request)
        try Self.checkResponse(response, data)
        return try JSONCoding.decoder.decode(ReplyResponse.self, from: data)
    }
}
