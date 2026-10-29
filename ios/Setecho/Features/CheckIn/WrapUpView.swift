import SwiftUI

/// Wrap-up (DESIGN.md): answer the fields data can't, by voice, in about two minutes. One question
/// at a time, spoken and shown in the same conversation layout as Check-in morning, with each
/// answer stored under its check. Voice: "skip", "go back", "say that again". Ends on Review and send.
struct WrapUpView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    let coordinator: CheckInCoordinator
    @State private var model: WrapUpModel
    @State private var showReview = false

    init(coordinator: CheckInCoordinator) {
        self.coordinator = coordinator
        _model = State(initialValue: WrapUpModel(coordinator: coordinator))
    }

    var body: some View {
        ConversationScreen(
            eyebrow: model.isDone ? "Wrap-up · done" : "Wrap-up · \(model.progressText)",
            entries: model.transcript,
            phase: model.phase,
            level: model.audio.inputLevel,
            notice: model.status,
            voiceName: AudioService.voiceDescription
        ) {
            if model.isDone {
                Button("Review and send") { showReview = true }.buttonStyle(.setechoPrimary)
                LinkButton(title: "Done", chevron: .none) {
                    model.stop()
                    dismiss()
                }
            } else {
                Text("Say skip, go back, or say that again").font(.hudLabel).secondaryText().multilineTextAlignment(.center)
                HoldButton(title: "Hold to stop", accessibilityHint: "Press and hold. Your answers are saved.") {
                    model.stop()
                    dismiss()
                }
            }
        }
        .task { await model.start() }
        .keepsScreenAwake()
        .fullScreenCover(isPresented: $showReview) {
            NavigationStack { ReviewSendView(coordinator: coordinator) }.environment(store)
        }
        .animation(.snappy(duration: 0.3), value: model.isDone)
    }
}

@MainActor
@Observable
final class WrapUpModel {
    private(set) var index = 0
    private(set) var transcript: [ConversationEntry] = []
    private(set) var lastTranscript: String?
    private(set) var status: String?
    private(set) var isListening = false
    private(set) var isThinking = false
    private(set) var isDone = false

    let coordinator: CheckInCoordinator
    let audio = AudioService()
    private let api = APIClient()
    /// The one voice, with the fixed lines pre-rendered (HANDOFF.md §7).
    let voice: SystemSpeaker
    private var questions: [[FieldSpec]]
    private var busy = false
    private var weightAsked = false
    private var lastAcknowledgment: String?

    init(coordinator: CheckInCoordinator) {
        self.coordinator = coordinator
        self.questions = coordinator.questions
        audio.holdsDucking = true
        self.voice = SystemSpeaker(audio: audio, cacheDirectory: coordinator.store.mediaDirectory.appendingPathComponent("voice", isDirectory: true))
    }

    static let doneLine = "That's everything. Review and send is next."
    private static let fixedLines = [doneLine, "Okay, we'll skip that one.", "Didn't catch that. Say it again?", "Okay.", "Got it.", "Nice."]

    var progressText: String { "\(min(index + 1, max(questions.count, 1))) of \(questions.count)" }

    /// Whose turn it is, for the voice bar.
    var phase: VoicePhase {
        if isDone { return .idle }
        if audio.isSpeaking { return .speaking }
        if isThinking { return .thinking }
        if isListening { return .listening }
        return .idle
    }

    var questionText: String {
        guard questions.indices.contains(index) else { return "" }
        return Self.question(for: questions[index])
    }

    /// The question as it follows in the conversation: the first stands alone, the last says so, the
    /// ones between join on with "and".
    private var bridgedQuestionText: String {
        guard questions.indices.contains(index) else { return "" }
        if index == 0 { return questionText }
        return CheckInMorningFlow.bridged(questionText, index: index, count: questions.count)
    }

    /// Each question the way a person would ask it, from his form's labels (Oct 28: "Energy levels,
    /// 1 to 10?" sounded like a form): "How were your energy levels this week, out of ten?", "How's
    /// your recovery been this week?", "What did the tape say for your waist, bicep and thigh?"
    nonisolated static func question(for group: [FieldSpec]) -> String {
        if group.count == 1, group[0].source.key == .currentWeight { return "What's your weight today?" }
        if group.count > 1 {
            let names = group.map { Self.shortName($0.label) }
            return "What did the tape say for your " + names.dropLast().joined(separator: ", ") + " and \(names.last ?? "")?"
        }
        let field = group[0]
        let label = spokenLabel(field)
        let lower = field.label.lowercased()
        let plural = label.hasSuffix("s") && !label.hasSuffix("ss")
        if lower.contains("additional notes") || lower.contains("concerns") { return "Anything else you want your coach to know?" }
        if lower.hasPrefix("biggest") { return "What was your \(label)?" }
        switch field.kind {
        case .scale10: return "How \(plural ? "were" : "was") your \(label) this week, out of ten?"
        case .text where lower.hasPrefix("notes on"): return plural ? "How have your \(label) been this week?" : "How's your \(label) been this week?"
        case .measurement, .number, .percent: return "What's your \(label)?"
        case .date: return "When was your \(label)?"
        default: return label.capitalizedFirst + "?"
        }
    }

    /// The label as said in a sentence: "notes on recovery" → "recovery", "Date of last refeed or cheat
    /// meal" → "last refeed or cheat meal", "Bicep measurement, flexed" → "bicep measurement, flexed".
    nonisolated static func spokenLabel(_ field: FieldSpec) -> String {
        let label = shortLabel([field])
        return label.hasPrefix("date of ") ? String(label.dropFirst("date of ".count)) : label
    }

    nonisolated static func shortName(_ label: String) -> String {
        let lower = label.lowercased()
        for part in ["waist", "bicep", "thigh", "calf", "chest", "hips", "arm"] where lower.contains(part) { return part }
        return label
    }

    func start() async {
        await coordinator.refreshWeightToday()
        if coordinator.weightMissingToday {
            status = CheckInCoordinator.weightMissingMessage
        }
        guard !questions.isEmpty || coordinator.weightMissingToday else {
            isDone = true
            append(.setecho("Nothing left to answer out loud."))
            return
        }
        var lines = Self.fixedLines + questions.map { Self.question(for: $0) }
        lines += questions.enumerated().map { index, group in
            index == 0 ? Self.question(for: group) : CheckInMorningFlow.bridged(Self.question(for: group), index: index, count: questions.count)
        }
        voice.prerender(lines)
        // The first line is due in a moment: wait briefly for its file.
        await voice.warm(coordinator.weightMissingToday ? [CheckInCoordinator.weightMissingMessage + ". Carrying on."] : [questionText])
        _ = await audio.requestMicrophone()
        audio.configure()
        audio.onUtterance = { [weak self] utterance in Task { await self?.handle(utterance) } }
        audio.startListening()
        if coordinator.weightMissingToday {
            await say(CheckInCoordinator.weightMissingMessage + ". Carrying on.")
        }
        await ask()
    }

    /// If the weigh-in still hasn't arrived by the last question, ask for it (DESIGN.md Wrap-up).
    private func appendWeightQuestionIfStillMissing() async {
        guard !weightAsked else { return }
        weightAsked = true
        await coordinator.refreshWeightToday()
        guard coordinator.weightMissingToday, let field = coordinator.weightField,
              !questions.contains(where: { $0.contains { $0.id == field.id } })
        else { return }
        questions.append([field])
    }

    func stop() {
        audio.stopListening()
        audio.stopSpeaking()
    }

    private func append(_ entry: ConversationEntry) {
        transcript.append(entry)
        if transcript.count > 60 { transcript.removeFirst(transcript.count - 60) }
    }

    private func say(_ text: String) async {
        append(.setecho(text))
        await voice.speak(text)
    }

    /// Ask the current question, plainly or after an acknowledgment in the same breath.
    private func ask(after ack: String? = nil, bridge: Bool = true) async {
        if !questions.indices.contains(index) { await appendWeightQuestionIfStillMissing() }
        guard questions.indices.contains(index) else {
            isDone = true
            if let ack {
                append(.setecho(ack))
                append(.setecho(Self.doneLine))
                await voice.speak(ack + " " + Self.doneLine)
            } else {
                await say(Self.doneLine)
            }
            audio.stopListening()
            return
        }
        status = nil
        let line = bridge ? bridgedQuestionText : questionText
        if let ack, !ack.isEmpty {
            append(.setecho(ack))
            append(.setecho(line))
            await voice.speak(ack + " " + line)
        } else {
            await say(line)
        }
        isListening = true
    }

    private func handle(_ utterance: VoiceDetector.Utterance) async {
        guard !busy, !isDone else { return }
        let pcm = Resample.toInt16Mono(utterance.samples, from: utterance.sampleRate, to: 16_000)
        guard pcm.count > 16_000 / 4 else { return }
        busy = true
        defer { busy = false }
        isListening = false
        isThinking = true
        defer { isThinking = false }
        audio.playTurnEndSound()
        let wav = WAVFile.data(pcm16: pcm, sampleRate: 16_000)
        do {
            let group = questions[index]
            let response = try await api.checkInAnswer(wav: wav, fields: group, styleExamples: StyleExamples.load(), askedOn: .now)
            isThinking = false
            await apply(response, group: group)
        } catch {
            status = error.userMessage
            isListening = true
        }
    }

    /// One answer applied: the control words first, then the fields it fills.
    private func apply(_ response: AnswerResponse, group: [FieldSpec]) async {
        lastTranscript = response.transcript
        if response.transcript.contains(where: { $0.isLetter || $0.isNumber }) { append(.athlete(response.transcript)) }
        let control = response.transcript.lowercased()
        if control.contains("say that again") || control.contains("repeat") {
            await ask(bridge: false)
            return
        }
        if control.contains("go back") {
            index = max(0, index - 1)
            await ask(bridge: false)
            return
        }
        if control.hasPrefix("skip") || control == "next" {
            index += 1
            await ask(after: "Okay, we'll skip that one.")
            return
        }
        let usable = response.answers.filter { $0.state != .missing }
        guard !usable.isEmpty else {
            status = "Didn't catch that"
            await say("Didn't catch that. Say it again?")
            isListening = true
            return
        }
        coordinator.apply(response.answers)
        for answer in usable {
            let field = group.first { $0.id == answer.fieldId }
            append(.answer(label: field.map { Self.shortLabel([$0]).capitalizedFirst } ?? answer.fieldId, value: answer.text,
                           source: answer.provenance.first?.source ?? "You said"))
        }
        index += 1
        await ask(after: acknowledged(Self.confirmation(for: group, answers: usable)))
    }

    /// The confirmation with its "got it" swapped for the acknowledgment in turn, never the same twice.
    private func acknowledged(_ confirmation: String) -> String {
        let ack = SpokenFacts.next(after: lastAcknowledgment, beforeAFact: false)
        guard let swapped = SpokenFacts.reacknowledged(confirmation, with: ack) else { return confirmation }
        lastAcknowledgment = ack
        return swapped
    }

    /// "Got it, 6 for energy." / "Waist 31, bicep 16, thigh 24 and three quarters."
    nonisolated static func confirmation(for group: [FieldSpec], answers: [FieldAnswer]) -> String {
        if group.count > 1 {
            return answers.map { a in
                let name = shortName(group.first { $0.id == a.fieldId }?.label ?? "")
                return "\(name) \(a.text.replacingOccurrences(of: " in", with: ""))"
            }.joined(separator: ", ") + "."
        }
        let label = shortLabel(group)
        let text = answers.first?.text ?? ""
        let head = text.split(separator: ",").first.map(String.init) ?? text
        return "Got it, \(head.replacingOccurrences(of: "/10", with: "")) for \(label)."
    }

    nonisolated static func shortLabel(_ group: [FieldSpec]) -> String {
        guard let field = group.first else { return "" }
        if group.count > 1 { return "measurements" }
        var label = field.label.replacingOccurrences(of: "Notes on ", with: "").replacingOccurrences(of: "Notes on", with: "")
        if let paren = label.firstIndex(of: "(") { label = String(label[..<paren]) }
        return label.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
