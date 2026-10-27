import Foundation

/// The backend's structured output for every spoken command (HANDOFF.md §5).
struct VoiceIntent: Codable, Equatable {
    enum Kind: String, Codable {
        case rpe, reps, setLoad, loadDelta, skipSet, nextExercise, note, undo, pause, resume
        case endSession, starting, endSet, replayCue, yes, no, answer, unknown
    }

    var intent: Kind
    var number: Double?
    var text: String?
    var fieldId: String?
    var confidence: Double

    /// Under 0.7, or unknown, the app asks back ("Did you say 215?") and does nothing yet.
    static let actThreshold = 0.7
    var isActionable: Bool { intent != .unknown && confidence >= Self.actThreshold }
}

struct VoiceCommandResponse: Codable, Equatable {
    var transcript: String
    var intent: VoiceIntent
    var sessionId: String?
}

/// What the app tells the backend about the session so the model can read a command in context.
struct SessionContext: Codable, Equatable {
    var state: String
    var exerciseName: String?
    var setIndex: Int?
    var setCount: Int?
    var plannedLoadLb: Double?
    var plannedReps: Int?
}
