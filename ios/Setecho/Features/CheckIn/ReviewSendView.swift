import AVFoundation
import PhotosUI
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
    /// Adjustments and gym changes he unticked: left out of his notes field this time.
    @State private var leftOut: Set<UUID> = []
    @State private var banner: String?
    /// Which of the steps goes out next: the plan message, the check-in with the collage, the videos.
    @State private var sendStep = 0
    @State private var picks: [VideoPick] = []
    @State private var videoFiles: [UUID: String] = [:]
    @State private var showPicker = false
    @State private var exporting = false
    /// What is happening to the videos right now: "Cropping Incline DB press to the reps, 1 of 2".
    @State private var exportStatus: String?
    /// The current export's own progress, 0…1.
    @State private var exportProgress = 0.0
    /// The share sheet closed without saying the share finished (WhatsApp sometimes doesn't): the
    /// athlete says whether it went out, and the step moves on from his word.
    @State private var unreported = false
    @State private var exportTask: Task<Void, Never>?
    @State private var photosFirst = false
    /// "Finish check-in" with steps still to go: asked once before it's marked sent.
    @State private var confirmFinish = false
    /// The videos went by WhatsApp's own picker: the banner asks whether they went.
    @State private var attachingInWhatsApp = false
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
    private var isSent: Bool { coordinator.draft?.isSent == true }
    /// What hasn't gone out yet, for the finish question: "the two videos".
    private var stepsLeft: [String] { sendStep < stepCount ? Array(steps[sendStep...]) : [] }

    /// The period's sessions, for the videos and the adjustments line.
    private var periodSessions: [Session] {
        let (start, end) = coordinator.week
        return store.sessions.filter { $0.startedAt >= start && $0.startedAt < end }
    }

    private func exerciseName(_ id: String) -> String {
        store.currentProgram?.allExercises.first { $0.id == id }?.name ?? id
    }

    /// "Incline press set 3, 225 → 215 (RPE 9.5 vs 8)": only accepted suggestions (HANDOFF.md §7).
    private var adjustments: [(id: UUID, line: String)] {
        periodSessions.flatMap(\.suggestions).filter { $0.decision == .accepted }.map { s in
            let set = periodSessions.flatMap(\.sets).first { $0.id == s.setId }
            let when = s.scope == .nextSession ? " next session" : ""
            return (s.id, "\(exerciseName(s.exerciseId)) set \((set?.setIndex ?? 0) + 1), \(Format.number(s.fromLb)) → \(Format.number(s.toLb))\(when) (\(s.reason))")
        }
    }

    private var adjustmentLines: [String] { adjustments.filter { !leftOut.contains($0.id) }.map(\.line) }

    /// "Smith close-grip press 225 × 9, slowed 46%, failure": each lift's best measured top set this
    /// period, in by default while the setting is on (HANDOFF.md §7, Measured effort). Numbers from the log.
    private var measuredTopSets: [Effort.TopSetNote] {
        guard settings.measuredTopSetsInCheckIns else { return [] }
        return Effort.measuredTopSets(in: periodSessions, names: exerciseName, calibration: store.calibration)
    }

    private var measuredLines: [String] { measuredTopSets.filter { !leftOut.contains($0.id) }.map(\.line) }

    /// "Tue, Smith close-grip press → close-grip bench press (Smith taken)": every gym change this
    /// period, in by default (HANDOFF.md §7, Machine taken).
    private var deviations: [PlanDeviation] { periodSessions.flatMap(\.deviations).sorted { $0.at < $1.at } }

    private func deviationLine(_ d: PlanDeviation) -> String {
        let day = d.at.formatted(.dateTime.weekday(.abbreviated))
        if d.kind == .reorder { return "\(day), \(d.exerciseName) \(d.reason ?? "moved ahead")" }
        let what = d.doneAs.map { "\(d.exerciseName) → \($0.prefix(1).lowercased() + $0.dropFirst())" } ?? "\(d.exerciseName) skipped"
        return "\(day), \(what)" + (d.reason.map { " (\($0))" } ?? "")
    }

    private var deviationLines: [String] { deviations.filter { !leftOut.contains($0.id) }.map(deviationLine) }

    private func toggle(_ id: UUID) {
        if leftOut.contains(id) { leftOut.remove(id) } else { leftOut.insert(id) }
        Task { await render() }
    }

    /// This week's photo set: the four files as taken, in his order.
    private var photoSet: PhotoSet? {
        guard let id = coordinator.draft?.photoSetId ?? store.lastPhotoSet?.id else { return nil }
        return store.photoSets.first { $0.id == id }
    }

    /// The four as (pose, file), in his order, for the strip; the share sends `photoURLs`.
    private var posePhotos: [(pose: Pose, url: URL)] {
        guard let photoSet else { return [] }
        return Pose.allCases.compactMap { pose in
            photoSet.photo(for: pose).map { (pose: pose, url: store.mediaDirectory.appendingPathComponent($0.file)) }
        }.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    private var photoURLs: [URL] { posePhotos.map(\.url) }

    /// Whether an earlier week exists to put beside this one.
    private var hasEarlierPhotos: Bool {
        guard let photoSet else { return false }
        return store.photoSets.contains { $0.id != photoSet.id }
    }

    /// A photo open full screen, from the Photos card.
    @State private var viewing: PhotoViewing?

    /// Only for the on-screen preview; the share sends the files.
    private var collage: UIImage? { photoURLs.first.flatMap { UIImage(contentsOfFile: $0.path) } }

    var body: some View {
        ScreenScaffold(onClose: { dismiss() }) {
            TitleBlock(title: "Review and send", subtitle: "Exactly what your coach receives, in his format.")
            // Turned on in Settings → Developer; shown here only while it's on, so a rehearsal is never mistaken for the real send.
            if settings.rehearsalMode {
                SectionCard("Rehearsal") {
                    Toggle("Send to my own chat, not his", isOn: Bindable(settings).rehearsalMode)
                        .tint(Theme.cobalt).font(.subheadline).foregroundStyle(Theme.navy)
                    Text("Each step opens the share sheet: pick WhatsApp, then your own chat. Nothing reaches your coach.")
                        .font(.footnote).secondaryText()
                }
            }
            if let bannerText = banner {
                SectionCard {
                    HStack(spacing: Theme.Space.s) {
                        TargetTag(text: unreported ? "Did it go?" : "Next")
                        Text(bannerText).font(.subheadline).foregroundStyle(Theme.navy)
                    }
                    if unreported {
                        HStack(spacing: Theme.Space.xs) {
                            Button("It went out", systemImage: "checkmark") { unreported = false; attachingInWhatsApp = false; stepWentOut() }
                                .buttonStyle(.setechoTonalWide)
                            Button("Try again", systemImage: "arrow.counterclockwise") {
                                unreported = false
                                banner = nil
                                if attachingInWhatsApp { openWhatsApp() } else { showShare = true }
                            }
                            .buttonStyle(.setechoTonal)
                        }
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
                    LoadingRow(title: "Writing the message", detail: "In his format and order.")
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
                            ForEach(posePhotos, id: \.pose) { item in
                                if let image = UIImage(contentsOfFile: item.url.path) {
                                    Button {
                                        viewing = photoSet.map { PhotoViewing(photoSet: $0, pose: item.pose) }
                                    } label: {
                                        Image(uiImage: image).resizable().scaledToFill().frame(width: 90, height: 120)
                                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tag, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("\(item.pose.title). Opens full screen")
                                }
                            }
                        }
                    }
                    Text("Sent exactly as taken, in his order. Tap one to see it full screen.").font(.footnote).secondaryText()
                    if hasEarlierPhotos {
                        Button("Compare with last week", systemImage: "rectangle.split.2x1") {
                            viewing = photoSet.map { PhotoViewing(photoSet: $0, compare: true) }
                        }
                        .buttonStyle(.setechoTonal)
                    }
                }
            }
            SectionCard("Videos for your coach", accessory: {
                if picks.count < 2 { LinkButton(title: picks.isEmpty ? "Pick two" : "Add one", chevron: .none) { showPicker = true } }
            }) {
                Text("The sets you flagged, two at most from two different movements, each cropped to just the reps. No verdicts. "
                     + "Or skip this and attach videos from your camera roll straight in WhatsApp at the last step: one upload, no wait here.")
                    .font(.footnote).secondaryText()
                if picks.isEmpty {
                    Text("Nothing flagged this period. Say \"flag that\" after a set, or pick two.").font(.subheadline).secondaryText()
                }
                ForEach(picks) { pick in
                    CardDivider()
                    VideoPickRow(pick: pick) { showPicker = true }
                }
                if let exportStatus {
                    CardDivider()
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(exportStatus).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.navy)
                            Spacer()
                            Text("\(Int((exportProgress * 100).rounded()))%").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.cobalt)
                        }
                        MeterBar(fraction: exportProgress)
                        Text("On the phone, before it goes to WhatsApp. To skip the wait, attach them in WhatsApp yourself.").font(.footnote).secondaryText()
                    }
                    .accessibilityElement(children: .combine)
                } else if !picks.isEmpty, picks.allSatisfy({ videoFiles[$0.setId] != nil }) {
                    CardDivider()
                    HStack(spacing: Theme.Space.xs) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.cobalt)
                        Text("Ready to send. WhatsApp uploads them when you share.").font(.footnote).secondaryText()
                    }
                }
            }
            if !measuredTopSets.isEmpty {
                SectionCard("Top sets, measured") {
                    Text("Each lift's best measured top set this period, first in your notes field: load, reps, how much it slowed, and the estimated effort. Untick any you'd rather leave out.")
                        .font(.footnote).secondaryText()
                    ForEach(measuredTopSets) { note in
                        CardDivider()
                        HStack(alignment: .top, spacing: Theme.Space.s) {
                            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                                Text(note.line).font(.subheadline).monospacedDigit().foregroundStyle(Theme.navy)
                                Text("Measured · \(note.at.formatted(.dateTime.weekday(.wide)))").font(.footnote).secondaryText()
                            }
                            Spacer(minLength: Theme.Space.xs)
                            Checkbox(isOn: !leftOut.contains(note.id)) { toggle(note.id) }
                                .accessibilityLabel("\(note.line), \(leftOut.contains(note.id) ? "left out" : "in the notes")")
                        }
                    }
                }
            }
            if !adjustments.isEmpty || !deviations.isEmpty {
                SectionCard("In his notes") {
                    Text("Added to your notes field as plain sentences. Untick anything you'd rather leave out.").font(.footnote).secondaryText()
                    ForEach(adjustments, id: \.id) { adjustment in
                        CardDivider()
                        HStack(alignment: .top, spacing: Theme.Space.s) {
                            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                                Text(adjustment.line).font(.subheadline).monospacedDigit().foregroundStyle(Theme.navy)
                                Text("His rule, accepted").font(.footnote).secondaryText()
                            }
                            Spacer(minLength: Theme.Space.xs)
                            Checkbox(isOn: !leftOut.contains(adjustment.id)) { toggle(adjustment.id) }
                                .accessibilityLabel("\(adjustment.line), \(leftOut.contains(adjustment.id) ? "left out" : "in the notes")")
                        }
                    }
                    ForEach(deviations) { d in
                        CardDivider()
                        DeviationRow(planned: d.exerciseName, done: d.doneAs,
                                     detail: [d.reason.map { $0.prefix(1).uppercased() + $0.dropFirst() }, d.at.formatted(.dateTime.weekday(.wide))]
                                        .compactMap { $0 }.joined(separator: " · "),
                                     included: !leftOut.contains(d.id)) { toggle(d.id) }
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
                            Button { editing = field } label: {
                                FieldRow(field: field, answer: coordinator.answer(for: field))
                                    .multilineTextAlignment(.leading)
                                    .frame(minHeight: Theme.Control.minimum)
                            }
                            .buttonStyle(QuietPressStyle())
                            .accessibilityHint("Edit this answer")
                        }
                    }
                }
            }
            let open = coordinator.questions.flatMap { $0 }
            if !open.isEmpty {
                SectionCard("Still to answer") {
                    Text("\(open.count) left. They go out blank if you send now; tap one to type it.")
                        .font(.footnote).secondaryText()
                    ForEach(Array(open.enumerated()), id: \.element.id) { index, field in
                        if index > 0 { CardDivider() }
                        Button { editing = field } label: {
                                FieldRow(field: field, answer: coordinator.answer(for: field))
                                    .multilineTextAlignment(.leading)
                                    .frame(minHeight: Theme.Control.minimum)
                            }
                            .buttonStyle(QuietPressStyle())
                            .accessibilityHint("Edit this answer")
                    }
                }
            }
        } footer: {
            // Every step goes through the share sheet, the plan message too (Oct 28: whatsapp://send
            // with the text in the URL cut the supplements off; the share sheet carries the whole message).
            if sendStep >= stepCount || isSent {
                // Everything went out (Oct 29: the button sat disabled here, with no way to finish).
                Button("Done") { dismiss() }.buttonStyle(.setechoPrimary)
            } else {
                Button(exporting && isVideoStep ? (exportStatus ?? "Preparing the videos…") : sendStep == 0 ? "Send to WhatsApp" : "Next: \(stepName)") {
                    includeText = true
                    banner = nil
                    if isVideoStep {
                        Task { await prepareVideos(); showShare = true }
                    } else {
                        showShare = true
                    }
                }
                .buttonStyle(.setechoPrimary)
                .disabled(text == nil || (exporting && isVideoStep))
            }
            if isVideoStep, sendStep < stepCount {
                // The alternative to waiting: WhatsApp's own picker reads the camera roll, and uploads once.
                Button("Attach them in WhatsApp instead") {
                    exportTask?.cancel()
                    attachingInWhatsApp = true
                    openWhatsApp()
                }
                .buttonStyle(.setechoOutline)
            }
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
                Text("Step \(sendStep + 1) of \(stepCount): \(stepName). The share sheet opens; pick WhatsApp and the chat, then Send. One message each, in his order.")
                    .font(.footnote).secondaryText()
            }
            if !isSent, text != nil, sendStep < stepCount {
                // The way to end it: already sent some other way, or the rest isn't going.
                LinkButton(title: "Finish check-in", chevron: .none) {
                    if stepsLeft.isEmpty { finish() } else { confirmFinish = true }
                }
            }
        }
        .confirmationDialog("Finish without \(stepsLeft.joined(separator: " and "))?", isPresented: $confirmFinish, titleVisibility: .visible) {
            Button("Finish, it's all sent") { finish() }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("The check-in is marked sent and saved under History. Anything not sent from here, send in WhatsApp yourself.")
        }
        .keepsScreenAwake()
        .sheet(item: $editing, onDismiss: { Task { await render() } }) { field in
            FieldEditSheet(field: field, coordinator: coordinator)
        }
        .task {
            picks = coordinator.draft?.videoPicks ?? []
            if picks.isEmpty { picks = VideoCropper.picks(from: periodSessions, names: exerciseName) }
            await render()
            // The set clips are cropped while he reads, so the third send is ready when he gets there.
            await prepareVideos()
        }
        .sheet(isPresented: $showShare) {
            if isVideoStep {
                ShareSheet(image: nil, text: nil, files: picks.compactMap { videoFiles[$0.setId].map { store.mediaDirectory.appendingPathComponent($0) } }) { completed in
                    if completed { stepWentOut() } else { shareNotReported() }
                }
            } else if let body = isPlanStep ? planMessage : checkInMessage {
                ShareSheet(image: nil, text: includeText ? body : nil, files: isPlanStep || photosFirst == false && !includeText ? [] : photoURLs) { completed in
                    guard completed else { shareNotReported(); return }
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
                    stepWentOut()
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            VideoPickerSheet(sessions: periodSessions, picks: $picks, names: exerciseName)
        }
        .fullScreenCover(item: $viewing) { viewing in
            PhotoViewer(viewing: viewing).environment(store)
        }
        .onChange(of: picks) { _, new in
            coordinator.setVideoPicks(new)
            Task { await prepareVideos() }
        }
    }

    /// One step went out: the next step, or the whole check-in marked sent after the last.
    private func stepWentOut() {
        sendStep += 1
        if sendStep >= stepCount {
            coordinator.markSent()
            banner = isVideoStep || picks.isEmpty == false && sendStep == stepCount
                ? "Handed to WhatsApp; it uploads from there. The check-in is saved under History."
                : "Handed to WhatsApp. The check-in is saved under History."
        } else {
            banner = "Handed to WhatsApp. Next: \(stepName)."
        }
    }

    /// Marked sent as it stands, and closed. Check-in morning hears it and says it's sent.
    private func finish() {
        coordinator.markSent()
        dismiss()
    }

    /// WhatsApp, to attach the videos from its own camera-roll picker. Coming back asks whether they went.
    private func openWhatsApp() {
        guard let url = URL(string: "whatsapp://") else { return }
        UIApplication.shared.open(url) { opened in
            unreported = true
            banner = opened
                ? "In WhatsApp, open his chat, tap +, pick the videos from your camera roll and send. Then tap It went out."
                : "WhatsApp didn't open. Attach the videos there yourself, then tap It went out."
        }
    }

    /// The share sheet closed without a result: cancelled, or WhatsApp just didn't say.
    private func shareNotReported() {
        unreported = true
        banner = "WhatsApp didn't say whether \(stepName) went out. If you tapped Send there, it did."
    }

    private func render() async {
        guard let template = coordinator.template, let draft = coordinator.draft else { return }
        error = nil
        do {
            let response = try await APIClient().checkInRenderMessages(template: template, draft: draft, adjustments: adjustmentLines,
                                                                       deviations: deviationLines, measured: measuredLines)
            messages = response.messages
            coordinator.setAdjustments(adjustments.map(\.id).filter { !leftOut.contains($0) })
        } catch {
            self.error = error.userMessage
        }
    }

    /// One preparation at a time; a second call waits for the first and finds the work done.
    private func prepareVideos() async {
        if let running = exportTask { await running.value }
        let task = Task { await exportVideos() }
        exportTask = task
        await task.value
        exportTask = nil
    }

    /// A camera-roll video goes out exactly as he chose it, with no re-encode (Oct 28: he had already
    /// trimmed it, and the 720p export took minutes). A set's clip is cropped to the reps, once.
    private func exportVideos() async {
        exporting = true
        defer { exporting = false }
        defer { exportStatus = nil }
        for (index, pick) in picks.enumerated() where videoFiles[pick.setId] == nil {
            if let source = pick.sourceFile {
                videoFiles[pick.setId] = source
                continue
            }
            guard let set = periodSessions.flatMap(\.sets).first(where: { $0.id == pick.setId }), let file = set.clipFile else { continue }
            exportStatus = "Cropping \(pick.caption) to just the reps, \(index + 1) of \(picks.count)"
            exportProgress = 0
            let url = store.mediaDirectory.appendingPathComponent(file)
            if let name = try? await VideoCropper.export(clip: url, pick: pick, into: store.mediaDirectory, progress: { exportProgress = $0 }) {
                videoFiles[pick.setId] = name
            }
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
                Text("\(Format.duration(pick.cropEnd - pick.cropStart)) · \(pick.sourceFile == nil ? "just the reps" : "as you trimmed it")")
                    .font(.footnote).monospacedDigit().secondaryText()
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
    @Environment(Store.self) private var store
    let sessions: [Session]
    @Binding var picks: [VideoPick]
    let names: (String) -> String
    @State private var rollItem: PhotosPickerItem?
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        ScreenScaffold(onClose: { dismiss() }) {
            TitleBlock(title: "Pick two", subtitle: "Two movements you'd like his eyes on. Each is cropped to the reps. Your picks are kept as you tap.")
            SectionCard("From your camera roll") {
                Text("Goes out exactly as you trimmed it. It counts as one of the two.").font(.footnote).secondaryText()
                // As stored, no re-encode: a compatible copy can take minutes for a long video.
                PhotosPicker(selection: $rollItem, matching: .videos, preferredItemEncoding: .current) {
                    Text(importing ? "Copying from your camera roll…" : "Choose a video").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.cobalt)
                        .frame(minHeight: 44)
                }
                .disabled(importing)
                if let importError { Text(importError).font(.footnote).foregroundStyle(Theme.navy) }
            }
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
        .onChange(of: rollItem) { _, item in
            if let item { Task { await importFromRoll(item) } }
        }
    }

    /// Copy the chosen video into the media folder and add it as a pick, whole.
    private func importFromRoll(_ item: PhotosPickerItem) async {
        importing = true
        defer { importing = false; rollItem = nil }
        do {
            guard let movie = try await item.loadTransferable(type: MovieFile.self) else { return }
            let name = "roll-\(UUID().uuidString.prefix(8)).mov"
            let destination = store.mediaDirectory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: movie.url, to: destination)
            let seconds = (try? await AVURLAsset(url: destination).load(.duration).seconds) ?? 0
            if picks.count >= 2 { picks.removeFirst() }
            picks.append(VideoPick(setId: UUID(), caption: "From your camera roll · \(Format.shortDate(.now))", cropStart: 0,
                                   cropEnd: max(0.5, seconds), sourceFile: name))
            importError = nil
        } catch {
            importError = "Couldn't import that video: \(error.localizedDescription)"
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

/// A video from the Photos picker, copied to a temporary file.
struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("roll-\(UUID().uuidString.prefix(8)).mov")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return MovieFile(url: copy)
        }
    }
}
