import Foundation

/// The backend's structured output for every spoken command (HANDOFF.md §5).
struct VoiceIntent: Codable, Equatable {
    enum Kind: String, Codable {
        case rpe, reps, setLoad, loadDelta, skipSet, nextExercise, note, undo, pause, resume
        case endSession, starting, endSet, replayCue, yes, no, answer, unknown
        // The real sheet (HANDOFF.md §7): warm-ups, add-ons, the day, and a set flagged for the coach.
        case topSet, warmup, addAddOn, skipAddOn, changeDay, flagSet
        // His rule's suggestion (HANDOFF.md §7, Measured effort): "go with it" / "keep it".
        case acceptSuggestion, keepLoad
        // Between sets (HANDOFF.md §7, The between-set conversation).
        case chatter, question, choose, skipExercise, logbook, equipmentTaken, equipmentFree, swapTo
        // He drives (HANDOFF.md §7): "go back", "I'm on flyes now", "one more set", "that's it for incline".
        case goTo, addSet, endExercise

        /// A kind this build doesn't know yet is `unknown`: never acted on, never a crash.
        init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    /// What a `question` asks about; every answer is a template with numbers from the engine.
    enum Topic: String, Codable {
        case next, restLeft, lastSet, lastTime, load, setsLeft, effort, coachNotes, outOfScope
        /// "What can I say?": the few lines that work right now (`VoiceGuide.spokenHelp`).
        case help
        /// "Where am I?": "Incline press, set 2 of 3, back-off."
        case whereAmI
    }

    var intent: Kind
    var number: Double?
    /// The count when a load and a count are said together ("last time I did 145 for 9").
    var reps: Int?
    /// A set he named ("set 3 of incline was 7").
    var setNumber: Int?
    var text: String?
    var topic: Topic?
    var fieldId: String?
    var confidence: Double

    init(intent: Kind, number: Double? = nil, reps: Int? = nil, setNumber: Int? = nil, text: String? = nil,
         topic: Topic? = nil, fieldId: String? = nil, confidence: Double) {
        self.intent = intent
        self.number = number
        self.reps = reps
        self.setNumber = setNumber
        self.text = text
        self.topic = topic
        self.fieldId = fieldId
        self.confidence = confidence
    }

    /// 0.7 and over acts. 0.4 to 0.7 asks back, worded as the action ("Twelve reps on set 2?").
    /// Under 0.4, chatter and unknown are silent: the HUD shows "Heard: …".
    static let actThreshold = 0.7
    static let askThreshold = 0.4
    var isActionable: Bool { intent != .unknown && intent != .chatter && confidence >= Self.actThreshold }
}

struct VoiceCommandResponse: Codable, Equatable {
    var transcript: String
    var intent: VoiceIntent
    var sessionId: String?
    /// "rules", "spark" or "none": during a set only the rules' set commands are acted on.
    var classifiedBy: String?
}

/// What the app tells the backend about the session so the model can read a command in context.
struct SessionContext: Codable, Equatable {
    var state: String
    var exerciseName: String?
    var setIndex: Int?
    var setCount: Int?
    var plannedLoadLb: Double?
    var plannedReps: Int?
    /// The question the app asked and is waiting on, its last line, what's still to do today.
    var pendingAsk: String?
    var lastSpoken: String?
    var exercisesAhead: [String] = []
    var addOnNames: [String] = []
}
