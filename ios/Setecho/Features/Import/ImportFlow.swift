import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Import (DESIGN.md): bring in the coach's material once. Two steps, the spreadsheet program and the
/// check-in form. Each can be a Google Sheets link (program), pasted text, a file or a screenshot.
struct ImportFlow: View {
    @Environment(Store.self) private var store
    @State private var programModel = ImportModel(kind: .program)
    @State private var formModel = ImportModel(kind: .form)
    @State private var path: [ImportStep] = []

    enum ImportStep: Hashable { case programReview, form, formReview }

    var body: some View {
        NavigationStack(path: $path) {
            ImportInputView(model: programModel, step: 1, onDone: { path.append(.programReview) })
                .navigationDestination(for: ImportStep.self) { step in
                    switch step {
                    case .programReview:
                        ProgramReviewView(model: programModel) {
                            if let program = programModel.program { store.saveProgram(program) }
                            path.append(.form)
                        }
                    case .form:
                        ImportInputView(model: formModel, step: 2, onDone: { path.append(.formReview) })
                    case .formReview:
                        FormReviewView(model: formModel) {
                            if let template = formModel.template { store.saveTemplate(template) }
                            AppRouter.shared.showImport = false
                        }
                    }
                }
        }
        .tint(Theme.cobalt)
    }
}

// MARK: - Input step

private struct ImportInputView: View {
    @Bindable var model: ImportModel
    let step: Int
    let onDone: () -> Void

    @State private var showFilePicker = false
    @State private var photoItem: PhotosPickerItem?

    private var isProgram: Bool { model.kind == .program }

    var body: some View {
        ScreenScaffold {
            if step == 2 {
                LinkButton(title: "Back", chevron: .leading) { AppRouter.shared.showImport = false }
            } else {
                LinkButton(title: "Not now", chevron: .leading) { AppRouter.shared.showImport = false }
            }
            TitleBlock(
                eyebrow: "Import · step \(step) of 2",
                title: isProgram ? "Coach's program" : "Check-in form",
                subtitle: isProgram
                    ? "The spreadsheet, exactly as your coach sent it."
                    : "The weekly check-in, exactly as your coach wrote it."
            )
            if isProgram {
                SectionCard("Google Sheets link") {
                    Text("Share the sheet as \"Anyone with the link\" first.").font(.subheadline).secondaryText()
                    ImportField(placeholder: "https://docs.google.com/spreadsheets/…", text: $model.link)
                }
            }
            SectionCard(isProgram ? "Or paste the sheet" : "Paste the form") {
                TextEditor(text: $model.text)
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
            if let error = model.error {
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
                    Label("Reading with Muse Spark…", systemImage: "sparkles")
                } else {
                    Text(isProgram ? "Read spreadsheet" : "Read form")
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

private struct ProgramReviewView: View {
    @Bindable var model: ImportModel
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScreenScaffold {
            LinkButton(title: "Back", chevron: .leading) { dismiss() }
            if let program = model.program {
                TitleBlock(
                    eyebrow: "Import · step 1 of 2",
                    title: program.name,
                    subtitle: "\(program.weeks.count) week\(program.weeks.count == 1 ? "" : "s") · "
                        + "\(program.exerciseCount) exercise\(program.exerciseCount == 1 ? "" : "s"). Check it against the sheet."
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
                ForEach(program.weeks, id: \.number) { week in
                    ForEach(week.days) { day in
                        SectionCard("\(day.name) · Week \(week.number)") {
                            ForEach(Array(day.exercises.enumerated()), id: \.element.id) { index, exercise in
                                if index > 0 { CardDivider() }
                                ExerciseRow(exercise: exercise, flagged: isFlagged(exercise, day: day, week: week, program: program))
                            }
                        }
                    }
                }
            }
        } footer: {
            Button("Save program", action: onSave).buttonStyle(.setechoPrimary)
        }
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

private struct FormReviewView: View {
    @Bindable var model: ImportModel
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showCarried = false

    var body: some View {
        ScreenScaffold {
            LinkButton(title: "Back", chevron: .leading) { dismiss() }
            if let template = model.template {
                TitleBlock(
                    eyebrow: "Import · step 2 of 2",
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
