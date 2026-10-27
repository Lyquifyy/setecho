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
    case answer, correction, pause, resume, skip, goBack, repeat_ = "repeat", forCoach, ready, chitchat, unclear
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
}

struct TurnResponse: Codable, Equatable {
    var transcript: String
    var intent: TurnIntent
    var answers: [FieldAnswer]
    var reply: String
    var confidence: Double
}

struct AnswerResponse: Codable, Equatable {
    var transcript: String
    var answers: [FieldAnswer]
}
