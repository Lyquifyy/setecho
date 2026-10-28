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

    /// A weight he said himself this morning counts as done without a confirmation.
    private func spokenWeight(draft: CheckInDraft?) -> Bool {
        guard let weightField, let answer = draft?.answers.first(where: { $0.fieldId == weightField.id }) else { return false }
        return answer.provenance.contains { $0.source.hasPrefix("You said") }
    }

    func isAnswered(_ field: FieldSpec?, draft: CheckInDraft?) -> Bool {
        guard let field, let answer = draft?.answers.first(where: { $0.fieldId == field.id }) else { return false }
        return answer.state == .filled || answer.state == .confirmed
    }

    /// Where to pick up: the first step with something still pending. The weight is done only once
    /// he confirms Apple Health's number or says his own; a value filled from data is offered first.
    func nextStep(draft: CheckInDraft?, photosTakenToday: Bool) -> CheckInMorningStep {
        if let weightField {
            let state = draft?.answers.first { $0.fieldId == weightField.id }?.state
            if state != .confirmed, !(state == .filled && spokenWeight(draft: draft)) { return .weight }
        }
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

    /// The values filled from Apple Health and the log that he has not heard (Oct 28: steps went out
    /// without a word). Short ones only; the weight has its own step, and a long text is on the screen.
    func readBackFields(draft: CheckInDraft?) -> [(field: FieldSpec, answer: FieldAnswer)] {
        template.orderedFields.compactMap { field in
            guard field.source.type != .voice, field.source.type != .photo, field.id != weightField?.id,
                  let answer = draft?.answers.first(where: { $0.fieldId == field.id }),
                  answer.state == .filled, !answer.text.isEmpty, answer.text.count <= 40
            else { return nil }
            return (field, answer)
        }
    }

    /// "From your data: average daily steps, 9.4k. Training consistency, 100%. Sound right?"
    static func readBackLine(_ items: [(field: FieldSpec, answer: FieldAnswer)]) -> String {
        let parts = items.map { "\(WrapUpModel.shortLabel([$0.field]).capitalizedFirst), \($0.answer.text)" }
        return "From your data: " + parts.joined(separator: ". ") + ". Sound right?"
    }

    /// The field he named ("steps", "the training one"), among the ones just read back.
    func field(named transcript: String, among ids: [String]) -> FieldSpec? {
        let said = transcript.lowercased()
        let candidates = template.fields.filter { ids.contains($0.id) }
        if let exact = candidates.first(where: { said.contains(WrapUpModel.shortLabel([$0])) }) { return exact }
        return candidates.first { field in
            WrapUpModel.shortLabel([field]).split(separator: " ").contains { word in word.count > 3 && said.contains(word) }
        }
    }

    /// The notes field a question for the coach lands in ("Additional notes or concerns").
    var notesField: FieldSpec? {
        template.orderedFields.first { $0.id.contains("additional_notes") } ?? template.orderedFields.last { $0.source.type == .voice && $0.kind == .text }
    }

    static let yesWords: Set<String> = ["yes", "yeah", "yep", "yup", "correct", "right", "sure", "that's right", "thats right", "confirm", "confirmed",
                                        "use that", "use it", "use that one", "that's it", "thats it", "that's fine", "sounds good", "looks good",
                                        "ok", "okay", "good", "yes please", "yeah that's right", "all good"]
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
    /// Speech that arrived while a turn was in flight, read when that turn comes to nothing.
    private var pendingUtterance: VoiceDetector.Utterance?
    /// The data read back before review: a yes confirms them all, a name or "change steps" asks that one.
    private(set) var dataReadBack: [String]?
    private var dataReadBackAsked = false
    private var awaitingWhichOne: [String]?
    /// Apple Health's weigh-in on offer: a yes takes it, a number replaces it, a no asks for the reading.
    private(set) var offeredWeight: String?
    private(set) var questionIndex = 0
    /// A fresh rehearsal: today's photo set is set aside until a new one is taken.
    private var ignorePhotosToday = false
    private let fresh: Bool
    private let openedAt = Date.now

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

    init(coordinator: CheckInCoordinator, store: Store, api: APIClient = APIClient(), fresh: Bool = false,
         speak: ((String) async -> Void)? = nil) {
        self.coordinator = coordinator
        self.fresh = fresh
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
        guard !ignorePhotosToday, let set = store.lastPhotoSet else { return false }
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
        TurnTimings.shared.opened()
        Task { [api] in _ = try? await api.health() } // warm the backend before the first turn
        if fresh {
            coordinator.resetSpokenAnswers()
            ignorePhotosToday = true
        }
        // The draft (Apple Health, the log, Spark for the notes) takes seconds: build it under the
        // introduction, which needs none of it, so the voice is heard the moment the screen opens.
        let draft = Task { [coordinator] in if coordinator.draft == nil { await coordinator.buildDraft() } }
        await natural.prepare()
        await natural.warm([intro])
        TurnTimings.shared.stage("voice")
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
        TurnTimings.shared.stage("intro")
        await say(intro)
        if coordinator.draft == nil { status = "Reading Apple Health and the training log…" }
        await draft.value
        TurnTimings.shared.stage("draft")
        await coordinator.refreshWeightToday()
        if let known = coordinator.weightTodayText { await natural.warm([Self.weightOffer(known)], within: .seconds(1)) }
        status = nil
        pregenerate()
        await resume(opening: true)
        TurnTimings.shared.stage("first question")
    }

    /// The app left the front (the screen locked, a call): nothing plays or listens until it is back.
    func enterBackground() {
        silenceTask?.cancel()
        realtime.cancel()
        audio.stopListening()
        natural.stop()
        isListening = false
        if !isDone { isPaused = true }
    }

    /// Back in front: listen again and pick up at the current step. The photo session and review
    /// handle their own return.
    func enterForeground() async {
        guard !showPhotos, !showReview, !isDone, isPaused else { return }
        audio.startListening()
        await resume()
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
                // Today's weigh-in is in Apple Health: offer it; he can say the number instead.
                await offerWeight(known)
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
            let items = flow.readBackFields(draft: draft)
            if !items.isEmpty, !dataReadBackAsked {
                dataReadBackAsked = true
                dataReadBack = items.map(\.field.id)
                await ask(CheckInMorningFlow.readBackLine(items))
                return
            }
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
        // A turn is in flight (often a bump or the dog): keep what he says now and read it next,
        // instead of dropping it (Oct 28: "it didn't hear me the first time").
        guard !busy else {
            pendingUtterance = utterance
            TurnTimings.shared.heard(.queued)
            return
        }
        busy = true
        let answered = await runTurn(utterance)
        busy = false
        if let next = pendingUtterance {
            pendingUtterance = nil
            if !answered { await handle(next) }
        }
    }

    /// One utterance to one turn. False when nothing usable came of it (no words, or unclear with
    /// more speech waiting), so a waiting utterance is read instead.
    private func runTurn(_ utterance: VoiceDetector.Utterance) async -> Bool {
        let pcm = Resample.toInt16Mono(utterance.samples, from: utterance.sampleRate, to: 16_000)
        guard pcm.count > 16_000 / 4 else {
            realtime.cancel()
            TurnTimings.shared.heard(.tooShort)
            return false
        }
        TurnTimings.shared.heard(.turn)
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
            let hasWords = response.transcript.contains { $0.isLetter || $0.isNumber }
            if !hasWords {
                TurnTimings.shared.heard(.noWords)
                // A short sound with no words was not him. A long one probably was: say so.
                if utterance.seconds >= 1.2, pendingUtterance == nil {
                    await say("Sorry, I didn't catch that.")
                }
                isListening = true
                return false
            }
            if response.intent == .unclear, pendingUtterance != nil {
                TurnTimings.shared.unclear(response.unclearReason)
                return false
            }
            await apply(response)
            return true
        } catch {
            status = error.userMessage
            isListening = true
            return false
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
        if let ids = dataReadBack ?? awaitingWhichOne {
            let named = flow.field(named: response.transcript, among: ids)
            if dataReadBack != nil, CheckInMorningFlow.isYes(response.transcript) {
                for id in ids { coordinator.confirm(id) }
                dataReadBack = nil
                echo = "From your data → confirmed"
                await say("Got it.")
                await resume()
                return
            }
            if dataReadBack != nil, CheckInMorningFlow.isNo(response.transcript), named == nil {
                dataReadBack = nil
                awaitingWhichOne = ids
                await ask("Which one should change?")
                return
            }
            if let named, response.intent != .answer && response.intent != .correction {
                dataReadBack = nil
                awaitingWhichOne = nil
                await change(named.id)
                return
            }
            dataReadBack = nil
            awaitingWhichOne = nil
        }
        if step == .weight, let known = offeredWeight {
            if CheckInMorningFlow.isYes(response.transcript) {
                offeredWeight = nil
                if let field = flow.weightField {
                    coordinator.set(field.id, text: known, state: .confirmed,
                                    provenance: [Provenance(source: "Apple Health", detail: "This morning's weigh-in, \(known) lb")])
                }
                echo = "Weight → \(known) lb · Apple Health"
                await say("Got it.")
                await resume()
                return
            }
            if CheckInMorningFlow.isNo(response.transcript) {
                offeredWeight = nil
                awaitingWeightReading = true
                await ask("What did it say?")
                return
            }
            if response.intent == .answer || response.intent == .correction, !response.answers.isEmpty { offeredWeight = nil }
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
        case .change:
            // The field to ask again, picked by code: it goes back to missing and its question comes next.
            if let id = response.changeFieldId, flow.template.fields.contains(where: { $0.id == id }) {
                await change(id)
            } else {
                await ask(response.reply.isEmpty ? "Which one do you want to change?" : response.reply)
            }
        case .chitchat:
            await say(response.reply)
            isListening = true
        case .unclear:
            TurnTimings.shared.unclear(response.unclearReason)
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
                await offerWeight(known)
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

    /// Ask one field again: it goes back to unanswered and its question is next.
    private func change(_ id: String) async {
        coordinator.set(id, text: "", state: .missing)
        if let index = questionGroups.firstIndex(where: { $0.contains { $0.id == id } }) {
            step = .questions
            questionIndex = index
            echo = "\(label(for: id)) → asked again"
            await ask("\(label(for: id)). What should it say?")
        } else {
            await resume()
        }
    }

    /// "Apple Health has 180.8. Use that, or tell me the number." (Oct 27 rehearsal: he wants to say it.)
    private func offerWeight(_ known: String) async {
        offeredWeight = known
        awaitingWeightReading = false
        await ask(Self.weightOffer(known))
    }

    static func weightOffer(_ known: String) -> String { "Apple Health has \(known). Use that, or tell me the number." }

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
        if let set = store.lastPhotoSet, Calendar.current.isDateInToday(set.takenAt), set.takenAt > openedAt || !ignorePhotosToday {
            ignorePhotosToday = false
            coordinator.attachPhotoSet(set.id)
            await say("Got the photos.")
        }
        // Dismissed because the app left the front: the return to the front picks the step up.
        guard !isPaused else { return }
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
