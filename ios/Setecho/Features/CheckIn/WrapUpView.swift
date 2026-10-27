import SwiftUI

/// Wrap-up (DESIGN.md): answer the fields data can't, by voice, in about two minutes. One question
/// at a time, spoken and shown, then the listening pulse, the transcript, and auto-advance.
/// Voice: "skip", "go back", "say that again". Ends on Review and send.
struct WrapUpView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    let coordinator: CheckInCoordinator
    @State private var model: WrapUpModel

    init(coordinator: CheckInCoordinator) {
        self.coordinator = coordinator
        _model = State(initialValue: WrapUpModel(coordinator: coordinator))
    }

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            HStack {
                Image("Lockup").renderingMode(.template).resizable().scaledToFit().frame(height: 26).foregroundStyle(Theme.cobalt)
                Spacer()
                Text(model.progressText).font(.hudLabel).monospacedDigit().secondaryText()
            }
            Spacer(minLength: 0)
            if model.isDone {
                Text("That's everything").font(.hudState).foregroundStyle(Theme.navy)
                Text("Review and send is next.").font(.hudLabel).secondaryText()
            } else {
                Text(model.questionText).font(.hudState).foregroundStyle(Theme.navy).multilineTextAlignment(.center)
                if model.isListening { ListeningIndicator() }
                if let transcript = model.transcript {
                    Text("“\(transcript)”").font(.hudLabel).foregroundStyle(Theme.navy).multilineTextAlignment(.center)
                }
                if let status = model.status {
                    Text(status).font(.hudLabel).secondaryText()
                }
            }
            Spacer(minLength: 0)
            Text("Say skip, go back, or say that again").font(.hudLabel).secondaryText()
            Text(model.isDone ? "Done" : "Hold to stop")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 60)
                .background(Theme.cobalt, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: model.isDone ? 0.01 : 1.0) {
                    model.stop()
                    dismiss()
                }
                .accessibilityLabel(model.isDone ? "Done" : "Stop the wrap-up")
        }
        .padding(Theme.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.page.ignoresSafeArea())
        .task { await model.start() }
        .statusBarHidden()
    }
}

@MainActor
@Observable
final class WrapUpModel {
    private(set) var index = 0
    private(set) var transcript: String?
    private(set) var status: String?
    private(set) var isListening = false
    private(set) var isDone = false

    let coordinator: CheckInCoordinator
    let audio = AudioService()
    private let api = APIClient()
    private var questions: [[FieldSpec]]
    private var busy = false

    init(coordinator: CheckInCoordinator) {
        self.coordinator = coordinator
        self.questions = coordinator.questions
    }

    var progressText: String { "\(min(index + 1, max(questions.count, 1))) of \(questions.count)" }

    var questionText: String {
        guard questions.indices.contains(index) else { return "" }
        return Self.question(for: questions[index])
    }

    /// "Energy levels, 1 to 10?" or "Waist, bicep and thigh?"
    static func question(for group: [FieldSpec]) -> String {
        if group.count > 1 {
            let names = group.map { Self.shortName($0.label) }
            return names.dropLast().joined(separator: ", ") + " and \(names.last ?? "")?"
        }
        let field = group[0]
        var text = field.label.trimmingCharacters(in: .whitespaces)
        if let prompt = field.prompt?.lowercased() {
            if prompt.contains("1-10") { text += ", 1 to 10" } else { text += " " + prompt.trimmingCharacters(in: CharacterSet(charactersIn: "()")) }
        }
        return text + "?"
    }

    static func shortName(_ label: String) -> String {
        let lower = label.lowercased()
        for part in ["waist", "bicep", "thigh", "calf", "chest", "hips", "arm"] where lower.contains(part) { return part }
        return label
    }

    func start() async {
        guard !questions.isEmpty else { isDone = true; return }
        _ = await audio.requestMicrophone()
        audio.configure()
        audio.onUtterance = { [weak self] utterance in Task { await self?.handle(utterance) } }
        audio.startListening()
        await ask()
    }

    func stop() {
        audio.stopListening()
        audio.stopSpeaking()
    }

    private func ask() async {
        guard questions.indices.contains(index) else {
            isDone = true
            await audio.speak("That's everything. Review and send is next.")
            audio.stopListening()
            return
        }
        transcript = nil
        status = nil
        isListening = true
        await audio.speak(questionText)
    }

    private func handle(_ utterance: VoiceDetector.Utterance) async {
        guard !busy, !isDone else { return }
        let pcm = Resample.toInt16Mono(utterance.samples, from: utterance.sampleRate, to: 16_000)
        guard pcm.count > 16_000 / 4 else { return }
        busy = true
        defer { busy = false }
        isListening = false
        status = "Hearing that…"
        let wav = WAVFile.data(pcm16: pcm, sampleRate: 16_000)
        do {
            let group = questions[index]
            let response = try await api.checkInAnswer(wav: wav, fields: group, styleExamples: StyleExamples.load(), askedOn: .now)
            transcript = response.transcript
            let control = response.transcript.lowercased()
            if control.contains("say that again") || control.contains("repeat") {
                await ask()
                return
            }
            if control.contains("go back") {
                index = max(0, index - 1)
                await ask()
                return
            }
            if control.hasPrefix("skip") || control == "next" {
                index += 1
                await audio.speak("Skipped.")
                await ask()
                return
            }
            let usable = response.answers.filter { $0.state != .missing }
            guard !usable.isEmpty else {
                status = "Didn't catch that"
                await audio.speak("Didn't catch that. Say it again?")
                isListening = true
                return
            }
            coordinator.apply(response.answers)
            index += 1
            let confirmation = Self.confirmation(for: group, answers: usable)
            let next = questions.indices.contains(index) ? " Next: \(Self.shortLabel(questions[index]))." : ""
            await audio.speak(confirmation + next)
            await ask()
        } catch {
            status = error.localizedDescription
            isListening = true
        }
    }

    /// "Energy 6." / "Waist 31, bicep 16, thigh 24 and three quarters."
    static func confirmation(for group: [FieldSpec], answers: [FieldAnswer]) -> String {
        if group.count > 1 {
            return answers.map { a in
                let name = shortName(group.first { $0.id == a.fieldId }?.label ?? "")
                return "\(name) \(a.text.replacingOccurrences(of: " in", with: ""))"
            }.joined(separator: ", ") + "."
        }
        let label = shortLabel(group)
        let text = answers.first?.text ?? ""
        let head = text.split(separator: ",").first.map(String.init) ?? text
        return "\(label): \(head.replacingOccurrences(of: "/10", with: ""))."
    }

    static func shortLabel(_ group: [FieldSpec]) -> String {
        guard let field = group.first else { return "" }
        if group.count > 1 { return "measurements" }
        var label = field.label.replacingOccurrences(of: "Notes on ", with: "").replacingOccurrences(of: "Notes on", with: "")
        if let paren = label.firstIndex(of: "(") { label = String(label[..<paren]) }
        return label.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
