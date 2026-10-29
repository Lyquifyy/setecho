import SwiftUI

/// "Last time 145 × 9" under a lift that has a top set (HANDOFF.md §7, The logbook line): from the
/// app's log when it has the lift, else the newer of his paper logbook and his imported Liftoff or
/// Garmin sets. Without any, "Add last time" opens a small form; the entry is the line Setecho says
/// before the top set.
struct LastTimeRow: View {
    @Environment(Store.self) private var store
    let exercise: PlannedExercise
    @State private var editing = false

    /// Lifts the logbook line applies to: the first set is a top set or a straight set, not a hold.
    static func applies(to exercise: PlannedExercise) -> Bool {
        guard let first = exercise.sets.first, !first.isTimed else { return false }
        return first.role == .top || first.role == nil
    }

    private var role: SetRole? { exercise.sets.first?.role }
    private var key: String { SessionEngine.loadKey(exercise.id, role) }
    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if let last = store.lastSets[key] {
                Text("Last time \(Format.number(last.loadLb)) × \(last.reps)").font(.subheadline).monospacedDigit().secondaryText()
                SourceChip(source: last.source ?? "Logbook")
                Spacer()
                if last.source != "Training log" { LinkButton(title: "Edit", chevron: .none) { editing = true } }
            } else {
                LinkButton(title: "Add last time", chevron: .none) { editing = true }
                Spacer()
            }
        }
        .sheet(isPresented: $editing) {
            LastTimeForm(exercise: exercise, role: role, current: store.lastSets[key]) { load, reps in
                store.addLogbook(LogbookEntry(id: UUID(), exerciseId: exercise.id, role: role, loadLb: load, reps: reps, date: .now))
            }
            .presentationDetents([.medium])
        }
    }
}

/// Weight × reps from his paper logbook, for one lift.
private struct LastTimeForm: View {
    @Environment(\.dismiss) private var dismiss
    let exercise: PlannedExercise
    let role: SetRole?
    let current: LastSet?
    let save: (Double, Int) -> Void
    @State private var load = ""
    @State private var reps = ""

    private var parsed: (Double, Int)? {
        guard let l = Double(load.replacingOccurrences(of: ",", with: ".")), l > 0, let r = Int(reps), r > 0 else { return nil }
        return (l, r)
    }

    var body: some View {
        ScreenScaffold(onClose: { dismiss() }) {
            TitleBlock(eyebrow: exercise.name, title: "Last time", subtitle: "\(role == .top ? "Your last top set" : "Your last set"), from your logbook. Setecho says it before the top set.")
            SectionCard("Weight × reps") {
                HStack(spacing: Theme.Space.s) {
                    SettingsField(placeholder: "Weight (lb)", text: $load).keyboardType(.decimalPad)
                    Text("×").font(.body).secondaryText()
                    SettingsField(placeholder: "Reps", text: $reps).keyboardType(.numberPad)
                }
            }
        } footer: {
            Button("Save") {
                guard let (l, r) = parsed else { return }
                save(l, r)
                dismiss()
            }
            .buttonStyle(.setechoPrimary)
            .disabled(parsed == nil)
        }
        .onAppear {
            if let current {
                load = Format.number(current.loadLb)
                reps = "\(current.reps)"
            }
        }
    }
}
