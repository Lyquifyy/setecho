import SwiftUI
import UIKit

/// History (DESIGN.md): This week · Previous sessions · Sent check-ins · Photos.
struct HistoryView: View {
    @Environment(Store.self) private var store
    @State private var openCheckIn: CheckInDraft?
    @State private var comparePhotos = false

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
            SectionCard("Photos", accessory: {
                if store.photoSets.count >= 2 {
                    LinkButton(title: comparePhotos ? "Timeline" : "Compare", chevron: .none) { comparePhotos.toggle() }
                }
            }) {
                let sets = store.photoSets.sorted { $0.takenAt > $1.takenAt }
                if sets.isEmpty {
                    Text("Collages build a timeline here.").font(.subheadline).secondaryText()
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
        }
        .sheet(item: $openCheckIn) { draft in
            SentCheckInView(draft: draft).environment(store)
        }
    }

    private func collageTile(_ set: PhotoSet) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            if let data = try? Data(contentsOf: store.mediaDirectory.appendingPathComponent(set.collageFile)),
               let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tag, style: .continuous))
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
                Text(store.program?.day(id: session.programDayId)?.day.name ?? session.programDayId).font(.subheadline).secondaryText()
                Spacer()
                Text("\(session.sets.count) sets").font(.subheadline).monospacedDigit().secondaryText()
            }
            ForEach(session.sets) { set in
                HStack(spacing: Theme.Space.s) {
                    if set.clipFile != nil {
                        PlayButton(accessibilityLabel: "Play set \(set.setIndex + 1)") {}
                    }
                    Text(store.program?.exerciseName(id: set.exerciseId) ?? set.exerciseId).font(.footnote).foregroundStyle(Theme.navy)
                    Spacer()
                    Text("\(Format.number(set.loadLb)) × \(set.reps)\(set.rpe.map { " · RPE \(Format.number($0))" } ?? "")")
                        .font(.footnote).monospacedDigit().secondaryText()
                }
            }
        }
        .padding(.vertical, Theme.Space.xxs)
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
            if let template = store.template {
                text = try? await APIClient().checkInRender(template: template, draft: draft)
            }
        }
    }
}
