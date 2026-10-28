import Foundation

// Wire shapes for /checkin/* (HANDOFF.md §5). Field names match the backend's Pydantic models.

struct PersonalRecord: Codable, Equatable {
    var exercise: String
    var loadLb: Double
    var reps: Int
}

struct TrainingSummary: Codable, Equatable {
    var sessionsDone: Int
    var sessionsScheduled: Int
    var setsLogged: Int
    var prs: [PersonalRecord]
    var exercises: [String]
}

struct DraftRequest: Codable {
    var template: CheckInTemplate
    var facts: WeekFacts
    var notes: [VoiceNote]
    var training: TrainingSummary
    var lastCheckIn: CheckInDraft?
    var styleExamples: [String]
    var draftId: String?
}

struct RenderRequest: Codable {
    var template: CheckInTemplate
    var draft: CheckInDraft
    /// The accepted suggestions as lines computed on the phone (HANDOFF.md §7, In the check-in).
    var adjustments: [String] = []
}

struct RenderResponse: Codable {
    var text: String
    /// The plan message (carried blocks), then the questionnaire, in his order (HANDOFF.md §7, step 6).
    var messages: [String]

    init(text: String, messages: [String]) {
        self.text = text
        self.messages = messages
    }

    private enum CodingKeys: String, CodingKey { case text, messages }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        messages = try c.decodeIfPresent([String].self, forKey: .messages) ?? [text]
    }
}

// MARK: - /checkin/turn (HANDOFF.md §5): one spoken turn of Check-in morning

enum TurnIntent: String, Codable {
    case answer, correction, change, keep, decline, pause, resume, skip, goBack, repeat_ = "repeat", forCoach, ready, chitchat, unclear

    /// An intent this build doesn't know (a newer backend) reads as unclear instead of failing the turn.
    init(from decoder: Decoder) throws {
        self = TurnIntent(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unclear
    }
}

struct TurnContext: Codable {
    var template: CheckInTemplate
    /// weight, glucose, photos, questions or review
    var step: String
    var askedFieldId: String?
    var pending: [String]
    var answered: [FieldAnswer]
    var styleExamples: [String]
    var askedOn: String?
    /// What was just offered for a yes or a no ("Weight: 180.8 (Apple Health)"); nil after an open question.
    var offered: String?
}

struct TurnResponse: Codable, Equatable {
    var transcript: String
    var intent: TurnIntent
    var answers: [FieldAnswer]
    var reply: String
    var confidence: Double
    /// Seconds per backend stage: transcribe, spark, validate.
    var timings: [String: Double]
    /// Code answered a plain number; Spark was not called.
    var fastPath: Bool
    /// For `change`: the field the athlete wants to redo.
    var changeFieldId: String?
    /// Why a turn came back unclear (never the words): noWords, model, reply, field, number, empty.
    var unclearReason: String?

    init(transcript: String, intent: TurnIntent, answers: [FieldAnswer], reply: String, confidence: Double,
         timings: [String: Double] = [:], fastPath: Bool = false, changeFieldId: String? = nil) {
        self.transcript = transcript
        self.intent = intent
        self.answers = answers
        self.reply = reply
        self.confidence = confidence
        self.timings = timings
        self.fastPath = fastPath
        self.changeFieldId = changeFieldId
    }

    private enum CodingKeys: String, CodingKey { case transcript, intent, answers, reply, confidence, timings, fastPath, changeFieldId, unclearReason }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transcript = try c.decode(String.self, forKey: .transcript)
        intent = try c.decode(TurnIntent.self, forKey: .intent)
        answers = try c.decode([FieldAnswer].self, forKey: .answers)
        reply = try c.decode(String.self, forKey: .reply)
        confidence = try c.decode(Double.self, forKey: .confidence)
        timings = try c.decodeIfPresent([String: Double].self, forKey: .timings) ?? [:]
        fastPath = try c.decodeIfPresent(Bool.self, forKey: .fastPath) ?? false
        changeFieldId = try c.decodeIfPresent(String.self, forKey: .changeFieldId)
        unclearReason = try c.decodeIfPresent(String.self, forKey: .unclearReason)
    }
}

struct AnswerResponse: Codable, Equatable {
    var transcript: String
    var answers: [FieldAnswer]
}
