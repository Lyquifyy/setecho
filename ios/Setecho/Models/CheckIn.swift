import Foundation

// A week's check-in (HANDOFF.md §4).

struct CheckInDraft: Codable, Equatable, Identifiable {
    var id: UUID
    var weekStart: Date
    var weekEnd: Date
    var answers: [FieldAnswer]
    var photoSetId: UUID?
    var sentAt: Date?
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
