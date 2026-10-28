import SwiftUI
import UIKit

/// History (DESIGN.md): This week · Previous sessions · Sent check-ins · Photos.
struct HistoryView: View {
    @Environment(Store.self) private var store
    @State private var openCheckIn: CheckInDraft?
    @State private var comparePhotos = false
    @State private var exportTake: TakeExport?

    private var weekStart: Date { CheckInSchedule().week(endingBefore: CheckInSchedule().nextDue(from: .now)).start }

    var body: some View {
        let sessions = store.sessions.filter { !$0.sets.isEmpty }.sorted { $0.startedAt > $1.startedAt }
        let thisWeek = sessions.filter { $0.startedAt >= weekStart }
        let previous = sessions.filter { $0.startedAt < weekStart }
        ScreenScaffold {
            TitleBlock(title: "History")
            SectionCard("This week") {
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
            SectionCard("Sent check-ins") {
                let sent = store.checkIns.filter(\.isSent).sorted { $0.sentAt! > $1.sentAt! }
                if sent.isEmpty {
                    Text("Sent check-ins reopen here, read-only.").font(.subheadline).secondaryText()
                } else {
                    ForEach(Array(sent.enumerated()), id: \.element.id) { index, draft in
                        if index > 0 { CardDivider() }
                        HStack {
                            Text("Sent \(Format.shortDate(draft.sentAt!))").font(.body).foregroundStyle(Theme.navy)
                            Spacer()
                            LinkButton(title: "Open") { openCheckIn = draft }
                        }
                    }
                }
            }
            let takes = FilmingRecorder.takes(in: store.mediaDirectory)
            if !takes.isEmpty {
                SectionCard("Filming takes") {
                    Text("Every line and answer as audio, with captions. Stays on the phone until you AirDrop it.").font(.footnote).secondaryText()
                    ForEach(takes, id: \.self) { take in
                        CardDivider()
                        HStack {
                            Text(take.lastPathComponent).font(.subheadline).monospacedDigit().foregroundStyle(Theme.navy)
                            Spacer()
                            LinkButton(title: "AirDrop", chevron: .none) { exportTake = TakeExport(url: take) }
                        }
                    }
                }
            }
            SectionCard("Photos", accessory: {
                if store.photoSets.count >= 2 {
                    LinkButton(title: comparePhotos ? "Timeline" : "Compare", chevron: .none) { comparePhotos.toggle() }
                }
            }) {
                let sets = store.photoSets.sorted { $0.takenAt > $1.takenAt }
                if sets.isEmpty {
                    Text("Each week's four photos line up here.").font(.subheadline).secondaryText()
                } else if comparePhotos, sets.count >= 2 {
                    HStack(spacing: Theme.Space.xs) {
                        collageTile(sets[1])
                        collageTile(sets[0])
                    }
                } else {
                    ForEach(Array(sets.enumerated()), id: \.element.id) { index, set in
                        if index > 0 { CardDivider() }
                        collageTile(set)
                    }
                }
            }
            SectionCard("Plan changes") {
                let applied = store.appliedReplies
                if applied.isEmpty {
                    Text("Applied coach replies appear here, with their changes.").font(.subheadline).secondaryText()
                } else {
                    ForEach(Array(applied.enumerated()), id: \.element.id) { index, reply in
                        if index > 0 { CardDivider() }
                        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(Format.shortDate(reply.receivedAt)) · plan v\(reply.appliedVersion ?? 0)")
                                    .font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.navy)
                                Spacer()
                                if index == 0, store.plan?.replyId == reply.id {
                                    LinkButton(title: "Revert", chevron: .none) { store.revertLatestPlan() }
                                }
                                LinkButton(title: "Open", chevron: .none) { AppRouter.shared.openReply = reply }
                            }
                            ForEach(reply.changes.filter(\.approved)) { change in
                                Text("\(change.label): \(change.beforeAfterText)").font(.footnote).monospacedDigit().secondaryText()
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $exportTake) { take in
            ShareSheet(image: nil, text: nil, files: [take.url]) { _ in }
        }
        .sheet(item: $openCheckIn) { draft in
            SentCheckInView(draft: draft).environment(store)
        }
    }

    /// One week: the four photos as taken, in his order (no collage since Oct 27).
    private func collageTile(_ set: PhotoSet) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            HStack(spacing: Theme.Space.xxs) {
                ForEach(Pose.allCases, id: \.self) { pose in
                    if let file = set.photo(for: pose)?.file,
                       let image = UIImage(contentsOfFile: store.mediaDirectory.appendingPathComponent(file).path) {
                        Color.clear
                            .aspectRatio(3 / 4, contentMode: .fit)
                            .overlay { Image(uiImage: image).resizable().scaledToFill() }
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tag, style: .continuous))
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

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                let dm = Format.dayAndMonth(session.startedAt)
                Text("\(dm.day) \(dm.month)").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.navy)
                Text(sessionName).font(.subheadline).secondaryText()
                Spacer()
                Text("\(session.workingSets.count) sets").font(.subheadline).monospacedDigit().secondaryText()
            }
            ForEach(session.sets) { set in
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
            }
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
        ScreenScaffold {
            LinkButton(title: "Back", chevron: .leading) { dismiss() }
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

/// A filming take to AirDrop, by its folder.
private struct TakeExport: Identifiable {
    let url: URL
    var id: String { url.path }
}
