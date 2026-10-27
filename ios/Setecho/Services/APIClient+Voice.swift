import Foundation

extension APIClient {
    /// One utterance as 16 kHz mono WAV plus the session context -> transcript and intent.
    func voiceCommand(wav: Data, context: SessionContext) async throws -> VoiceCommandResponse {
        let contextJSON = String(decoding: try JSONCoding.encoder.encode(context), as: UTF8.self)
        var request = URLRequest(url: baseURL.appendingPathComponent("/voice/command"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        let body = Multipart(parts: [
            .file(name: "audio", filename: "utterance.wav", mime: "audio/wav", data: wav),
            .field(name: "context", value: contextJSON),
        ])
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError(status: 0, message: "No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            struct ErrorBody: Decodable { let error: String }
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "HTTP \(http.statusCode)"
            throw APIError(status: http.statusCode, message: message)
        }
        return try JSONCoding.decoder.decode(VoiceCommandResponse.self, from: data)
    }
}
