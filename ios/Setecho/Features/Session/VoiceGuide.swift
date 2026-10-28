import Foundation

/// What you can say in a session: the lines on `VoiceGuideView`, from `Resources/VoiceGuide.json`
/// (test_voice.py reads every one through the real rules), and the spoken answer to "what can I say?".
enum VoiceGuide {
    struct Phrase: Decodable, Equatable {
        var say: String
        var does: String
    }

    struct Section: Decodable, Equatable {
        var title: String
        var detail: String
        var phrases: [Phrase]
    }

    /// One kind of session: Working out, Abs, Vacuums.
    struct Guide: Decodable, Equatable {
        var title: String
        var sections: [Section]
    }

    private struct File: Decodable {
        var guides: [Guide]
    }

    static let guides: [Guide] = {
        guard let url = Bundle.main.url(forResource: "VoiceGuide", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [] }
        return file.guides
    }()

    /// "What can I say?": the few lines that work right now, as a template. During a set only
    /// "done" counts, so the question is never heard then. On the tripod a set starts on "go".
    static func spokenHelp(state: SessionEngine.State, firstSet: Bool, suggestion: Bool, timed: Bool, arming: Bool = false) -> String {
        switch state {
        case .hold: return "Say done to end the hold early."
        case .leadIn: return "Say hold on to wait, or go to start now."
        case .paused: return "Say resume to carry on."
        case .ended: return "That's the session."
        default: break
        }
        var lines: [String] = []
        if suggestion { lines.append("Say go with it, or keep it.") }
        if case .rest = state, !firstSet {
            lines.append("Fix a count with that was seven. Ask what's next, or how long left.")
        } else if timed {
            lines.append("Holds start themselves. Say done to end one early.")
        } else if arming {
            lines.append("Say go when you lift. When you finish, say done and the count, like done, eight.")
        } else {
            lines.append("Just lift. When you finish, say done and the count, like done, eight. Ask what's next anytime.")
        }
        lines.append("Talk to me like a spotter: ask anything about today, or tell me if a machine's taken. Undo takes back anything.")
        return lines.joined(separator: " ")
    }

    /// Two or three things he could say right now, on screen so he never needs the list
    /// (HANDOFF.md §7, Talk to it like a person): an open ask's answers first.
    @MainActor
    static func hints(for engine: SessionEngine) -> [String] {
        switch engine.pendingAsk {
        case .suggestion: return ["go with it", "keep it"]
        case .countConfirm(let q): return ["yes", "no, it was \(max(1, q.current - 1))"]
        case .takenOffer: return ["go with it", "the other one", "I'll wait"]
        case .howMany: return ["eight", "that was ten"]
        case .endSession, .noteOffer, .logPlanSets, .clarify, .countFor: return ["yes", "no"]
        case nil: break
        }
        switch engine.state {
        case .recording: return ["done", "done, 8"]
        case .hold: return ["done"]
        case .leadIn: return ["hold on", "go"]
        case .paused: return ["resume"]
        case .ended: return []
        case .rest: return ["that was 9", "how long left?", "the bench is taken"]
        case .ready, .saved, .listening:
            if engine.isArmed { return ["done, 8", "what's next?"] }
            return engine.startsByArming || !engine.cameraSees ? ["go", "what did I do last time?"] : ["what did I do last time?", "what's next?"]
        }
    }
}
