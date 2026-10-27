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
}

struct RenderResponse: Codable {
    var text: String
}

struct AnswerResponse: Codable, Equatable {
    var transcript: String
    var answers: [FieldAnswer]
}
