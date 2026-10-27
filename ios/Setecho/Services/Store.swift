import Foundation
import Observation

/// The phone owns all data (HANDOFF.md §3). One JSON file per collection under Application
/// Support/Setecho, plus a media folder for JPEG and MOV files. No SwiftData; small and testable.
@MainActor
@Observable
final class Store {
    private(set) var program: Program?
    private(set) var template: CheckInTemplate?
    private(set) var sessions: [Session] = []
    private(set) var photoSets: [PhotoSet] = []
    private(set) var checkIns: [CheckInDraft] = []
    private(set) var loadError: String?

    let root: URL

    static func defaultRoot() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Setecho", isDirectory: true)
    }

    init(root: URL = Store.defaultRoot()) {
        self.root = root
        try? FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        load()
    }

    var mediaDirectory: URL { root.appendingPathComponent("media", isDirectory: true) }

    // MARK: Writes

    func saveProgram(_ program: Program) {
        self.program = program
        write(program, "program.json")
    }

    func saveTemplate(_ template: CheckInTemplate) {
        self.template = template
        write(template, "template.json")
    }

    func upsert(session: Session) {
        if let i = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[i] = session
        } else {
            sessions.append(session)
        }
        write(sessions, "sessions.json")
    }

    func upsert(photoSet: PhotoSet) {
        if let i = photoSets.firstIndex(where: { $0.id == photoSet.id }) {
            photoSets[i] = photoSet
        } else {
            photoSets.append(photoSet)
        }
        write(photoSets, "photoSets.json")
    }

    func upsert(checkIn: CheckInDraft) {
        if let i = checkIns.firstIndex(where: { $0.id == checkIn.id }) {
            checkIns[i] = checkIn
        } else {
            checkIns.append(checkIn)
        }
        write(checkIns, "checkIns.json")
    }

    // MARK: Derived

    /// The next program day with no completed session, in program order. Nil without a program.
    /// A session that ended with nothing logged (started by mistake) does not count as done.
    var nextDay: (week: ProgramWeek, day: ProgramDay)? {
        guard let program else { return nil }
        let done = Set(sessions.filter { $0.isComplete && !$0.sets.isEmpty }.map(\.programDayId))
        return program.days.first { !done.contains($0.day.id) } ?? program.days.first
    }

    var lastPhotoSet: PhotoSet? { photoSets.max { $0.takenAt < $1.takenAt } }
    /// The first photo set ever: every later week is cropped to match it.
    var referencePhotoSet: PhotoSet? { photoSets.min { $0.takenAt < $1.takenAt } }
    var lastSentCheckIn: CheckInDraft? { checkIns.filter(\.isSent).max { $0.sentAt! < $1.sentAt! } }

    // MARK: Files

    private func load() {
        program = read("program.json")
        template = read("template.json")
        sessions = read("sessions.json") ?? []
        photoSets = read("photoSets.json") ?? []
        checkIns = read("checkIns.json") ?? []
    }

    private func read<T: Decodable>(_ name: String) -> T? {
        let url = root.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONCoding.decoder.decode(T.self, from: data)
        } catch {
            loadError = "\(name): \(error.localizedDescription)"
            return nil
        }
    }

    private func write<T: Encodable>(_ value: T, _ name: String) {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let data = try JSONCoding.encoder.encode(value)
            try data.write(to: root.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
        } catch {
            loadError = "\(name): \(error.localizedDescription)"
        }
    }
}
