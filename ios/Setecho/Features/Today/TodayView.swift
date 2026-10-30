import SwiftUI

/// Today (DESIGN.md): the home base. The cycle day planned today (a rest day shows his cardio line),
/// any add-on joining it, a morning add-on when one is due, and where the current check-in stands.
struct TodayView: View {
    @Environment(Store.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showSession = false
    @State private var showMorning = false
    @State private var showPhotos = false
    /// How a session works, once before the first one; its Start opens the session.
    @State private var showIntro = false
    @State private var startAfterIntro = false
    @State private var showGuide = false
    /// Exercises opened to their details; closed by default so the whole day fits on screen.
    @State private var expanded: Set<String> = []
    private var schedule: CheckInSchedule { CheckInSchedule(plan: store.plan, lastSentAt: store.lastSentCheckIn?.sentAt) }

    private var today: (week: ProgramWeek, day: ProgramDay)? { store.todayDay }
    private var addOnsDue: [AddOnPlanner.Due] { today.map { store.addOnsDue(on: $0.day.id) } ?? [] }
    private var canStart: Bool { today.map { !$0.day.isRest } ?? false }

    /// One yellow tag at a time on Today, in this order: a coach reply to review, MacroFactor to update,
    /// the check-in due, then today's session when it's still to do.
    private enum Highlight { case reply, macroFactor, checkIn, session }
    private var highlight: Highlight? {
        if store.pendingReply != nil { return .reply }
        if !store.macroFactorReminders.isEmpty { return .macroFactor }
        if schedule.isCheckInMorning(on: .now) || schedule.isWrapUpDue(on: .now) { return .checkIn }
        if let next = today, canStart, !store.isDoneToday(dayId: next.day.id) { return .session }
        return nil
    }

    var body: some View {
        // A rest day has nothing to start: no footer, not a disabled button (DESIGN.md, Today).
        ScreenScaffold(showsFooter: today?.day.isRest != true) {
            TitleBlock(eyebrow: Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()),
                       title: today == nil ? "Make room for training." : "Today",
                       subtitle: today == nil ? "Your coach brings the plan. Setecho handles the logging." : nil)
            if let reply = store.pendingReply {
                SectionCard("Coach reply", accessory: { TargetTag(text: "Review") }) {
                    Text(reply.summary(duration: reply.audioFile.flatMap { CoachReplyModel.duration(of: store.mediaDirectory.appendingPathComponent($0)) }))
                        .font(.subheadline).foregroundStyle(Theme.navy)
                    Text("\(reply.changes.count) change\(reply.changes.count == 1 ? "" : "s") to review").font(.subheadline).monospacedDigit().secondaryText()
                    Button("Review changes", systemImage: "text.badge.checkmark") { AppRouter.shared.openReply = reply }
                        .buttonStyle(.setechoTonalWide)
                }
            }
            if !store.macroFactorReminders.isEmpty {
                SectionCard("MacroFactor", accessory: { if highlight == .macroFactor { TargetTag(text: "Update") } }) {
                    ForEach(Array(store.macroFactorReminders.enumerated()), id: \.offset) { index, line in
                        if index > 0 { CardDivider() }
                        Text(line).font(.subheadline).monospacedDigit().foregroundStyle(Theme.navy)
                    }
                    Text("Setecho can't change MacroFactor itself.").font(.footnote).secondaryText()
                    Button("Done, it's updated", systemImage: "checkmark") { store.clearMacroFactorReminders() }
                        .buttonStyle(.setechoTonalWide)
                }
            }
            if let morning = store.morningAddOnDue() {
                // "This morning: stomach vacuums · 4 × 20 s · 2 of 4 this week"
                SectionCard("This morning", accessory: {
                    if morning.catchUp { Text("Catch-up").font(.subheadline.weight(.semibold)).secondaryText() }
                }) {
                    HStack(alignment: .center, spacing: Theme.Space.s) {
                        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                            Text(morning.addOn.name).font(.body.weight(.semibold)).foregroundStyle(Theme.navy)
                            Text("\(morning.addOn.exercises.map(\.summary).joined(separator: ", ")) · \(morning.done) of \(morning.addOn.perWeek) this week")
                                .font(.subheadline).monospacedDigit().secondaryText()
                        }
                        Spacer(minLength: Theme.Space.xs)
                        Button("Start", systemImage: "play.fill") { showMorning = true }.buttonStyle(.setechoTonal)
                    }
                    Text(morning.addOn.quote.trimmingCharacters(in: CharacterSet(charactersIn: ": "))).font(.footnote).secondaryText()
                }
            }
            sessionCard
            if today != nil {
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.gutter))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: Theme.gutter))
                layout {
                    checkInTile
                    photosTile
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            if today == nil {
                // First run: importing the program is the one thing to do.
                Button("Set up with your coach’s plan", systemImage: "arrow.right") { AppRouter.shared.showImport = true }.buttonStyle(.setechoPrimary)
            } else {
                // The only tap of a training day.
                Button("Start session", systemImage: "play.fill") {
                    if Settings.shared.hasSeenSessionIntro { showSession = true } else { showIntro = true }
                }
                .buttonStyle(.setechoPrimary)
                .disabled(!canStart)
            }
        }
        .fullScreenCover(isPresented: $showIntro, onDismiss: {
            if startAfterIntro { startAfterIntro = false; showSession = true }
        }) {
            SessionIntroView(onStart: { startAfterIntro = true }).environment(store)
        }
        .sheet(isPresented: $showGuide) { VoiceGuideView() }
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
                // Ask for reminders only once there is a check-in to remind the athlete about.
                guard store.currentTemplate != nil else { return }
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

    // MARK: - Session

    @ViewBuilder private var sessionCard: some View {
        if let next = today {
            let title = store.currentProgram?.weeks.count ?? 1 > 1 ? "\(next.day.name) · Week \(next.week.number)" : next.day.name
            SectionCard(next.day.isRest ? "Rest day" : title, accessory: {
                if !next.day.isRest, store.isDoneToday(dayId: next.day.id) {
                    Label("Done today", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                } else if highlight == .session {
                    TargetTag(text: "Up next")
                }
            }) {
                if next.day.isRest {
                    Label(next.day.cardio ?? "No lifting today.", systemImage: "figure.walk")
                        .font(.body).foregroundStyle(Theme.navy)
                        .frame(minHeight: 44, alignment: .leading)
                } else {
                    sessionOverview(next.day)
                    ForEach(Array(next.day.exercises.enumerated()), id: \.element.id) { index, exercise in
                        CardDivider()
                        ExerciseDisclosureRow(number: index + 1, exercise: exercise, expanded: expanded.contains(exercise.id)) {
                            withAnimation(.snappy(duration: 0.25)) {
                                if expanded.contains(exercise.id) { expanded.remove(exercise.id) } else { expanded.insert(exercise.id) }
                            }
                        }
                        if expanded.contains(exercise.id), LastTimeRow.applies(to: exercise) {
                            LastTimeRow(exercise: exercise).padding(.leading, 18 + Theme.Space.s)
                        }
                    }
                    ForEach(addOnsDue, id: \.addOn.id) { due in
                        CardDivider()
                        Label {
                            Text("\(due.addOn.name) · \(due.done + 1) of \(due.addOn.perWeek) this week\(due.catchUp ? " · catch-up" : "")")
                                .font(.subheadline).monospacedDigit().foregroundStyle(Theme.navy)
                        } icon: {
                            Image(systemName: "plus.circle").foregroundStyle(Theme.textSecondary)
                        }
                        .frame(minHeight: 44, alignment: .leading)
                    }
                }
                CardDivider()
                let actions = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.xs))
                    : AnyLayout(HStackLayout(spacing: Theme.Space.xs))
                actions {
                    changeDayMenu
                    if !next.day.isRest {
                        Button("What to say", systemImage: "text.bubble") { showGuide = true }
                            .buttonStyle(.setechoTonalWide)
                            .accessibilityLabel("What you can say")
                        expandAllButton(next.day)
                    }
                }
            }
        } else {
            SectionCard("A little setup. A lot less admin.") {
                setupRow("doc.text", title: "Bring your program", detail: "Paste your coach’s spreadsheet link or choose a file.")
                CardDivider()
                setupRow("waveform", title: "Lift. Say it. Logged.", detail: "Log sets by voice, with camera counting when you want it.")
                CardDivider()
                setupRow("checklist", title: "Check in with less effort", detail: "Your data, photos and answers, in your coach’s format.")
            }
            Label("Your coach’s plan. Always your call.", systemImage: "checkmark.shield")
                .font(.subheadline).secondaryText()
                .padding(.horizontal, Theme.Space.xxs)
        }
    }

    private func setupRow(_ symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Theme.textSecondary)
                .frame(width: Theme.Control.icon, height: Theme.Control.icon)
                .background(Theme.page, in: RoundedRectangle(cornerRadius: Theme.Radius.tag))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(title).font(.headline).foregroundStyle(Theme.navy)
                Text(detail).font(.subheadline).secondaryText().fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Theme.Space.xs)
    }

    /// "5 exercises · 17 sets · tap one for its details".
    private func sessionOverview(_ day: ProgramDay) -> some View {
        let setCount = day.exercises.reduce(0) { $0 + $1.sets.count }
        return Text("\(day.exercises.count) exercises · \(setCount) sets · Your coach’s plan")
            .font(.subheadline).monospacedDigit().secondaryText()
    }

    /// The one toggle that opens or closes every exercise at once.
    private func expandAllButton(_ day: ProgramDay) -> some View {
        let ids = Set(day.exercises.map(\.id))
        let allOpen = !ids.isEmpty && ids.isSubset(of: expanded)
        return IconButton(systemImage: allOpen ? "rectangle.compress.vertical" : "rectangle.expand.vertical",
                          accessibilityLabel: allOpen ? "Hide every exercise's details" : "Show every exercise's details") {
            withAnimation(.snappy(duration: 0.25)) { expanded = allOpen ? [] : ids }
        }
    }

    /// "Change day": any day of the cycle, by hand (HANDOFF.md §7, Which day is today).
    private var changeDayMenu: some View {
        Menu {
            ForEach(store.currentProgram?.cycleDays ?? []) { day in
                Button(day.isRest ? "\(day.name) (rest)" : day.name) { store.changeDay(to: day.id) }
            }
        } label: {
            Label("Change day", systemImage: "arrow.left.arrow.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.cobalt)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, Theme.Space.xs)
                .frame(maxWidth: .infinity, minHeight: Theme.Control.minimum)
                .background(Theme.cobaltTint, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
    }

    // MARK: - Check-in and photos

    private var checkInTile: some View {
        let due = schedule.nextDue(from: .now)
        let morning = schedule.isCheckInMorning(on: .now)
        let tag = morning ? "Due today" : schedule.isWrapUpDue(on: .now) ? "Wrap-up due" : nil
        return TileCard(title: "Check-in", systemImage: "checklist") {
            if store.currentTemplate == nil {
                AppRouter.shared.showImport = true
            } else if morning {
                AppRouter.shared.showCheckInMorning = true
            } else {
                // Rehearsing the morning on another day lives in Settings → Developer.
                AppRouter.shared.tab = .checkIn
            }
        } content: {
            if let template = store.currentTemplate {
                let ready = CheckInCoordinator.currentDraft(in: store, schedule: schedule)?.answers
                    .filter { $0.state == .filled || $0.state == .confirmed }.count ?? 0
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xxs) {
                    Text("\(ready)").font(.title.weight(.bold)).monospacedDigit().foregroundStyle(Theme.navy)
                    Text("of \(template.fields.count) ready").font(.subheadline).monospacedDigit().secondaryText()
                }
                MeterBar(value: ready, total: template.fields.count)
                if let tag {
                    if highlight == .checkIn { TargetTag(text: tag) } else { Text(tag).font(.subheadline.weight(.semibold)).secondaryText() }
                } else {
                    Text("Due \(due.formatted(.dateTime.weekday(.abbreviated))) by \(Format.clock(schedule.dueBy))")
                        .font(.subheadline).monospacedDigit().secondaryText()
                }
            } else {
                Text("Import your coach's form to see what fills itself.").font(.subheadline).secondaryText()
            }
        }
        .accessibilityHint(morning ? "Starts the check-in. Or say \"Hey Siri, start my Setecho check-in\"" : "Opens the check-in")
    }

    private var photosTile: some View {
        let due = schedule.nextDue(from: .now)
        return TileCard(title: "Photos", systemImage: "camera") { showPhotos = true } content: {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text("Last taken").font(.footnote).secondaryText()
                Text(store.lastPhotoSet.map { Format.shortDate($0.takenAt) } ?? "Not yet")
                    .font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.navy)
            }
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text("Next due").font(.footnote).secondaryText()
                Text(Format.shortDate(due)).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.navy)
            }
        }
        .accessibilityHint("Takes the check-in photos")
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
