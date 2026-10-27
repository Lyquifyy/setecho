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
    let schedule = CheckInSchedule()
    private let api: APIClient
    private let health = HealthService()

    init(store: Store, settings: Settings = .shared, api: APIClient = APIClient()) {
        self.store = store
        self.settings = settings
        self.api = api
        self.draft = Self.currentDraft(in: store, schedule: schedule)
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
            if field.kind == .measurement, field.source.type == .voice {
                measurements.append(field)
            } else {
                groups.append([field])
            }
        }
        if !measurements.isEmpty { groups.append(measurements) }
        return groups
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
            }
            if fresh.photoSetId == nil { fresh.photoSetId = store.lastPhotoSet?.id }
            draft = fresh
            store.upsert(checkIn: fresh)
        } catch {
            self.error = error.localizedDescription
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

    // MARK: Helpers

    /// Kept as the seeding function only (HANDOFF.md §4, Migrations); the plan owns the targets after that.
    static func targets(from template: CheckInTemplate) -> MacroTargets {
        CheckInTemplate.parsedTargets(template)
    }

    // MARK: Weight fallback (HANDOFF.md §7, HealthKit)

    /// No bodyMass sample since 4 AM today: Withings only writes to Apple Health when its app is opened.
    private(set) var weightMissingToday = false
    static let weightMissingMessage = "Open Withings once to sync today's weight"

    /// Re-queried when the wrap-up starts and when Setecho comes back to the foreground.
    func refreshWeightToday() async {
        guard health.isAvailable else { weightMissingToday = false; return }
        weightMissingToday = await !health.hasWeighIn(sinceHour: 4)
        if !weightMissingToday, let draft, let template,
           let field = template.fields.first(where: { $0.source.key == .currentWeight }),
           draft.answers.first(where: { $0.fieldId == field.id })?.state != .confirmed {
            await buildDraft()
        }
    }

    /// The last wrap-up question when the weigh-in never arrived: "Today's weight?"
    var weightField: FieldSpec? {
        template?.fields.first { $0.source.key == .currentWeight }
    }

    static func lastWeight(in store: Store) -> Double? {
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

/// Bundled examples of how the athlete writes (numbers blanked), sent as styleExamples.
enum StyleExamples {
    static func load() -> [String] {
        guard let url = Bundle.main.url(forResource: "StyleExamples", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
