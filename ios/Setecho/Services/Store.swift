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
    /// Last time's top sets from his paper logbook, for lifts not yet logged in the app.
    private(set) var logbook: [LogbookEntry] = []
    /// Past check-ins and the coach's replies, read from a WhatsApp export (HANDOFF.md §9).
    private(set) var chatHistory = ChatHistory()
    /// The sets he logged before Setecho, from Liftoff and Garmin (HANDOFF.md §9, Bring your history).
    private(set) var history = TrainingHistory()
    private(set) var loadError: String?

    let root: URL

    nonisolated static func defaultRoot() -> URL {
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

    /// One entry per exercise and role: a newer one replaces it.
    func addLogbook(_ entry: LogbookEntry) {
        logbook.removeAll { $0.exerciseId == entry.exerciseId && $0.role == entry.role }
        logbook.append(entry)
        write(logbook, "logbook.json")
    }

    func removeLogbook(exerciseId: String, role: SetRole?) {
        logbook.removeAll { $0.exerciseId == exerciseId && $0.role == role }
        write(logbook, "logbook.json")
    }

    /// Last time's set for each exercise and role ("exerciseId|role"): his paper logbook and his
    /// imported Liftoff and Garmin sets, the newer winning, beneath the app's log, so any set logged
    /// in the app wins. The starting load on a sheet that gives none, and the logbook line (HANDOFF.md §7).
    var lastSets: [String: LastSet] {
        var earlier: [(key: String, set: LastSet)] = logbook.map {
            (SessionEngine.loadKey($0.exerciseId, $0.role), LastSet(loadLb: $0.loadLb, reps: $0.reps, source: "Logbook", date: $0.date))
        }
        let exercises = currentProgram.map { $0.cycleDays.flatMap(\.exercises) + $0.addOns.flatMap(\.exercises) } ?? []
        earlier += history.lastSets(for: exercises, steps: Settings.shared.loadSteps).map { ($0.key, $0.value) }
        var sets: [String: LastSet] = [:]
        for entry in earlier.sorted(by: { ($0.set.date ?? .distantPast) < ($1.set.date ?? .distantPast) }) {
            sets[entry.key] = entry.set
        }
        for session in sessions.sorted(by: { $0.startedAt < $1.startedAt }) {
            for set in session.workingSets where set.loadLb > 0 {
                sets["\(set.exerciseId)|\(set.role?.rawValue ?? "")"] = LastSet(loadLb: set.loadLb, reps: set.reps,
                                                                                source: "Training log", date: session.startedAt)
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
        let next = Cycle.current(plan.cycle, program: plan.program, sessions: sessions, today: now, firstWeekday: Settings.shared.cycleFirstWeekday)
        if let next, next != plan.cycle { mutatePlan { $0.cycle = next } }
    }

    /// "Change day" on Today, or "I'm doing Day 5 today".
    func changeDay(to dayId: String, now: Date = .now) {
        mutatePlan { $0.cycle = Cycle.changed(to: dayId, today: now) }
    }

    func setAddOnDays(_ days: [AddOnDays]) {
        mutatePlan { $0.addOnDays = days }
    }

    /// "When a machine's taken, what does your coach want?", answered and confirmed in the rules review.
    func setTakenRule(_ rule: TakenRule?) {
        mutatePlan { $0.takenRule = rule }
    }

    /// Each swapped variant's last working load ("exerciseId|doneAs", lowercased): a swap's load comes
    /// from its own history, never converted from the planned lift's.
    var variantLoads: [String: Double] {
        var loads: [String: Double] = [:]
        for session in sessions.sorted(by: { $0.startedAt < $1.startedAt }) {
            for set in session.workingSets where set.loadLb > 0 {
                if let doneAs = set.doneAs { loads["\(set.exerciseId)|\(doneAs.lowercased())"] = set.loadLb }
            }
        }
        return loads
    }

    /// The variants he swapped to, most recent first: "prefer the variant done most recently".
    var recentVariants: [String] {
        var seen = Set<String>()
        return sessions.sorted { $0.startedAt > $1.startedAt }.flatMap(\.deviations).compactMap(\.doneAs)
            .filter { seen.insert($0.lowercased()).inserted }
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

    func remove(checkInId: UUID) {
        checkIns.removeAll { $0.id == checkInId }
        write(checkIns, "checkIns.json")
    }

    func upsert(checkIn: CheckInDraft) {
        if let i = checkIns.firstIndex(where: { $0.id == checkIn.id }) {
            checkIns[i] = checkIn
        } else {
            checkIns.append(checkIn)
        }
        write(checkIns, "checkIns.json")
    }

    // MARK: WhatsApp history (HANDOFF.md §9, WhatsApp history import)

    /// Add what's new in an export: a check-in or reply already imported is skipped, and every
    /// message read is remembered (timestamp + sender + text). `copy` writes one of the export's
    /// files to the given place in the media folder, and only the kept items' files are copied.
    @discardableResult
    func mergeChat(_ result: ChatImport.Result, athlete: String, coach: String, template: CheckInTemplate,
                   now: Date = .now, copy: (_ file: String, _ to: URL) throws -> Void) throws -> (checkIns: Int, coachMessages: Int) {
        var history = chatHistory
        let seen = history.seen.union(history.checkIns.map(\.id)).union(history.coachMessages.map(\.id))
        var checkIns = result.checkIns.filter { !seen.contains($0.id) }
        var messages = result.coachMessages.filter { !seen.contains($0.id) }
        // A file the export doesn't hold (shared without media, or damaged) drops out of its item.
        var missing = Set<String>()
        for file in checkIns.flatMap(\.photoFiles) + messages.compactMap(\.audioFile) {
            let url = mediaDirectory.appendingPathComponent(file)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try copy((file as NSString).lastPathComponent, url) } catch { missing.insert(file) }
        }
        for i in checkIns.indices { checkIns[i].photoFiles.removeAll(where: missing.contains) }
        for i in messages.indices where messages[i].audioFile.map(missing.contains) == true { messages[i].audioFile = nil }
        messages.removeAll { $0.text.isEmpty && $0.audioFile == nil }
        history.athleteName = athlete
        history.coachName = coach
        history.checkIns = (history.checkIns + checkIns).sorted { $0.sentAt < $1.sentAt }
        history.coachMessages = (history.coachMessages + messages).sorted { $0.at < $1.at }
        history.seen.formUnion(result.keys)
        history.styleExamples = ChatImport.styleExamples(history.checkIns, template: template)
        history.lastImportAt = now
        chatHistory = history
        write(chatHistory, "whatsapp.json")
        return (checkIns.count, messages.count)
    }

    // MARK: Liftoff and Garmin history (HANDOFF.md §9, Bring your history)

    /// Keep an import: its sessions replace any with the same id, and every name he confirmed is
    /// remembered (a plan exercise id, or nil for its own name) so the next import asks only new ones.
    func mergeHistory(_ sessions: [ImportedSession], matches: [String: String?], liftoffUnit: WeightUnit, now: Date = .now) {
        var next = history
        let incoming = Set(sessions.map(\.id))
        next.sessions = (next.sessions.filter { !incoming.contains($0.id) } + sessions).sorted { $0.startedAt < $1.startedAt }
        for (name, exerciseId) in matches {
            if let exerciseId {
                next.matches[name] = exerciseId
                next.ownNames.remove(name)
            } else {
                next.matches[name] = nil
                next.ownNames.insert(name)
            }
        }
        next.liftoffUnit = liftoffUnit
        next.lastImportAt = now
        history = next
        write(history, "history.json")
    }

    /// "Start over": the imported sessions and the remembered matches go.
    func clearHistory() {
        history = TrainingHistory()
        write(history, "history.json")
    }

    /// "Start over": the imported history and its files go, so a fresh export can be read again.
    func clearChatHistory() {
        try? FileManager.default.removeItem(at: mediaDirectory.appendingPathComponent(ChatImport.mediaFolder))
        chatHistory = ChatHistory()
        write(chatHistory, "whatsapp.json")
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
        logbook = read("logbook.json") ?? []
        chatHistory = read("whatsapp.json") ?? ChatHistory()
        history = read("history.json") ?? TrainingHistory()
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
