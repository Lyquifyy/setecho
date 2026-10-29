import Foundation
import HealthKit

/// Read-only Apple Health (AGENTS.md rule 11): body mass, dietary energy, protein, carbohydrates,
/// fat, steps, sleep and workouts. Returns one DayFacts per day with the source app recorded.
/// Rules from HANDOFF.md §7: daily cumulative sums anchored at local midnight; the first bodyMass
/// sample each morning in pounds; sleep per night as the asleep stages ending that morning;
/// LISS as walking, elliptical, stair climbing or cycling workouts.
/// Weight comes from Withings direct when it's connected, else Apple Health (HANDOFF.md §9).
@MainActor
final class HealthService: @unchecked Sendable {
    struct DayReading: Equatable {
        var date: Date
        var kcal: Double?
        var proteinG: Double?
        var carbsG: Double?
        var fatG: Double?
        var steps: Double?
        var sleepHours: Double?
        var weighInLb: Double?
        var liss: [LissSession] = []
    }

    struct Week {
        var days: [DayReading]
        /// Metric -> source app names, e.g. "weight": "Withings". "weight.direct": "Withings" when
        /// the week's latest weigh-in came straight from Withings, not through Apple Health.
        var sources: [String: String]
    }

    /// One weigh-in from either route.
    struct WeightSample: Equatable, Sendable {
        var at: Date
        var lb: Double
        var source: String
        var direct: Bool
    }

    /// Withings writes the same weigh-in to Apple Health once its app is opened: one within this
    /// long of a direct one is that weigh-in again.
    nonisolated static let duplicateWindow: TimeInterval = 2 * 60
    nonisolated static let directSource = "Withings"

    static let lissTypes: Set<HKWorkoutActivityType> = [.walking, .elliptical, .stairClimbing, .cycling]

    private static let dailySums: [(HKQuantityTypeIdentifier, HKUnit, String)] = [
        (.dietaryEnergyConsumed, .kilocalorie(), "calories"),
        (.dietaryProtein, .gram(), "protein"),
        (.dietaryCarbohydrates, .gram(), "carbs"),
        (.dietaryFatTotal, .gram(), "fat"),
        (.stepCount, .count(), "steps"),
    ]

    private let store = HKHealthStore()
    private let calendar: Calendar
    private let direct: (any DirectWeightSource)?

    init(calendar: Calendar = .current, direct: (any DirectWeightSource)? = WithingsService.shared) {
        self.calendar = calendar
        self.direct = direct
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    static var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>(dailySums.map { HKQuantityType($0.0) })
        types.insert(HKQuantityType(.bodyMass))
        types.insert(HKCategoryType(.sleepAnalysis))
        types.insert(HKObjectType.workoutType())
        return types
    }

    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: Self.readTypes)
    }

    /// Whether a weigh-in exists since `hour` o'clock today: Withings direct, else a bodyMass sample.
    func hasWeighIn(sinceHour hour: Int, now: Date = .now) async -> Bool {
        let since = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? calendar.startOfDay(for: now)
        if await direct?.directWeighIns(from: since, to: now)?.isEmpty == false { return true }
        let query = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(.bodyMass), predicate: HKQuery.predicateForSamples(withStart: since, end: now))],
            sortDescriptors: [], limit: 1
        )
        return ((try? await query.result(for: store))?.isEmpty == false)
    }

    /// Today's weigh-in in pounds, if there is one since `hour`: the one value Check-in morning offers.
    /// Withings direct first; Apple Health when it isn't connected or has nothing yet.
    func weighInLb(sinceHour hour: Int, now: Date = .now) async -> Double? {
        let since = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? calendar.startOfDay(for: now)
        if let latest = await direct?.directWeighIns(from: since, to: now)?.last { return latest.lb }
        let query = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(.bodyMass), predicate: HKQuery.predicateForSamples(withStart: since, end: now))],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)], limit: 1
        )
        return (try? await query.result(for: store))?.first?.quantity.doubleValue(for: .pound())
    }

    private struct SumRow: Sendable { var identifier: String; var day: Date; var value: Double; var sources: [String] }
    private struct SampleRow: Sendable { var start: Date; var end: Date; var value: Double; var source: String; var name: String }

    /// Readings for every day from `start` (midnight) up to `end`. The eight queries run at the
    /// same time; the read took longest in the Oct 27 rehearsal when they ran one after another.
    func read(from start: Date, to end: Date) async throws -> Week {
        let startDay = calendar.startOfDay(for: start)
        let dayCount = max(1, (calendar.dateComponents([.day], from: startDay, to: end).day ?? 0) + 1)
        var days = (0..<dayCount).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: startDay).map { DayReading(date: $0) }
        }
        var sources: [String: Set<String>] = [:]

        func index(_ date: Date) -> Int? {
            let d = calendar.dateComponents([.day], from: startDay, to: calendar.startOfDay(for: date)).day ?? -1
            return days.indices.contains(d) ? d : nil
        }

        // Withings direct, when connected, fetches (at most every 10 minutes) while Health is read.
        async let directRows = direct?.directWeighIns(from: startDay, to: end)
        async let sumRows = readSums(startDay: startDay, end: end)
        async let weightRows = readWeights(startDay: startDay, end: end)
        async let sleepRows = readSleep(startDay: startDay, end: end)
        async let workoutRows = readWorkouts(startDay: startDay, end: end)
        let (sums, healthWeights, sleeps, workouts) = try await (sumRows, weightRows, sleepRows, workoutRows)
        let weights = Self.mergeWeights(
            health: healthWeights.map { WeightSample(at: $0.start, lb: $0.value, source: $0.source, direct: false) },
            direct: await directRows
        )

        for row in sums {
            guard let i = index(row.day) else { continue }
            switch HKQuantityTypeIdentifier(rawValue: row.identifier) {
            case .dietaryEnergyConsumed: days[i].kcal = row.value
            case .dietaryProtein: days[i].proteinG = row.value
            case .dietaryCarbohydrates: days[i].carbsG = row.value
            case .dietaryFatTotal: days[i].fatG = row.value
            case .stepCount: days[i].steps = row.value
            default: break
            }
            let label = Self.dailySums.first { $0.0.rawValue == row.identifier }?.2 ?? row.identifier
            for source in row.sources { sources[label, default: []].insert(source) }
        }
        let firstWeights = Self.firstPerDay(weights, day: index)
        for (i, lb) in firstWeights.byDay { days[i].weighInLb = lb }
        for row in weights { sources["weight", default: []].insert(row.source) }
        if firstWeights.latestDirect { sources["weight.direct"] = [Self.directSource] }
        for row in sleeps {
            guard let i = index(row.end) else { continue }
            days[i].sleepHours = (days[i].sleepHours ?? 0) + row.end.timeIntervalSince(row.start) / 3600
            sources["sleep", default: []].insert(row.source)
        }
        for row in workouts {
            guard let i = index(row.start) else { continue }
            days[i].liss.append(LissSession(type: row.name, minutes: Int(row.value / 60)))
            sources["workouts", default: []].insert(row.source)
        }
        return Week(days: days, sources: sources.mapValues { $0.sorted().joined(separator: ", ") })
    }

    /// Weight from Withings direct when connected (`direct` non-nil), else Apple Health. A Health
    /// sample that is the same weigh-in as a direct one is dropped; Health still fills a day Withings
    /// has nothing for. Oldest first.
    nonisolated static func mergeWeights(health: [WeightSample], direct: [WithingsWeighIn]?) -> [WeightSample] {
        guard let direct else { return health.sorted { $0.at < $1.at } }
        let fromWithings = direct.map { WeightSample(at: $0.at, lb: $0.lb, source: directSource, direct: true) }
        let rest = health.filter { sample in
            !fromWithings.contains { abs($0.at.timeIntervalSince(sample.at)) <= duplicateWindow }
        }
        return (fromWithings + rest).sorted { $0.at < $1.at }
    }

    /// The first weigh-in each day (the morning one), and whether the latest of those came straight
    /// from Withings: that one is the check-in's current weight, so it names its source.
    nonisolated static func firstPerDay(_ weights: [WeightSample], day: (Date) -> Int?) -> (byDay: [Int: Double], latestDirect: Bool) {
        var byDay: [Int: Double] = [:]
        var latest: (day: Int, direct: Bool)?
        for row in weights.sorted(by: { $0.at < $1.at }) {
            guard let i = day(row.at), byDay[i] == nil else { continue }
            byDay[i] = row.lb
            if latest == nil || i > latest!.day { latest = (i, row.direct) }
        }
        return (byDay, latest?.direct ?? false)
    }

    private func readSums(startDay: Date, end: Date) async throws -> [SumRow] {
        try await withThrowingTaskGroup(of: [SumRow].self) { group in
            for (identifier, unit, _) in Self.dailySums {
                group.addTask { [store] in
                    let descriptor = HKStatisticsCollectionQueryDescriptor(
                        predicate: .quantitySample(type: HKQuantityType(identifier), predicate: HKQuery.predicateForSamples(withStart: startDay, end: end)),
                        options: [.cumulativeSum, .separateBySource], anchorDate: startDay, intervalComponents: DateComponents(day: 1)
                    )
                    return try await descriptor.result(for: store).statistics().compactMap { stats -> SumRow? in
                        guard let sum = stats.sumQuantity() else { return nil }
                        return SumRow(identifier: identifier.rawValue, day: stats.startDate, value: sum.doubleValue(for: unit),
                                      sources: (stats.sources ?? []).map(\.name))
                    }
                }
            }
            var rows: [SumRow] = []
            for try await part in group { rows += part }
            return rows
        }
    }

    private func readWeights(startDay: Date, end: Date) async throws -> [SampleRow] {
        let query = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(.bodyMass), predicate: HKQuery.predicateForSamples(withStart: startDay, end: end))],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )
        return try await query.result(for: store).map {
            SampleRow(start: $0.startDate, end: $0.endDate, value: $0.quantity.doubleValue(for: .pound()), source: $0.sourceRevision.source.name, name: "")
        }
    }

    private func readSleep(startDay: Date, end: Date) async throws -> [SampleRow] {
        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepCore.rawValue, HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue, HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
        ]
        let sleepStart = calendar.date(byAdding: .hour, value: -12, to: startDay) ?? startDay
        let query = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: HKQuery.predicateForSamples(withStart: sleepStart, end: end))],
            sortDescriptors: []
        )
        return try await query.result(for: store).filter { asleep.contains($0.value) }.map {
            SampleRow(start: $0.startDate, end: $0.endDate, value: 0, source: $0.sourceRevision.source.name, name: "")
        }
    }

    private func readWorkouts(startDay: Date, end: Date) async throws -> [SampleRow] {
        let query = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForSamples(withStart: startDay, end: end))],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )
        return try await query.result(for: store).filter { Self.lissTypes.contains($0.workoutActivityType) }.map {
            SampleRow(start: $0.startDate, end: $0.endDate, value: $0.duration, source: $0.sourceRevision.source.name,
                      name: Self.name($0.workoutActivityType))
        }
    }

    static func name(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .walking: "walking"
        case .elliptical: "elliptical"
        case .stairClimbing: "stair climbing"
        case .cycling: "cycling"
        default: "other"
        }
    }
}

extension WeekFacts {
    /// Assemble the week the backend cites from Health readings and the log. Pure, so it is testable.
    static func build(
        week: HealthService.Week,
        weekStart: Date,
        weekEnd: Date,
        targets: MacroTargets,
        sessions: [Session],
        scheduledWeekdays: Set<Int>,
        showDate: String?,
        lastCheckInWeightLb: Double?,
        calendar: Calendar = .current
    ) -> WeekFacts {
        let daily = week.days.map { day in
            DayFacts(
                date: DayKey.string(day.date, calendar: calendar),
                isTrainingDay: Adherence.isTrainingDay(
                    day.date, sessions: sessions, scheduledWeekdays: scheduledWeekdays, calendar: calendar
                ),
                kcal: day.kcal.map { $0.rounded() },
                proteinG: day.proteinG.map { $0.rounded() },
                carbsG: day.carbsG.map { $0.rounded() },
                fatG: day.fatG.map { $0.rounded() },
                steps: day.steps.map { $0.rounded() },
                sleepHours: day.sleepHours.map { ($0 * 10).rounded() / 10 },
                weighInLb: day.weighInLb.map { ($0 * 10).rounded() / 10 },
                liss: day.liss
            )
        }
        return WeekFacts(
            weekStart: DayKey.string(weekStart, calendar: calendar),
            weekEnd: DayKey.string(weekEnd, calendar: calendar),
            daily: daily,
            targets: targets,
            showDate: showDate,
            lastCheckInWeightLb: lastCheckInWeightLb,
            sources: week.sources
        )
    }
}
