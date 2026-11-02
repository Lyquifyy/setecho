import SwiftUI
import UniformTypeIdentifiers

/// More → "Add coach reply": paste his text, or pick his voice note as an audio file. Reading it
/// opens the Coach reply screen (HANDOFF.md §7, Coach reply, step 1).
struct AddCoachReplyView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    @State private var model: CoachReplyModel?
    @State private var text = ""
    @State private var picked: (data: Data, name: String)?
    @State private var showFilePicker = false

    var body: some View {
        ScreenScaffold(onClose: { dismiss() }) {
            TitleBlock(title: "Add coach reply", subtitle: "His WhatsApp text or voice note. Nothing changes until you approve it.")
            SectionCard("Paste his text") {
                TextEditor(text: $text)
                    .accessibilityLabel("Coach’s message")
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Paste your coach’s message here…")
                                .font(.body).secondaryText().padding(Theme.Space.xs)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .font(.body)
                    .foregroundStyle(Theme.navy)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 140)
                    .padding(Theme.Space.xs)
                    .background(Theme.nearWhite, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                if Settings.shared.sampleMode {
                    // The sample coach: a made-up message (one load change, one swap) to watch Muse Spark read.
                    Button("Use an example reply", systemImage: "text.quote") { text = SampleCoach.exampleReply }
                        .buttonStyle(.setechoTonal)
                }
            }
            SectionCard("Or his voice note") {
                Text("In WhatsApp: long-press the note → Forward → Share → Save to Files, then pick it here. Or share it straight to Setecho.")
                    .font(.footnote).secondaryText()
                Button { showFilePicker = true } label: { Label("Pick an audio file", systemImage: "waveform") }
                    .buttonStyle(.setechoOutline)
                if let picked {
                    CardDivider()
                    HStack {
                        Text(picked.name).font(.subheadline).foregroundStyle(Theme.navy)
                        Spacer()
                        LinkButton(title: "Remove", chevron: .none) { self.picked = nil }
                    }
                }
            }
            if let error = model?.error {
                SectionCard("Couldn't read it") {
                    Text(error).font(.subheadline).foregroundStyle(Theme.navy)
                }
            }
            if store.plan == nil {
                SectionCard("Import first") {
                    Text("A reply is read against the plan, so import the program and the form first.").font(.subheadline).secondaryText()
                    LinkButton(title: "Import") { dismiss(); AppRouter.shared.showImport = true }
                }
            }
        } footer: {
            Button {
                Task { await read() }
            } label: {
                if model?.isReading == true {
                    Label(picked == nil ? "Reading with Muse Spark…" : "Transcribing and reading…", systemImage: "sparkles")
                } else {
                    Text("Read the reply")
                }
            }
            .buttonStyle(.setechoPrimary)
            .disabled(store.plan == nil || model?.isReading == true || (picked == nil && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.audio, UTType("org.xiph.opus") ?? .audio, UTType("org.xiph.ogg-audio") ?? .audio, .mpeg4Audio]) { result in
            if case .success(let url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) { picked = (data, url.lastPathComponent) }
            }
        }
    }

    private func read() async {
        let model = CoachReplyModel(store: store)
        self.model = model
        if let picked {
            await model.read(audio: picked.data, filename: picked.name)
        } else {
            await model.read(text: text)
        }
        if let reply = model.reply {
            dismiss()
            AppRouter.shared.openReply = reply
        }
    }
}
