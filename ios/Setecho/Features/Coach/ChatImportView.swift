import SwiftUI
import UniformTypeIdentifiers

/// More → "Import WhatsApp chat" (HANDOFF.md §9, WhatsApp history import): the coach chat's export,
/// read on the phone. Asks once which sender is the athlete and which the coach, then keeps the
/// past check-ins, their photos and the coach's replies. Nothing is sent anywhere.
@MainActor
@Observable
final class ChatImportModel {
    enum Step { case start, whoIsWho, review, done }

    private(set) var step: Step = .start
    private(set) var error: String?
    private(set) var senders: [(name: String, count: Int)] = []
    var athlete: String?
    var coach: String?
    private(set) var result: ChatImport.Result?
    private(set) var added: (checkIns: Int, coachMessages: Int)?
    private var export: ChatExport?
    private var messages: [ChatMessage] = []
    private let store: Store
    private let workingCopy = FileManager.default.temporaryDirectory.appendingPathComponent("whatsapp-export")

    init(store: Store) { self.store = store }

    /// The picked file: read, parsed, and the senders asked about unless the last import named them.
    func open(_ url: URL) {
        error = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let export = try ChatExport.read(url, workingCopy: workingCopy)
            let messages = WhatsAppChat.parse(export.text)
            guard !messages.isEmpty else {
                error = "No messages in that chat. In WhatsApp, use Export Chat on your coach's chat."
                return
            }
            self.export = export
            self.messages = messages
            senders = ChatImport.senders(messages)
            let names = Set(senders.map(\.name))
            if let a = store.chatHistory.athleteName, let c = store.chatHistory.coachName, names.contains(a), names.contains(c) {
                athlete = a
                coach = c
                review()
            } else {
                athlete = nil
                coach = nil
                step = .whoIsWho
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// With two senders, picking one is both answers.
    func choose(athlete name: String) {
        athlete = name
        if senders.count == 2 { coach = senders.first { $0.name != name }?.name }
        if coach == name { coach = nil }
    }

    func review() {
        guard let template = store.currentTemplate, let athlete, let coach, athlete != coach else { return }
        result = ChatImport.classify(messages, athlete: athlete, coach: coach, template: template)
        step = .review
    }

    var alreadySeen: Int { result.map { Set($0.keys).intersection(store.chatHistory.seen).count } ?? 0 }
    /// New messages that aren't a check-in, its photos or a coach reply.
    var leftOut: Int { result.map { Set($0.keys).subtracting($0.kept).subtracting(store.chatHistory.seen).count } ?? 0 }
    var newCheckIns: [PastCheckIn] { result?.checkIns.filter { !store.chatHistory.seen.contains($0.id) } ?? [] }
    var newReplies: [CoachMessage] { result?.coachMessages.filter { !store.chatHistory.seen.contains($0.id) } ?? [] }

    func commit() {
        guard let result, let athlete, let coach, let template = store.currentTemplate, let export else { return }
        do {
            added = try store.mergeChat(result, athlete: athlete, coach: coach, template: template) { file, to in
                try export.copy(file, to: to)
            }
            step = .done
            try? FileManager.default.removeItem(at: workingCopy)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ChatImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    @State private var model: ChatImportModel?
    @State private var showPicker = false
    @State private var confirmStartOver = false

    /// A model already part-way through (the tests' renders); the sheet starts with none.
    init(model: ChatImportModel? = nil) { _model = State(initialValue: model) }

    var body: some View {
        let model = model ?? ChatImportModel(store: store)
        ScreenScaffold(onClose: { dismiss() }) {
            TitleBlock(title: "Import WhatsApp chat", subtitle: "Your past check-ins and your coach's replies, read once on this phone.")
            switch model.step {
            case .start: start
            case .whoIsWho: whoIsWho(model)
            case .review: review(model)
            case .done: done(model)
            }
            if let error = model.error {
                SectionCard("Couldn't read it") {
                    Text(error).font(.subheadline).foregroundStyle(Theme.navy)
                }
            }
        } footer: {
            footer(model)
        }
        .onAppear { if self.model == nil { self.model = model } }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.zip, .plainText, .text]) { result in
            if case .success(let url) = result { model.open(url) }
        }
        .confirmationDialog("Start over?", isPresented: $confirmStartOver, titleVisibility: .visible) {
            Button("Remove the imported chat", role: .destructive) { store.clearChatHistory() }
        } message: {
            Text("Its check-ins, photos and coach replies leave Setecho. Your chat in WhatsApp isn't touched.")
        }
    }

    // MARK: Steps

    @ViewBuilder private var start: some View {
        SectionCard("Export the chat") {
            Text("In WhatsApp, open your coach's chat, tap the name at the top, then Export Chat → Attach Media → Save to Files. Pick the zip here.")
                .font(.subheadline).foregroundStyle(Theme.navy)
        }
        SectionCard("What's kept") {
            Text("Your past check-ins, read through your coach's form, become History's trends. Your coach's replies after each one are listed under History → Plan, word for word; they don't change your plan. Check-in photos stay on this phone. Every other message is left out.")
                .font(.subheadline).secondaryText()
        }
        if store.currentTemplate == nil {
            SectionCard("Import the form first") {
                Text("Past check-ins are read through your coach's check-in form, so import it first.").font(.subheadline).secondaryText()
                LinkButton(title: "Import") { dismiss(); AppRouter.shared.showImport = true }
            }
        }
        let history = store.chatHistory
        if let last = history.lastImportAt {
            SectionCard("Last import", accessory: {
                Button("Start over", systemImage: "arrow.counterclockwise") { confirmStartOver = true }.buttonStyle(.setechoTonal)
            }) {
                Text("\(Format.shortDate(last)) · \(history.checkIns.count) check-ins · \(history.coachMessages.count) coach replies")
                    .font(.subheadline).monospacedDigit().foregroundStyle(Theme.navy)
                Text("A newer export adds only what's new.").font(.footnote).secondaryText()
            }
        }
    }

    @ViewBuilder private func whoIsWho(_ model: ChatImportModel) -> some View {
        SectionCard("Which one is you?") {
            senderRows(model, selected: model.athlete) { model.choose(athlete: $0) }
        }
        if model.senders.count > 2 {
            SectionCard("And your coach?") {
                senderRows(model, selected: model.coach) { model.coach = $0 }
            }
        } else if let coach = model.coach {
            SectionCard("Your coach") {
                Text(coach).font(.body).foregroundStyle(Theme.navy)
            }
        }
    }

    private func senderRows(_ model: ChatImportModel, selected: String?, pick: @escaping (String) -> Void) -> some View {
        ForEach(Array(model.senders.enumerated()), id: \.element.name) { index, sender in
            if index > 0 { CardDivider() }
            Button { pick(sender.name) } label: {
                HStack {
                    Image(systemName: selected == sender.name ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected == sender.name ? Theme.cobalt : Theme.textSecondary)
                    Text(sender.name).font(.body).foregroundStyle(Theme.navy)
                    Spacer()
                    Text("\(sender.count) messages").font(.subheadline).monospacedDigit().secondaryText()
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected == sender.name ? .isSelected : [])
        }
    }

    @ViewBuilder private func review(_ model: ChatImportModel) -> some View {
        let checkIns = model.newCheckIns
        let photos = checkIns.flatMap(\.photoFiles).count
        SectionCard("Found in the chat") {
            countRow("Past check-ins", checkIns.count)
            CardDivider()
            countRow("Coach replies", model.newReplies.count)
            CardDivider()
            countRow("Check-in photos", photos)
            if model.alreadySeen > 0 {
                CardDivider()
                countRow("Already imported", model.alreadySeen)
            }
            CardDivider()
            countRow("Other messages, left out", model.leftOut)
        }
        if let first = checkIns.first, let last = checkIns.last {
            SectionCard("Check-ins") {
                Text("\(Format.shortDate(first.sentAt)) to \(Format.shortDate(last.sentAt))").font(.subheadline).monospacedDigit().foregroundStyle(Theme.navy)
                if photos == 0 {
                    Text("No photos in this export. Export with Attach Media to bring them in.").font(.footnote).secondaryText()
                }
            }
        } else if model.alreadySeen == 0 {
            SectionCard("No check-ins found") {
                Text("None of your messages match your coach's form. Check you picked yourself above.").font(.subheadline).secondaryText()
            }
        }
    }

    @ViewBuilder private func done(_ model: ChatImportModel) -> some View {
        SectionCard("Imported") {
            Text("\(model.added?.checkIns ?? 0) check-ins and \(model.added?.coachMessages ?? 0) coach replies added.")
                .font(.body).monospacedDigit().foregroundStyle(Theme.navy)
            Text("Trends are on History → Check-ins, your coach's replies on History → Plan.").font(.footnote).secondaryText()
        }
    }

    private func countRow(_ title: String, _ count: Int) -> some View {
        HStack {
            Text(title).font(.body).foregroundStyle(Theme.navy)
            Spacer()
            Text("\(count)").font(.body.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.navy)
        }
    }

    @ViewBuilder private func footer(_ model: ChatImportModel) -> some View {
        switch model.step {
        case .start:
            Button("Choose the export") { showPicker = true }
                .buttonStyle(.setechoPrimary)
                .disabled(store.currentTemplate == nil)
        case .whoIsWho:
            Button("Continue") { model.review() }
                .buttonStyle(.setechoPrimary)
                .disabled(model.athlete == nil || model.coach == nil || model.athlete == model.coach)
        case .review:
            let count = model.newCheckIns.count + model.newReplies.count
            Button(count == 0 ? "Nothing new to import" : "Import") { model.commit() }
                .buttonStyle(.setechoPrimary)
                .disabled(count == 0)
        case .done:
            Button("Done") { dismiss() }.buttonStyle(.setechoPrimary)
        }
    }
}
