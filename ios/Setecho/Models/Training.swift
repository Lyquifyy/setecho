import Foundation

// Training log (HANDOFF.md §4). Everything lives on the phone.

struct Session: Codable, Equatable, Identifiable {
    var id: UUID
    var programDayId: String
    var startedAt: Date
    var endedAt: Date?
    var sets: [LoggedSet]
    var notes: [VoiceNote]
}

struct LoggedSet: Codable, Equatable, Identifiable {
    var id: UUID
    var exerciseId: String
    var setIndex: Int
    var loadLb: Double
    var reps: Int
    var rpe: Double?
    var startedAt: Date
    var endedAt: Date
    var clipFile: String?
    /// Audit trail for spoken corrections: "that was 7 reps".
    var edits: [SetEdit]
}

struct SetEdit: Codable, Equatable {
    var at: Date
    var field: String
    var from: String
    var to: String
    var transcript: String
}

struct VoiceNote: Codable, Equatable, Identifiable {
    var id: UUID
    var at: Date
    var transcript: String
    var targetFieldId: String?
}

extension Session {
    var isComplete: Bool { endedAt != nil }
}
