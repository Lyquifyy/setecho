import Foundation
import Testing
@testable import Setecho

// Settings → Developer → Storage: recordings go, the log stays unless he deletes every session.

@MainActor
@Test func deletingRecordingsKeepsTheLogAndEverythingElse() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("storage-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let store = Store(root: root)
    let media = store.mediaDirectory
    let recordings = ["set-ABCD1234-0.mov", "set-ABCD1234-0-count.mp4", "segment-ABCD1234-0.mov",
                      "wrist-ABCD1234.json", "utterances-ABCD1234.json", "counts-ABCD1234.json", "audio-ABCD1234.json"]
    let kept = ["photo-front.jpg", "video-ABCD1234.mp4"]
    for name in recordings + kept { try Data(repeating: 1, count: 1000).write(to: media.appendingPathComponent(name)) }
    let take = media.appendingPathComponent("filming/session-1", isDirectory: true)
    try fm.createDirectory(at: take, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 500).write(to: take.appendingPathComponent("001-athlete.wav"))

    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let set = LoggedSet(id: UUID(), exerciseId: "press", setIndex: 0, loadLb: 50, reps: 10, rpe: nil,
                        startedAt: start, endedAt: start.addingTimeInterval(30), clipFile: "set-ABCD1234-0.mov", edits: [])
    store.upsert(session: Session(id: UUID(), programDayId: nil, startedAt: start, endedAt: nil, sets: [set], notes: [], addOnIds: []))

    #expect(store.recordingBytes >= 7500)
    store.deleteRecordings()
    #expect(store.recordingBytes == 0)
    for name in recordings { #expect(!fm.fileExists(atPath: media.appendingPathComponent(name).path)) }
    #expect(!fm.fileExists(atPath: media.appendingPathComponent("filming").path))
    for name in kept { #expect(fm.fileExists(atPath: media.appendingPathComponent(name).path)) }
    // The set stays logged, without the clip it no longer has, and survives a relaunch.
    let reopened = Store(root: root)
    #expect(reopened.sessions.count == 1)
    #expect(reopened.sessions[0].sets.map(\.reps) == [10])
    #expect(reopened.sessions[0].sets[0].clipFile == nil)

    reopened.deleteAllSessions()
    #expect(reopened.sessions.isEmpty)
    #expect(Store(root: root).sessions.isEmpty)
    for name in kept { #expect(fm.fileExists(atPath: media.appendingPathComponent(name).path)) }
}

@Test func storageReadsInFileUnits() {
    #expect(Format.bytes(412_000_000) == "412 MB")
}
