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
    /// Every plan version, oldest first. `plan` is the current one; the rest allow revert.
    private(set) var plans: [PlanState] = []
    private(set) var coachReplies: [CoachReply] = []
    private(set) var cues: [VoiceCue] = []
    /// "Update MacroFactor: …" lines waiting for the athlete to mark done.
    private(set) var macroFactorReminders: [String] = []
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
    var cuesDirectory: URL { mediaDirectory.appendingPathComponent("cues", isDirectory: true) }

    /// The plan the coach controls. Every reader of the program, targets, cardio protocol and
    /// carried blocks goes through here (HANDOFF.md §4, Migrations).
    var plan: PlanState? { plans.last }
    /// The current program: the plan's, else the import before plans existed.
    var currentProgram: Program? { plan?.program ?? program }
    /// The check-in template with the plan's carried blocks (the coach's latest words).
    var currentTemplate: CheckInTemplate? {
        guard var template else { return nil }
        if let plan { template.carriedBlocks = plan.carriedBlocks }
        return template
    }

    // MARK: Writes

    /// A new program import: plan version +1 with the new program, everything else carried over.
    func saveProgram(_ program: Program, cardioProtocol: String = Settings.shared.cardioProtocol) {
        self.program = program
        write(program, "program.json")
        if let plan {
            var next = plan
            next.version += 1
            next.program = program
            next.replyId = nil
            appendPlan(next)
        } else {
            appendPlan(PlanState.seed(program: program, template: template, targets: nil, cardioProtocol: cardioProtocol))
        }
    }

    /// A new form import: plan version +1 with its blocks, targets and cardio protocol.
    func saveTemplate(_ template: CheckInTemplate, targets: MacroTargets? = nil, cardioProtocol: String? = nil) {
        self.template = template
        write(template, "template.json")
        let cardio = cardioProtocol ?? plan?.cardioProtocol ?? Settings.shared.cardioProtocol
        if let plan {
            var next = plan
            next.version += 1
            next.carriedBlocks = template.carriedBlocks
            next.targets = targets ?? CheckInTemplate.parsedTargets(template)
            next.cardioProtocol = cardio
            next.replyId = nil
            appendPlan(next)
        } else if let program {
            appendPlan(PlanState.seed(program: program, template: template, targets: targets, cardioProtocol: cardio))
        }
        if let cardioProtocol, !cardioProtocol.isEmpty { Settings.shared.cardioProtocol = cardioProtocol }
    }

    func appendPlan(_ plan: PlanState) {
        plans.append(plan)
        write(plans, "plans.json")
    }

    /// Revert the latest applied reply: drop its version and mark the reply unapplied.
    @discardableResult
    func revertLatestPlan() -> PlanState? {
        guard plans.count > 1, let latest = plans.last else { return nil }
        plans.removeLast()
        write(plans, "plans.json")
        if let replyId = latest.replyId, let i = coachReplies.firstIndex(where: { $0.id == replyId }) {
            coachReplies[i].appliedVersion = nil
            write(coachReplies, "coachReplies.json")
        }
        return plans.last
    }

    func upsert(reply: CoachReply) {
        if let i = coachReplies.firstIndex(where: { $0.id == reply.id }) {
            coachReplies[i] = reply
        } else {
            coachReplies.append(reply)
        }
        write(coachReplies, "coachReplies.json")
    }

    func delete(replyId: UUID) {
        coachReplies.removeAll { $0.id == replyId }
        write(coachReplies, "coachReplies.json")
        cues.removeAll { $0.replyId == replyId }
        write(cues, "cues.json")
    }

    /// Cues stay active until the coach's next reply replaces them (HANDOFF.md §7, Coach voice cues).
    func replaceCues(with new: [VoiceCue]) {
        cues = new
        write(cues, "cues.json")
    }

    func update(cue: VoiceCue) {
        if let i = cues.firstIndex(where: { $0.id == cue.id }) { cues[i] = cue }
        write(cues, "cues.json")
    }

    func addMacroFactorReminders(_ lines: [String]) {
        macroFactorReminders.append(contentsOf: lines)
        write(macroFactorReminders, "reminders.json")
    }

    func clearMacroFactorReminders() {
        macroFactorReminders = []
        write(macroFactorReminders, "reminders.json")
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
        guard let program = currentProgram else { return nil }
        let done = Set(sessions.filter { $0.isComplete && !$0.sets.isEmpty }.map(\.programDayId))
        return program.days.first { !done.contains($0.day.id) } ?? program.days.first
    }

    var lastPhotoSet: PhotoSet? { photoSets.max { $0.takenAt < $1.takenAt } }
    /// The first photo set ever: every later week is cropped to match it.
    var referencePhotoSet: PhotoSet? { photoSets.min { $0.takenAt < $1.takenAt } }
    var lastSentCheckIn: CheckInDraft? { checkIns.filter(\.isSent).max { $0.sentAt! < $1.sentAt! } }
    /// A reply read but not yet applied: the Today card's "Review changes".
    var pendingReply: CoachReply? { coachReplies.filter { !$0.isApplied }.max { $0.receivedAt < $1.receivedAt } }
    var appliedReplies: [CoachReply] { coachReplies.filter(\.isApplied).sorted { ($0.appliedVersion ?? 0) > ($1.appliedVersion ?? 0) } }

    // MARK: Files

    private func load() {
        program = read("program.json")
        template = read("template.json")
        sessions = read("sessions.json") ?? []
        photoSets = read("photoSets.json") ?? []
        checkIns = read("checkIns.json") ?? []
        plans = read("plans.json") ?? []
        coachReplies = read("coachReplies.json") ?? []
        cues = read("cues.json") ?? []
        macroFactorReminders = read("reminders.json") ?? []
        try? FileManager.default.createDirectory(at: cuesDirectory, withIntermediateDirectories: true)
        // Migration: the first launch after plans arrived seeds version 1 from what the phone already has.
        if plans.isEmpty, let program {
            appendPlan(PlanState.seed(program: program, template: template, targets: nil, cardioProtocol: Settings.shared.cardioProtocol))
        }
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
