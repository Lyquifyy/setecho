import SwiftUI
import UIKit
@testable import Setecho

/// Synthetic data for the screen renders (ScreenRenderTests): his program's shape from the backend's
/// cycle fixture (five training days, two rest days, vacuums on waking, abs twice a week), the coach's
/// rules from the synthetic onboarding email, two weeks of sessions, last week's sent check-in, this
/// week's half-filled one, a coach reply waiting, and a week of photos drawn as plain silhouettes.
/// Every number is made up (PRODUCT.md, Evidence on hand); nothing here is his.
@MainActor
enum ScreenFixtures {
    /// Which store a shot reads.
    enum Variant: Hashable {
        /// A training day (Day 1, abs joining), mid-week, the check-in filling itself.
        case trainingDay
        /// The same week with a coach reply to review and a MacroFactor line to update.
        case replyWaiting
        /// Today as the calendar has it, unforced (Thursday: a rest day and check-in morning).
        case asToday
        /// First run: nothing imported yet.
        case firstRun
    }

    struct FixtureMissing: Error { let name: String }

    private final class Anchor {}

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        guard let url = Bundle(for: Anchor.self).url(forResource: name, withExtension: "json") else { throw FixtureMissing(name: name) }
        return try JSONCoding.decoder.decode(T.self, from: Data(contentsOf: url))
    }

    static func program() throws -> Program { try decode(Program.self, "program_cycle") }
    static func template() throws -> CheckInTemplate { try decode(CheckInTemplate.self, "template") }
    static func rules() throws -> RulesImport { try decode(RulesImport.self, "rules_cycle") }

    private static var stores: [Variant: Store] = [:]

    /// One store per variant, built once per run in a fresh folder.
    static func store(_ variant: Variant) throws -> Store {
        if let store = stores[variant] { return store }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("screens-\(variant)-\(UUID().uuidString)")
        let store = Store(root: root)
        if variant != .firstRun { try seed(store, variant: variant) }
        stores[variant] = store
        return store
    }

    /// The app's own settings, set once: his first name for the greetings, the defaults otherwise.
    static func prepareSettings() {
        let settings = Settings.shared
        settings.athleteFirstName = "Zander"
        settings.hasSeenSessionIntro = true
        settings.developerTools = false
    }

    // MARK: Seeding

    private static let calendar = Calendar.current

    private static func seed(_ store: Store, variant: Variant) throws {
        let program = try program()
        let template = try template()
        store.saveProgram(program, cardioProtocol: "25 minutes of fasted LISS, 2× a week")
        store.setAddOnDays(program.addOns.map { AddOnDays(addOnId: $0.id, dayIds: AddOnPlanner.proposedDays(for: $0, in: program)) })
        store.saveTemplate(template, targets: CheckInTemplate.parsedTargets(template), cardioProtocol: "25 minutes of fasted LISS, 2× a week")
        store.saveRules(try rules())

        for session in sessions(program: program) { store.upsert(session: session) }
        let photos = try photoSets(in: store.mediaDirectory)
        for set in photos { store.upsert(photoSet: set) }

        // Last week's check-in went out; this week's is half filled.
        store.upsert(checkIn: sentCheckIn(template: template, photoSetId: photos.first?.id))
        let schedule = CheckInSchedule(plan: store.plan, lastSentAt: store.lastSentCheckIn?.sentAt)
        let week = schedule.week(endingBefore: schedule.nextDue(from: .now))
        store.upsert(checkIn: currentDraft(template: template, week: week, photoSetId: photos.last?.id))

        switch variant {
        case .trainingDay:
            store.changeDay(to: "w1_day_1")
        case .replyWaiting:
            store.changeDay(to: "w1_day_1")
            store.upsert(reply: coachReply())
            store.addMacroFactorReminders(["Training-day carbs 250 → 225 g"])
        case .asToday, .firstRun:
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

    /// Monday is Day 1, as his cycle runs (Settings → cycle starts Monday).
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
    private static func sessions(program: Program) -> [Session] {
        let today = calendar.startOfDay(for: .now)
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

    /// 11 of 23 ready: the data fields filled, three drafted for him to confirm, three said earlier in the week.
    private static func currentAnswers(photoSetReady: Bool) -> [FieldAnswer] {
        [
            answer("weeks_away_from_target_date", "20", .filled, "Show date", "Mar 20, 2027"),
            answer("accuracy_on_plan", "86%", .filled, "MacroFactor via Apple Health", "6 of 7 days within targets"),
            answer("nutrition_consistency", "6 of 7 days on target", .filled, "MacroFactor via Apple Health", "Oct 23–29"),
            answer("training_consistency", "5 of 5 sessions, every set logged", .filled, "Training log", "Mon–Sat"),
            answer("current_cardio_protocol", "25 minutes of fasted LISS, 2× a week", .filled, "Coach's plan", "Plan v3"),
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

    private static func sentCheckIn(template: CheckInTemplate, photoSetId: UUID?) -> CheckInDraft {
        let sent = calendar.date(byAdding: .day, value: -7, to: calendar.date(bySettingHour: 8, minute: 42, second: 0, of: .now)!)!
        let start = calendar.date(byAdding: .day, value: -7, to: sent)!
        var answers = currentAnswers(photoSetReady: true).map { a -> FieldAnswer in
            var a = a
            if a.state != .filled { a.state = .confirmed }
            if a.text.isEmpty { a.text = "7" }
            return a
        }
        // What he said last week, so History's trends read like a check-in and not a placeholder.
        let said = ["waist_measurement": "31.75 in", "bicep_measurement_flexed": "16.25 in", "thigh_measurement_flexed": "24.5 in",
                    "fasted_blood_glucose": "89", "energy_levels": "7", "notes_on_appetite": "6, hungrier at night",
                    "notes_on_recovery": "Good", "additional_notes_or_concerns": "None this week"]
        for (id, text) in said { if let i = answers.firstIndex(where: { $0.fieldId == id }) { answers[i].text = text } }
        if let i = answers.firstIndex(where: { $0.fieldId == "current_body_weight" }) { answers[i].text = "181.6 lb" }
        if let i = answers.firstIndex(where: { $0.fieldId == "last_check_in_body_weight" }) { answers[i].text = "182.4 lb" }
        return CheckInDraft(id: UUID(), weekStart: start, weekEnd: sent, answers: answers, photoSetId: photoSetId, sentAt: sent)
    }

    // MARK: Coach reply

    private static func coachReply() -> CoachReply {
        let words = "Great week. Drop training-day carbs by 25 starting Monday. Swap the walking lunges for Bulgarian split squats, same sets. Add a third cardio session, 25 minutes. And keep pushing that incline."
        return CoachReply(
            id: UUID(), receivedAt: calendar.date(byAdding: .hour, value: -2, to: .now)!, kind: .voiceNote, audioFile: nil,
            transcript: words,
            changes: [
                PlanChange(id: "c1", kind: .macroTarget, path: "targets.training.carbsG", label: "Training-day carbs", op: .decrease, amount: 25,
                           before: "250 g", after: "225 g", quote: "Drop training-day carbs by 25 starting Monday", appliesFrom: nextMonday(), approved: true),
                PlanChange(id: "c2", kind: .exerciseSwap, path: "program.day_2.walking_lunge", label: "Walking Lunge", op: .replace, amount: nil,
                           before: "Walking Lunge", after: "Bulgarian split squat", quote: "Swap the walking lunges for Bulgarian split squats, same sets",
                           appliesFrom: nil, approved: true),
                PlanChange(id: "c3", kind: .cardio, path: "cardioProtocol", label: "Cardio", op: .set, amount: 3,
                           before: "25 minutes of fasted LISS, 2× a week", after: "25 minutes of fasted LISS, 3× a week",
                           quote: "Add a third cardio session, 25 minutes", appliesFrom: nil, approved: true),
            ],
            unclear: ["keep pushing that incline"], appliedVersion: nil)
    }

    private static func nextMonday() -> String {
        let next = calendar.nextDate(after: .now, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime)!
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: next)
    }

    static func pendingReply(in store: Store) -> CoachReply? { store.pendingReply }

    // MARK: Photos

    /// Two weeks of check-in photos: a plain silhouette per pose, so the screens have real images in them.
    private static func photoSets(in media: URL) throws -> [PhotoSet] {
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        var sets: [PhotoSet] = []
        for weeksAgo in [1, 0] {
            let taken = calendar.date(byAdding: .day, value: -7 * weeksAgo, to: calendar.date(bySettingHour: 7, minute: 15, second: 0, of: .now)!)!
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

    static func photoThumbnails(_ set: PhotoSet, in store: Store) -> [Pose: UIImage] {
        var result: [Pose: UIImage] = [:]
        for photo in set.poses {
            if let data = try? Data(contentsOf: store.mediaDirectory.appendingPathComponent(photo.file)), let image = UIImage(data: data) {
                result[photo.pose] = image
            }
        }
        return result
    }

    static func collage(_ set: PhotoSet, in store: Store) -> UIImage {
        (try? Data(contentsOf: store.mediaDirectory.appendingPathComponent(set.collageFile))).flatMap(UIImage.init(data:)) ?? UIImage()
    }
}
