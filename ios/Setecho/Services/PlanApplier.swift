import Foundation

/// Approved changes -> the next PlanState, in Swift, deterministically (HANDOFF.md §7, Coach reply).
/// A program change applies to every remaining week from `appliesFrom`. A macro or supplement
/// change also edits the carried block's text: the old value is replaced on the matching line when
/// it appears there exactly once; otherwise the block is left for a manual edit and reported.
enum PlanApplier {
    struct Result: Equatable {
        var plan: PlanState
        /// Carried blocks the text edit could not make on its own ("Nutrition").
        var blocksNeedingHandEdit: [String]
        /// "Update MacroFactor: training-day carbs 250 → 225 g" lines, one per macro change.
        var macroFactorReminders: [String]
    }

    static func apply(_ changes: [PlanChange], to plan: PlanState, replyId: UUID, today: Date = .now, calendar: Calendar = .current) -> Result {
        var next = plan
        next.version = plan.version + 1
        next.replyId = replyId
        var handEdits: [String] = []
        var reminders: [String] = []
        for change in changes where change.approved {
            switch change.kind {
            case .macroTarget:
                guard let after = number(in: change.after), let before = number(in: change.before) else { continue }
                setMacro(&next.targets, path: change.path, value: after)
                let unit = change.path.hasSuffix("kcal") ? "" : " g"
                let edited = replaceOnce(in: &next.carriedBlocks, old: before, new: after, within: change.label, unit: unit)
                if !edited { handEdits.append(contentsOf: next.carriedBlocks.filter { !isSupplement($0) }.map(\.title)) }
                reminders.append("Update MacroFactor: \(change.label.lowercased()) \(Format.number(before)) → \(Format.number(after))\(unit)")
            case .cardio:
                if let after = change.after { next.cardioProtocol = after }
            case .supplement:
                applySupplement(change, to: &next.carriedBlocks, handEdits: &handEdits)
            case .exerciseSwap, .exerciseAdd, .exerciseRemove, .sets, .reps, .load, .rest, .other:
                applyProgram(change, to: &next.program, today: today, calendar: calendar)
            }
        }
        return Result(plan: next, blocksNeedingHandEdit: Array(Set(handEdits)).sorted(), macroFactorReminders: reminders)
    }

    // MARK: Targets

    static func setMacro(_ targets: inout MacroTargets, path: String, value: Double) {
        let parts = path.split(separator: ".").map(String.init)
        guard parts.count == 3, parts[0] == "targets" else { return }
        var macros = parts[1] == "training" ? targets.training : targets.rest
        switch parts[2] {
        case "kcal": macros.kcal = value
        case "proteinG": macros.proteinG = value
        case "carbsG": macros.carbsG = value
        case "fatG": macros.fatG = value
        default: return
        }
        if parts[1] == "training" { targets.training = macros } else { targets.rest = macros }
    }

    /// Replace `old` with `new` on the one line of a non-supplement block that names the macro
    /// ("carb", "protein") under the right day heading. Returns false when no single line matches.
    static func replaceOnce(in blocks: inout [CarriedBlock], old: Double, new: Double, within label: String, unit: String) -> Bool {
        let lower = label.lowercased()
        let dayWord = lower.contains("rest") ? "rest" : "training"
        let macroWords: [String] = lower.contains("calor") ? ["calor", "kcal"] : lower.contains("protein") ? ["protein"]
            : lower.contains("carb") ? ["carb"] : lower.contains("fat") ? ["fat"] : []
        guard !macroWords.isEmpty else { return false }
        for b in blocks.indices where !isSupplement(blocks[b]) {
            let lines = blocks[b].text.components(separatedBy: "\n")
            var section = "training"
            var matches: [Int] = []
            for (i, line) in lines.enumerated() {
                let l = line.lowercased()
                if l.contains("non-training") || l.contains("rest day") || l.contains("off day") { section = "rest" }
                else if l.contains("training day") { section = "training" }
                if section == dayWord, macroWords.contains(where: { l.contains($0) }), occurrences(of: old, in: line) == 1 {
                    matches.append(i)
                }
            }
            guard matches.count == 1 else { continue }
            var edited = lines
            edited[matches[0]] = replaceNumber(old, with: new, in: lines[matches[0]])
            blocks[b].text = edited.joined(separator: "\n")
            return true
        }
        return false
    }

    static func occurrences(of value: Double, in line: String) -> Int {
        numbers(in: line).filter { $0 == value }.count
    }

    static func replaceNumber(_ old: Double, with new: Double, in line: String) -> String {
        var out = ""
        var current = ""
        func flush() {
            if !current.isEmpty {
                out += Double(current) == old ? Format.number(new) : current
                current = ""
            }
        }
        for ch in line {
            if ch.isNumber || (ch == "." && !current.isEmpty) { current.append(ch) } else { flush(); out.append(ch) }
        }
        flush()
        return out
    }

    static func numbers(in text: String) -> [Double] {
        var out: [Double] = []
        var current = ""
        for ch in text {
            if ch.isNumber || (ch == "." && !current.isEmpty) { current.append(ch) } else if !current.isEmpty { out.append(Double(current) ?? 0); current = "" }
        }
        if !current.isEmpty { out.append(Double(current) ?? 0) }
        return out
    }

    static func number(in text: String?) -> Double? {
        text.flatMap { numbers(in: $0).first }
    }

    // MARK: Supplements

    static func isSupplement(_ block: CarriedBlock) -> Bool {
        block.title.lowercased().contains("supplement")
    }

    static func applySupplement(_ change: PlanChange, to blocks: inout [CarriedBlock], handEdits: inout [String]) {
        guard let b = blocks.firstIndex(where: isSupplement) else {
            handEdits.append("Supplements")
            return
        }
        var lines = blocks[b].text.components(separatedBy: "\n")
        switch change.op {
        case .add:
            guard let item = change.after else { return }
            let bullet = lines.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("-") }?.prefix { $0 == "-" || $0 == " " } ?? "- "
            lines.append("\(bullet)\(item)")
        case .remove, .replace, .set:
            guard let before = change.before else { return }
            let matches = lines.indices.filter { lines[$0].lowercased().contains(before.lowercased()) }
            guard matches.count == 1 else {
                handEdits.append(blocks[b].title)
                return
            }
            if change.op == .remove {
                lines.remove(at: matches[0])
            } else if let after = change.after {
                lines[matches[0]] = lines[matches[0]].replacingOccurrences(of: before, with: after, options: .caseInsensitive)
            }
        default:
            handEdits.append(blocks[b].title)
            return
        }
        blocks[b].text = lines.joined(separator: "\n")
    }

    // MARK: Program

    /// The path's day slug and exercise slug: "program.upper_a.bench_press.load" → ("upper_a", "bench_press", "load").
    static func programPath(_ path: String) -> (day: String, exercise: String?, field: String?)? {
        let parts = path.split(separator: ".").map(String.init)
        guard parts.count >= 2, parts[0] == "program" else { return nil }
        return (parts[1], parts.count > 2 ? parts[2] : nil, parts.count > 3 ? parts[3] : nil)
    }

    /// Mirrors the backend's `slug`: lowercase, runs of non-alphanumerics become "_".
    static func slug(_ text: String) -> String {
        var out = ""
        var pendingUnderscore = false
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber, ch.isASCII {
                if pendingUnderscore, !out.isEmpty { out.append("_") }
                pendingUnderscore = false
                out.append(ch)
            } else {
                pendingUnderscore = true
            }
        }
        return out.isEmpty ? "item" : out
    }

    static func applyProgram(_ change: PlanChange, to program: inout Program, today: Date, calendar: Calendar) {
        guard let target = programPath(change.path) else { return }
        let from = change.appliesFromDate ?? today
        for w in program.weeks.indices {
            for d in program.weeks[w].days.indices {
                let day = program.weeks[w].days[d]
                guard slug(day.name) == target.day else { continue }
                // A week whose sessions all happened before `from` is left alone: the past stays logged as it was.
                if weekIsPast(program.weeks[w], before: from, calendar: calendar) { continue }
                if change.kind == .exerciseAdd, let name = change.after {
                    let id = unique("\(day.id)_\(slug(name))", in: day.exercises.map(\.id))
                    let template = day.exercises.first?.sets.first.map { PlannedSet(reps: $0.reps, repsMin: $0.repsMin, repsMax: $0.repsMax, loadLb: nil, rpe: nil, rir: nil) }
                        ?? PlannedSet(reps: nil, repsMin: nil, repsMax: nil, loadLb: nil, rpe: nil, rir: nil)
                    program.weeks[w].days[d].exercises.append(
                        PlannedExercise(id: id, name: name, sets: [template, template, template], equipment: nil, restSeconds: nil, notes: "Added by the coach: \(change.quote)")
                    )
                    continue
                }
                guard let exerciseSlug = target.exercise else { continue }
                guard let e = day.exercises.firstIndex(where: { slug($0.name) == exerciseSlug }) else { continue }
                switch change.kind {
                case .exerciseRemove:
                    program.weeks[w].days[d].exercises.remove(at: e)
                case .exerciseSwap:
                    if let name = change.after {
                        program.weeks[w].days[d].exercises[e].name = name
                        program.weeks[w].days[d].exercises[e].equipment = Equipment.infer(from: name)
                        program.weeks[w].days[d].exercises[e].notes = "Swapped by the coach: \(change.quote)"
                    }
                case .sets:
                    if let n = number(in: change.after).map(Int.init), n > 0 {
                        var sets = program.weeks[w].days[d].exercises[e].sets
                        let last = sets.last ?? PlannedSet(reps: nil, repsMin: nil, repsMax: nil, loadLb: nil, rpe: nil, rir: nil)
                        while sets.count < n { sets.append(last) }
                        while sets.count > n { sets.removeLast() }
                        program.weeks[w].days[d].exercises[e].sets = sets
                    }
                case .reps:
                    guard let after = change.after else { continue }
                    let nums = numbers(in: after).map(Int.init)
                    for s in program.weeks[w].days[d].exercises[e].sets.indices {
                        if nums.count >= 2 {
                            program.weeks[w].days[d].exercises[e].sets[s].reps = nil
                            program.weeks[w].days[d].exercises[e].sets[s].repsMin = nums[0]
                            program.weeks[w].days[d].exercises[e].sets[s].repsMax = nums[1]
                        } else if let n = nums.first {
                            program.weeks[w].days[d].exercises[e].sets[s].reps = n
                            program.weeks[w].days[d].exercises[e].sets[s].repsMin = nil
                            program.weeks[w].days[d].exercises[e].sets[s].repsMax = nil
                        }
                    }
                case .load:
                    if let lb = number(in: change.after) {
                        for s in program.weeks[w].days[d].exercises[e].sets.indices {
                            program.weeks[w].days[d].exercises[e].sets[s].loadLb = lb
                        }
                    }
                case .rest:
                    if let seconds = number(in: change.after) {
                        program.weeks[w].days[d].exercises[e].restSeconds = Int(seconds)
                    }
                default:
                    break
                }
            }
        }
    }

    /// Without dates on the program, a week is "past" only when the change starts later than today
    /// and this week is before the week that holds today. Programs carry no dates, so the first
    /// remaining week is taken as the current one: every week changes from `from` onwards.
    static func weekIsPast(_ week: ProgramWeek, before from: Date, calendar: Calendar) -> Bool {
        false
    }

    static func unique(_ base: String, in taken: [String]) -> String {
        var candidate = base
        var n = 2
        while taken.contains(candidate) {
            candidate = "\(base)_\(n)"
            n += 1
        }
        return candidate
    }
}
