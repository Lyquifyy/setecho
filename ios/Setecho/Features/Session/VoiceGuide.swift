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
    /// "done" counts, so the question is never heard then.
    static func spokenHelp(state: SessionEngine.State, firstSet: Bool, suggestion: Bool, timed: Bool) -> String {
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
        } else {
            lines.append("Just lift. When you finish, say done and the count, like done, eight. Ask what's next anytime.")
        }
        lines.append("Change the weight with add five, or say skip this set or next exercise. Start with note for the coach to leave him a message. Undo takes back anything.")
        return lines.joined(separator: " ")
    }
}
