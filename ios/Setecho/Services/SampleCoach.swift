import Foundation
import UIKit

/// Sample coach mode (HANDOFF.md §7, Sample coach): a made-up athlete, "Alex", and a made-up coach,
/// so a judge with no coach, no Apple Health data and no WhatsApp sees the whole loop. The program's
/// shape is the backend's cycle fixture (five training days, two rest days, vacuums on waking, abs
/// twice a week), the coach's rules are the synthetic onboarding email, two weeks of sessions, last
/// week's sent check-in, this week's half-filled one, a coach reply waiting, and a week of photos
/// drawn as plain silhouettes. The screen renders (ScreenFixtures) seed from here too, so there is
/// one source of made-up data. Every number is made up; nothing here is anyone's.
///
/// The sample lives in its own store (`SampleCoach.root()`), never the athlete's (`Store.defaultRoot()`).
@MainActor
enum SampleCoach {
    /// The first name the spotter uses while the sample is on.
    static let firstName = "Alex"

    /// Application Support/Setecho-Sample: swapped in for the app's store while the sample is on.
    nonisolated static func root() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Setecho-Sample", isDirectory: true)
    }

    /// Which week the store shows.
    enum Scenario: Hashable {
        /// A training day (Day 1, abs joining), mid-week, the check-in filling itself.
        case trainingDay
        /// The same week with a coach reply to review and a MacroFactor line to update. The app's sample.
        case replyWaiting
        /// Today as the calendar has it, unforced.
        case asToday
    }

    struct FixtureMissing: Error { let name: String }

    /// Anchors the lookup to the app bundle, where Resources/Sample lives, from the app and from the tests.
    private final class Anchor {}

    /// One of the three JSON fixtures in Resources/Sample.
    nonisolated static func url(_ name: String) -> URL? {
        Bundle(for: Anchor.self).url(forResource: name, withExtension: "json")
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        guard let url = url(name) else { throw FixtureMissing(name: name) }
        return try JSONCoding.decoder.decode(T.self, from: Data(contentsOf: url))
    }

    static func program() throws -> Program { try decode(Program.self, "program_cycle") }
    static func template() throws -> CheckInTemplate { try decode(CheckInTemplate.self, "template") }
    static func rules() throws -> RulesImport { try decode(RulesImport.self, "rules_cycle") }

    static let cardioProtocol = "25 minutes of fasted LISS, 2× a week"
    /// Monday to Wednesday, Friday and Saturday, as the cycle fixture runs (Monday is Day 1).
    static let trainingWeekdays: Set<Int> = [2, 3, 4, 6, 7]

    // MARK: Seeding

    private static let calendar = Calendar.current

    /// Fill an empty store with the sample. The app seeds `.replyWaiting` and lands on the first
    /// training day, so "Start session" is there whatever weekday it is opened on.
    static func seed(into store: Store, scenario: Scenario = .replyWaiting, now: Date = .now) throws {
        let program = try program()
        let template = try template()
        store.saveProgram(program, cardioProtocol: cardioProtocol)
        store.setAddOnDays(program.addOns.map { AddOnDays(addOnId: $0.id, dayIds: AddOnPlanner.proposedDays(for: $0, in: program)) })
        store.saveTemplate(template, targets: CheckInTemplate.parsedTargets(template), cardioProtocol: cardioProtocol)
        store.saveRules(try rules())

        for session in sessions(program: program, now: now) { store.upsert(session: session) }
        let photos = try photoSets(in: store.mediaDirectory, now: now)
        for set in photos { store.upsert(photoSet: set) }

        // Last week's check-in went out; this week's is half filled.
        store.upsert(checkIn: sentCheckIn(template: template, photoSetId: photos.first?.id, now: now))
        let schedule = CheckInSchedule(plan: store.plan, lastSentAt: store.lastSentCheckIn?.sentAt)
        let week = schedule.week(endingBefore: schedule.nextDue(from: now))
        store.upsert(checkIn: currentDraft(template: template, week: week, photoSetId: photos.last?.id))

        switch scenario {
        case .trainingDay:
            store.changeDay(to: "w1_day_1", now: now)
        case .replyWaiting:
            store.changeDay(to: program.trainingDays.first?.id ?? "w1_day_1", now: now)
            store.upsert(reply: coachReply(now: now))
            store.addMacroFactorReminders(["Training-day carbs 250 → 225 g"])
        case .asToday:
            break
        }
    }

    /// Loads per exercise: top set, back-off, and the rest-pause or straight-set load.
    private static let loads: [String: (top: Double, back: Double)] = [
        "w1_day_1_incline_db_press": (70, 55), "w1_day_1_flat_machine_press": (180, 140), "w1_day_1_pec_deck": (120, 120),
        "w1_day_1_lateral_raise": (25, 25), "w1_day_2_hack_squat": (270, 215), "w1_day_2_lying_leg_curl": (110, 110),
        "w1_day_2_walking_lunge": (40, 40), "w1_day_2_standing_calf_raise": (180, 180), "w1_day_3_lat_pulldown": (160, 130),
        "w1_day_3_chest_supported_row": (140, 140), "w1_day_3_face_pull": (50, 50), "w1_day_3_barbell_curl": (85, 70),
        "w1_day_5_smith_machine_bench": (205, 165), "w1_day_5_shoulder_press_machine": (130, 130), "w1_day_5_cable_fly": (40, 40),
        "w1_day_5_rope_pushdown": (60, 60), "w1_day_6_romanian_deadlift": (245, 195), "w1_day_6_leg_extension": (150, 150),
        "w1_day_6_seated_calf_raise": (135, 135), "addon_abs_cable_crunch": (70, 70),
    ]

    /// Monday is Day 1, as the cycle runs (Settings → cycle starts Monday).
    private static func dayId(for date: Date) -> String? {
        switch calendar.component(.weekday, from: date) {
        case 2: "w1_day_1"
        case 3: "w1_day_2"
        case 4: "w1_day_3"
        case 6: "w1_day_5"
        case 7: "w1_day_6"
        default: nil
        }
    }

    /// Every training day of the last twelve, before today: the week's loads, 5 lb lighter the week before.
    private static func sessions(program: Program, now: Date) -> [Session] {
        let today = calendar.startOfDay(for: now)
        var result: [Session] = []
        for back in 1...12 {
            guard let date = calendar.date(byAdding: .day, value: -back, to: today), let id = dayId(for: date),
                  let day = program.cycleDays.first(where: { $0.id == id }) else { continue }
            let start = calendar.date(bySettingHour: 18, minute: 10, second: 0, of: date)!
            let lighter = back > 6 ? 5.0 : 0
            let withAbs = id == "w1_day_1" || id == "w1_day_5"
            var exercises = day.exercises
            if withAbs, let abs = program.addOns.first(where: { $0.id == "addon_abs" }) { exercises += abs.exercises }
            var sets: [LoggedSet] = []
            var clock = start.addingTimeInterval(300)
            for exercise in exercises {
                for (index, planned) in exercise.sets.enumerated() {
                    let set = loggedSet(exercise: exercise, planned: planned, index: index, lighter: lighter, at: clock,
                                        flagged: back == 2 && exercise.id.hasSuffix("hack_squat") && index == 0)
                    sets.append(set)
                    clock = set.endedAt.addingTimeInterval(150)
                }
            }
            let notes = back == 1
                ? [VoiceNote(id: UUID(), at: start.addingTimeInterval(1800), transcript: "Left elbow a little cranky on the pulldown.", targetFieldId: "notes_on_recovery")]
                : []
            result.append(Session(id: UUID(), programDayId: id, startedAt: start, endedAt: clock, sets: sets, notes: notes,
                                  addOnIds: withAbs ? ["addon_abs"] : []))
        }
        return result
    }

    private static func loggedSet(exercise: PlannedExercise, planned: PlannedSet, index: Int, lighter: Double, at start: Date, flagged: Bool) -> LoggedSet {
        if let seconds = planned.seconds {
            return LoggedSet(id: UUID(), exerciseId: exercise.id, setIndex: index, loadLb: 0, reps: 0, rpe: nil, seconds: seconds,
                             role: planned.role, startedAt: start, endedAt: start.addingTimeInterval(Double(seconds)), clipFile: nil, edits: [])
        }
        let pair = loads[exercise.id] ?? (0, 0)
        let load: Double
        switch planned.role {
        case .backOff: load = pair.back - lighter
        case .restPause: load = (planned.totalReps != nil && exercise.sets.count > 1 ? (pair.top * 0.8).rounded() : pair.top) - lighter
        default: load = max(0, pair.top - lighter)
        }
        let reps: Int
        if planned.role == .restPause, let total = planned.totalReps {
            reps = total + 1
        } else if let max = planned.repsMax {
            reps = planned.role == .top ? max - 1 : max
        } else {
            reps = planned.reps ?? 10
        }
        // Top sets measured by SAM, the rest counted on the phone or said.
        let count: RepCount
        if planned.role == .top {
            count = RepCount(source: .measured, phone: reps, measured: reps, confidence: 0.84, velocityLossPct: 41, estimatedRIR: 0.5)
        } else if index % 2 == 0 {
            count = RepCount(source: .phone, phone: reps)
        } else {
            count = RepCount(source: .spoken, phone: reps - 1)
        }
        return LoggedSet(id: UUID(), exerciseId: exercise.id, setIndex: index, loadLb: load, reps: reps,
                         rpe: planned.role == .top ? 10 : nil, role: planned.role, flaggedForCoach: flagged, repCount: count,
                         startedAt: start, endedAt: start.addingTimeInterval(Double(reps) * 3.4), clipFile: nil, edits: [])
    }

    // MARK: Check-ins

    private static func answer(_ id: String, _ text: String, _ state: AnswerState, _ source: String, _ detail: String = "") -> FieldAnswer {
        FieldAnswer(fieldId: id, text: text, state: state, provenance: source.isEmpty ? [] : [Provenance(source: source, detail: detail)])
    }

    /// 11 of 23 ready: the data fields filled, three drafted to confirm, three said earlier in the week.
    /// The synthetic Health week below carries the same numbers.
    static func currentAnswers(photoSetReady: Bool) -> [FieldAnswer] {
        [
            answer("weeks_away_from_target_date", "20", .filled, "Show date", "Mar 20, 2027"),
            answer("accuracy_on_plan", "86%", .filled, "MacroFactor via Apple Health", "6 of 7 days within targets"),
            answer("nutrition_consistency", "6 of 7 days on target", .filled, "MacroFactor via Apple Health", "Oct 23–29"),
            answer("training_consistency", "5 of 5 sessions, every set logged", .filled, "Training log", "Mon–Sat"),
            answer("current_cardio_protocol", cardioProtocol, .filled, "Coach's plan", "Plan v3"),
            answer("notes_on_performance", "Incline DB press up to 70 × 7 on the top set, hack squat 270 × 7. Everything else held.", .drafted,
                   "Training log", "Top sets this week"),
            answer("date_of_last_refeed_or_cheat_meal", "Saturday, Oct 24", .drafted, "You said · Sat", "“refeed was saturday”"),
            answer("average_daily_steps", "9,842", .filled, "Apple Health", "Oct 23–29"),
            answer("last_check_in_body_weight", "181.6 lb", .filled, "Last check-in", "Oct 22"),
            answer("current_body_weight", "180.8 lb", .filled, "Withings", "7-day average"),
            answer("notes_on_sleep", "7 h 12 min a night on average; 6 h 20 min Tuesday.", .drafted, "Apple Health", "Oct 23–29"),
            answer("biggest_win_this_week", "Hit the 70s for 7 on incline, first time.", .confirmed, "You said · Wed"),
            answer("energy_levels", "", .missing, ""),
            answer("notes_on_recovery", "", .missing, ""),
            answer("notes_on_digestion", "Good. A bit bloated Tuesday.", .confirmed, "You said · Tue"),
            answer("notes_on_appetite", "", .missing, ""),
            answer("notes_on_stress", "4", .confirmed, "You said · Wed"),
            answer("waist_measurement", "", .missing, ""),
            answer("bicep_measurement_flexed", "", .missing, ""),
            answer("thigh_measurement_flexed", "", .missing, ""),
            answer("fasted_blood_glucose", "", .missing, ""),
            answer("additional_notes_or_concerns", "", .missing, ""),
            answer("check_in_photos_front_right_side_arms_up_back_left_side_arms_up", photoSetReady ? "4 photos" : "", photoSetReady ? .filled : .missing,
                   photoSetReady ? "Photo session" : ""),
        ]
    }

    private static func currentDraft(template: CheckInTemplate, week: (start: Date, end: Date), photoSetId: UUID?) -> CheckInDraft {
        CheckInDraft(id: UUID(), weekStart: week.start, weekEnd: week.end, answers: currentAnswers(photoSetReady: false), photoSetId: nil, sentAt: nil)
    }

    private static func sentCheckIn(template: CheckInTemplate, photoSetId: UUID?, now: Date) -> CheckInDraft {
        let sent = calendar.date(byAdding: .day, value: -7, to: calendar.date(bySettingHour: 8, minute: 42, second: 0, of: now)!)!
        let start = calendar.date(byAdding: .day, value: -7, to: sent)!
        var answers = currentAnswers(photoSetReady: true).map { a -> FieldAnswer in
            var a = a
            if a.state != .filled { a.state = .confirmed }
            if a.text.isEmpty { a.text = "7" }
            return a
        }
        // What was said last week, so History's trends read like a check-in and not a placeholder.
        let said = ["waist_measurement": "31.75 in", "bicep_measurement_flexed": "16.25 in", "thigh_measurement_flexed": "24.5 in",
                    "fasted_blood_glucose": "89", "energy_levels": "7", "notes_on_appetite": "6, hungrier at night",
                    "notes_on_recovery": "Good", "additional_notes_or_concerns": "None this week"]
        for (id, text) in said { if let i = answers.firstIndex(where: { $0.fieldId == id }) { answers[i].text = text } }
        if let i = answers.firstIndex(where: { $0.fieldId == "current_body_weight" }) { answers[i].text = "181.6 lb" }
        if let i = answers.firstIndex(where: { $0.fieldId == "last_check_in_body_weight" }) { answers[i].text = "182.4 lb" }
        return CheckInDraft(id: UUID(), weekStart: start, weekEnd: sent, answers: answers, photoSetId: photoSetId, sentAt: sent)
    }

    // MARK: Coach reply

    private static func coachReply(now: Date) -> CoachReply {
        let words = "Great week. Drop training-day carbs by 25 starting Monday. Swap the walking lunges for Bulgarian split squats, same sets. Add a third cardio session, 25 minutes. And keep pushing that incline."
        return CoachReply(
            id: UUID(), receivedAt: calendar.date(byAdding: .hour, value: -2, to: now)!, kind: .voiceNote, audioFile: nil,
            transcript: words,
            changes: [
                PlanChange(id: "c1", kind: .macroTarget, path: "targets.training.carbsG", label: "Training-day carbs", op: .decrease, amount: 25,
                           before: "250 g", after: "225 g", quote: "Drop training-day carbs by 25 starting Monday", appliesFrom: nextMonday(after: now), approved: true),
                PlanChange(id: "c2", kind: .exerciseSwap, path: "program.day_2.walking_lunge", label: "Walking Lunge", op: .replace, amount: nil,
                           before: "Walking Lunge", after: "Bulgarian split squat", quote: "Swap the walking lunges for Bulgarian split squats, same sets",
                           appliesFrom: nil, approved: true),
                PlanChange(id: "c3", kind: .cardio, path: "cardioProtocol", label: "Cardio", op: .set, amount: 3,
                           before: cardioProtocol, after: "25 minutes of fasted LISS, 3× a week",
                           quote: "Add a third cardio session, 25 minutes", appliesFrom: nil, approved: true),
            ],
            unclear: ["keep pushing that incline"], appliedVersion: nil)
    }

    private static func nextMonday(after now: Date) -> String {
        let next = calendar.nextDate(after: now, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime)!
        return DayKey.string(next)
    }

    /// "Add coach reply" → "Use an example reply": a made-up message with one load change and one swap,
    /// so a judge can watch Muse Spark propose the changes live.
    static let exampleReply = "Nice work this week. Take the hack squat top set up 10 pounds next leg day, same reps. Swap the pec deck for a cable fly, same sets and reps. Cardio stays where it is."

    // MARK: Photos

    /// Two weeks of check-in photos: a plain silhouette per pose, so the screens have real images in them.
    private static func photoSets(in media: URL, now: Date) throws -> [PhotoSet] {
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        var sets: [PhotoSet] = []
        for weeksAgo in [1, 0] {
            let taken = calendar.date(byAdding: .day, value: -7 * weeksAgo, to: calendar.date(bySettingHour: 7, minute: 15, second: 0, of: now)!)!
            let tag = UUID().uuidString.prefix(8)
            var poses: [PosePhoto] = []
            var images: [UIImage] = []
            for pose in Pose.allCases {
                let image = silhouette(pose: pose, leaner: weeksAgo == 0)
                images.append(image)
                let file = "photo-\(tag)-\(pose.rawValue).jpg"
                try image.jpegData(compressionQuality: 0.8)?.write(to: media.appendingPathComponent(file))
                let rect = CGRect(origin: .zero, size: CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale))
                poses.append(PosePhoto(pose: pose, file: file, bodyBox: rect.insetBy(dx: rect.width * 0.3, dy: rect.height * 0.1),
                                       alignedFile: file, cropRect: rect, maskFile: nil))
            }
            let collage = "collage-\(tag).jpg"
            try collageImage(images).jpegData(compressionQuality: 0.8)?.write(to: media.appendingPathComponent(collage))
            sets.append(PhotoSet(id: UUID(), takenAt: taken, poses: poses, collageFile: collage))
        }
        return sets
    }

    private static func silhouette(pose: Pose, leaner: Bool) -> UIImage {
        let size = CGSize(width: 600, height: 800)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            // Wall and floor.
            UIColor(red: 0.86, green: 0.85, blue: 0.83, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.74, green: 0.72, blue: 0.69, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: 640, width: 600, height: 160))
            UIColor(red: 0.27, green: 0.24, blue: 0.22, alpha: 1).setFill()
            let w: CGFloat = leaner ? 1 : 1.05
            let side = pose == .rightArmsUp || pose == .leftArmsUp
            let torsoW = (side ? 96 : 150) * w
            cg.fillEllipse(in: CGRect(x: 300 - 34, y: 110, width: 68, height: 80))
            UIBezierPath(roundedRect: CGRect(x: 300 - torsoW / 2, y: 200, width: torsoW, height: 230), cornerRadius: 40).fill()
            let legW: CGFloat = side ? 44 : 50
            UIBezierPath(roundedRect: CGRect(x: 300 - (side ? 30 : 58), y: 410, width: legW, height: 250), cornerRadius: 22).fill()
            UIBezierPath(roundedRect: CGRect(x: 300 + (side ? -14 : 8), y: 410, width: legW, height: 250), cornerRadius: 22).fill()
            if side {
                // Arms up behind the head.
                UIBezierPath(roundedRect: CGRect(x: 300 - 20, y: 70, width: 36, height: 170), cornerRadius: 18).fill()
            } else {
                UIBezierPath(roundedRect: CGRect(x: 300 - torsoW / 2 - 40, y: 215, width: 36, height: 200), cornerRadius: 18).fill()
                UIBezierPath(roundedRect: CGRect(x: 300 + torsoW / 2 + 4, y: 215, width: 36, height: 200), cornerRadius: 18).fill()
            }
        }
    }

    private static func collageImage(_ images: [UIImage]) -> UIImage {
        let cell = CGSize(width: 600, height: 800)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: cell.width * 2, height: cell.height * 2), format: format).image { _ in
            for (i, image) in images.prefix(4).enumerated() {
                image.draw(in: CGRect(x: CGFloat(i % 2) * cell.width, y: CGFloat(i / 2) * cell.height, width: cell.width, height: cell.height))
            }
        }
    }

    // MARK: The synthetic Health week

    /// What Apple Health would have read, from the same made-up numbers as the check-in answers:
    /// steps averaging 9,842, weight averaging 180.8 lb, sleep 7 h 12 min with a short Tuesday, food
    /// on target six days of seven (Saturday's refeed over), and the two LISS walks. Apple Health is
    /// never asked while the sample is on.
    static func healthWeek(from start: Date, to end: Date) -> HealthService.Week {
        let startDay = calendar.startOfDay(for: start)
        let dayCount = max(1, (calendar.dateComponents([.day], from: startDay, to: end).day ?? 0) + 1)
        let steps: [Double] = [10120, 9640, 9870, 10310, 9420, 9980, 9554]
        let weights: [Double] = [181.2, 181.0, 180.9, 180.8, 180.7, 180.6, 180.4]
        let days = (0..<dayCount).compactMap { offset -> HealthService.DayReading? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: startDay) else { return nil }
            let weekday = calendar.component(.weekday, from: date)
            let training = trainingWeekdays.contains(weekday)
            let refeed = weekday == 7
            var day = HealthService.DayReading(date: date)
            day.kcal = refeed ? 2950 : training ? 2410 : 2090
            day.proteinG = refeed ? 205 : 201
            day.carbsG = refeed ? 330 : training ? 252 : 173
            day.fatG = refeed ? 88 : 64
            day.steps = steps[offset % steps.count]
            day.sleepHours = weekday == 3 ? 6.33 : [7.4, 7.3, 7.5, 7.2, 7.4, 7.27][offset % 6]
            day.weighInLb = weights[offset % weights.count]
            if !training { day.liss = [LissSession(type: "walking", minutes: 25)] }
            return day
        }
        return HealthService.Week(days: days, sources: [
            "calories": "MacroFactor", "protein": "MacroFactor", "carbs": "MacroFactor", "fat": "MacroFactor",
            "steps": "iPhone", "sleep": "Garmin Connect", "weight": "Withings", "workouts": "Garmin Connect",
        ])
    }

    /// This morning's weigh-in while the sample is on, so Check-in morning never asks for a scale.
    static let todayWeighInLb = 180.4

    // MARK: The athlete's own settings

    /// The few settings the sample changes, kept so leaving it puts them back.
    private struct Backup: Codable {
        var athleteFirstName: String
        var cardioProtocol: String
        var showDate: String
        var trainingWeekdays: [Int]
        var rehearsalMode: Bool
        var hasSeenSessionIntro: Bool
    }

    /// On entering: the athlete's values are kept once, then the sample's go in. Alex, the cycle's
    /// training days, a show 20 weeks out, and rehearsal mode on so the send never looks real.
    static func applySettings(_ settings: Settings, now: Date = .now) {
        if settings.settingsBeforeSample == nil {
            let backup = Backup(athleteFirstName: settings.athleteFirstName, cardioProtocol: settings.cardioProtocol, showDate: settings.showDate,
                                trainingWeekdays: Array(settings.trainingWeekdays).sorted(), rehearsalMode: settings.rehearsalMode,
                                hasSeenSessionIntro: settings.hasSeenSessionIntro)
            settings.settingsBeforeSample = try? JSONEncoder().encode(backup)
        }
        settings.athleteFirstName = firstName
        settings.cardioProtocol = cardioProtocol
        settings.trainingWeekdays = trainingWeekdays
        settings.showDate = DayKey.string(calendar.date(byAdding: .weekOfYear, value: 20, to: now) ?? now)
        settings.rehearsalMode = true
        settings.hasSeenSessionIntro = false
    }

    /// On leaving: the athlete's values come back exactly.
    static func restoreSettings(_ settings: Settings) {
        defer { settings.settingsBeforeSample = nil }
        guard let data = settings.settingsBeforeSample, let backup = try? JSONDecoder().decode(Backup.self, from: data) else { return }
        settings.athleteFirstName = backup.athleteFirstName
        settings.cardioProtocol = backup.cardioProtocol
        settings.showDate = backup.showDate
        settings.trainingWeekdays = Set(backup.trainingWeekdays)
        settings.rehearsalMode = backup.rehearsalMode
        settings.hasSeenSessionIntro = backup.hasSeenSessionIntro
    }
}

/// The store the app runs on: the athlete's own, or the sample's while the sample is on. Turning the
/// sample on or off rebuilds the store, and `SetechoApp` rebuilds its views around it. The athlete's
/// store is never read or written while the sample is on.
@MainActor
@Observable
final class StoreHolder {
    static let shared = StoreHolder()

    private(set) var store: Store
    let realRoot: URL
    let sampleRoot: URL
    private let settings: Settings

    init(realRoot: URL = Store.defaultRoot(), sampleRoot: URL = SampleCoach.root(), settings: Settings = .shared) {
        self.realRoot = realRoot
        self.sampleRoot = sampleRoot
        self.settings = settings
        store = Store(root: settings.sampleMode ? sampleRoot : realRoot)
    }

    var isSample: Bool { settings.sampleMode }

    /// "Try it with a sample coach", and "Start the sample over": a fresh sample store, seeded, in front.
    func enterSample(now: Date = .now) throws {
        try? FileManager.default.removeItem(at: sampleRoot)
        let fresh = Store(root: sampleRoot)
        try SampleCoach.seed(into: fresh, now: now)
        SampleCoach.applySettings(settings, now: now)
        settings.sampleMode = true
        store = fresh
    }

    /// "Leave the sample": back to the athlete's own store, exactly as it was. The sample's files go.
    func leaveSample() {
        SampleCoach.restoreSettings(settings)
        settings.sampleMode = false
        store = Store(root: realRoot)
        try? FileManager.default.removeItem(at: sampleRoot)
    }
}
