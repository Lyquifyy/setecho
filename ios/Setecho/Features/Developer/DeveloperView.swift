import SwiftUI

/// Settings → Developer: everything for testing and tuning, in one place and off the everyday
/// screens. Rehearsing the check-in, filming the demo, exporting a session's data, the phone probes.
struct DeveloperView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    @State private var settings = Settings.shared
    @State private var exportFile: FileExport?
    @State private var exportError: String?
    @State private var rehearsingSession = false
    @State private var mixingProbe = AudioMixingProbe()
    /// Closes the whole Settings sheet from here; "‹ Settings" goes back one screen.
    var onClose: (() -> Void)?

    var body: some View {
        @Bindable var settings = settings
        let takes = FilmingRecorder.takes(in: store.mediaDirectory)
        // Every session, sets or not: a test whose sets were undone still has its camera and voice record (Oct 29).
        let sessions = store.sessions.sorted { $0.startedAt > $1.startedAt }
        ScreenScaffold(onClose: onClose) {
            LinkButton(title: "Settings", chevron: .leading) { dismiss() }
            TitleBlock(title: "Developer", subtitle: "For testing and tuning. Everything here stays on the phone unless you share it.")

            SectionCard("Rehearsal") {
                Text("Your own WhatsApp number, digits only. A rehearsal sends to you, never to your coach.").font(.subheadline).secondaryText()
                SettingsField(placeholder: "Your number", text: $settings.ownWhatsAppNumber)
                    .keyboardType(.numberPad)
                CardDivider()
                Toggle("Send check-ins to my own chat", isOn: $settings.rehearsalMode)
                    .tint(Theme.cobalt).font(.subheadline).foregroundStyle(Theme.navy)
                Text("While it's on, Review and send says so at the top.").font(.footnote).secondaryText()
                CardDivider()
                LinkButton(title: "Rehearse check-in morning") { AppRouter.shared.rehearseCheckInMorning() }
                Text("The whole morning flow on any day: spoken answers start over, nothing is sent.").font(.footnote).secondaryText()
                CardDivider()
                LinkButton(title: "Rehearse a session") { rehearsingSession = true }
                Text("Today's session with the camera and mic off: type what you'd say between sets, and it goes through the real backend and speaks back. Nothing is logged.")
                    .font(.footnote).secondaryText()
            }

            SectionCard("Hearing") {
                Toggle("Apple voice processing", isOn: $settings.voiceProcessing)
                    .tint(Theme.cobalt).font(.subheadline).foregroundStyle(Theme.navy)
                Text("Noise suppression and gain control on the session mic. It never runs while your music plays: iOS turns it into a phone call, which stops the music and the AirPods' full quality. Each utterance in the session data says whether it was on.")
                    .font(.footnote).secondaryText()
                CardDivider()
                HStack {
                    Text("Lower music on the AirPods mic").font(.subheadline).foregroundStyle(Theme.navy)
                    Spacer(minLength: Theme.Space.s)
                    Picker("Lower music on the AirPods mic", selection: $settings.airPodsLowering) {
                        ForEach(AirPodsLowering.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(Theme.cobalt)
                }
                .frame(minHeight: 44)
                Text("While the AirPods mic records at full quality, lowering your music can pause it. Whole session lowers it from start to end. Apple's speech session lowers it only while a line plays, in Apple's voice without the Voice tone settings. Run the test below to hear it. Don't lower: lines play over your music.")
                    .font(.footnote).secondaryText()
                CardDivider()
                LinkButton(title: mixingProbe.running ? "Testing…" : "Test music with the AirPods mic") {
                    Task { await mixingProbe.run() }
                }
                .disabled(mixingProbe.running)
                Text("Play music on your AirPods first. About 40 seconds: it starts a session one piece at a time (audio, mic, camera, a spoken line), then says a line on Apple's speech session two ways, each followed by 6 quiet seconds. Listen: does your music dip under each line and come back up after? If your music pauses, press play within 15 seconds.")
                    .font(.footnote).secondaryText()
                ForEach(mixingProbe.summary, id: \.self) { line in
                    Text(line).font(.footnote).foregroundStyle(line.contains("ok · music playing") ? Theme.textSecondary : Theme.navy)
                }
            }

            SectionCard("Filming") {
                Toggle("Filming mode", isOn: $settings.filmingMode)
                    .tint(Theme.cobalt).font(.subheadline).foregroundStyle(Theme.navy)
                Text("Records every spoken line and answer for the demo video, with captions.")
                    .font(.footnote).secondaryText()
                CardDivider()
                if takes.isEmpty {
                    Text("Takes appear here.").font(.subheadline).secondaryText()
                } else {
                    // Every take at once, as one zip, for the edit.
                    Button("AirDrop all \(takes.count) takes", systemImage: "square.and.arrow.up") {
                        do { exportFile = FileExport(url: try FilmingRecorder.zippedAll(in: store.mediaDirectory)) } catch { exportError = error.userMessage }
                    }
                    .buttonStyle(.setechoTonalWide)
                }
                ForEach(takes, id: \.self) { take in
                    CardDivider()
                    HStack {
                        Text(take.lastPathComponent).font(.subheadline).monospacedDigit().foregroundStyle(Theme.navy)
                        Spacer()
                        LinkButton(title: "AirDrop", chevron: .none) {
                            do { exportFile = FileExport(url: try FilmingRecorder.zipped(take)) } catch { exportError = error.userMessage }
                        }
                    }
                }
            }

            SectionCard("Session data") {
                Text("Each session's tuning JSON: the wrist series and every SAM answer with its latency. AirDrop it into backend/private/sessions/.")
                    .font(.footnote).secondaryText()
                if sessions.isEmpty {
                    CardDivider()
                    Text("Logged sessions appear here.").font(.subheadline).secondaryText()
                }
                ForEach(sessions.prefix(10)) { session in
                    CardDivider()
                    HStack {
                        let dm = Format.dayAndMonth(session.startedAt)
                        Text("\(dm.day) \(dm.month)").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.navy)
                        Text("\(session.workingSets.count) sets").font(.subheadline).monospacedDigit().secondaryText()
                        Spacer()
                        LinkButton(title: "Share", chevron: .none) { share(session) }
                    }
                }
            }

            SectionCard("Diagnostics") {
                NavigationLink {
                    ProbeHomeView()
                } label: {
                    HStack(spacing: Theme.Space.xxs) {
                        Text("Phone probes and turn timings")
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.cobalt)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("With developer tools on, the Check-in tab also shows Facts: the raw numbers the draft was built from.")
                    .font(.footnote).secondaryText()
            }
        }
        .fullScreenCover(isPresented: $rehearsingSession) {
            let today = store.todayDay
            SessionView(day: today?.day, addOns: today.map { store.addOnsDue(on: $0.day.id).map(\.addOn) } ?? [],
                        weekNumber: today?.week.number ?? 1, store: store, rehearsal: true)
        }
        .sheet(item: $exportFile) { file in
            ShareSheet(image: nil, text: nil, files: [file.url]) { _ in }
        }
        .alert("Couldn't export the session", isPresented: Binding { exportError != nil } set: { if !$0 { exportError = nil } }) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    /// The session's debug JSON for tuning (`SessionDebug`).
    private func share(_ session: Session) {
        do {
            exportFile = FileExport(url: try SessionDebug.export(session: session, store: store))
        } catch {
            exportError = error.userMessage
        }
    }
}

/// A file to share: a filming take's folder, or a session's debug JSON.
private struct FileExport: Identifiable {
    let url: URL
    var id: String { url.path }
}

#Preview {
    NavigationStack { DeveloperView() }
        .environment(Store(root: FileManager.default.temporaryDirectory.appendingPathComponent("preview-store")))
}
