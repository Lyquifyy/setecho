import Foundation

/// When a machine's taken, what his coach wants, in his order (HANDOFF.md §7, Machine taken). Asked
/// once in the rules review and confirmed as his; until then only Wait is offered, plus whatever the
/// athlete names himself. A reorder (move a later lift up) waits for the exercise tags.
struct TakenRule: Codable, Equatable {
    enum Option: String, Codable, CaseIterable {
        /// His own "or" options from the sheet, in his words.
        case alternate
        /// The same lift on other equipment, named by the catalog.
        case sameLift

        var label: String {
            switch self {
            case .alternate: "His listed alternates"
            case .sameLift: "The same lift on other equipment"
            }
        }
    }

    var order: [Option]
    var confirmed: Bool

    /// The order shown before he answers: his own alternates first.
    static let suggested = TakenRule(order: [.alternate, .sameLift], confirmed: false)

    var text: String { order.map(\.label).joined(separator: ", then ") + ", else wait" }
}

/// `ExerciseFamilies.json`: each movement family, the words that name it, and its variants by
/// equipment with the catalog's own names. Variant names come from here, never from the model.
struct ExerciseFamily: Codable, Equatable {
    struct Variant: Codable, Equatable {
        var equipment: String
        var name: String
    }

    var id: String
    /// Every word of one list must be in the exercise's name: [["incline", "press"], ["incline", "bench"]].
    var names: [[String]]
    var variants: [Variant]

    static let catalog: [ExerciseFamily] = {
        guard let url = Bundle.main.url(forResource: "ExerciseFamilies", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ExerciseFamily].self, from: data)) ?? []
    }()

    static func words(_ name: String) -> Set<String> {
        Set(name.lowercased().split { !$0.isLetter }.map(String.init))
    }

    /// The first family whose words are all in the name ("Smith close-grip press" is close-grip-press).
    static func family(of name: String, in catalog: [ExerciseFamily] = catalog) -> ExerciseFamily? {
        let w = words(name)
        return catalog.first { family in family.names.contains { $0.allSatisfy(w.contains) } }
    }

    /// The equipment a name says it's on ("Smith", "DB", "cable"), else the exercise's own.
    static func equipment(of name: String, fallback: Equipment) -> String {
        let w = words(name)
        if w.contains("smith") { return "smith" }
        if w.contains("dumbbell") || w.contains("dumbbells") || w.contains("db") { return "dumbbell" }
        if w.contains("cable") { return "cable" }
        if w.contains("barbell") || w.contains("bb") { return "barbell" }
        if w.contains("machine") || w.contains("hack") || w.contains("deck") { return "machine" }
        return fallback.rawValue
    }
}

/// One way to carry on when a machine's taken.
struct TakenOption: Codable, Equatable {
    enum Kind: String, Codable { case alternate, sameLift, wait }
    var kind: Kind
    /// What he would do instead, as it is said and logged ("Incline dumbbell press").
    var name: String

    static let wait = TakenOption(kind: .wait, name: "Wait")
}

/// The options for a taken exercise, in his order (pure, unit-tested).
enum TakenEngine {
    /// Walk his options in his order and keep the first two that exist, then Wait. Same-lift
    /// variants leave out the equipment taken now and anything taken earlier this session, and put
    /// the one he did most recently first, then the catalog's order.
    static func options(for exercise: PlannedExercise, rule: TakenRule?, takenEquipment: Set<String>, recentVariants: [String] = [],
                        catalog: [ExerciseFamily] = ExerciseFamily.catalog) -> [TakenOption] {
        guard let rule, rule.confirmed else { return [.wait] }
        var found: [TakenOption] = []
        func add(_ option: TakenOption) {
            guard !found.contains(where: { $0.name.lowercased() == option.name.lowercased() }),
                  option.name.lowercased() != exercise.name.lowercased() else { return }
            found.append(option)
        }
        let current = ExerciseFamily.equipment(of: exercise.name, fallback: exercise.equipment)
        for option in rule.order {
            switch option {
            case .alternate:
                for alternate in exercise.alternates { add(TakenOption(kind: .alternate, name: alternate.name)) }
            case .sameLift:
                guard let family = ExerciseFamily.family(of: exercise.name, in: catalog) else { continue }
                let free = family.variants.filter { $0.equipment != current && !takenEquipment.contains($0.equipment) }
                let rank = { (v: ExerciseFamily.Variant) in recentVariants.firstIndex { $0.lowercased() == v.name.lowercased() } ?? Int.max }
                for variant in free.enumerated().sorted(by: { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }).map(\.element) {
                    add(TakenOption(kind: .sameLift, name: variant.name))
                }
            }
        }
        return Array(found.prefix(2)) + [.wait]
    }
}
