import Foundation

// A week's check-in (HANDOFF.md §4).

struct CheckInDraft: Codable, Equatable, Identifiable {
    var id: UUID
    var weekStart: Date
    var weekEnd: Date
    var answers: [FieldAnswer]
    var photoSetId: UUID?
    /// The two videos for his review, cropped to the reps (HANDOFF.md §7, Two videos for your coach).
    var videoPicks: [VideoPick]
    /// Accepted LoadSuggestion ids that go out on the adjustments line.
    var adjustments: [UUID]
    var sentAt: Date?

    init(id: UUID, weekStart: Date, weekEnd: Date, answers: [FieldAnswer], photoSetId: UUID?, videoPicks: [VideoPick] = [],
         adjustments: [UUID] = [], sentAt: Date?) {
        self.id = id
        self.weekStart = weekStart
        self.weekEnd = weekEnd
        self.answers = answers
        self.photoSetId = photoSetId
        self.videoPicks = videoPicks
        self.adjustments = adjustments
        self.sentAt = sentAt
    }

    private enum CodingKeys: String, CodingKey { case id, weekStart, weekEnd, answers, photoSetId, videoPicks, adjustments, sentAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        weekStart = try c.decode(Date.self, forKey: .weekStart)
        weekEnd = try c.decode(Date.self, forKey: .weekEnd)
        answers = try c.decode([FieldAnswer].self, forKey: .answers)
        photoSetId = try c.decodeIfPresent(UUID.self, forKey: .photoSetId)
        videoPicks = try c.decodeIfPresent([VideoPick].self, forKey: .videoPicks) ?? []
        adjustments = try c.decodeIfPresent([UUID].self, forKey: .adjustments) ?? []
        sentAt = try c.decodeIfPresent(Date.self, forKey: .sentAt)
    }
}

/// One of the two videos for the coach: the set, its caption, and the crop to just the reps.
struct VideoPick: Codable, Equatable, Identifiable {
    var setId: UUID
    /// "Incline DB press · top set"
    var caption: String
    /// Seconds into the clip: just the reps.
    var cropStart: Double
    var cropEnd: Double
    /// A video from the camera roll instead of a logged set: the imported file in the media folder, sent whole.
    var sourceFile: String?
    var id: UUID { setId }
}

struct FieldAnswer: Codable, Equatable {
    var fieldId: String
    /// Exactly what goes to the coach.
    var text: String
    var state: AnswerState
    /// What the text was built from.
    var provenance: [Provenance]
}

enum AnswerState: String, Codable {
    case filled, drafted, missing, confirmed
}

struct Provenance: Codable, Equatable {
    /// "Withings via Apple Health"
    var source: String
    /// "Oct 19–25: 181.2, 181.0, …"
    var detail: String
}

extension CheckInDraft {
    var readyCount: Int { answers.filter { $0.state == .filled || $0.state == .confirmed }.count }
    var isSent: Bool { sentAt != nil }
}
