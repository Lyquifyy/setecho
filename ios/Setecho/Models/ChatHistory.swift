import Foundation

// The coach chat's history, read once from WhatsApp's Export Chat (HANDOFF.md §9, WhatsApp history
// import). Only past check-ins and the coach's replies to them are kept; every other message is
// dropped on the phone, and only the photos and voice notes that belong to them are copied out of
// the export, into media/whatsapp/. Saved as whatsapp.json; none of it leaves the phone.

struct ChatHistory: Codable, Equatable {
    /// The export's sender names, asked once: which one is the athlete, which one the coach.
    var athleteName: String?
    var coachName: String?
    var checkIns: [PastCheckIn] = []
    var coachMessages: [CoachMessage] = []
    /// The check-in agent's styleExamples, from the last few past check-ins, numbers blanked.
    var styleExamples: [String] = []
    /// Every message key already read, kept or dropped (`ChatMessage.key`), so a re-import adds only what's new.
    var seen: Set<String> = []
    var lastImportAt: Date?

    init() {}

    private enum CodingKeys: String, CodingKey { case athleteName, coachName, checkIns, coachMessages, styleExamples, seen, lastImportAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        athleteName = try c.decodeIfPresent(String.self, forKey: .athleteName)
        coachName = try c.decodeIfPresent(String.self, forKey: .coachName)
        checkIns = try c.decodeIfPresent([PastCheckIn].self, forKey: .checkIns) ?? []
        coachMessages = try c.decodeIfPresent([CoachMessage].self, forKey: .coachMessages) ?? []
        styleExamples = try c.decodeIfPresent([String].self, forKey: .styleExamples) ?? []
        seen = try c.decodeIfPresent(Set<String>.self, forKey: .seen) ?? []
        lastImportAt = try c.decodeIfPresent(Date.self, forKey: .lastImportAt)
    }

    var isEmpty: Bool { checkIns.isEmpty && coachMessages.isEmpty }
}

/// A check-in he sent before Setecho, read through the coach's form.
struct PastCheckIn: Codable, Equatable, Identifiable {
    /// The key of its first message.
    var id: String
    var sentAt: Date
    /// Field id → his words after the coach's label, exactly as he wrote them.
    var answers: [String: String]
    /// The check-in photos sent with it, relative to the media folder ("whatsapp/…jpg"), in the order sent.
    var photoFiles: [String]
}

/// One of the coach's messages after a check-in: his exact words, not applied to anything.
struct CoachMessage: Codable, Equatable, Identifiable {
    var id: String
    var at: Date
    /// Empty for a voice note.
    var text: String
    /// A voice note, relative to the media folder.
    var audioFile: String?
    /// The past check-in it came after.
    var checkInId: String?
}
