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
    /// The athlete's own effort map, per exercise, from his spoken RPEs (HANDOFF.md §7, Calibration).
    private(set) var calibration = Effort.Calibration()
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
            next.rules = plan.rules.filter { $0.source != "Sheet note" } + program.rules
            appendPlan(next)
        } else {
            var seeded = PlanState.seed(program: program, template: template, targets: nil, cardioProtocol: cardioProtocol)
            seeded.rules = program.rules
            appendPlan(seeded)
        }
        refreshCycle()
    }

    /// A spoken RPE on a measured set: one more pair for that exercise's map.
    func addCalibration(exerciseId: String, velocityLossPct: Double, rpe: Double) {
        calibration.add(exerciseId: exerciseId, velocityLossPct: velocityLossPct, rpe: rpe)
        write(calibration, "calibration.json")
    }

    /// Last time's set for each exercise and role ("exerciseId|role"), from the log: the starting
    /// load on a sheet that gives none, and the logbook line (HANDOFF.md §7).
    var lastSets: [String: LastSet] {
        var sets: [String: LastSet] = [:]
        for session in sessions.sorted(by: { $0.startedAt < $1.startedAt }) {
            for set in session.workingSets where set.loadLb > 0 {
                sets["\(set.exerciseId)|\(set.role?.rawValue ?? "")"] = LastSet(loadLb: set.loadLb, reps: set.reps)
            }
        }
        return sets
    }

    /// Accepted next-session suggestions not yet used: the load step waiting for each exercise.
    var nextSessionLoads: [String: Double] {
        var loads: [String: Double] = [:]
        for session in sessions.sorted(by: { $0.startedAt < $1.startedAt }) {
            for s in session.suggestions where s.scope == .nextSession && s.decision == .accepted {
                loads["\(s.exerciseId)|\(s.role?.rawValue ?? "")"] = s.toLb
            }
            // A later session that used the exercise clears the step: the log now carries it.
            for set in session.workingSets {
                let key = "\(set.exerciseId)|\(set.role?.rawValue ?? "")"
                if let pending = loads[key], set.loadLb >= pending, !session.suggestions.contains(where: { $0.exerciseId == set.exerciseId }) {
                    loads[key] = nil
                }
            }
        }
        return loads
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

    /// Edit the current plan in place: confirmations, the cycle cursor and add-on days are the
    /// athlete's bookkeeping, not a new version the coach wrote.
    func mutatePlan(_ body: (inout PlanState) -> Void) {
        guard !plans.isEmpty else { return }
        var current = plans[plans.count - 1]
        body(&current)
        guard current != plans[plans.count - 1] else { return }
        plans[plans.count - 1] = current
        write(plans, "plans.json")
    }

    /// His written instructions, read once (HANDOFF.md §5, /import/rules): a new plan version with
    /// the rules, targets, rest, warm-ups, cadence and quiet days, each unconfirmed until the
    /// athlete confirms it on Import. Rules from an earlier paste of his instructions are replaced.
    func saveRules(_ imported: RulesImport) {
        guard let plan else { return }
        var next = plan
        next.version += 1
        next.replyId = nil
        next.rules = plan.rules.filter { $0.source != "Coach's instructions" } + imported.rules
        next.roleTargets = imported.roleTargets
        next.restRules = imported.restRules
        next.warmups = imported.warmups
        next.checkInSchedule = imported.checkInSchedule
        next.quietDays = imported.quietDays
        appendPlan(next)
    }

    // MARK: The cycle (HANDOFF.md §7, Which day is today)

    /// Seed or advance the cursor; called on launch and when the app comes to the foreground.
    func refreshCycle(now: Date = .now) {
        guard let plan, !plan.program.cycleDays.isEmpty else { return }
        let next: CycleCursor?
        if let cursor = plan.cycle {
            next = Cycle.advanced(cursor, program: plan.program, sessions: sessions, today: now)
        } else {
            next = Cycle.seed(program: plan.program, sessions: sessions, today: now)
        }
        if let next, next != plan.cycle { mutatePlan { $0.cycle = next } }
    }

    /// "Change day" on Today, or "I'm doing Day 5 today".
    func changeDay(to dayId: String, now: Date = .now) {
        mutatePlan { $0.cycle = Cycle.changed(to: dayId, today: now) }
    }

    func setAddOnDays(_ days: [AddOnDays]) {
        mutatePlan { $0.addOnDays = days }
    }

    /// The cycle day Today shows, with its week. Nil without a program.
    var todayDay: (week: ProgramWeek, day: ProgramDay)? {
        guard let plan, let program = currentProgram else { return nil }
        if let cursor = plan.cycle, let found = program.day(id: cursor.dayId) { return found }
        return program.days.first
    }

    /// Today's session is complete: a second session the same day is still fine.
    func isDoneToday(dayId: String, now: Date = .now) -> Bool {
        sessions.contains { $0.programDayId == dayId && $0.isComplete && !$0.workingSets.isEmpty && Calendar.current.isDate($0.startedAt, inSameDayAs: now) }
    }

    /// The with-session add-ons due with today's session, catch-up included.
    func addOnsDue(on dayId: String?, now: Date = .now) -> [AddOnPlanner.Due] {
        guard let plan else { return [] }
        let schedule = CheckInSchedule()
        let week = schedule.week(endingBefore: schedule.nextDue(from: now))
        return plan.program.addOns.filter { $0.timing == .withSession }.compactMap { addOn in
            let chosen = plan.addOnDays.first { $0.addOnId == addOn.id }?.dayIds ?? AddOnPlanner.proposedDays(for: addOn, in: plan.program)
            return AddOnPlanner.due(addOn, dayId: dayId, chosenDays: chosen, sessions: sessions, today: now, week: week)
        }
    }

    /// The on-waking add-on due this morning, if any.
    func morningAddOnDue(now: Date = .now) -> AddOnPlanner.Due? {
        guard let plan else { return nil }
        let schedule = CheckInSchedule()
        let week = schedule.week(endingBefore: schedule.nextDue(from: now))
        let dayId = plan.cycle?.dayId
        return plan.program.addOns.filter { $0.timing == .onWaking }.compactMap { addOn in
            let chosen = plan.addOnDays.first { $0.addOnId == addOn.id }?.dayIds ?? AddOnPlanner.proposedDays(for: addOn, in: plan.program)
            return AddOnPlanner.due(addOn, dayId: dayId, chosenDays: chosen, sessions: sessions, today: now, week: week)
        }.first
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
        calibration = read("calibration.json") ?? Effort.Calibration()
        try? FileManager.default.createDirectory(at: cuesDirectory, withIntermediateDirectories: true)
        // Migration: the first launch after plans arrived seeds version 1 from what the phone already has.
        if plans.isEmpty, let program {
            appendPlan(PlanState.seed(program: program, template: template, targets: nil, cardioProtocol: Settings.shared.cardioProtocol))
        }
        // Migration: the cycle cursor is seeded as the day after the last completed session, then kept current.
        refreshCycle()
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
