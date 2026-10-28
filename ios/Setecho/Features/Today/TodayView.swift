import SwiftUI

/// Today (DESIGN.md): the home base. The cycle day planned today (a rest day shows his cardio line),
/// any add-on joining it, a morning add-on when one is due, and where the current check-in stands.
struct TodayView: View {
    @Environment(Store.self) private var store
    @State private var showSession = false
    @State private var showMorning = false
    @State private var showPhotos = false
    private var schedule: CheckInSchedule { CheckInSchedule(plan: store.plan, lastSentAt: store.lastSentCheckIn?.sentAt) }

    private var today: (week: ProgramWeek, day: ProgramDay)? { store.todayDay }
    private var addOnsDue: [AddOnPlanner.Due] { today.map { store.addOnsDue(on: $0.day.id) } ?? [] }
    private var canStart: Bool { today.map { !$0.day.isRest } ?? false }

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
            if let morning = store.morningAddOnDue() {
                // "This morning: stomach vacuums · 4 × 20 s · 2 of 4 this week"
                SectionCard("This morning", accessory: {
                    if morning.catchUp { Text("Catch-up").font(.subheadline.weight(.semibold)).secondaryText() }
                }) {
                    Text("\(morning.addOn.name) · \(morning.addOn.exercises.map(\.summary).joined(separator: ", ")) · \(morning.done) of \(morning.addOn.perWeek) this week")
                        .font(.subheadline).monospacedDigit().foregroundStyle(Theme.navy)
                    Text(morning.addOn.quote).font(.footnote).secondaryText()
                    LinkButton(title: "Start") { showMorning = true }
                }
            }
            if let next = today {
                SectionCard(next.day.isRest ? "Rest day" : "Today's session", accessory: {
                    HStack(spacing: Theme.Space.s) {
                        if !next.day.isRest, store.isDoneToday(dayId: next.day.id) {
                            Text("Done today").font(.subheadline.weight(.semibold)).secondaryText()
                        }
                        Text(store.currentProgram?.weeks.count ?? 1 > 1 ? "\(next.day.name) · Week \(next.week.number)" : next.day.name)
                            .font(.subheadline).monospacedDigit().secondaryText()
                    }
                }) {
                    if next.day.isRest {
                        Text(next.day.cardio ?? "No lifting today.").font(.body).foregroundStyle(Theme.navy)
                    } else {
                        ForEach(Array(next.day.exercises.enumerated()), id: \.element.id) { index, exercise in
                            if index > 0 { CardDivider() }
                            ExerciseRow(exercise: exercise)
                        }
                        ForEach(addOnsDue, id: \.addOn.id) { due in
                            CardDivider()
                            Text("+ \(due.addOn.name) · \(due.done + 1) of \(due.addOn.perWeek) this week\(due.catchUp ? " · catch-up" : "")")
                                .font(.subheadline).monospacedDigit().foregroundStyle(Theme.navy)
                        }
                    }
                    changeDayMenu
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
            Button(today?.day.isRest == true ? "Rest day" : "Start session") { showSession = true }
                .buttonStyle(.setechoPrimary)
                .disabled(!canStart)
        }
        .fullScreenCover(isPresented: $showSession) {
            if let next = today {
                SessionView(day: next.day, addOns: addOnsDue.map(\.addOn), weekNumber: next.week.number, store: store)
            }
        }
        .fullScreenCover(isPresented: $showMorning) {
            if let morning = store.morningAddOnDue() {
                SessionView(day: nil, addOns: [morning.addOn], weekNumber: today?.week.number ?? 1, store: store)
            }
        }
        .onAppear {
            store.refreshCycle()
            Task {
                if await Reminders.requestPermission() {
                    Reminders.scheduleEveReminder(schedule: schedule)
                    Reminders.scheduleDeadlineGuard(schedule: schedule)
                    Reminders.scheduleMorningStart(schedule: schedule, wakeTime: Settings.shared.checkInWakeTime)
                }
            }
            if Reminders.deadlinePassed(schedule: schedule), store.lastSentCheckIn.map({ !Calendar.current.isDateInToday($0.sentAt ?? .distantPast) }) ?? true {
                AppRouter.shared.tab = .checkIn
                NotificationCenter.default.post(name: .checkInDeadline, object: nil)
            }
        }
        .fullScreenCover(isPresented: $showPhotos) {
            PhotoSessionView(store: store).environment(store)
        }
    }

    /// "Change day": any day of the cycle, by hand (HANDOFF.md §7, Which day is today).
    private var changeDayMenu: some View {
        Menu {
            ForEach(store.currentProgram?.cycleDays ?? []) { day in
                Button(day.isRest ? "\(day.name) (rest)" : day.name) { store.changeDay(to: day.id) }
            }
        } label: {
            HStack(spacing: Theme.Space.xxs) {
                Text("Change day").font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
            }
            .foregroundStyle(Theme.cobalt)
            .frame(minHeight: 44)
        }
    }

    private var checkInCard: some View {
        let due = schedule.nextDue(from: .now)
        let morning = schedule.isCheckInMorning(on: .now)
        let wrapUpDue = schedule.isWrapUpDue(on: .now)
        let yellowTaken = store.pendingReply != nil || !store.macroFactorReminders.isEmpty
        let tag = morning ? "Due today" : wrapUpDue ? "Wrap-up due" : nil
        return SectionCard(schedule.everyWeeks > 1 ? "This check-in" : "This week's check-in", accessory: {
            if let tag {
                if yellowTaken { Text(tag).font(.subheadline.weight(.semibold)).secondaryText() } else { TargetTag(text: tag) }
            }
        }) {
            if let template = store.currentTemplate {
                HStack(alignment: .firstTextBaseline) {
                    MetricText(value: "0", unit: "of \(template.fields.count) ready")
                }
                Text("Due \(due.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) morning, by \(schedule.dueBy)")
                    .font(.subheadline).monospacedDigit().secondaryText()
                if morning {
                    LinkButton(title: "Start check-in") { AppRouter.shared.showCheckInMorning = true }
                    Text("Or say \"Hey Siri, start my Setecho check-in\"").font(.footnote).secondaryText()
                } else {
                    LinkButton(title: "Open check-in") { AppRouter.shared.tab = .checkIn }
                    // The morning flow on any other day, for rehearsals: same screens, nothing sent to him.
                    LinkButton(title: "Rehearse the morning", chevron: .none) { AppRouter.shared.showCheckInMorning = true }
                }
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
