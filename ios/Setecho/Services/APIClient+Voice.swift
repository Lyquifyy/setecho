import Foundation

extension APIClient {
    /// A session command never waits long: on a bad connection the HUD says "Didn't catch that"
    /// after this and the mic carries on (HANDOFF.md §7, The between-set conversation).
    static let voiceCommandTimeout: TimeInterval = 8

    /// One utterance as 16 kHz mono WAV plus the session context -> transcript and intent. The
    /// fallback when the realtime stream has no words.
    func voiceCommand(wav: Data, context: SessionContext) async throws -> VoiceCommandResponse {
        let contextJSON = String(decoding: try JSONCoding.encoder.encode(context), as: UTF8.self)
        var request = URLRequest(url: baseURL.appendingPathComponent("/voice/command"))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.voiceCommandTimeout
        let body = Multipart(parts: [
            .file(name: "audio", filename: "utterance.wav", mime: "audio/wav", data: wav),
            .field(name: "context", value: contextJSON),
        ])
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data
        let (data, response) = try await session.data(for: request)
        try Self.checkResponse(response, data)
        return try JSONCoding.decoder.decode(VoiceCommandResponse.self, from: data)
    }

    /// Words the realtime stream already produced: the same rules then Spark, no audio, no Transcribe call.
    func voiceCommand(transcript: String, context: SessionContext) async throws -> VoiceCommandResponse {
        struct Body: Encodable { var transcript: String; var context: SessionContext }
        var request = URLRequest(url: baseURL.appendingPathComponent("/voice/command/text"))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.voiceCommandTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONCoding.encoder.encode(Body(transcript: transcript, context: context))
        let (data, response) = try await session.data(for: request)
        try Self.checkResponse(response, data)
        return try JSONCoding.decoder.decode(VoiceCommandResponse.self, from: data)
    }
}
