import SwiftUI
import UIKit

/// Review and send (DESIGN.md): both messages in the coach's format and order (the plan message,
/// then the check-in), with the collage beneath the check-in. The send runs in his order as
/// steps, one share sheet each (HANDOFF.md §7, Check-in, step 6): the plan message, the check-in
/// with the collage, then the videos (P4). The footer names the next step. If WhatsApp drops the
/// text when an image is shared, step 2 falls back to the image with the text copied.
struct ReviewSendView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    let coordinator: CheckInCoordinator
    @State private var messages: [String] = []
    @State private var editing: FieldSpec?
    @State private var error: String?
    @State private var showShare = false
    @State private var includeText = true
    @State private var banner: String?
    /// Which of the steps goes out next: the plan message, the check-in with the collage, the videos.
    @State private var sendStep = 0
    @State private var picks: [VideoPick] = []
    @State private var videoFiles: [UUID: String] = [:]
    @State private var showPicker = false
    @State private var exporting = false
    @State private var photosFirst = false
    @State private var settings = Settings.shared

    private var text: String? { messages.isEmpty ? nil : messages.joined(separator: "\n\n") }
    private var planMessage: String? { messages.count > 1 ? messages[0] : nil }
    private var checkInMessage: String? { messages.last }
    private var steps: [String] {
        var names: [String] = []
        if planMessage != nil { names.append("the plan message") }
        names.append("the check-in with the photos")
        if !picks.isEmpty { names.append("the two videos") }
        return names
    }
    private var stepCount: Int { steps.count }
    private var stepName: String { steps.indices.contains(sendStep) ? steps[sendStep] : "" }
    private var isVideoStep: Bool { !picks.isEmpty && sendStep == stepCount - 1 }
    private var isPlanStep: Bool { sendStep == 0 && planMessage != nil }

    /// The period's sessions, for the videos and the adjustments line.
    private var periodSessions: [Session] {
        let (start, end) = coordinator.week
        return store.sessions.filter { $0.startedAt >= start && $0.startedAt < end }
    }

    private func exerciseName(_ id: String) -> String {
        store.currentProgram?.allExercises.first { $0.id == id }?.name ?? id
    }

    /// "Incline press set 3, 225 → 215 (RPE 9.5 vs 8)": only accepted suggestions (HANDOFF.md §7).
    private var adjustmentLines: [String] {
        periodSessions.flatMap(\.suggestions).filter { $0.decision == .accepted }.map { s in
            let set = periodSessions.flatMap(\.sets).first { $0.id == s.setId }
            let when = s.scope == .nextSession ? " next session" : ""
            return "\(exerciseName(s.exerciseId)) set \((set?.setIndex ?? 0) + 1), \(Format.number(s.fromLb)) → \(Format.number(s.toLb))\(when) (\(s.reason))"
        }
    }

    /// This week's photo set: the four files as taken, in his order.
    private var photoSet: PhotoSet? {
        guard let id = coordinator.draft?.photoSetId ?? store.lastPhotoSet?.id else { return nil }
        return store.photoSets.first { $0.id == id }
    }

    private var photoURLs: [URL] {
        guard let photoSet else { return [] }
        return Pose.allCases.compactMap { pose in photoSet.photo(for: pose).map { store.mediaDirectory.appendingPathComponent($0.file) } }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Only for the on-screen preview; the share sends the files.
    private var collage: UIImage? { photoURLs.first.flatMap { UIImage(contentsOfFile: $0.path) } }

    var body: some View {
        ScreenScaffold {
            LinkButton(title: "Back to check-in", chevron: .leading) { dismiss() }
            TitleBlock(title: "Review and send", subtitle: "Exactly what your coach receives, in his format.")
            SectionCard("Rehearsal", accessory: { if settings.rehearsalMode { TargetTag(text: "On") } }) {
                Toggle("Send to my own chat, not his", isOn: Bindable(settings).rehearsalMode)
                    .tint(Theme.cobalt).font(.subheadline).foregroundStyle(Theme.navy)
                Text(settings.rehearsalMode
                     ? "Each share opens your own WhatsApp chat\(settings.ownWhatsAppNumber.isEmpty ? " once your number is in Settings" : ""). Nothing reaches your coach."
                     : "Off: the shares go wherever you pick in the share sheet.")
                    .font(.footnote).secondaryText()
            }
            if let banner {
                SectionCard {
                    HStack(spacing: Theme.Space.s) {
                        TargetTag(text: "Next")
                        Text(banner).font(.subheadline).foregroundStyle(Theme.navy)
                    }
                }
            }
            if let planMessage {
                SectionCard("Message 1 · the plan", accessory: { if sendStep > 0 { Text("Sent").font(.subheadline.weight(.semibold)).secondaryText() } }) {
                    Text(planMessage).font(.footnote).monospacedDigit().foregroundStyle(Theme.navy)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            SectionCard(planMessage == nil ? "Message" : "Message 2 · the check-in") {
                if let checkInMessage {
                    Text(checkInMessage).font(.footnote).monospacedDigit().foregroundStyle(Theme.navy)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                } else if let error {
                    Text(error).font(.subheadline).foregroundStyle(Theme.navy)
                    LinkButton(title: "Try again", chevron: .none) { Task { await render() } }
                } else {
                    LoadingCard(title: "Writing the message", detail: "In his format and order.")
                }
                CardDivider()
                Text("Every number comes from Apple Health, the training log or what you said. Tap a field on the Check-in tab to see its source.")
                    .font(.footnote).secondaryText()
            }
            SectionCard("Photos", accessory: { Text("\(photoURLs.count) of 4").font(.subheadline).monospacedDigit().secondaryText() }) {
                if photoURLs.isEmpty {
                    Text("No photos this week yet. Take photos from Today.").font(.subheadline).secondaryText()
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.Space.xs) {
                            ForEach(photoURLs, id: \.self) { url in
                                if let image = UIImage(contentsOfFile: url.path) {
                                    Image(uiImage: image).resizable().scaledToFill().frame(width: 90, height: 120)
                                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tag, style: .continuous))
                                }
                            }
                        }
                    }
                    Text("Sent exactly as taken, in his order.").font(.footnote).secondaryText()
                }
            }
            SectionCard("Videos for your coach", accessory: {
                if picks.count < 2 { LinkButton(title: picks.isEmpty ? "Pick two" : "Add one", chevron: .none) { showPicker = true } }
            }) {
                Text("The sets you flagged, two at most from two different movements, each cropped to just the reps. No verdicts.")
                    .font(.footnote).secondaryText()
                if picks.isEmpty {
                    Text("Nothing flagged this period. Say \"flag that\" after a set, or pick two.").font(.subheadline).secondaryText()
                }
                ForEach(picks) { pick in
                    CardDivider()
                    VideoPickRow(pick: pick) { showPicker = true }
                }
            }
            if !adjustmentLines.isEmpty {
                SectionCard("Adjustments") {
                    Text("The suggestions you accepted this period, his rule applied, as they'll appear in the message.").font(.footnote).secondaryText()
                    ForEach(Array(adjustmentLines.enumerated()), id: \.offset) { index, line in
                        if index > 0 { CardDivider() }
                        Text(line).font(.subheadline).monospacedDigit().foregroundStyle(Theme.navy)
                    }
                }
            }
            if let template = coordinator.template, let draft = coordinator.draft {
                let answered = template.orderedFields.filter { field in
                    draft.answers.contains { $0.fieldId == field.id && $0.state != .missing && !$0.text.isEmpty }
                }
                if !answered.isEmpty {
                    SectionCard("Change an answer") {
                        Text("Tap one to change it before it goes out; the message is rewritten.").font(.footnote).secondaryText()
                        ForEach(Array(answered.enumerated()), id: \.element.id) { index, field in
                            if index > 0 { CardDivider() }
                            FieldRow(field: field, answer: coordinator.answer(for: field))
                                .contentShape(Rectangle())
                                .onTapGesture { editing = field }
                        }
                    }
                }
            }
            let missing = coordinator.questions.count
            if missing > 0 {
                SectionCard("Still to answer") {
                    Text("\(missing) question\(missing == 1 ? "" : "s") left. They go out blank if you send now; tap a field on the Check-in tab to type it.")
                        .font(.subheadline).foregroundStyle(Theme.navy)
                    LinkButton(title: "Type the rest") { dismiss(); AppRouter.shared.tab = .checkIn }
                }
            }
        } footer: {
            Button(exporting ? "Cropping the videos…" : sendStep == 0 ? "Send to WhatsApp" : "Next: \(stepName)") {
                includeText = true
                banner = nil
                if isVideoStep {
                    Task { await exportVideos(); showShare = true }
                } else if settings.rehearsalMode, !settings.ownWhatsAppNumber.isEmpty, isPlanStep, let planMessage {
                    // Rehearsal: a text-only step goes straight to the athlete's own chat.
                    openOwnChat(with: planMessage)
                } else {
                    showShare = true
                }
            }
            .buttonStyle(.setechoPrimary)
            .disabled(text == nil || sendStep >= stepCount || exporting)
            if !isVideoStep, sendStep == (planMessage == nil ? 0 : 1) {
                // If WhatsApp splits the text from the photos: the photos first, the text right after.
                Button("Photos first, then the text") {
                    includeText = false
                    banner = "Next: the check-in text, right after the photos."
                    photosFirst = true
                    showShare = true
                }
                .buttonStyle(.setechoOutline)
                .disabled(text == nil || photoURLs.isEmpty)
            }
            if stepCount > 1, sendStep < stepCount {
                Text("Step \(sendStep + 1) of \(stepCount): \(stepName). One WhatsApp message each, in his order.")
                    .font(.footnote).secondaryText()
            }
        }
        .sheet(item: $editing, onDismiss: { Task { await render() } }) { field in
            FieldEditSheet(field: field, coordinator: coordinator)
        }
        .task {
            picks = coordinator.draft?.videoPicks ?? []
            if picks.isEmpty { picks = VideoCropper.picks(from: periodSessions, names: exerciseName) }
            await render()
        }
        .sheet(isPresented: $showShare) {
            if isVideoStep {
                ShareSheet(image: nil, text: nil, files: picks.compactMap { videoFiles[$0.setId].map { store.mediaDirectory.appendingPathComponent($0) } }) { completed in
                    guard completed else { return }
                    sendStep += 1
                    coordinator.markSent()
                    banner = "Sent. The check-in is saved under History."
                }
            } else if let body = isPlanStep ? planMessage : checkInMessage {
                ShareSheet(image: nil, text: includeText ? body : nil, files: isPlanStep || photosFirst == false && !includeText ? [] : photoURLs) { completed in
                    guard completed else { return }
                    if photosFirst {
                        // The photos went; now the text, as its own share.
                        photosFirst = false
                        includeText = true
                        banner = "Now the check-in text."
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(400))
                            showShare = true
                        }
                        return
                    }
                    sendStep += 1
                    if sendStep >= stepCount {
                        coordinator.markSent()
                        banner = "Sent. The check-in is saved under History."
                    } else {
                        banner = "Next: \(stepName)."
                    }
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            VideoPickerSheet(sessions: periodSessions, picks: $picks, names: exerciseName)
        }
        .onChange(of: picks) { _, new in coordinator.setVideoPicks(new) }
    }

    /// whatsapp://send to the athlete's own number: nothing can reach the coach from here.
    private func openOwnChat(with text: String) {
        let digits = settings.ownWhatsAppNumber.filter(\.isNumber)
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "whatsapp://send?phone=\(digits)&text=\(encoded)") else { return }
        UIApplication.shared.open(url) { opened in
            guard opened else { return }
            sendStep += 1
            banner = sendStep >= stepCount ? "Rehearsal sent to your own chat." : "Rehearsal: next, \(stepName). Pick your own chat in the share sheet."
        }
    }

    private func render() async {
        guard let template = coordinator.template, let draft = coordinator.draft else { return }
        error = nil
        do {
            let response = try await APIClient().checkInRenderMessages(template: template, draft: draft, adjustments: adjustmentLines)
            messages = response.messages
            coordinator.setAdjustments(periodSessions.flatMap(\.suggestions).filter { $0.decision == .accepted }.map(\.id))
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Crop each picked set's MOV to the reps, once, before the third share.
    private func exportVideos() async {
        exporting = true
        defer { exporting = false }
        for pick in picks where videoFiles[pick.setId] == nil {
            guard let set = periodSessions.flatMap(\.sets).first(where: { $0.id == pick.setId }), let clip = set.clipFile else { continue }
            let url = store.mediaDirectory.appendingPathComponent(clip)
            if let name = try? await VideoCropper.export(clip: url, pick: pick, into: store.mediaDirectory) { videoFiles[pick.setId] = name }
        }
    }
}

/// One of the two videos (DESIGN.md Components, `VideoPickRow`): thumbnail, the caption, the cropped length, "Swap".
struct VideoPickRow: View {
    let pick: VideoPick
    let onSwap: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            SetThumbnail(width: 96, height: 58)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(pick.caption).font(.body.weight(.semibold)).foregroundStyle(Theme.navy)
                Text("\(Format.duration(pick.cropEnd - pick.cropStart)) · just the reps").font(.footnote).monospacedDigit().secondaryText()
            }
            Spacer()
            LinkButton(title: "Swap", chevron: .none, action: onSwap)
        }
        .padding(.vertical, Theme.Space.xxs)
    }
}

/// "Pick two": the period's sets by exercise. Tapping one swaps it in; two at most, two movements.
private struct VideoPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let sessions: [Session]
    @Binding var picks: [VideoPick]
    let names: (String) -> String

    var body: some View {
        ScreenScaffold {
            LinkButton(title: "Done", chevron: .leading) { dismiss() }
            TitleBlock(title: "Pick two", subtitle: "Two movements you'd like his eyes on. Each is cropped to the reps.")
            ForEach(sessions.sorted { $0.startedAt > $1.startedAt }) { session in
                let sets = session.sets.filter { $0.clipFile != nil && !$0.isWarmup }
                if !sets.isEmpty {
                    SectionCard(Format.shortDate(session.startedAt)) {
                        ForEach(Array(sets.enumerated()), id: \.element.id) { index, set in
                            if index > 0 { CardDivider() }
                            let chosen = picks.contains { $0.setId == set.id }
                            Button {
                                toggle(set)
                            } label: {
                                HStack {
                                    Text(VideoCropper.caption(exerciseName: names(set.exerciseId), set: set)).font(.body).foregroundStyle(Theme.navy)
                                    Spacer()
                                    Text("\(Format.number(set.loadLb)) × \(set.reps)").font(.subheadline).monospacedDigit().secondaryText()
                                    Checkbox(isOn: chosen) { toggle(set) }
                                }
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func toggle(_ set: LoggedSet) {
        if let i = picks.firstIndex(where: { $0.setId == set.id }) {
            picks.remove(at: i)
            return
        }
        picks.removeAll { pick in sessions.flatMap(\.sets).first { $0.id == pick.setId }?.exerciseId == set.exerciseId } // one per movement
        if picks.count >= 2 { picks.removeFirst() }
        picks.append(VideoCropper.pick(for: set, exerciseName: names(set.exerciseId)))
    }
}

/// UIActivityViewController with an optional image, an optional text, and optional files (the videos).
struct ShareSheet: UIViewControllerRepresentable {
    let image: UIImage?
    let text: String?
    var files: [URL] = []
    let onComplete: @MainActor (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        var items: [Any] = []
        if let image { items.append(image) }
        if let text { items.append(text) }
        items.append(contentsOf: files)
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let onComplete = self.onComplete
        controller.completionWithItemsHandler = { _, completed, _, _ in
            MainActor.assumeIsolated { onComplete(completed) }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
