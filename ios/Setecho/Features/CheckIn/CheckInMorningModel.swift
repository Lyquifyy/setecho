import Foundation
import Observation

/// The steps of Check-in morning, fixed in code, in this order (HANDOFF.md §7, Check-in morning).
enum CheckInMorningStep: Int, CaseIterable, Equatable {
    case weight, glucose, photos, questions, review

    var title: String {
        switch self {
        case .weight: "Weight"
        case .glucose: "Glucose"
        case .photos: "Photos"
        case .questions: "Questions"
        case .review: "Review"
        }
    }

    var wire: String {
        switch self {
        case .weight: "weight"
        case .glucose: "glucose"
        case .photos: "photos"
        case .questions: "questions"
        case .review: "review"
        }
    }
}

/// What the conversation asks next, derived from the draft every time so the check-in resumes
/// anywhere: reopening picks up at the next pending step and field.
struct CheckInMorningFlow: Equatable {
    let template: CheckInTemplate

    var weightField: FieldSpec? { template.fields.first { $0.source.key == .currentWeight } }
    var glucoseField: FieldSpec? {
        template.orderedFields.first { $0.source.type == .voice && $0.label.lowercased().contains("glucose") }
    }

    /// The coach's questions in his order: every voice or drafted field except weight, glucose and
    /// the photos, with the three tape measurements as one question. A drafted field is read back
    /// for a yes.
    func questionGroups(draft: CheckInDraft?) -> [[FieldSpec]] {
        let byId = Dictionary(uniqueKeysWithValues: (draft?.answers ?? []).map { ($0.fieldId, $0) })
        var groups: [[FieldSpec]] = []
        var measurements: [FieldSpec] = []
        for field in template.orderedFields where field.id != weightField?.id && field.id != glucoseField?.id {
            guard field.source.type != .photo else { continue }
            let state = byId[field.id]?.state ?? .missing
            let asks = field.source.type == .voice || state == .missing || state == .drafted
            guard asks, state == .missing || state == .drafted else { continue }
            if field.kind == .measurement, field.source.type == .voice {
                measurements.append(field)
            } else {
                groups.append([field])
            }
        }
        if !measurements.isEmpty { groups.append(measurements) }
        return groups
    }

    func isAnswered(_ field: FieldSpec?, draft: CheckInDraft?) -> Bool {
        guard let field, let answer = draft?.answers.first(where: { $0.fieldId == field.id }) else { return false }
        return answer.state == .filled || answer.state == .confirmed
    }

    /// Where to pick up: the first step with something still pending.
    func nextStep(draft: CheckInDraft?, photosTakenToday: Bool) -> CheckInMorningStep {
        if weightField != nil, !isAnswered(weightField, draft: draft) { return .weight }
        if glucoseField != nil, !isAnswered(glucoseField, draft: draft) { return .glucose }
        if !photosTakenToday { return .photos }
        if !questionGroups(draft: draft).isEmpty { return .questions }
        return .review
    }

    /// "Energy levels, 1 to 10?"; a drafted field reads its value back: "Last refeed, 10/24/26?"
    func prompt(for group: [FieldSpec], draft: CheckInDraft?) -> String {
        if group.count == 1, let answer = draft?.answers.first(where: { $0.fieldId == group[0].id }), answer.state == .drafted, !answer.text.isEmpty {
            return "\(WrapUpModel.shortLabel(group).capitalizedFirst), \(answer.text)?"
        }
        return WrapUpModel.question(for: group)
    }

    /// The notes field a question for the coach lands in ("Additional notes or concerns").
    var notesField: FieldSpec? {
        template.orderedFields.first { $0.id.contains("additional_notes") } ?? template.orderedFields.last { $0.source.type == .voice && $0.kind == .text }
    }

    static let yesWords: Set<String> = ["yes", "yeah", "yep", "yup", "correct", "right", "sure", "that's right", "thats right", "confirm", "confirmed"]
    static let noWords: Set<String> = ["no", "nope", "nah", "wrong", "not quite", "no that's wrong"]

    /// The opening line (Oct 27 rehearsal): who it is for, which check-in, and what is coming. Every
    /// word is fixed or computed here; the name is the athlete's own first name from Settings.
    static func intro(firstName: String, dueDay: String, isDueMorning: Bool) -> String {
        let name = firstName.trimmingCharacters(in: .whitespaces)
        let greeting = name.isEmpty ? "Morning." : "Morning, \(name)."
        let which = isDueMorning ? "Your \(dueDay) check-in" : "A rehearsal of your \(dueDay) check-in"
        return "\(greeting) \(which): weight, glucose, four photos, then the coach's questions."
    }

    static func isYes(_ transcript: String) -> Bool { yesWords.contains(normalize(transcript)) }
    static func isNo(_ transcript: String) -> Bool { noWords.contains(normalize(transcript)) }

    private static func normalize(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Check-in morning as one conversation (HANDOFF.md §7): weight, glucose, photos, the coach's
/// questions, then review. Every utterance goes to /checkin/turn; the phone applies the answers,
/// speaks the reply and picks the next question itself. Spark understands; code decides.
@MainActor
@Observable
final class CheckInMorningModel {
    private(set) var step: CheckInMorningStep = .weight
    private(set) var question: String = ""
    private(set) var lastWords: String?
    private(set) var reply: String?
    private(set) var echo: String?
    private(set) var isListening = false
    private(set) var isPaused = false
    private(set) var isDone = false
    private(set) var status: String?
    /// The photo session runs full-screen, then the conversation carries on.
    var showPhotos = false
    /// Review and send, the one tap of the morning.
    var showReview = false
    private(set) var pendingForCoach: String?
    private(set) var awaitingWeightReading = false
    private(set) var questionIndex = 0

    let coordinator: CheckInCoordinator
    let flow: CheckInMorningFlow
    let audio: AudioService
    private let api: APIClient
    private let store: Store
    private var busy = false
    private var silenceTask: Task<Void, Never>?
    /// The voice: injectable so the conversation can be tested without a synthesizer.
    var speak: (String) async -> Void

    static let silenceMinutes: TimeInterval = 10 * 60

    /// The natural voice when the backend has one configured; the system voice otherwise, and for
    /// any line whose audio does not arrive within 700 ms (HANDOFF.md §9, block 1).
    let natural: NaturalVoiceSpeaker
    /// Filming mode: every line and utterance saved with one clock, off the speaking path.
    private(set) var filming: FilmingRecorder?
    /// Realtime transcription: opened the moment speech starts; file mode is the fallback.
    let realtime = RealtimeTranscriber()
    /// The slate flash, shown by the view for a moment.
    private(set) var showSlate = false

    init(coordinator: CheckInCoordinator, store: Store, api: APIClient = APIClient(), speak: ((String) async -> Void)? = nil) {
        self.coordinator = coordinator
        self.store = store
        self.api = api
        self.flow = CheckInMorningFlow(template: coordinator.template ?? CheckInTemplate(fields: [], carriedBlocks: []))
        let audio = AudioService()
        self.audio = audio
        let natural = NaturalVoiceSpeaker(api: api, fallback: audio, cacheDirectory: store.mediaDirectory.appendingPathComponent("voice", isDirectory: true))
        self.natural = natural
        let filming = Settings.shared.filmingMode ? FilmingRecorder(root: store.mediaDirectory, kind: "checkin") : nil
        self.filming = filming
        self.speak = speak ?? { text in
            filming?.spoke(text, audio: natural.cachedAudio(for: text), voice: AudioService.preferredVoice())
            await natural.speak(text)
            TurnTimings.shared.firstAudio()
        }
    }

    /// The coach's questions and the fixed lines, generated once and cached by a text hash.
    private func pregenerate() {
        var lines = ["Step on the scale, and tell me when you're off.", "What did it say?", "Fasted glucose?",
                     "Set up your tripod for photos, and tell me when you're ready.", "Got the photos.",
                     "That's everything. Want me to read it back, or open it to send?", "No worries, just tell me whenever you're ready.",
                     "Welcome back.", "Sorry, say that again?", "Skipped.", "Got it.", "Added to your notes.", "Okay, leaving it out.",
                     "Take your time.", "What should it say?"]
        lines += questionGroups.map { flow.prompt(for: $0, draft: draft) }
        natural.pregenerate([intro] + lines)
    }

    var stepIndex: Int { step.rawValue }
    private var draft: CheckInDraft? { coordinator.draft }
    private var photosTakenToday: Bool {
        guard let set = store.lastPhotoSet else { return false }
        return Calendar.current.isDateInToday(set.takenAt)
    }
    var questionGroups: [[FieldSpec]] { flow.questionGroups(draft: draft) }

    /// The introduction for this morning, from Settings and the schedule.
    var intro: String {
        let schedule = CheckInSchedule(plan: store.plan, lastSentAt: store.lastSentCheckIn?.sentAt)
        let dueDay = schedule.nextDue(from: .now).formatted(.dateTime.weekday(.wide))
        return CheckInMorningFlow.intro(firstName: Settings.shared.athleteFirstName, dueDay: dueDay,
                                        isDueMorning: schedule.isCheckInMorning(on: .now))
    }

    // MARK: Lifecycle

    func start() async {
        Task { [api] in _ = try? await api.health() } // warm the backend before the first turn
        // The draft (Apple Health, the log, Spark for the notes) takes seconds: build it under the
        // introduction, which needs none of it, so the voice is heard the moment the screen opens.
        let draft = Task { [coordinator] in if coordinator.draft == nil { await coordinator.buildDraft() } }
        await natural.prepare()
        await natural.warm([intro])
        if let filming {
            showSlate = true
            filming.slate()
            try? await Task.sleep(for: .milliseconds(300))
            showSlate = false
        }
        _ = await audio.requestMicrophone()
        audio.configure()
        audio.onUtterance = { [weak self] utterance in Task { await self?.handle(utterance) } }
        audio.onSpeechStart = { [weak self] in self?.realtime.start() }
        audio.onLiveSamples = { [weak self] samples, rate in self?.realtime.send(samples, rate: rate) }
        audio.startListening()
        // A beat for the session and the input engine to settle before the first line plays.
        try? await Task.sleep(for: .milliseconds(250))
        await say(intro)
        if coordinator.draft == nil { status = "Reading Apple Health and the training log…" }
        await draft.value
        status = nil
        pregenerate()
        await resume(opening: true)
    }

    func stop() {
        silenceTask?.cancel()
        realtime.cancel()
        audio.stopListening()
        audio.stopSpeaking()
        TurnTimings.shared.write(to: store.mediaDirectory, name: DayKey.string(.now))
    }

    /// Pick up at the next pending step, on start and after the photos or a pause.
    func resume(opening: Bool = false) async {
        isPaused = false
        Reminders.clearWaiting()
        await coordinator.refreshWeightToday()
        step = flow.nextStep(draft: draft, photosTakenToday: photosTakenToday)
        questionIndex = 0
        switch step {
        case .weight:
            if !coordinator.weightMissingToday, let known = coordinator.weightTodayText {
                // Today's weigh-in is already in Apple Health: say it and move on.
                if let field = flow.weightField { coordinator.set(field.id, text: known, state: .filled) }
                await say("\(known), got it.")
                await resume()
                return
            }
            awaitingWeightReading = false
            await ask("Step on the scale, and tell me when you're off.")
        case .glucose:
            await ask("Fasted glucose?")
        case .photos:
            await ask("Set up your tripod for photos, and tell me when you're ready.")
        case .questions:
            await askCurrentQuestion()
        case .review:
            isDone = true
            await ask("That's everything. Want me to read it back, or open it to send?")
        }
    }

    private var currentGroup: [FieldSpec]? {
        let groups = questionGroups
        return groups.indices.contains(questionIndex) ? groups[questionIndex] : nil
    }

    private func askCurrentQuestion() async {
        guard let group = currentGroup else {
            await resume()
            return
        }
        await ask(flow.prompt(for: group, draft: draft))
    }

    private func ask(_ text: String) async {
        question = text
        await say(text)
        isListening = true
        armSilenceTimer()
    }

    private func say(_ text: String) async {
        reply = text
        await speak(text)
    }

    // MARK: Turns

    private func handle(_ utterance: VoiceDetector.Utterance) async {
        guard !busy else { return }
        let pcm = Resample.toInt16Mono(utterance.samples, from: utterance.sampleRate, to: 16_000)
        guard pcm.count > 16_000 / 4 else { return }
        busy = true
        defer { busy = false }
        isListening = false
        TurnTimings.shared.endOfSpeech()
        audio.playTurnEndSound() // a soft sound the moment a turn ends
        filming?.heard(pcm16: pcm, sampleRate: 16_000)
        status = "Hearing that…"
        let wav = WAVFile.data(pcm16: pcm, sampleRate: 16_000)
        do {
            // The words from the realtime stream, if it delivered; else the WAV by file mode.
            let words = await realtime.end()
            TurnTimings.shared.sent()
            let response: TurnResponse
            if let words, !words.isEmpty {
                response = try await api.checkInTurn(transcript: words, context: context())
            } else {
                response = try await api.checkInTurn(wav: wav, context: context())
            }
            TurnTimings.shared.received(response)
            filming?.transcribed(response.transcript)
            status = nil
            await apply(response)
        } catch {
            status = error.localizedDescription
            isListening = true
        }
    }

    /// What the backend needs to read the turn: the step, the field asked, what is pending and answered.
    func context() -> TurnContext {
        let asked: FieldSpec? = switch step {
        case .weight: flow.weightField
        case .glucose: flow.glucoseField
        case .questions: currentGroup?.first
        case .photos, .review: nil
        }
        var pending: [String] = []
        for group in questionGroups {
            for field in group { pending.append(field.id) }
        }
        if let glucose = flow.glucoseField, !flow.isAnswered(glucose, draft: draft) { pending.append(glucose.id) }
        let answered = (draft?.answers ?? []).filter { $0.state == .filled || $0.state == .confirmed }
        return TurnContext(template: flow.template, step: step.wire, askedFieldId: asked?.id, pending: pending,
                           answered: answered, styleExamples: StyleExamples.load(), askedOn: DayKey.string(.now))
    }

    /// Apply one turn: the answers go in the draft (saved after every one), the reply is spoken,
    /// and the next question is the first pending one in the coach's order.
    func apply(_ response: TurnResponse) async {
        lastWords = response.transcript
        armSilenceTimer()
        // A yes or a no to a drafted value, or to "add it to your notes?", is decided here, not by the model.
        if let question = pendingForCoach {
            pendingForCoach = nil
            if CheckInMorningFlow.isYes(response.transcript), let notes = flow.notesField {
                let existing = coordinator.answer(for: notes)?.text ?? ""
                let text = existing.isEmpty ? question : "\(existing) \(question)"
                coordinator.set(notes.id, text: text, state: .filled, provenance: [Provenance(source: "You said · \(DayKey.string(.now))", detail: response.transcript)])
                echo = "Notes → \(question)"
                await say("Added to your notes.")
                await askCurrentQuestion()
                return
            }
            if CheckInMorningFlow.isNo(response.transcript) {
                await say("Okay, leaving it out.")
                await askCurrentQuestion()
                return
            }
        }
        if step == .questions, let group = currentGroup, group.count == 1, let drafted = coordinator.answer(for: group[0]), drafted.state == .drafted {
            if CheckInMorningFlow.isYes(response.transcript) {
                coordinator.confirm(group[0].id)
                echo = "\(WrapUpModel.shortLabel(group).capitalized) → \(drafted.text) · Confirmed"
                questionIndex += 1
                await say("Got it.")
                await askCurrentQuestion()
                return
            }
            if CheckInMorningFlow.isNo(response.transcript) {
                await ask("What should it say?")
                return
            }
        }
        switch response.intent {
        case .pause:
            isPaused = true
            isListening = true
            await say(response.reply.isEmpty ? "No worries, just tell me whenever you're ready." : response.reply)
        case .resume:
            await say(response.reply.isEmpty ? "Welcome back." : response.reply)
            await resume()
        case .ready:
            await ready()
        case .repeat_:
            await ask(question)
        case .skip:
            if step == .questions { questionIndex += 1 }
            await say("Skipped.")
            await advance()
        case .goBack:
            if step == .questions, questionIndex > 0 { questionIndex -= 1 }
            await askCurrentQuestion()
        case .forCoach:
            let asked = response.answers.first?.text ?? response.transcript
            pendingForCoach = asked
            await ask(response.reply.isEmpty ? "That's one for your coach. Want me to add it to your notes?" : response.reply)
        case .answer, .correction:
            coordinator.apply(response.answers)
            let lines: [String] = response.answers.map { answer -> String in
                "\(self.label(for: answer.fieldId)) → \(answer.text) · You said"
            }
            echo = lines.joined(separator: "\n")
            await say(response.reply.isEmpty ? Self.readBack(response.answers, labels: label(for:)) : response.reply)
            if response.intent == .correction {
                isListening = true
                armSilenceTimer()
            } else {
                await advance()
            }
        case .chitchat:
            await say(response.reply)
            isListening = true
        case .unclear:
            await say(response.reply.isEmpty ? "Sorry, say that again?" : response.reply)
            isListening = true
        }
    }

    /// "Tell me when you're off" / "tell me when you're ready": the scale, or the photos.
    private func ready() async {
        switch step {
        case .weight:
            await coordinator.refreshWeightToday()
            if !coordinator.weightMissingToday, let known = coordinator.weightTodayText {
                if let field = flow.weightField { coordinator.set(field.id, text: known, state: .filled) }
                echo = "Weight → \(known) lb · Apple Health"
                await say("\(known), got it.")
                await resume()
            } else {
                awaitingWeightReading = true
                await ask("What did it say?")
            }
        case .photos:
            showPhotos = true
            isListening = false
        case .review:
            showReview = true
        default:
            await say("Go ahead.")
            isListening = true
        }
    }

    /// After an answer: the next pending step or question, by the draft, never by the model.
    private func advance() async {
        if step == .questions {
            // The index moves past what is now answered; a confirmed or filled group drops out of the list.
            let groups = questionGroups
            if questionIndex >= groups.count || groups.isEmpty {
                await resume()
                return
            }
            await askCurrentQuestion()
            return
        }
        await resume()
    }

    /// Back from the photo session: carry on with the questions.
    func photosFinished() async {
        if let set = store.lastPhotoSet, Calendar.current.isDateInToday(set.takenAt) {
            coordinator.attachPhotoSet(set.id)
            await say("Got the photos.")
        }
        await resume()
    }

    /// "Read it back": the answers, in his order.
    func readBack() async {
        guard let template = coordinator.template, let draft = coordinator.draft else { return }
        let lines = template.orderedFields.compactMap { field -> String? in
            guard let a = draft.answers.first(where: { $0.fieldId == field.id }), a.state != .missing, !a.text.isEmpty else { return nil }
            return "\(WrapUpModel.shortLabel([field]).capitalized): \(a.text)."
        }
        await say(lines.joined(separator: " "))
        isListening = true
    }

    private func label(for fieldId: String) -> String {
        guard let field = flow.template.fields.first(where: { $0.id == fieldId }) else { return fieldId }
        return WrapUpModel.shortLabel([field]).capitalized
    }

    static func readBack(_ answers: [FieldAnswer], labels: (String) -> String) -> String {
        answers.map { "\(labels($0.fieldId)), \($0.text)." }.joined(separator: " ")
    }

    // MARK: Silence

    /// Ten minutes of silence: stop listening and send one notification (HANDOFF.md §7, Pause).
    private func armSilenceTimer() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.silenceMinutes))
            guard !Task.isCancelled, let self else { return }
            self.audio.stopListening()
            self.isListening = false
            self.isPaused = true
            Reminders.notifyCheckInWaiting()
        }
    }
}
