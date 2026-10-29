import SwiftUI
import UIKit

/// History (DESIGN.md): tabs for Sessions (this week, previous, last time) · Sent check-ins · Photos · Plan changes.
struct HistoryView: View {
    @Environment(Store.self) private var store
    @State private var openCheckIn: CheckInDraft?
    /// A check-in from the WhatsApp import, open read-only.
    @State private var openPast: PastCheckIn?
    /// A session from the Liftoff and Garmin import, open read-only.
    @State private var openImported: ImportedSession?
    @State private var showAllImported = false
    /// A week's photo open full screen, from the Photos tab.
    @State private var viewing: PhotoViewing?

    private var weekStart: Date { CheckInSchedule().week(endingBefore: CheckInSchedule().nextDue(from: .now)).start }

    /// Every lift of the cycle the logbook line applies to, once each, in the program's order.
    static func logbookLifts(_ program: Program?) -> [PlannedExercise] {
        var seen = Set<String>()
        return (program?.cycleDays ?? []).flatMap(\.exercises).filter { LastTimeRow.applies(to: $0) && seen.insert($0.id).inserted }
    }

    /// The tabs across the top: one kind of history at a time instead of one long scroll.
    enum Section: Hashable { case sessions, checkIns, photos, plan }
    @State private var section: Section
    @State private var showLastTime = false

    /// Opens on Sessions; the screen renders (ScreenRenderTests) open it on each tab.
    init(section: Section = .sessions) { _section = State(initialValue: section) }

    var body: some View {
        let sessions = store.sessions.filter { !$0.sets.isEmpty }.sorted { $0.startedAt > $1.startedAt }
        let sent = store.checkIns.filter(\.isSent).sorted { $0.sentAt! > $1.sentAt! }
        ScreenScaffold {
            TitleBlock(title: "History")
            SegmentTabs(items: [
                .init(value: Section.sessions, title: "Sessions"),
                .init(value: Section.checkIns, title: "Check-ins"),
                .init(value: Section.photos, title: "Photos"),
                .init(value: Section.plan, title: "Plan"),
            ], selection: $section)
            switch section {
            case .sessions: sessionsSection(sessions)
            case .checkIns: checkInsSection(sent)
            case .photos: photosSection
            case .plan: planSection
            }
        }
        .sheet(item: $openCheckIn) { draft in
            SentCheckInView(draft: draft).environment(store)
        }
        .sheet(item: $openPast) { checkIn in
            PastCheckInView(checkIn: checkIn).environment(store)
        }
        .sheet(item: $openImported) { session in
            ImportedSessionView(session: session).environment(store)
        }
        .fullScreenCover(item: $viewing) { viewing in
            PhotoViewer(viewing: viewing).environment(store)
        }
    }

    @ViewBuilder private func sessionsSection(_ sessions: [Session]) -> some View {
        let thisWeek = sessions.filter { $0.startedAt >= weekStart }
        let previous = sessions.filter { $0.startedAt < weekStart }
        SectionCard("This week", accessory: {
            Text("\(thisWeek.count) session\(thisWeek.count == 1 ? "" : "s")").font(.subheadline).monospacedDigit().secondaryText()
        }) {
            if thisWeek.isEmpty {
                Text("No sessions yet this week.").font(.subheadline).secondaryText()
            } else {
                ForEach(Array(thisWeek.enumerated()), id: \.element.id) { index, session in
                    if index > 0 { CardDivider() }
                    SessionRow(session: session)
                }
            }
        }
        SectionCard("Previous sessions") {
            if previous.isEmpty {
                Text("Sessions from earlier weeks appear here.").font(.subheadline).secondaryText()
            } else {
                ForEach(Array(previous.prefix(20).enumerated()), id: \.element.id) { index, session in
                    if index > 0 { CardDivider() }
                    SessionRow(session: session)
                }
            }
        }
        let imported = store.history.sessions.sorted { $0.startedAt > $1.startedAt }
        if !imported.isEmpty {
            SectionCard("Before Setecho", accessory: {
                Text("\(imported.count) sessions").font(.subheadline).monospacedDigit().secondaryText()
            }) {
                ForEach(Array(imported.prefix(showAllImported ? imported.count : 5).enumerated()), id: \.element.id) { index, session in
                    if index > 0 { CardDivider() }
                    ImportedSessionRow(session: session) { openImported = session }
                }
                if imported.count > 5 {
                    CardDivider()
                    LinkButton(title: showAllImported ? "Show fewer" : "Show all \(imported.count)", chevron: .none) { showAllImported.toggle() }
                }
            }
        }
        let lifts = Self.logbookLifts(store.currentProgram)
        if !lifts.isEmpty {
            SectionCard("Last time", accessory: {
                Button(showLastTime ? "Hide" : "\(lifts.count) lifts", systemImage: showLastTime ? "chevron.up" : "chevron.down") {
                    withAnimation(.snappy(duration: 0.25)) { showLastTime.toggle() }
                }
                .buttonStyle(.setechoTonal)
            }) {
                Text("Each lift's last top set, from the log, your paper logbook or Liftoff and Garmin. Said before the top set.").font(.footnote).secondaryText()
                if showLastTime {
                    ForEach(lifts) { exercise in
                        CardDivider()
                        Text(exercise.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.navy)
                        LastTimeRow(exercise: exercise)
                    }
                }
            }
        }
    }

    @ViewBuilder private func checkInsSection(_ sent: [CheckInDraft]) -> some View {
        // Weight, the tape and glucose across every check-in: the imported ones and those sent from here.
        if let template = store.currentTemplate {
            let trends = HistoryTrends.series(template: template, past: store.chatHistory.checkIns, sent: sent)
            if !trends.isEmpty {
                SectionCard("Trends") {
                    ForEach(Array(trends.enumerated()), id: \.element.id) { index, series in
                        if index > 0 { CardDivider() }
                        TrendRow(series: series)
                    }
                }
            }
        }
        SectionCard("Sent check-ins") {
            if sent.isEmpty {
                Text("Sent check-ins reopen here, read-only.").font(.subheadline).secondaryText()
            } else {
                ForEach(Array(sent.enumerated()), id: \.element.id) { index, draft in
                    if index > 0 { CardDivider() }
                    HStack {
                        Text("Sent \(Format.shortDate(draft.sentAt!))").font(.body).monospacedDigit().foregroundStyle(Theme.navy)
                        Spacer()
                        Button("Open", systemImage: "doc.text") { openCheckIn = draft }.buttonStyle(.setechoTonal)
                    }
                }
            }
        }
        let past = store.chatHistory.checkIns.sorted { $0.sentAt > $1.sentAt }
        if !past.isEmpty {
            SectionCard("From WhatsApp", accessory: {
                Text("\(past.count) check-ins").font(.subheadline).monospacedDigit().secondaryText()
            }) {
                ForEach(Array(past.enumerated()), id: \.element.id) { index, checkIn in
                    if index > 0 { CardDivider() }
                    PastCheckInRow(checkIn: checkIn) { openPast = checkIn }
                }
            }
        }
    }

    /// Every week with photos, newest first.
    private var photoWeeks: [PhotoSet] { store.photoSets.sorted { $0.takenAt > $1.takenAt } }

    private var photosSection: some View {
        SectionCard("Photos", accessory: {
            // The latest week beside the one before it, full screen; the viewer steps through the rest.
            if photoWeeks.count >= 2 {
                Button("Compare", systemImage: "rectangle.split.2x1") { viewing = PhotoViewing(photoSet: photoWeeks[0], compare: true) }
                    .buttonStyle(.setechoTonal)
            }
        }) {
            if photoWeeks.isEmpty {
                Text("Each week's four photos line up here.").font(.subheadline).secondaryText()
            } else {
                Text("Tap a photo to see it full screen.").font(.footnote).secondaryText()
                ForEach(Array(photoWeeks.enumerated()), id: \.element.id) { index, set in
                    if index > 0 { CardDivider() }
                    collageTile(set)
                }
            }
        }
    }

    @ViewBuilder private var planSection: some View {
        SectionCard("Plan changes") {
            let applied = store.appliedReplies
            if applied.isEmpty {
                Text("Applied coach replies appear here, with their changes.").font(.subheadline).secondaryText()
            } else {
                ForEach(Array(applied.enumerated()), id: \.element.id) { index, reply in
                    if index > 0 { CardDivider() }
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text("\(Format.shortDate(reply.receivedAt)) · plan v\(reply.appliedVersion ?? 0)")
                            .font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.navy)
                        ForEach(reply.changes.filter(\.approved)) { change in
                            Text("\(change.label): \(change.beforeAfterText)").font(.footnote).monospacedDigit().secondaryText()
                        }
                        HStack(spacing: Theme.Space.xs) {
                            Button("Open", systemImage: "text.bubble") { AppRouter.shared.openReply = reply }.buttonStyle(.setechoTonal)
                            if index == 0, store.plan?.replyId == reply.id {
                                Button("Revert", systemImage: "arrow.uturn.backward") { store.revertLatestPlan() }.buttonStyle(.setechoTonal)
                            }
                        }
                    }
                }
            }
        }
        if !store.chatHistory.coachMessages.isEmpty {
            CoachTimelineCard()
        }
    }

    /// One week: the four photos as taken, in his order (no collage since Oct 27). Each opens full screen.
    private func collageTile(_ set: PhotoSet) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            HStack(spacing: Theme.Space.xxs) {
                ForEach(Pose.allCases, id: \.self) { pose in
                    if let file = set.photo(for: pose)?.file,
                       let image = UIImage(contentsOfFile: store.mediaDirectory.appendingPathComponent(file).path) {
                        Button {
                            viewing = PhotoViewing(photoSet: set, pose: pose)
                        } label: {
                            Color.clear
                                .aspectRatio(3 / 4, contentMode: .fit)
                                .overlay { Image(uiImage: image).resizable().scaledToFill() }
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tag, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(pose.title), \(Format.shortDate(set.takenAt)). Opens full screen")
                    } else {
                        Theme.cameraFill.aspectRatio(3 / 4, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tag, style: .continuous))
                    }
                }
            }
            Text(Format.shortDate(set.takenAt)).font(.caption.weight(.semibold)).foregroundStyle(Theme.navy)
        }
    }
}

/// A session with its sets: the board's grouped-card layout.
struct SessionRow: View {
    @Environment(Store.self) private var store
    let session: Session

    /// Closed to its one-line summary; tap to see every set.
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack(alignment: .center) {
                    let dm = Format.dayAndMonth(session.startedAt)
                    Text("\(dm.day) \(dm.month)").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.navy)
                    Text(sessionName).font(.subheadline).secondaryText()
                    Spacer()
                    Text("\(session.workingSets.count) sets").font(.subheadline).monospacedDigit().secondaryText()
                    DisclosureChevron(expanded: expanded)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Hides the sets" : "Shows the sets")
            if expanded { ForEach(session.sets) { set in
                HStack(spacing: Theme.Space.s) {
                    if set.clipFile != nil {
                        PlayButton(accessibilityLabel: "Play set \(set.setIndex + 1)") {}
                    }
                    Text(exerciseName(set)).font(.footnote).foregroundStyle(Theme.navy)
                    Spacer()
                    Text(setText(set)).font(.footnote).monospacedDigit().secondaryText()
                    if set.seconds == nil {
                        SourceChip(source: set.isWarmup ? "Warm-up" : set.repCount.source.chipText)
                    }
                }
            } }
        }
        .padding(.vertical, Theme.Space.xxs)
    }

    /// The cycle day, or the add-on a morning session is made of.
    private var sessionName: String {
        if let dayId = session.programDayId {
            return store.currentProgram?.day(id: dayId)?.day.name ?? dayId
        }
        return session.addOnIds.compactMap { store.currentProgram?.addOn(id: $0)?.name }.first ?? "Session"
    }

    private func exerciseName(_ set: LoggedSet) -> String {
        store.currentProgram?.allExercises.first { $0.id == set.exerciseId }?.name ?? set.exerciseId
    }

    /// "225 × 8 · RPE 9", "0:45" for a hold, or "warm-up · 135 × 6".
    private func setText(_ set: LoggedSet) -> String {
        if let seconds = set.seconds { return Format.duration(TimeInterval(seconds)) }
        var text = "\(Format.number(set.loadLb)) × \(set.reps)"
        if let role = set.role, role != .warmup { text = "\(role.label.lowercased()) · " + text }
        if let rpe = set.rpe { text += " · RPE \(Format.number(rpe))" }
        return text
    }
}

/// A sent check-in, read-only.
struct SentCheckInView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    let draft: CheckInDraft
    @State private var text: String?

    var body: some View {
        ScreenScaffold(onClose: { dismiss() }) {
            TitleBlock(eyebrow: "Sent \(Format.shortDate(draft.sentAt ?? draft.weekEnd))", title: "Check-in")
            SectionCard("Message") {
                if let text {
                    Text(text).font(.footnote).monospacedDigit().foregroundStyle(Theme.navy).textSelection(.enabled)
                } else {
                    ProgressView().tint(Theme.cobalt)
                }
            }
        }
        .task {
            if let template = store.currentTemplate {
                text = try? await APIClient().checkInRender(template: template, draft: draft)
            }
        }
    }
}
