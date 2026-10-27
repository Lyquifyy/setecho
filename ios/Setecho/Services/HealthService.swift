import Foundation
import HealthKit

/// Read-only Apple Health (AGENTS.md rule 11): body mass, dietary energy, protein, carbohydrates,
/// fat, steps, sleep and workouts. Returns one DayFacts per day with the source app recorded.
/// Rules from HANDOFF.md §7: daily cumulative sums anchored at local midnight; the first bodyMass
/// sample each morning in pounds; sleep per night as the asleep stages ending that morning;
/// LISS as walking, elliptical, stair climbing or cycling workouts.
@MainActor
final class HealthService {
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
        /// Metric -> source app names, e.g. "weight": "Withings".
        var sources: [String: String]
    }

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

    init(calendar: Calendar = .current) {
        self.calendar = calendar
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

    /// Readings for every day from `start` (midnight) up to `end`.
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

        for (identifier, unit, label) in Self.dailySums {
            let descriptor = HKStatisticsCollectionQueryDescriptor(
                predicate: .quantitySample(
                    type: HKQuantityType(identifier),
                    predicate: HKQuery.predicateForSamples(withStart: startDay, end: end)
                ),
                options: [.cumulativeSum, .separateBySource],
                anchorDate: startDay,
                intervalComponents: DateComponents(day: 1)
            )
            for stats in try await descriptor.result(for: store).statistics() {
                guard let i = index(stats.startDate), let sum = stats.sumQuantity() else { continue }
                let value = sum.doubleValue(for: unit)
                switch identifier {
                case .dietaryEnergyConsumed: days[i].kcal = value
                case .dietaryProtein: days[i].proteinG = value
                case .dietaryCarbohydrates: days[i].carbsG = value
                case .dietaryFatTotal: days[i].fatG = value
                case .stepCount: days[i].steps = value
                default: break
                }
                for source in stats.sources ?? [] { sources[label, default: []].insert(source.name) }
            }
        }

        let weight = HKSampleQueryDescriptor(
            predicates: [.quantitySample(
                type: HKQuantityType(.bodyMass),
                predicate: HKQuery.predicateForSamples(withStart: startDay, end: end)
            )],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )
        for sample in try await weight.result(for: store) {
            guard let i = index(sample.startDate) else { continue }
            if days[i].weighInLb == nil {
                days[i].weighInLb = sample.quantity.doubleValue(for: .pound())
            }
            sources["weight", default: []].insert(sample.sourceRevision.source.name)
        }

        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
        ]
        let sleepStart = calendar.date(byAdding: .hour, value: -12, to: startDay) ?? startDay
        let sleep = HKSampleQueryDescriptor(
            predicates: [.categorySample(
                type: HKCategoryType(.sleepAnalysis),
                predicate: HKQuery.predicateForSamples(withStart: sleepStart, end: end)
            )],
            sortDescriptors: []
        )
        for sample in try await sleep.result(for: store) where asleep.contains(sample.value) {
            guard let i = index(sample.endDate) else { continue }
            days[i].sleepHours = (days[i].sleepHours ?? 0) + sample.endDate.timeIntervalSince(sample.startDate) / 3600
            sources["sleep", default: []].insert(sample.sourceRevision.source.name)
        }

        let workouts = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForSamples(withStart: startDay, end: end))],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )
        for workout in try await workouts.result(for: store) where Self.lissTypes.contains(workout.workoutActivityType) {
            guard let i = index(workout.startDate) else { continue }
            days[i].liss.append(LissSession(type: Self.name(workout.workoutActivityType), minutes: Int(workout.duration / 60)))
            sources["workouts", default: []].insert(workout.sourceRevision.source.name)
        }

        return Week(days: days, sources: sources.mapValues { $0.sorted().joined(separator: ", ") })
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
