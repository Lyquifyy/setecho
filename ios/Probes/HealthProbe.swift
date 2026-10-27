import HealthKit
import SwiftUI

/// G3: read the last 7 days of every type the check-in needs (HANDOFF.md §7 HealthKit) and show
/// each value with the app it came from. The human compares the numbers with MacroFactor, Withings
/// and Garmin. Read-only: nothing is written to Health.
struct HealthProbeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = HealthProbeModel()

    var body: some View {
        ScreenScaffold {
            LinkButton(title: "Back to probes", chevron: .leading) { dismiss() }
            TitleBlock(eyebrow: "G3", title: "Apple Health", subtitle: model.status)
            SectionCard("Last 7 days") {
                if model.days.isEmpty {
                    Text("Tap Read 7 days. The first run asks for read access to eight types.")
                        .font(.subheadline).secondaryText()
                } else {
                    ForEach(Array(model.days.enumerated()), id: \.element.id) { index, day in
                        if index > 0 { CardDivider() }
                        DayRow(day: day)
                    }
                }
            }
            SectionCard("Sources") {
                if model.sources.isEmpty {
                    Text("Source apps appear here after a read.").font(.subheadline).secondaryText()
                } else {
                    ForEach(Array(model.sources.enumerated()), id: \.offset) { index, source in
                        if index > 0 { CardDivider() }
                        LabeledRow(source.type, source.names)
                    }
                }
            }
            PassChecksCard(items: [
                "Calories, protein, carbs and fat match MacroFactor day by day.",
                "Weight matches the Withings morning weigh-in.",
                "Steps and sleep match Garmin. Missing sleep or steps means the wrap-up asks by voice.",
                "Every source name is the real app, not \"Health\" or the iPhone.",
            ])
            ProbeLog(lines: model.log)
        } footer: {
            Button(model.isRunning ? "Reading…" : "Read 7 days") {
                Task { await model.run() }
            }
            .buttonStyle(.setechoPrimary)
            .disabled(model.isRunning)
        }
    }
}

private struct DayRow: View {
    let day: HealthDay

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            HStack(alignment: .firstTextBaseline) {
                Text(day.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.navy)
                Spacer()
                Text(day.weightLb.map { Format.load($0) } ?? "no weigh-in")
                    .font(.subheadline).monospacedDigit().foregroundStyle(Theme.navy)
            }
            Text(day.macrosLine).font(.footnote).monospacedDigit().secondaryText()
            Text(day.activityLine).font(.footnote).monospacedDigit().secondaryText()
            if !day.workouts.isEmpty {
                Text(day.workouts.joined(separator: " · ")).font(.footnote).secondaryText()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Space.xxs)
    }
}

struct HealthDay: Identifiable {
    let date: Date
    var kcal: Double?
    var proteinG: Double?
    var carbsG: Double?
    var fatG: Double?
    var steps: Double?
    var sleepHours: Double?
    var weightLb: Double?
    var workouts: [String] = []

    var id: Date { date }

    var macrosLine: String {
        guard kcal != nil || proteinG != nil else { return "no nutrition logged" }
        let k = kcal.map { "\(Format.number($0.rounded())) kcal" } ?? "— kcal"
        let p = proteinG.map { Format.number($0.rounded()) } ?? "—"
        let c = carbsG.map { Format.number($0.rounded()) } ?? "—"
        let f = fatG.map { Format.number($0.rounded()) } ?? "—"
        return "\(k) · \(p) P / \(c) C / \(f) F"
    }

    var activityLine: String {
        let s = steps.map { "\(Int($0).formatted()) steps" } ?? "no steps"
        let z = sleepHours.map { String(format: "%.1f h sleep", $0) } ?? "no sleep"
        return "\(s) · \(z)"
    }
}

@MainActor
@Observable
final class HealthProbeModel {
    var days: [HealthDay] = []
    var sources: [(type: String, names: String)] = []
    var status = "Reads 7 days of weight, macros, steps, sleep and workouts."
    var isRunning = false
    var log: [String] = []

    private let store = HKHealthStore()

    private static let dailySums: [(HKQuantityTypeIdentifier, HKUnit, String)] = [
        (.dietaryEnergyConsumed, .kilocalorie(), "Calories"),
        (.dietaryProtein, .gram(), "Protein"),
        (.dietaryCarbohydrates, .gram(), "Carbs"),
        (.dietaryFatTotal, .gram(), "Fat"),
        (.stepCount, .count(), "Steps"),
    ]

    private static let lissTypes: Set<HKWorkoutActivityType> = [.walking, .elliptical, .stairClimbing, .cycling]

    func run() async {
        guard !isRunning else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            status = "Health data is not available on this device."
            return
        }
        isRunning = true
        defer { isRunning = false }

        var readTypes = Set<HKObjectType>(Self.dailySums.map { HKQuantityType($0.0) })
        readTypes.insert(HKQuantityType(.bodyMass))
        readTypes.insert(HKCategoryType(.sleepAnalysis))
        readTypes.insert(HKObjectType.workoutType())
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            note("Authorization prompt handled (read-only, 8 types)")
        } catch {
            status = "Authorization failed: \(error.localizedDescription)"
            note(status)
            return
        }

        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: .now)
        guard let start = cal.date(byAdding: .day, value: -6, to: todayStart) else { return }
        let end = Date.now
        var rows = (0..<7).compactMap { offset in
            cal.date(byAdding: .day, value: offset, to: start).map { HealthDay(date: $0) }
        }
        var sourceNames: [String: Set<String>] = [:]

        func dayIndex(_ date: Date) -> Int? {
            let d = cal.dateComponents([.day], from: start, to: cal.startOfDay(for: date)).day ?? -1
            return rows.indices.contains(d) ? d : nil
        }

        do {
            for (identifier, unit, label) in Self.dailySums {
                let type = HKQuantityType(identifier)
                let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
                let descriptor = HKStatisticsCollectionQueryDescriptor(
                    predicate: .quantitySample(type: type, predicate: predicate),
                    options: [.cumulativeSum, .separateBySource],
                    anchorDate: todayStart,
                    intervalComponents: DateComponents(day: 1)
                )
                let collection = try await descriptor.result(for: store)
                var found = 0
                for stats in collection.statistics() {
                    guard let i = dayIndex(stats.startDate), let sum = stats.sumQuantity() else { continue }
                    let value = sum.doubleValue(for: unit)
                    switch identifier {
                    case .dietaryEnergyConsumed: rows[i].kcal = value
                    case .dietaryProtein: rows[i].proteinG = value
                    case .dietaryCarbohydrates: rows[i].carbsG = value
                    case .dietaryFatTotal: rows[i].fatG = value
                    case .stepCount: rows[i].steps = value
                    default: break
                    }
                    found += 1
                    for source in stats.sources ?? [] { sourceNames[label, default: []].insert(source.name) }
                }
                note("\(label): \(found) day(s) with data")
            }

            let weightDescriptor = HKSampleQueryDescriptor(
                predicates: [.quantitySample(type: HKQuantityType(.bodyMass),
                                             predicate: HKQuery.predicateForSamples(withStart: start, end: end))],
                sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
            )
            var weighIns = 0
            for sample in try await weightDescriptor.result(for: store) {
                guard let i = dayIndex(sample.startDate) else { continue }
                if rows[i].weightLb == nil {
                    rows[i].weightLb = sample.quantity.doubleValue(for: .pound())
                    weighIns += 1
                }
                sourceNames["Weight", default: []].insert(sample.sourceRevision.source.name)
            }
            note("Weight: \(weighIns) morning weigh-in(s)")

            let asleep: Set<Int> = [
                HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            ]
            let sleepStart = cal.date(byAdding: .hour, value: -12, to: start) ?? start
            let sleepDescriptor = HKSampleQueryDescriptor(
                predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis),
                                             predicate: HKQuery.predicateForSamples(withStart: sleepStart, end: end))],
                sortDescriptors: []
            )
            var nights = Set<Int>()
            for sample in try await sleepDescriptor.result(for: store) where asleep.contains(sample.value) {
                guard let i = dayIndex(sample.endDate) else { continue }
                rows[i].sleepHours = (rows[i].sleepHours ?? 0) + sample.endDate.timeIntervalSince(sample.startDate) / 3600
                nights.insert(i)
                sourceNames["Sleep", default: []].insert(sample.sourceRevision.source.name)
            }
            note("Sleep: \(nights.count) night(s)")

            let workoutDescriptor = HKSampleQueryDescriptor(
                predicates: [.workout(HKQuery.predicateForSamples(withStart: start, end: end))],
                sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
            )
            var workoutCount = 0
            for workout in try await workoutDescriptor.result(for: store) {
                guard let i = dayIndex(workout.startDate) else { continue }
                let kind = Self.lissTypes.contains(workout.workoutActivityType) ? "LISS" : "Workout"
                rows[i].workouts.append("\(kind): \(Self.name(workout.workoutActivityType)) \(Int(workout.duration / 60)) min")
                workoutCount += 1
                sourceNames["Workouts", default: []].insert(workout.sourceRevision.source.name)
            }
            note("Workouts: \(workoutCount)")
        } catch {
            status = "Query failed: \(error.localizedDescription)"
            note(status)
            return
        }

        days = rows.reversed()
        sources = sourceNames.keys.sorted().map { ($0, sourceNames[$0]!.sorted().joined(separator: ", ")) }
        status = "Read \(rows.count) days ending today."
    }

    private static func name(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .walking: "walking"
        case .elliptical: "elliptical"
        case .stairClimbing: "stair climbing"
        case .cycling: "cycling"
        case .traditionalStrengthTraining: "strength"
        case .running: "running"
        default: "other (\(type.rawValue))"
        }
    }

    private func note(_ line: String) {
        log.append("\(Date.now.probeStamp)  \(line)")
    }
}
