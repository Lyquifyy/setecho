import Foundation
import Observation

/// The week's check-in (HANDOFF.md §7 Check-in): build WeekFacts from Apple Health and the log,
/// ask the backend for the draft, keep it in the Store, and track what the wrap-up still has to ask.
@MainActor
@Observable
final class CheckInCoordinator {
    private(set) var draft: CheckInDraft?
    private(set) var isDrafting = false
    private(set) var error: String?
    private(set) var facts: WeekFacts?

    let store: Store
    let settings: Settings
    /// His cadence once confirmed on Import, with the period running since the last sent check-in.
    let schedule: CheckInSchedule
    private let api: APIClient
    private let health = HealthService()

    init(store: Store, settings: Settings = .shared, api: APIClient = APIClient()) {
        self.store = store
        self.settings = settings
        self.api = api
        self.schedule = CheckInSchedule(plan: store.plan, lastSentAt: store.lastSentCheckIn?.sentAt)
        self.draft = Self.currentDraft(in: store, schedule: schedule)
        normalizeGlucose()
    }

    /// A glucose reading filed under measurements went out as "91 in" (Oct 28): the inches come off
    /// a glucose answer here, once, for a draft made before the fix.
    private func normalizeGlucose() {
        guard var current = draft, let template else { return }
        var changed = false
        for field in template.fields where field.label.lowercased().contains("glucose") {
            if let i = current.answers.firstIndex(where: { $0.fieldId == field.id }), current.answers[i].text.hasSuffix(" in") {
                current.answers[i].text = String(current.answers[i].text.dropLast(3))
                changed = true
            }
        }
        if changed {
            draft = current
            store.upsert(checkIn: current)
        }
    }

    /// The form with the plan's carried blocks, so the coach's latest words go out each week.
    var template: CheckInTemplate? { store.currentTemplate }
    var due: Date { schedule.nextDue(from: .now) }
    var week: (start: Date, end: Date) { schedule.week(endingBefore: due) }

    static func currentDraft(in store: Store, schedule: CheckInSchedule) -> CheckInDraft? {
        let due = schedule.nextDue(from: .now)
        let week = schedule.week(endingBefore: due)
        return store.checkIns.first { Calendar.current.isDate($0.weekEnd, inSameDayAs: week.end) && !$0.isSent }
    }

    var readyCount: Int { draft?.answers.filter { $0.state == .filled || $0.state == .confirmed }.count ?? 0 }
    var fieldCount: Int { template?.fields.count ?? 0 }
    var toAnswerCount: Int { questions.count }

    func answer(for field: FieldSpec) -> FieldAnswer? {
        draft?.answers.first { $0.fieldId == field.id }
    }

    /// Wrap-up questions: every missing or drafted voice field, with the tape measurements as one.
    var questions: [[FieldSpec]] {
        guard let template, let draft else { return [] }
        let byId = Dictionary(uniqueKeysWithValues: draft.answers.map { ($0.fieldId, $0) })
        var groups: [[FieldSpec]] = []
        var measurements: [FieldSpec] = []
        for field in template.orderedFields {
            let state = byId[field.id]?.state ?? .missing
            let asks = field.source.type == .voice || (state == .missing && field.source.type != .photo)
            guard asks, state == .missing || state == .drafted else { continue }
            if field.isTape, field.source.type == .voice {
                measurements.append(field)
            } else {
                groups.append([field])
            }
        }
        if !measurements.isEmpty { groups.append(measurements) }
        return groups
    }

    /// A rehearsal starts from nothing: the unsent draft goes, and the next build fills it again from data.
    func discardDraft() {
        if let draft { store.remove(checkInId: draft.id) }
        draft = nil
    }

    // MARK: Build the draft

    func buildDraft() async {
        guard let template else { return }
        guard !isDrafting else { return }
        isDrafting = true
        error = nil
        defer { isDrafting = false }
        do {
            let (start, end) = week
            var weekReadings = HealthService.Week(days: [], sources: [:])
            if health.isAvailable {
                try? await health.requestAuthorization()
                weekReadings = (try? await health.read(from: start, to: end)) ?? weekReadings
            }
            let sessions = store.sessions
            let thisWeek = sessions.filter { $0.startedAt >= start && $0.startedAt < end && !$0.sets.isEmpty }
            let earlier = sessions.filter { $0.startedAt < start }
            let targets = store.plan?.targets ?? CheckInTemplate.parsedTargets(template)
            let facts = WeekFacts.build(
                week: weekReadings, weekStart: start, weekEnd: end, targets: targets, sessions: sessions,
                scheduledWeekdays: settings.trainingWeekdays, showDate: settings.showDateOrNil,
                lastCheckInWeightLb: Self.lastWeight(in: store)
            )
            var withProtocol = facts
            let cardio = store.plan?.cardioProtocol.isEmpty == false ? store.plan!.cardioProtocol : settings.cardioProtocol
            withProtocol.cardioProtocol = cardio.isEmpty ? nil : cardio
            self.facts = withProtocol
            if health.isAvailable { weightMissingToday = await !health.hasWeighIn(sinceHour: 4) }

            let prs = Adherence.personalRecords(thisWeek: thisWeek, earlier: earlier).map { set in
                PersonalRecord(exercise: store.currentProgram?.exerciseName(id: set.exerciseId) ?? set.exerciseId, loadLb: set.loadLb, reps: set.reps)
            }
            let scheduled = settings.trainingWeekdays.isEmpty ? (store.currentProgram?.weeks.first?.days.count ?? thisWeek.count) : settings.trainingWeekdays.count
            let training = TrainingSummary(
                sessionsDone: thisWeek.filter(\.isComplete).count,
                sessionsScheduled: max(scheduled, thisWeek.count),
                setsLogged: thisWeek.flatMap(\.sets).count,
                prs: prs,
                exercises: Array(Set(thisWeek.flatMap(\.sets).compactMap { store.currentProgram?.exerciseName(id: $0.exerciseId) })).sorted()
            )
            let notes = thisWeek.flatMap(\.notes)
            let draftId = draft?.id ?? UUID()
            let request = DraftRequest(
                template: template, facts: withProtocol, notes: notes, training: training,
                lastCheckIn: store.lastSentCheckIn, styleExamples: StyleExamples.load(), draftId: draftId.uuidString
            )
            var fresh = try await api.checkInDraft(request)
            // Keep answers the athlete already confirmed or spoke this week.
            if let existing = draft {
                let kept = Dictionary(uniqueKeysWithValues: existing.answers.filter { $0.state == .confirmed || $0.provenance.contains { $0.source.hasPrefix("You said") } }.map { ($0.fieldId, $0) })
                fresh.answers = fresh.answers.map { kept[$0.fieldId] ?? $0 }
                fresh.photoSetId = existing.photoSetId
                fresh.videoPicks = existing.videoPicks
                fresh.adjustments = existing.adjustments
            }
            if fresh.photoSetId == nil { fresh.photoSetId = store.lastPhotoSet?.id }
            draft = fresh
            store.upsert(checkIn: fresh)
        } catch {
            self.error = error.userMessage
        }
    }

    // MARK: Edits

    func set(_ fieldId: String, text: String, state: AnswerState, provenance: [Provenance]? = nil) {
        guard var draft else { return }
        if let i = draft.answers.firstIndex(where: { $0.fieldId == fieldId }) {
            draft.answers[i].text = text
            draft.answers[i].state = state
            if let provenance { draft.answers[i].provenance = provenance }
        } else {
            draft.answers.append(FieldAnswer(fieldId: fieldId, text: text, state: state, provenance: provenance ?? []))
        }
        self.draft = draft
        store.upsert(checkIn: draft)
    }

    func apply(_ answers: [FieldAnswer]) {
        for a in answers where a.state != .missing {
            set(a.fieldId, text: a.text, state: a.state, provenance: a.provenance)
        }
    }

    func confirm(_ fieldId: String) {
        guard let a = answer(for: FieldSpec(id: fieldId, label: "", prompt: nil, kind: .text, source: FieldSource(type: .voice, key: nil), order: 0)) else { return }
        set(fieldId, text: a.text, state: .confirmed)
    }

    func markSent() {
        guard var draft else { return }
        draft.sentAt = .now
        self.draft = draft
        store.upsert(checkIn: draft)
    }

    func setVideoPicks(_ picks: [VideoPick]) {
        guard var draft, draft.videoPicks != picks else { return }
        draft.videoPicks = picks
        self.draft = draft
        store.upsert(checkIn: draft)
    }

    func setAdjustments(_ ids: [UUID]) {
        guard var draft, draft.adjustments != ids else { return }
        draft.adjustments = ids
        self.draft = draft
        store.upsert(checkIn: draft)
    }

    /// The collage taken on check-in morning joins the draft.
    func attachPhotoSet(_ id: UUID) {
        guard var draft else { return }
        draft.photoSetId = id
        self.draft = draft
        store.upsert(checkIn: draft)
    }

    /// Today's weigh-in from Apple Health, as the check-in writes it ("180.8"), once it is in.
    var weightTodayText: String? {
        if let lb = todayWeighInLb { return Format.number((lb * 10).rounded() / 10) }
        guard let facts, let today = facts.daily.last(where: { $0.weighInLb != nil && $0.date == DayKey.string(.now) }),
              let lb = today.weighInLb else { return nil }
        return Format.number((lb * 10).rounded() / 10)
    }

    // MARK: Helpers

    /// Kept as the seeding function only (HANDOFF.md §4, Migrations); the plan owns the targets after that.
    static func targets(from template: CheckInTemplate) -> MacroTargets {
        CheckInTemplate.parsedTargets(template)
    }

    // MARK: Weight fallback (HANDOFF.md §7, HealthKit)

    /// No bodyMass sample since 4 AM today: Withings only writes to Apple Health when its app is opened.
    private(set) var weightMissingToday = false
    static let weightMissingMessage = "Open Withings once to sync today's weight"

    /// Today's weigh-in from Apple Health, read on its own (one query) so a step change never
    /// rebuilds the whole draft: before Oct 27 every resume re-read the week and called Spark.
    private(set) var todayWeighInLb: Double?

    /// Re-queried at every step of Check-in morning and when Setecho comes back to the foreground.
    func refreshWeightToday() async {
        guard health.isAvailable else { weightMissingToday = false; return }
        todayWeighInLb = await health.weighInLb(sinceHour: 4)
        weightMissingToday = todayWeighInLb == nil
    }

    /// A rehearsal from the top without a rebuild: everything spoken goes back to unanswered, the
    /// weight is offered again, the data-filled fields and Spark's drafts stay, the photos are set aside.
    func resetSpokenAnswers() {
        guard var current = draft, let template else { return }
        let spoken = Set(template.fields.filter { $0.source.type == .voice || $0.source.key == .currentWeight }.map(\.id))
        current.answers = current.answers.map { answer in
            guard spoken.contains(answer.fieldId) || answer.provenance.contains(where: { $0.source.hasPrefix("You said") }) else { return answer }
            var reset = answer
            reset.text = ""
            reset.state = .missing
            reset.provenance = []
            return reset
        }
        current.photoSetId = nil
        draft = current
        store.upsert(checkIn: current)
    }

    /// The last wrap-up question when the weigh-in never arrived: "What's your weight today?"
    var weightField: FieldSpec? {
        template?.fields.first { $0.source.key == .currentWeight }
    }

    static func lastWeight(in store: Store) -> Double? {
        // A check-in from the WhatsApp import that's newer than any sent from Setecho: his first
        // Setecho check-in still has last week's weight.
        if let past = store.chatHistory.checkIns.max(by: { $0.sentAt < $1.sentAt }),
           past.sentAt > (store.lastSentCheckIn?.sentAt ?? .distantPast) {
            let id = store.currentTemplate?.fields.first { $0.source.key == .currentWeight }?.id
            let answer = past.answers.first { $0.key == id || $0.key.contains("current_body_weight") }?.value
            return answer.flatMap(CheckInText.number)
        }
        guard let last = store.lastSentCheckIn,
              let answer = last.answers.first(where: { $0.fieldId.contains("current_body_weight") })
        else { return nil }
        return Double(answer.text.filter { $0.isNumber || $0 == "." })
    }
}

extension Program {
    func exerciseName(id: String) -> String? {
        weeks.flatMap(\.days).flatMap(\.exercises).first { $0.id == id }?.name
    }
}

/// How the athlete writes (numbers blanked), sent as styleExamples: his last few check-ins from the
/// WhatsApp import when there is one, else the bundled examples.
enum StyleExamples {
    static func load(root: URL = Store.defaultRoot()) -> [String] {
        if let data = try? Data(contentsOf: root.appendingPathComponent("whatsapp.json")),
           let history = try? JSONCoding.decoder.decode(ChatHistory.self, from: data), !history.styleExamples.isEmpty {
            return history.styleExamples
        }
        guard let url = Bundle.main.url(forResource: "StyleExamples", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
