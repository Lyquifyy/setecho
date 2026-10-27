import SwiftUI

/// Check-in (DESIGN.md): the week's check-in, filling itself as the week goes. Header card with the
/// count and the due day, the carried blocks collapsed, one FieldRow per field in the coach's order.
struct CheckInView: View {
    @Environment(Store.self) private var store
    @State private var coordinator: CheckInCoordinator
    @State private var showCarried = false
    @State private var editing: FieldSpec?
    @State private var showWrapUp = false
    @State private var showReview = false

    init(store: Store) {
        _coordinator = State(initialValue: CheckInCoordinator(store: store))
    }

    var body: some View {
        ScreenScaffold {
            TitleBlock(title: "Check-in", subtitle: "Due \(coordinator.due.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) morning")
            if let template = coordinator.template {
                headerCard
                if !template.carriedBlocks.isEmpty {
                    SectionCard("Carried over from the coach", accessory: {
                        LinkButton(title: showCarried ? "Hide" : "Show", chevron: .none) { showCarried.toggle() }
                    }) {
                        ForEach(Array(template.carriedBlocks.enumerated()), id: \.offset) { index, block in
                            if index > 0 { CardDivider() }
                            Text(block.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.navy)
                            if showCarried {
                                Text(block.text).font(.footnote).monospacedDigit().secondaryText()
                            }
                        }
                    }
                }
                SectionCard("The coach's form") {
                    ForEach(Array(template.orderedFields.enumerated()), id: \.element.id) { index, field in
                        if index > 0 { CardDivider() }
                        FieldRow(field: field, answer: coordinator.answer(for: field))
                            .onTapGesture { editing = field }
                    }
                }
            } else {
                SectionCard("No form yet") {
                    Text("Import your coach's check-in form to see what fills itself.").font(.subheadline).secondaryText()
                    LinkButton(title: "Import the form") { AppRouter.shared.showImport = true }
                }
            }
        } footer: {
            Button("Review and send") { showReview = true }
                .buttonStyle(.setechoPrimary)
                .disabled(coordinator.draft == nil)
        }
        .task {
            if coordinator.draft == nil, coordinator.template != nil { await coordinator.buildDraft() }
        }
        .sheet(item: $editing) { field in
            FieldEditSheet(field: field, coordinator: coordinator)
        }
        .fullScreenCover(isPresented: $showWrapUp) {
            WrapUpView(coordinator: coordinator)
        }
        .fullScreenCover(isPresented: $showReview) {
            NavigationStack { ReviewSendView(coordinator: coordinator) }.environment(store)
        }
    }

    private var headerCard: some View {
        SectionCard("This week", accessory: {
            if coordinator.schedule.isWrapUpDue(on: .now) { TargetTag(text: "Wrap-up due") }
        }) {
            HStack(alignment: .firstTextBaseline) {
                MetricText(value: "\(coordinator.readyCount)", unit: "of \(coordinator.fieldCount) ready")
                Spacer()
            }
            Text("\(coordinator.toAnswerCount) to answer out loud").font(.subheadline).monospacedDigit().secondaryText()
            if coordinator.isDrafting {
                HStack(spacing: Theme.Space.xs) {
                    ProgressView().tint(Theme.cobalt)
                    Text("Filling from Apple Health and the log…").font(.subheadline).secondaryText()
                }
            } else if let error = coordinator.error {
                Text(error).font(.subheadline).foregroundStyle(Theme.navy)
                LinkButton(title: "Try again", chevron: .none) { Task { await coordinator.buildDraft() } }
            } else {
                HStack {
                    LinkButton(title: "Start 2-minute wrap-up") { showWrapUp = true }
                        .disabled(coordinator.questions.isEmpty)
                    Spacer()
                    LinkButton(title: "Refresh", chevron: .none) { Task { await coordinator.buildDraft() } }
                }
            }
        }
    }
}

/// Tapping a field opens it to edit, with its source values listed.
private struct FieldEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let field: FieldSpec
    let coordinator: CheckInCoordinator
    @State private var text = ""

    var body: some View {
        ScreenScaffold {
            LinkButton(title: "Back", chevron: .leading) { dismiss() }
            TitleBlock(eyebrow: field.prompt, title: field.label)
            SectionCard("Answer") {
                TextEditor(text: $text)
                    .font(.body)
                    .foregroundStyle(Theme.navy)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 100)
                    .padding(Theme.Space.xs)
                    .background(Theme.nearWhite, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            }
            if let answer = coordinator.answer(for: field), !answer.provenance.isEmpty {
                SectionCard("Where it came from") {
                    ForEach(Array(answer.provenance.enumerated()), id: \.offset) { index, p in
                        if index > 0 { CardDivider() }
                        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                            SourceChip(source: p.source)
                            Text(p.detail).font(.footnote).monospacedDigit().secondaryText()
                        }
                    }
                }
            }
        } footer: {
            Button("Confirm") {
                coordinator.set(field.id, text: text, state: .confirmed)
                dismiss()
            }
            .buttonStyle(.setechoPrimary)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onAppear { text = coordinator.answer(for: field)?.text ?? "" }
    }
}
