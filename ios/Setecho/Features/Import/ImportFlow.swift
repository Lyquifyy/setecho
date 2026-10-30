import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Import (DESIGN.md): bring in the coach's material once. Three steps: the spreadsheet program,
/// the check-in form, then his instructions (his onboarding email, pasted once). The first two can
/// be a Google Sheets link (program), pasted text, a file or a screenshot.
struct ImportFlow: View {
    @Environment(Store.self) private var store
    @State private var programModel = ImportModel(kind: .program)
    @State private var formModel = ImportModel(kind: .form)
    @State private var rulesModel = ImportModel(kind: .rules)
    @State private var path: [ImportStep] = []

    enum ImportStep: Hashable { case programReview, form, formReview, rules, rulesReview }

    var body: some View {
        NavigationStack(path: $path) {
            ImportInputView(model: programModel, step: 1, onDone: { path.append(.programReview) })
                .navigationDestination(for: ImportStep.self) { step in
                    switch step {
                    case .programReview:
                        ProgramReviewView(model: programModel) {
                            if let program = programModel.program {
                                store.saveProgram(program)
                                store.setAddOnDays(programModel.addOnDays)
                            }
                            path.append(.form)
                        }
                    case .form:
                        ImportInputView(model: formModel, step: 2, onDone: { path.append(.formReview) })
                    case .formReview:
                        FormReviewView(model: formModel) {
                            if let form = formModel.formImport { store.saveTemplate(form.template, targets: form.targets, cardioProtocol: form.cardioProtocol) }
                            path.append(.rules)
                        }
                    case .rules:
                        ImportInputView(model: rulesModel, step: 3, onDone: { path.append(.rulesReview) })
                    case .rulesReview:
                        RulesReviewView(model: rulesModel) {
                            if let rules = rulesModel.rules { store.saveRules(rules) }
                            AppRouter.shared.showImport = false
                        }
                    }
                }
        }
        .tint(Theme.cobalt)
    }
}

/// The X on every Import screen: leave the flow. What earlier steps saved stays saved.
@MainActor private func closeImport() { AppRouter.shared.showImport = false }

// MARK: - Input step

private struct ImportInputView: View {
    @Bindable var model: ImportModel
    let step: Int
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showFilePicker = false
    @State private var photoItem: PhotosPickerItem?

    private var isProgram: Bool { model.kind == .program }
    private var isRules: Bool { model.kind == .rules }

    var body: some View {
        ScreenScaffold(onClose: closeImport) {
            // Step 1 is the sheet's first screen: the X is its way out. Later steps go back one step.
            if step > 1 {
                LinkButton(title: "Back", chevron: .leading) { dismiss() }
            }
            SetupProgress(current: step)
            TitleBlock(
                title: isProgram ? "Coach's program" : isRules ? "His instructions" : "Check-in form",
                subtitle: isProgram
                    ? "The spreadsheet, exactly as your coach sent it."
                    : isRules ? "His onboarding email, pasted once. Setecho reads only the rules he states, and nothing applies until you confirm it."
                    : "The check-in, exactly as your coach wrote it."
            )
            if isProgram {
                SectionCard("Google Sheets link") {
                    Text("Share the sheet as \"Anyone with the link\" first.").font(.subheadline).secondaryText()
                    ImportField(placeholder: "https://docs.google.com/spreadsheets/…", text: $model.link)
                }
            }
            SectionCard(isProgram ? "Or paste the sheet" : isRules ? "Paste his email" : "Paste the form") {
                TextEditor(text: $model.text)
                    .accessibilityLabel(isProgram ? "Program text" : isRules ? "Coach’s instructions" : "Check-in form")
                    .overlay(alignment: .topLeading) {
                        if model.text.isEmpty {
                            Text(isProgram ? "Paste the rows from your coach’s sheet…" : isRules ? "Paste your coach’s instructions here…" : "Paste the questions your coach asks each week…")
                                .font(.body).secondaryText()
                                .padding(Theme.Space.xs)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .font(.body)
                    .foregroundStyle(Theme.navy)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
                    .padding(Theme.Space.xs)
                    .background(Theme.nearWhite, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    )
            }
            if !isRules {
            SectionCard("Or add a file") {
                HStack(spacing: Theme.Space.s) {
                    Button { showFilePicker = true } label: {
                        Label(isProgram ? "CSV or Excel" : "Text file", systemImage: "doc")
                    }
                    .buttonStyle(.setechoOutline)
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Screenshot", systemImage: "photo")
                    }
                    .buttonStyle(.setechoOutline)
                    Spacer()
                }
                if let picked = model.picked {
                    CardDivider()
                    HStack {
                        Text(picked.label).font(.subheadline).foregroundStyle(Theme.navy)
                        Spacer()
                        LinkButton(title: "Remove", chevron: .none) { model.picked = nil }
                    }
                }
            }
            }
            if model.isLoading {
                LoadingCard(title: isProgram ? "Reading the spreadsheet" : isRules ? "Reading his rules" : "Reading the form",
                            detail: "You’ll review everything before saving it.")
            } else if let error = model.error {
                SectionCard("Couldn't read it") {
                    Text(error).font(.subheadline).foregroundStyle(Theme.navy)
                }
            }
        } footer: {
            Button {
                Task {
                    await model.run()
                    if model.hasResult { onDone() }
                }
            } label: {
                if model.isLoading {
                    HStack(spacing: Theme.Space.s) {
                        ProgressView().tint(Theme.surface)
                        Text("Reading your material…")
                    }
                } else {
                    Text(isProgram ? "Read spreadsheet" : isRules ? "Read his rules" : "Read form")
                }
            }
            .buttonStyle(.setechoPrimary)
            .disabled(!model.hasInput || model.isLoading)
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: fileTypes) { result in
            if case .success(let url) = result { load(url) }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    model.picked = .screenshot(data)
                }
                photoItem = nil
            }
        }
    }

    private var fileTypes: [UTType] {
        var types: [UTType] = [.commaSeparatedText, .plainText, .png, .jpeg]
        if let xlsx = UTType("org.openxmlformats.spreadsheetml.sheet") { types.append(xlsx) }
        return types
    }

    private func load(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            model.error = "Couldn't open \(url.lastPathComponent)."
            return
        }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        model.picked = .file(data, filename: url.lastPathComponent, mime: mime)
    }
}

private struct ImportField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .font(.body)
            .foregroundStyle(Theme.navy)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .padding(.horizontal, Theme.Space.s)
            .frame(minHeight: 44)
            .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}

// MARK: - Program review

/// Internal, not private, so the screen renders (ScreenRenderTests) can show it.
struct ProgramReviewView: View {
    @Bindable var model: ImportModel
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScreenScaffold(onClose: closeImport) {
            LinkButton(title: "Back", chevron: .leading) { dismiss() }
            if let program = model.program {
                TitleBlock(
                    eyebrow: "Import · step 1 of 3",
                    title: program.name,
                    subtitle: "\(program.cycleDays.count) cycle day\(program.cycleDays.count == 1 ? "" : "s") · "
                        + "\(program.exerciseCount) exercise\(program.exerciseCount == 1 ? "" : "s")"
                        + (program.addOns.isEmpty ? "" : " · \(program.addOns.count) add-on\(program.addOns.count == 1 ? "" : "s")") + ". Check it against the sheet."
                )
                if !program.flags.isEmpty {
                    SectionCard("Needs a look", accessory: { TargetTag(text: "Confirm") }) {
                        ForEach(Array(program.flags.enumerated()), id: \.offset) { index, flag in
                            if index > 0 { CardDivider() }
                            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                                Text(flag.path).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.navy)
                                Text(flag.message).font(.subheadline).secondaryText()
                            }
                        }
                    }
                }
                // The cycle in order, with rest days marked (DESIGN.md Import, Cycle and add-ons).
                SectionCard("The cycle") {
                    ForEach(Array(program.cycleDays.enumerated()), id: \.element.id) { index, day in
                        if index > 0 { CardDivider() }
                        HStack(alignment: .firstTextBaseline) {
                            Text(day.name).font(.body.weight(.semibold)).foregroundStyle(Theme.navy)
                            Spacer()
                            Text(day.isRest ? "Rest · \(day.cardio ?? "")" : "\(day.exercises.count) exercises")
                                .font(.subheadline).monospacedDigit().secondaryText()
                        }
                        .frame(minHeight: 28)
                    }
                }
                if !program.addOns.isEmpty {
                    SectionCard("Add-ons", accessory: { TargetTag(text: "Confirm") }) {
                        Text("Pick the days each one joins. Setecho proposed them evenly.").font(.subheadline).secondaryText()
                        ForEach(Array(program.addOns.enumerated()), id: \.element.id) { index, addOn in
                            if index > 0 { CardDivider() }
                            AddOnRow(addOn: addOn, days: addOn.timing == .withSession ? program.trainingDays : program.cycleDays,
                                     chosen: chosenDays(for: addOn.id))
                        }
                    }
                }
                ForEach(program.weeks, id: \.number) { week in
                    ForEach(week.days.filter { !$0.isRest }) { day in
                        SectionCard(program.weeks.count > 1 ? "\(day.name) · Week \(week.number)" : day.name) {
                            ForEach(Array(day.exercises.enumerated()), id: \.element.id) { index, exercise in
                                if index > 0 { CardDivider() }
                                ExerciseRow(exercise: exercise, flagged: isFlagged(exercise, day: day, week: week, program: program))
                            }
                        }
                    }
                }
                ForEach(program.addOns) { addOn in
                    SectionCard(addOn.name) {
                        ForEach(Array(addOn.exercises.enumerated()), id: \.element.id) { index, exercise in
                            if index > 0 { CardDivider() }
                            ExerciseRow(exercise: exercise)
                        }
                    }
                }
            }
        } footer: {
            Button("Save program", action: onSave).buttonStyle(.setechoPrimary)
        }
    }

    private func chosenDays(for addOnId: String) -> Binding<[String]> {
        Binding(
            get: { model.addOnDays.first { $0.addOnId == addOnId }?.dayIds ?? [] },
            set: { days in
                if let i = model.addOnDays.firstIndex(where: { $0.addOnId == addOnId }) {
                    model.addOnDays[i].dayIds = days
                } else {
                    model.addOnDays.append(AddOnDays(addOnId: addOnId, dayIds: days))
                }
            }
        )
    }

    private func isFlagged(_ exercise: PlannedExercise, day: ProgramDay, week: ProgramWeek, program: Program) -> Bool {
        program.flags.contains { flag in
            let path = flag.path.lowercased()
            return path.contains(exercise.name.lowercased()) && path.contains(day.name.lowercased())
                && path.contains("week \(week.number)")
        }
    }
}

/// "Bench press" with "4 × 8 · 185 lb · RPE 8" and the rest time, straight from the sheet.
struct ExerciseRow: View {
    let exercise: PlannedExercise
    var flagged = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(exercise.name).font(.body.weight(.semibold)).foregroundStyle(Theme.navy)
                Text(exercise.summary).font(.subheadline).monospacedDigit().secondaryText()
                Text([exercise.equipment.label, exercise.restText].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote).monospacedDigit().secondaryText()
                ForEach(exercise.alternates, id: \.name) { alternate in
                    Text("or \(alternate.name) · “\(alternate.quote)”").font(.footnote).secondaryText()
                }
                if let notes = exercise.notes, !notes.isEmpty {
                    Text(notes).font(.footnote).secondaryText()
                }
            }
            Spacer(minLength: Theme.Space.xs)
            if flagged { TargetTag(text: "Confirm") }
        }
        .padding(.vertical, Theme.Space.xxs)
    }
}

// MARK: - Form review

/// Internal, not private, so the screen renders (ScreenRenderTests) can show it.
struct FormReviewView: View {
    @Bindable var model: ImportModel
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showCarried = false

    var body: some View {
        ScreenScaffold(onClose: closeImport) {
            LinkButton(title: "Back", chevron: .leading) { dismiss() }
            if let template = model.template {
                TitleBlock(
                    eyebrow: "Import · step 2 of 3",
                    title: "Check-in form",
                    subtitle: "\(template.fields.count) fields. \(template.dataFieldCount) fill from data, \(template.voiceFieldCount) are asked out loud."
                )
                if !template.carriedBlocks.isEmpty {
                    SectionCard("Carried over each week", accessory: {
                        LinkButton(title: showCarried ? "Hide" : "Show", chevron: .none) { showCarried.toggle() }
                    }) {
                        ForEach(Array(template.carriedBlocks.enumerated()), id: \.offset) { index, block in
                            if index > 0 { CardDivider() }
                            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                                Text(block.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.navy)
                                if showCarried {
                                    Text(block.text).font(.footnote).monospacedDigit().secondaryText()
                                }
                            }
                        }
                    }
                }
                SectionCard("The coach's fields, in his order") {
                    ForEach(Array(template.orderedFields.enumerated()), id: \.element.id) { index, field in
                        if index > 0 { CardDivider() }
                        FieldPlanRow(field: field)
                    }
                }
            }
        } footer: {
            Button("Save check-in form", action: onSave).buttonStyle(.setechoPrimary)
        }
    }
}

/// How one field will be answered: Data, Drafted, Voice or Photos, plus the source.
private struct FieldPlanRow: View {
    let field: FieldSpec

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(field.label).font(.body).foregroundStyle(Theme.navy)
                if let prompt = field.prompt {
                    Text(prompt).font(.footnote).secondaryText()
                }
                HStack(spacing: Theme.Space.xs) {
                    Text(field.source.howAnswered).font(.footnote.weight(.semibold)).foregroundStyle(Theme.cobalt)
                    if let source = field.source.sourceName {
                        Text("· \(source)").font(.footnote).secondaryText()
                    }
                }
            }
            Spacer(minLength: Theme.Space.xs)
            if field.source.needsConfirmation { TargetTag(text: "Confirm") }
        }
        .padding(.vertical, Theme.Space.xxs)
    }
}


// MARK: - Rules review (DESIGN.md Import, Rules review)

/// How the coach adjusts loads, one `RuleRow` each, drafted from his instructions, beside his words.
/// The same card lists how hard each kind of set goes, the rest after top sets, warm-ups, the
/// check-in cadence and his quiet day. Nothing applies until it's confirmed.
/// Internal, not private, so the screen renders (ScreenRenderTests) can show it.
struct RulesReviewView: View {
    @Bindable var model: ImportModel
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    private let weekdays = ["", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    var body: some View {
        ScreenScaffold(onClose: closeImport) {
            LinkButton(title: "Back", chevron: .leading) { dismiss() }
            if let rules = model.rules {
                TitleBlock(
                    eyebrow: "Import · step 3 of 3",
                    title: "His rules",
                    subtitle: rules.isEmpty ? "No rules found in what you pasted. Setecho never invents one."
                        : "Each one in his words. Tap to confirm it's what he wants; nothing applies until you do."
                )
                if !rules.rules.isEmpty {
                    SectionCard("Adjusting loads", accessory: { if rules.rules.contains(where: { !$0.confirmed }) { TargetTag(text: "Confirm") } }) {
                        ForEach(Array(rules.rules.enumerated()), id: \.element.id) { index, rule in
                            if index > 0 { CardDivider() }
                            RuleRow(text: rule.text, quote: rule.quote, confirmed: rule.confirmed) { model.rules?.rules[index].confirmed.toggle() }
                        }
                    }
                }
                if !rules.roleTargets.isEmpty || !rules.restRules.isEmpty || rules.warmups != nil {
                    SectionCard("How hard, and the rest") {
                        ForEach(Array(rules.roleTargets.enumerated()), id: \.offset) { index, target in
                            if index > 0 { CardDivider() }
                            RuleRow(text: target.text, quote: target.quote, confirmed: target.confirmed) { model.rules?.roleTargets[index].confirmed.toggle() }
                        }
                        ForEach(Array(rules.restRules.enumerated()), id: \.offset) { index, rest in
                            if index > 0 || !rules.roleTargets.isEmpty { CardDivider() }
                            RuleRow(text: rest.text, quote: rest.quote, confirmed: rest.confirmed) { model.rules?.restRules[index].confirmed.toggle() }
                        }
                        if let warmups = rules.warmups {
                            if !rules.roleTargets.isEmpty || !rules.restRules.isEmpty { CardDivider() }
                            RuleRow(text: warmups.text, quote: warmups.quote, confirmed: warmups.confirmed) { model.rules?.warmups?.confirmed.toggle() }
                        }
                    }
                }
                if rules.checkInSchedule != nil || !rules.quietDays.isEmpty {
                    SectionCard("Check-ins") {
                        if let cadence = rules.checkInSchedule {
                            RuleRow(text: cadence.text, quote: cadence.quote, confirmed: cadence.confirmed) { model.rules?.checkInSchedule?.confirmed.toggle() }
                        }
                        if !rules.quietDays.isEmpty {
                            if rules.checkInSchedule != nil { CardDivider() }
                            Text("Quiet day\(rules.quietDays.count == 1 ? "" : "s"): \(rules.quietDays.map { weekdays.indices.contains($0) ? weekdays[$0] : "day \($0)" }.joined(separator: ", "))")
                                .font(.body).foregroundStyle(Theme.navy)
                            Text("Setecho won't put a message to him on screen that day.").font(.footnote).secondaryText()
                        }
                    }
                }
                TakenRuleCard()
                if !rules.flags.isEmpty {
                    SectionCard("Left out") {
                        ForEach(Array(rules.flags.enumerated()), id: \.offset) { index, flag in
                            if index > 0 { CardDivider() }
                            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                                Text(flag.path).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.navy)
                                Text(flag.message).font(.subheadline).secondaryText()
                            }
                        }
                    }
                }
            }
        } footer: {
            Button("Save his rules", action: onSave).buttonStyle(.setechoPrimary)
        }
    }
}
