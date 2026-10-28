import Foundation

/// One thing he said between sets, as a conversation turn (HANDOFF.md §5 /session/turn, §7 Talk
/// to it like a person). The fast path's lines come back as one action with no reply, so the
/// engine's template answers within a second; everything else is a Muse Spark turn: the engine's
/// own intents as actions (several in one breath), a short reply, and whether it was meant for
/// Setecho at all. Every number in the facts comes from the engine.
struct SessionTurnRequest: Codable, Equatable {
    var transcript: String
    var state: String
    var recentTurns: [Exchange]
    var facts: SessionFacts
}

/// One exchange: what he said and what Setecho said back.
struct Exchange: Codable, Equatable {
    var heard: String
    var said: String?
}

struct SessionTurnResponse: Codable, Equatable {
    var transcript: String
    var actions: [VoiceIntent]
    /// Spoken at once when the actions open no question of their own; nil means the engine's templates.
    var reply: String?
    var expectsAnswer: Bool
    /// False: talk to someone else, music, half-heard words. Nothing happens and nothing is said.
    var addressed: Bool
    /// "rules", "spark" or "fallback".
    var classifiedBy: String?
    var unclearReason: String?

    init(transcript: String, actions: [VoiceIntent], reply: String? = nil, expectsAnswer: Bool = false, addressed: Bool = true,
         classifiedBy: String? = nil, unclearReason: String? = nil) {
        self.transcript = transcript
        self.actions = actions
        self.reply = reply
        self.expectsAnswer = expectsAnswer
        self.addressed = addressed
        self.classifiedBy = classifiedBy
        self.unclearReason = unclearReason
    }

    /// A /voice/command answer read as a turn: chatter and unknown were not for Setecho.
    init(command: VoiceCommandResponse) {
        let silent = command.intent.intent == .chatter || command.intent.intent == .unknown
        self.init(transcript: command.transcript, actions: silent ? [] : [command.intent], addressed: !silent,
                  classifiedBy: command.classifiedBy)
    }

    /// Each action as the engine's command.
    var commands: [VoiceCommandResponse] {
        actions.map { VoiceCommandResponse(transcript: transcript, intent: $0, classifiedBy: classifiedBy) }
    }
}

/// What the turn knows about today, computed by the engine (HANDOFF.md §7). Every number a reply
/// may say is here, and the backend checks each one against it.
struct SessionFacts: Codable, Equatable {
    struct SetFact: Codable, Equatable {
        var exercise: String
        var setNumber: Int
        var role: String?
        var reps: Int?
        /// measured, phone, spoken, plan, or counting while SAM is still on it.
        var repSource: String?
        var loadLb: Double?
        var rpe: Double?
        var estimatedRIR: Double?
        var seconds: Int?
        var doneAs: String?
        var minutesAgo: Int?
    }

    struct ExerciseFact: Codable, Equatable {
        var name: String
        var setsPlanned: Int
        var setsDone: Int
        var target: String?
        var loadLb: Double?
        var lastTime: String?
        var sheetNote: String?
        var alternates: [String] = []
        var addOn: String?
    }

    var day: String?
    var state: String
    var exercise: String?
    var setNumber: Int?
    var setCount: Int?
    var targetLoadLb: Double?
    var targetReps: String?
    var restLeft: String?
    var openAsk: String?
    var exercises: [ExerciseFact] = []
    var sets: [SetFact] = []
    var rules: [String] = []
    var addOns: [String] = []
    var takenOptions: [String] = []
    var athleteName: String?
}

extension APIClient {
    /// The realtime stream's words for one utterance -> the turn.
    func sessionTurn(_ request: SessionTurnRequest) async throws -> SessionTurnResponse {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("/session/turn/text"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = Self.voiceCommandTimeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONCoding.encoder.encode(request)
        let (data, response) = try await session.data(for: urlRequest)
        try Self.checkResponse(response, data)
        return try JSONCoding.decoder.decode(SessionTurnResponse.self, from: data)
    }

    /// The fallback when the stream had no words: the utterance's WAV, transcribed by the backend.
    func sessionTurn(wav: Data, _ request: SessionTurnRequest) async throws -> SessionTurnResponse {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("/session/turn"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = Self.voiceCommandTimeout
        let body = Multipart(parts: [
            .file(name: "audio", filename: "utterance.wav", mime: "audio/wav", data: wav),
            .field(name: "request", value: String(decoding: try JSONCoding.encoder.encode(request), as: UTF8.self)),
        ])
        urlRequest.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body.data
        let (data, response) = try await session.data(for: urlRequest)
        try Self.checkResponse(response, data)
        return try JSONCoding.decoder.decode(SessionTurnResponse.self, from: data)
    }
}
