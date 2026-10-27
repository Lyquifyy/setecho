import SwiftUI

/// Today (DESIGN.md): the home base. What's planned today, and where the week's check-in stands.
struct TodayView: View {
    @Environment(Store.self) private var store
    @State private var showSession = false
    @State private var showPhotos = false
    private let schedule = CheckInSchedule()

    var body: some View {
        ScreenScaffold {
            TitleBlock(eyebrow: Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()), title: "Today")
            if let reply = store.pendingReply {
                // One yellow tag at a time on Today: a coach reply to review comes first.
                SectionCard("Coach reply", accessory: { TargetTag(text: "Review") }) {
                    Text(reply.summary(duration: reply.audioFile.flatMap { CoachReplyModel.duration(of: store.mediaDirectory.appendingPathComponent($0)) }))
                        .font(.subheadline).foregroundStyle(Theme.navy)
                    Text("\(reply.changes.count) change\(reply.changes.count == 1 ? "" : "s") to review").font(.subheadline).monospacedDigit().secondaryText()
                    LinkButton(title: "Review changes") { AppRouter.shared.openReply = reply }
                }
            }
            if !store.macroFactorReminders.isEmpty {
                SectionCard("MacroFactor", accessory: { if store.pendingReply == nil { TargetTag(text: "Update") } }) {
                    ForEach(Array(store.macroFactorReminders.enumerated()), id: \.offset) { index, line in
                        if index > 0 { CardDivider() }
                        Text(line).font(.subheadline).monospacedDigit().foregroundStyle(Theme.navy)
                    }
                    Text("Setecho can't change MacroFactor itself.").font(.footnote).secondaryText()
                    LinkButton(title: "Done", chevron: .none) { store.clearMacroFactorReminders() }
                }
            }
            if let next = store.nextDay {
                SectionCard("Today's session", accessory: {
                    Text("\(next.day.name) · Week \(next.week.number)").font(.subheadline).monospacedDigit().secondaryText()
                }) {
                    ForEach(Array(next.day.exercises.enumerated()), id: \.element.id) { index, exercise in
                        if index > 0 { CardDivider() }
                        ExerciseRow(exercise: exercise)
                    }
                }
            } else {
                SectionCard("Today's session") {
                    Text("Import your coach's program to see today's session.")
                        .font(.subheadline).secondaryText()
                    LinkButton(title: "Import the program") { AppRouter.shared.showImport = true }
                }
            }
            checkInCard
            photosCard
        } footer: {
            // The only tap of a training day.
            Button("Start session") { showSession = true }
                .buttonStyle(.setechoPrimary)
                .disabled(store.nextDay == nil)
        }
        .fullScreenCover(isPresented: $showSession) {
            if let next = store.nextDay {
                SessionView(day: next.day, weekNumber: next.week.number, store: store)
            }
        }
        .fullScreenCover(isPresented: $showPhotos) {
            PhotoSessionView(store: store).environment(store)
        }
    }

    private var checkInCard: some View {
        let due = schedule.nextDue(from: .now)
        let wrapUpDue = schedule.isWrapUpDue(on: .now)
        let yellowTaken = store.pendingReply != nil || !store.macroFactorReminders.isEmpty
        return SectionCard("This week's check-in", accessory: {
            if wrapUpDue {
                if yellowTaken { Text("Wrap-up due").font(.subheadline.weight(.semibold)).secondaryText() } else { TargetTag(text: "Wrap-up due") }
            }
        }) {
            if let template = store.currentTemplate {
                HStack(alignment: .firstTextBaseline) {
                    MetricText(value: "0", unit: "of \(template.fields.count) ready")
                }
                Text("Due \(due.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) morning")
                    .font(.subheadline).monospacedDigit().secondaryText()
                LinkButton(title: "Open check-in") { AppRouter.shared.tab = .checkIn }
            } else {
                Text("Import your coach's check-in form to see what fills itself.")
                    .font(.subheadline).secondaryText()
                LinkButton(title: "Import the form") { AppRouter.shared.showImport = true }
            }
        }
    }

    private var photosCard: some View {
        let due = schedule.nextDue(from: .now)
        return SectionCard("Check-in photos") {
            LabeledValue("Last taken", store.lastPhotoSet.map { Format.shortDate($0.takenAt) } ?? "Not yet")
            CardDivider()
            LabeledValue("Next due", Format.shortDate(due))
            LinkButton(title: "Take photos") { showPhotos = true }
        }
    }
}

/// Label left, value right, tabular.
struct LabeledValue: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.subheadline).secondaryText()
            Spacer()
            Text(value).font(.subheadline).monospacedDigit().foregroundStyle(Theme.navy)
        }
        .frame(minHeight: 28)
    }
}

#Preview {
    TodayView().environment(Store(root: FileManager.default.temporaryDirectory.appendingPathComponent("preview-store")))
}
