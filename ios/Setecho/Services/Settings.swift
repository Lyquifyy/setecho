import Foundation
import Observation

/// The few things only the athlete knows (HANDOFF.md §7 table): the assigned cardio protocol,
/// the show date, which weekdays the program schedules lifting, and the collage layout.
@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    var cardioProtocol: String { didSet { defaults.set(cardioProtocol, forKey: "cardioProtocol") } }
    /// yyyy-MM-dd, or empty when not in prep.
    var showDate: String { didSet { defaults.set(showDate, forKey: "showDate") } }
    /// Calendar weekdays (1 = Sunday … 7 = Saturday) the program schedules lifting on.
    var trainingWeekdays: Set<Int> { didSet { defaults.set(Array(trainingWeekdays).sorted(), forKey: "trainingWeekdays") } }
    var collageLayout: PhotoAlign.CollageLayout { didSet { defaults.set(collageLayout.rawValue, forKey: "collageLayout") } }
    var useSevenDayAverageWeight: Bool { didSet { defaults.set(useSevenDayAverageWeight, forKey: "useSevenDayAverageWeight") } }
    /// The coach's cues play before their exercise in a session. On by default (HANDOFF.md §13).
    var coachVoiceInSessions: Bool { didSet { defaults.set(coachVoiceInSessions, forKey: "coachVoiceInSessions") } }
    /// The voice Setecho speaks with everywhere; empty means the best installed voice, premium first.
    var voiceIdentifier: String { didSet { defaults.set(voiceIdentifier, forKey: "voiceIdentifier") } }
    /// Rate, pitch, warmth and clarity, saved per voice identifier (Settings → Voice).
    var voiceTones: [String: VoiceTone] {
        didSet { if let data = try? JSONEncoder().encode(voiceTones) { defaults.set(data, forKey: "voiceTones") } }
    }
    /// The rate slider from before tones were per voice: the starting rate for a voice not tuned yet.
    private let legacyRate: Double?

    /// The tone for one voice: what he set, or the defaults.
    func tone(for voiceId: String) -> VoiceTone {
        voiceTones[voiceId] ?? VoiceTone(rate: legacyRate ?? SpokenText.defaultRate)
    }

    func setTone(_ tone: VoiceTone, for voiceId: String) { voiceTones[voiceId] = tone.clamped }
    /// Next-set suggestions (P4). On by default; only with a confirmed coach's rule.
    var nextSetSuggestions: Bool { didSet { defaults.set(nextSetSuggestions, forKey: "nextSetSuggestions") } }
    /// Settings → "Start holds automatically": a hold starts itself after "Three, two, one" (HANDOFF.md §7, Add-ons).
    var autoStartHolds: Bool { didSet { defaults.set(autoStartHolds, forKey: "autoStartHolds") } }
    /// Settings → "Machine-taken help": his options when a machine's taken. Off, his own swaps still work and are logged.
    var machineTakenHelp: Bool { didSet { defaults.set(machineTakenHelp, forKey: "machineTakenHelp") } }
    /// "How a session works" has been shown once, before the first session (`SessionIntroView`).
    var hasSeenSessionIntro: Bool { didSet { defaults.set(hasSeenSessionIntro, forKey: "hasSeenSessionIntro") } }
    /// What the athlete can load (§13): barbell 5 lb, dumbbells 5 lb, machines from here.
    var barbellStepLb: Double { didSet { defaults.set(barbellStepLb, forKey: "barbellStepLb") } }
    var dumbbellStepLb: Double { didSet { defaults.set(dumbbellStepLb, forKey: "dumbbellStepLb") } }
    var machineStepLb: Double { didSet { defaults.set(machineStepLb, forKey: "machineStepLb") } }
    /// The spotter uses it sparingly; never sent anywhere but the line request.
    var athleteFirstName: String { didSet { defaults.set(athleteFirstName, forKey: "athleteFirstName") } }
    /// On a seven-day cycle, the weekday Day 1 falls on (1 = Sunday … 7 = Saturday). Monday by default.
    var cycleFirstWeekday: Int { didSet { defaults.set(cycleFirstWeekday, forKey: "cycleFirstWeekday") } }
    /// Rehearsal mode on Review and send: every step goes to the athlete's own WhatsApp chat.
    var rehearsalMode: Bool { didSet { defaults.set(rehearsalMode, forKey: "rehearsalMode") } }
    /// The athlete's own WhatsApp number, digits only, for rehearsal mode. Never sent anywhere else.
    var ownWhatsAppNumber: String { didSet { defaults.set(ownWhatsAppNumber, forKey: "ownWhatsAppNumber") } }
    /// Filming mode (off): save every spoken line and utterance with one clock, plus captions.
    var filmingMode: Bool { didSet { defaults.set(filmingMode, forKey: "filmingMode") } }
    /// Developer tools (off): Settings → Developer, plus the Facts link on the Check-in tab.
    var developerTools: Bool { didSet { defaults.set(developerTools, forKey: "developerTools") } }
    /// iOS 26 high-quality AirPods recording (HANDOFF.md §7, Hearing him in a gym): on by default
    /// since the Oct 28 gym test (the phone's mic on a tripod 2-3 m away missed half of what he said).
    /// Off: AirPods are output only, over A2DP, and the DJI receiver or the iPhone mic records. A
    /// plugged-in external mic wins either way. A change clears an earlier fallback.
    var useAirPodsMic: Bool {
        didSet {
            defaults.set(useAirPodsMic, forKey: "useAirPodsMic")
            Task { @MainActor in AirPodsMic.shared.reset() }
        }
    }
    /// Settings → "Start sets from the camera" (off): any movement in frame starts a set, for an empty
    /// home gym. Off, a set starts only after he arms it by voice ("go"), and the camera follows only
    /// him (HANDOFF.md §7, Sets start on his word).
    var cameraStartsSets: Bool { didSet { defaults.set(cameraStartsSets, forKey: "cameraStartsSets") } }
    /// Settings → "Camera faces you" (off until SAM's count is measured front against back): the
    /// front camera, so the screen faces him from the bench (HANDOFF.md §7, Built for not looking).
    var frontCameraInSessions: Bool { didSet { defaults.set(frontCameraInSessions, forKey: "frontCameraInSessions") } }
    /// Developer → "Apple voice processing" (off until the gym data says it hears more): noise
    /// suppression and gain control on the session mic, recorded with every utterance.
    var voiceProcessing: Bool { didSet { defaults.set(voiceProcessing, forKey: "voiceProcessing") } }
    /// Sessions started (rehearsals don't count): the spoken intro before the first, and "Say go
    /// when you lift." at the end of each rest for the first three.
    var sessionsStarted: Int { didSet { defaults.set(sessionsStarted, forKey: "sessionsStarted") } }
    /// When the due-day notification fires ("06:30"); opening the app from it starts the morning flow.
    var checkInWakeTime: String { didSet { defaults.set(checkInWakeTime, forKey: "checkInWakeTime") } }
    /// The day (DayKey) Check-in morning last started itself, so it starts once per due day.
    var lastMorningAutoStart: String { didSet { defaults.set(lastMorningAutoStart, forKey: "lastMorningAutoStart") } }

    var loadSteps: RuleEngine.LoadSteps {
        RuleEngine.LoadSteps(barbell: barbellStepLb, dumbbell: dumbbellStepLb, machine: machineStepLb, cable: machineStepLb)
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        cardioProtocol = defaults.string(forKey: "cardioProtocol") ?? ""
        showDate = defaults.string(forKey: "showDate") ?? ""
        trainingWeekdays = Set(defaults.array(forKey: "trainingWeekdays") as? [Int] ?? [])
        collageLayout = PhotoAlign.CollageLayout(rawValue: defaults.string(forKey: "collageLayout") ?? "") ?? .grid2x2
        useSevenDayAverageWeight = defaults.bool(forKey: "useSevenDayAverageWeight")
        coachVoiceInSessions = defaults.object(forKey: "coachVoiceInSessions") as? Bool ?? true
        voiceIdentifier = defaults.string(forKey: "voiceIdentifier") ?? ""
        legacyRate = defaults.object(forKey: "voiceRate") as? Double
        voiceTones = (defaults.data(forKey: "voiceTones")).flatMap { try? JSONDecoder().decode([String: VoiceTone].self, from: $0) } ?? [:]
        nextSetSuggestions = defaults.object(forKey: "nextSetSuggestions") as? Bool ?? true
        autoStartHolds = defaults.object(forKey: "autoStartHolds") as? Bool ?? false
        machineTakenHelp = defaults.object(forKey: "machineTakenHelp") as? Bool ?? true
        hasSeenSessionIntro = defaults.bool(forKey: "hasSeenSessionIntro")
        barbellStepLb = defaults.object(forKey: "barbellStepLb") as? Double ?? 5
        dumbbellStepLb = defaults.object(forKey: "dumbbellStepLb") as? Double ?? 5
        machineStepLb = defaults.object(forKey: "machineStepLb") as? Double ?? 10
        athleteFirstName = defaults.string(forKey: "athleteFirstName") ?? "Zander"
        cycleFirstWeekday = defaults.object(forKey: "cycleFirstWeekday") as? Int ?? 2
        rehearsalMode = defaults.bool(forKey: "rehearsalMode")
        ownWhatsAppNumber = defaults.string(forKey: "ownWhatsAppNumber") ?? ""
        filmingMode = defaults.bool(forKey: "filmingMode")
        developerTools = defaults.bool(forKey: "developerTools")
        useAirPodsMic = defaults.object(forKey: "useAirPodsMic") as? Bool ?? true
        cameraStartsSets = defaults.bool(forKey: "cameraStartsSets")
        voiceProcessing = defaults.bool(forKey: "voiceProcessing")
        frontCameraInSessions = defaults.bool(forKey: "frontCameraInSessions")
        sessionsStarted = defaults.integer(forKey: "sessionsStarted")
        checkInWakeTime = defaults.string(forKey: "checkInWakeTime") ?? "06:30"
        lastMorningAutoStart = defaults.string(forKey: "lastMorningAutoStart") ?? ""
    }

    var showDateOrNil: String? { showDate.trimmingCharacters(in: .whitespaces).isEmpty ? nil : showDate }
}
