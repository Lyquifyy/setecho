import SwiftUI
import UniformTypeIdentifiers

/// More → "Import Liftoff and Garmin" (HANDOFF.md §9, Bring your history): the sets he logged before
/// Setecho. The backend reads the files by code; Muse Spark matches the exercise names, names only,
/// to his plan; he confirms the whole list once, and the matches are remembered.
@MainActor
@Observable
final class HistoryImportModel {
    enum Step { case start, reading, review, done }

    /// One plan day's lifts, for the match list and the pickers.
    struct PlanDay: Identifiable {
        var id: String
        var name: String
        var exercises: [PlannedExercise]
    }

    private(set) var step: Step = .start
    private(set) var error: String?
    /// Matching failed: the list starts with every name unmatched, for him to match by hand.
    private(set) var matchError: String?
    private(set) var result: HistoryImportResult?
    private(set) var unit: WeightUnit
    /// Name → the plan exercises it is (empty: kept under its own name). Remembered answers, then Spark's.
    var proposed: [String: [String]] = [:]
    /// A day in both Liftoff and Garmin → the one he keeps.
    var choices: [String: HistorySource] = [:]
    private(set) var added: Int?
    private var files: [APIClient.HistoryFile] = []
    private let store: Store
    private let api: APIClient

    init(store: Store, api: APIClient = APIClient()) {
        self.store = store
        self.api = api
        unit = store.history.liftoffUnit
    }

    /// His plan's days and add-ons, each exercise once.
    var planDays: [PlanDay] {
        guard let program = store.currentProgram else { return [] }
        var seen = Set<String>()
        var days = program.trainingDays.map { day in
            PlanDay(id: day.id, name: day.name, exercises: day.exercises.filter { seen.insert($0.id).inserted })
        }
        days += program.addOns.map { addOn in
            PlanDay(id: addOn.id, name: addOn.name, exercises: addOn.exercises.filter { seen.insert($0.id).inserted })
        }
        return days.filter { !$0.exercises.isEmpty }
    }

    var sessions: [ImportedSession] { result?.sessions ?? [] }
    var kept: [ImportedSession] { TrainingHistory.kept(sessions, choices: choices) }
    var names: [String] { TrainingHistory.names(in: sessions) }
    var sameDays: [String] { TrainingHistory.sameDays(in: sessions) }
    var hasLiftoff: Bool { sessions.contains { $0.source == .liftoff } }
    var alreadyImported: Int { sessions.filter { s in store.history.sessions.contains { $0.id == s.id } }.count }

    func names(for exerciseId: String) -> [String] { names.filter { proposed[$0]?.contains(exerciseId) == true } }
    var ownNames: [String] { names.filter { proposed[$0]?.isEmpty ?? true } }

    /// "Change": a plan lift on or off for this name; a name can be the same lift on two days.
    func toggle(_ name: String, _ exerciseId: String) {
        var ids = proposed[name] ?? []
        if let i = ids.firstIndex(of: exerciseId) { ids.remove(at: i) } else { ids.append(exerciseId) }
        proposed[name] = ids
    }

    func exercise(_ id: String) -> PlannedExercise? { planDays.lazy.flatMap(\.exercises).first { $0.id == id } }

    /// The picked files: read on the backend, then the new names matched.
    func open(_ urls: [URL]) async {
        error = nil
        var picked: [APIClient.HistoryFile] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                picked.append(.init(filename: url.lastPathComponent, data: try Data(contentsOf: url)))
            } catch {
                self.error = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
                return
            }
        }
        guard !picked.isEmpty else { return }
        files = picked
        await read(matching: true)
    }

    /// "Liftoff weights are in pounds?": the other answer reads the files again, matches kept.
    func setUnit(_ unit: WeightUnit) async {
        guard unit != self.unit else { return }
        self.unit = unit
        await read(matching: false)
    }

    private func read(matching: Bool) async {
        step = .reading
        do {
            let result = try await api.importHistory(files, liftoffUnit: unit)
            self.result = result
            if matching { await match() }
            step = .review
        } catch {
            self.error = error.userMessage
            step = result == nil ? .start : .review
        }
    }

    /// "Try again" after a failed match: only the names still unmatched go.
    func retryMatch() async {
        let answered = proposed.filter { !$0.value.isEmpty }
        await match()
        for (name, ids) in answered { proposed[name] = ids }  // his own picks stay
    }

    /// Remembered answers first; only names he hasn't confirmed go to Spark.
    private func match() async {
        matchError = nil
        let history = store.history
        let ids = Set(planDays.flatMap(\.exercises).map(\.id))
        var proposed: [String: [String]] = [:]
        for name in names where history.isConfirmed(name) {
            proposed[name] = (history.matches[name] ?? []).filter(ids.contains)
        }
        let new = names.filter { proposed[$0] == nil }
        if !new.isEmpty, !planDays.isEmpty {
            do {
                for m in try await api.matchHistory(names: new, exercises: planDays.flatMap(\.exercises)) {
                    proposed[m.name] = m.exerciseIds.filter(ids.contains)
                }
            } catch {
                matchError = error.userMessage
            }
        }
        for name in names where proposed[name] == nil { proposed[name] = [] }
        self.proposed = proposed
    }

    func commit() {
        let answers = Dictionary(uniqueKeysWithValues: names.map { ($0, proposed[$0] ?? []) })
        store.mergeHistory(kept, matches: answers, liftoffUnit: unit)
        added = kept.count
        step = .done
    }
}

struct HistoryImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    @State private var model: HistoryImportModel?
    @State private var showPicker = false
    @State private var confirmStartOver = false

    init(model: HistoryImportModel? = nil) { _model = State(initialValue: model) }

    private static let fitType = UTType(filenameExtension: "fit") ?? .data

    var body: some View {
        let model = model ?? HistoryImportModel(store: store)
        ScreenScaffold(onClose: { dismiss() }) {
            TitleBlock(title: "Import Liftoff and Garmin", subtitle: "The sets you logged before Setecho, so Last time is right from your first session.")
            switch model.step {
            case .start: start
            case .reading: LoadingCard(title: "Reading your files", detail: "Then matching the names to your plan.")
            case .review: review(model)
            case .done: done(model)
            }
            if let error = model.error {
                SectionCard("Couldn't read it") {
                    Text(error).font(.subheadline).foregroundStyle(Theme.navy)
                }
            }
        } footer: {
            footer(model)
        }
        .onAppear { if self.model == nil { self.model = model } }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.commaSeparatedText, .zip, Self.fitType], allowsMultipleSelection: true) { result in
            // The stored model: this closure can outlive the render that made a fresh one.
            if case .success(let urls) = result, let model = self.model { Task { await model.open(urls) } }
        }
        .confirmationDialog("Start over?", isPresented: $confirmStartOver, titleVisibility: .visible) {
            Button("Remove the imported history", role: .destructive) { store.clearHistory() }
        } message: {
            Text("Its sessions and your confirmed matches leave Setecho. Liftoff and Garmin aren't touched.")
        }
    }

    // MARK: Steps

    @ViewBuilder private var start: some View {
        SectionCard("Export them") {
            Text("Liftoff: export your workout data as a CSV. Garmin Connect: open each strength activity, then the gear → Export Original. Save them to Files and pick them all here.")
                .font(.subheadline).foregroundStyle(Theme.navy)
        }
        SectionCard("What's kept") {
            Text("Every session, set by set, on this phone. The heaviest set of each lift is its top set, and lighter sets after it are back-offs. Only the exercise names go to Muse Spark, to match them to your plan; you confirm every match.")
                .font(.subheadline).secondaryText()
        }
        if store.currentProgram == nil {
            SectionCard("Import your program first") {
                Text("Names are matched to your coach's program, so import it first.").font(.subheadline).secondaryText()
                LinkButton(title: "Import") { dismiss(); AppRouter.shared.showImport = true }
            }
        }
        let history = store.history
        if let last = history.lastImportAt {
            SectionCard("Last import", accessory: {
                Button("Start over", systemImage: "arrow.counterclockwise") { confirmStartOver = true }.buttonStyle(.setechoTonal)
            }) {
                Text("\(Format.shortDate(last)) · \(history.sessions.count) sessions · \(history.matches.count) names matched")
                    .font(.subheadline).monospacedDigit().foregroundStyle(Theme.navy)
                Text("Importing again replaces those sessions and asks only about new names.").font(.footnote).secondaryText()
            }
        }
    }

    @ViewBuilder private func review(_ model: HistoryImportModel) -> some View {
        found(model)
        if model.hasLiftoff { unitCard(model) }
        if !model.sameDays.isEmpty { sameDaysCard(model) }
        if let matchError = model.matchError {
            SectionCard("Couldn't match the names", accessory: {
                Button("Try again", systemImage: "arrow.clockwise") { Task { await model.retryMatch() } }.buttonStyle(.setechoTonal)
            }) {
                Text("\(matchError) Try again, or match them below.").font(.subheadline).foregroundStyle(Theme.navy)
            }
        }
        ForEach(model.planDays) { day in
            planDayCard(model, day)
        }
        let own = model.ownNames
        if !own.isEmpty {
            SectionCard("Kept under their own name", accessory: {
                Text("\(own.count)").font(.subheadline).monospacedDigit().secondaryText()
            }) {
                Text("Not one of your plan's lifts. Kept as history; match one if it is.").font(.footnote).secondaryText()
                ForEach(own, id: \.self) { name in
                    CardDivider()
                    nameRow(model, name, action: "Match")
                }
            }
        }
    }

    @ViewBuilder private func found(_ model: HistoryImportModel) -> some View {
        let kept = model.kept
        SectionCard("Found") {
            ForEach(HistorySource.allCases, id: \.self) { source in
                let count = kept.filter { $0.source == source }.count
                if count > 0 {
                    countRow("\(source.label) sessions", count)
                    CardDivider()
                }
            }
            if let first = kept.first, let last = kept.last {
                Text("\(Format.shortDate(first.startedAt)) to \(Format.shortDate(last.startedAt))").font(.subheadline).monospacedDigit().secondaryText()
            }
            if model.alreadyImported > 0 {
                Text("\(model.alreadyImported) already imported: they're replaced.").font(.footnote).monospacedDigit().secondaryText()
            }
            ForEach(leftOutLines(model), id: \.self) { line in
                Text(line).font(.footnote).monospacedDigit().secondaryText()
            }
        }
    }

    private func leftOutLines(_ model: HistoryImportModel) -> [String] {
        let left = model.result?.leftOut ?? []
        var lines: [String] = []
        let noReps = left.filter { $0.reason == .noReps }.reduce(0) { $0 + $1.sets }
        if noReps > 0 { lines.append("Left out: \(noReps) Garmin set\(noReps == 1 ? "" : "s") with no reps.") }
        let empty = left.filter { $0.reason == .empty }.reduce(0) { $0 + $1.sets }
        if empty > 0 { lines.append("Left out: \(empty) Liftoff set\(empty == 1 ? "" : "s") with nothing recorded.") }
        return lines
    }

    private func unitCard(_ model: HistoryImportModel) -> some View {
        SectionCard("Liftoff weights are in pounds?") {
            ForEach(Array(WeightUnit.allCases.enumerated()), id: \.element) { index, unit in
                if index > 0 { CardDivider() }
                choiceRow(unit == .lb ? "Pounds" : "Kilograms, convert them", selected: model.unit == unit) {
                    Task { await model.setUnit(unit) }
                }
            }
        }
    }

    private func sameDaysCard(_ model: HistoryImportModel) -> some View {
        SectionCard("Same day in both") {
            Text("Keep one of them for each day.").font(.footnote).secondaryText()
            ForEach(model.sameDays, id: \.self) { day in
                CardDivider()
                if let date = DayKey.date(day) {
                    Text(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.navy)
                }
                ForEach(HistorySource.allCases, id: \.self) { source in
                    let lifts = model.sessions.filter { $0.source == source && DayKey.string($0.startedAt) == day }.flatMap(\.exercises).count
                    choiceRow("\(source.label) · \(lifts) lifts", selected: (model.choices[day] ?? .garmin) == source) {
                        model.choices[day] = source
                    }
                }
            }
        }
    }

    private func planDayCard(_ model: HistoryImportModel, _ day: HistoryImportModel.PlanDay) -> some View {
        SectionCard(day.name) {
            ForEach(Array(day.exercises.enumerated()), id: \.element.id) { index, exercise in
                if index > 0 { CardDivider() }
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(exercise.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.navy)
                    let names = model.names(for: exercise.id)
                    if names.isEmpty {
                        Text("Nothing matched").font(.footnote).secondaryText()
                    } else {
                        if LastTimeRow.applies(to: exercise) { lastTime(model, exercise, names: Set(names)) }
                        ForEach(names, id: \.self) { name in nameRow(model, name, action: "Change") }
                    }
                }
            }
        }
    }

    /// The set the rule picked: the heaviest of that session, shown beside the rest of them.
    @ViewBuilder private func lastTime(_ model: HistoryImportModel, _ exercise: PlannedExercise, names: Set<String>) -> some View {
        if let last = TrainingHistory.lastTop(names: names, in: model.kept), let reps = last.set.reps {
            HStack(spacing: Theme.Space.s) {
                Text("Last time \(Format.number(last.set.loadLb)) × \(reps) · \(Format.shortDate(last.session.startedAt))")
                    .font(.subheadline).monospacedDigit().foregroundStyle(Theme.navy)
                SourceChip(source: last.session.source.label)
            }
            let all = last.exercise.sets.compactMap { s in s.reps.map { "\(Format.number(s.loadLb)) × \($0)" } }
            if all.count > 1 {
                Text("Heaviest of \(all.joined(separator: " · "))").font(.footnote).monospacedDigit().secondaryText()
            }
        }
    }

    private func nameRow(_ model: HistoryImportModel, _ name: String, action: String) -> some View {
        let sources = Set(model.sessions.filter { $0.exercises.contains { $0.name == name } }.map(\.source))
        return HStack(spacing: Theme.Space.s) {
            Image(systemName: "arrow.turn.down.right").font(.footnote).secondaryText().accessibilityHidden(true)
            Text(name).font(.subheadline).foregroundStyle(Theme.navy)
            Text(sources.map(\.label).sorted().joined(separator: ", ")).font(.footnote).secondaryText()
            Spacer()
            Menu {
                ForEach(model.planDays) { day in
                    Section(day.name) {
                        ForEach(day.exercises) { exercise in
                            Toggle(exercise.name, isOn: Binding(get: { model.proposed[name]?.contains(exercise.id) == true },
                                                                 set: { _ in model.toggle(name, exercise.id) }))
                        }
                    }
                }
                Button("Keep under its own name") { model.proposed[name] = [] }
            } label: {
                Text(action).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.cobalt).frame(minHeight: 44)
            }
            .accessibilityLabel("\(action) the match for \(name)")
        }
    }

    private func choiceRow(_ title: String, selected: Bool, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.cobalt : Theme.textSecondary)
                Text(title).font(.body).foregroundStyle(Theme.navy)
                Spacer()
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func done(_ model: HistoryImportModel) -> some View {
        SectionCard("Imported") {
            Text("\(model.added ?? 0) sessions added.").font(.body).monospacedDigit().foregroundStyle(Theme.navy)
            Text("Today's Last time lines come from them now. A set you log in Setecho takes over.").font(.footnote).secondaryText()
        }
    }

    private func countRow(_ title: String, _ count: Int) -> some View {
        HStack {
            Text(title).font(.body).foregroundStyle(Theme.navy)
            Spacer()
            Text("\(count)").font(.body.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.navy)
        }
    }

    @ViewBuilder private func footer(_ model: HistoryImportModel) -> some View {
        switch model.step {
        case .start:
            Button("Choose the files") { showPicker = true }
                .buttonStyle(.setechoPrimary)
                .disabled(store.currentProgram == nil)
        case .reading:
            Button("Reading…") {}.buttonStyle(.setechoPrimary).disabled(true)
        case .review:
            Button(model.kept.isEmpty ? "Nothing to import" : "Confirm and import") { model.commit() }
                .buttonStyle(.setechoPrimary)
                .disabled(model.kept.isEmpty)
        case .done:
            Button("Done") { dismiss() }.buttonStyle(.setechoPrimary)
        }
    }
}

/// One imported session on History → Sessions: the day, Garmin's workout name or the lifts, and its source.
struct ImportedSessionRow: View {
    let session: ImportedSession
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: Theme.Space.s) {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(session.startedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                        .font(.body).monospacedDigit().foregroundStyle(Theme.navy)
                    Text(session.name.map { "\($0) · \(session.exercises.count) lifts" } ?? "\(session.exercises.count) lifts")
                        .font(.footnote).monospacedDigit().secondaryText()
                }
                Spacer()
                SourceChip(source: session.source.label)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).secondaryText().accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// An imported session, read-only: every lift and set as the file had them, top sets marked.
struct ImportedSessionView: View {
    @Environment(\.dismiss) private var dismiss
    let session: ImportedSession

    var body: some View {
        ScreenScaffold(onClose: { dismiss() }) {
            TitleBlock(eyebrow: session.source.label, title: session.name ?? session.startedAt.formatted(.dateTime.weekday(.wide)),
                       subtitle: session.startedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
            SectionCard {
                ForEach(Array(session.exercises.enumerated()), id: \.offset) { index, exercise in
                    if index > 0 { CardDivider() }
                    Text(exercise.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.navy)
                    ForEach(Array(exercise.sets.enumerated()), id: \.offset) { _, set in
                        HStack {
                            Text(Self.line(set)).font(.subheadline).monospacedDigit().foregroundStyle(Theme.navy)
                            Spacer()
                            if let role = set.role { Text(role.label).font(.footnote).secondaryText() }
                        }
                    }
                }
            }
        }
    }

    static func line(_ set: ImportedSet) -> String {
        if let reps = set.reps { return set.loadLb > 0 ? "\(Format.number(set.loadLb)) × \(reps)" : "\(reps) reps" }
        if let seconds = set.seconds { return Format.duration(seconds) }
        return "—"
    }
}
