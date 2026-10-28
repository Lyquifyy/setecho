import SwiftUI

/// Every design-system component with board values. Open the "Components" preview in Xcode to review them.
/// Values here are illustrative and only for this gallery.
struct ComponentGallery: View {
    var body: some View {
        ScreenScaffold {
            TitleBlock(eyebrow: "Upper A · Week 4", title: "Bench press", subtitle: "4 × 8 · Target RPE 8")

            SectionCard("Next set") {
                HStack(spacing: Theme.Space.s) {
                    TargetTag(text: "Set 4\nof 4")
                    LoadRepsText(loadLb: 220, reps: 8)
                    Spacer(minLength: Theme.Space.xs)
                    Button("Edit load") {}.buttonStyle(.setechoOutline)
                }
                CardDivider()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reduce 5 lb.").font(.headline).foregroundStyle(Theme.navy)
                    Text("31% velocity loss on set 3.").font(.subheadline).foregroundStyle(Theme.navy)
                }
                LinkButton(title: "Why this load?", chevron: .none, underline: true) {}
            }

            SectionCard("Recorded set") {
                HStack(spacing: Theme.gutter) {
                    MetricText(value: "225", unit: "lb")
                    VerticalCardDivider().frame(height: 44)
                    MetricText(value: "8", unit: "reps")
                }
                CardDivider()
                HStack {
                    PlayButton(accessibilityLabel: "Play set 3 video") {}
                    SetThumbnail(width: 88, height: 56)
                    Spacer()
                    LinkButton(title: "View set") {}
                }
            }

            SegmentTabs(items: [.init(value: 0, title: "All"), .init(value: 1, title: "To do", badge: 4, highlight: true),
                                .init(value: 2, title: "Ready", badge: 18)], selection: .constant(0))

            SectionCard("Day 2", accessory: { TargetTag(text: "Up next") }) {
                ExerciseDisclosureRow(number: 1, exercise: PlannedExercise(
                    id: "bench", name: "Bench press",
                    sets: Array(repeating: PlannedSet(reps: 8, repsMin: nil, repsMax: nil, loadLb: 185, rpe: 8, rir: nil), count: 4),
                    restSeconds: 150, notes: nil), expanded: true) {}
                CardDivider()
                HStack(spacing: Theme.Space.xs) {
                    Button("Change day", systemImage: "arrow.left.arrow.right") {}.buttonStyle(.setechoTonalWide)
                    IconButton(systemImage: "rectangle.expand.vertical", accessibilityLabel: "Show every exercise's details") {}
                }
            }

            HStack(spacing: Theme.gutter) {
                TileCard(title: "Check-in", systemImage: "checklist", action: {}) {
                    Text("11 of 22 ready").font(.subheadline).monospacedDigit().foregroundStyle(Theme.navy)
                    MeterBar(value: 11, total: 22)
                }
                TileCard(title: "Photos", systemImage: "camera", action: {}) {
                    Text("Next due Thu").font(.subheadline).secondaryText()
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            // The spoken check-in: the step track, a line each way, an answer with its check, whose turn it is.
            StepTrack(steps: [.init(id: "w", title: "Weight"), .init(id: "g", title: "Glucose"), .init(id: "p", title: "Photos"),
                              .init(id: "q", title: "Questions"), .init(id: "r", title: "Review")], current: 1)
            SetechoLine(text: "Okay. And your fasted glucose?", current: true)
            AthleteLine(text: "Ninety one.")
            AnswerCard(label: "Fasted blood glucose", value: "91", source: "You said · Thu")
            VoiceBar(phase: .listening, level: 0.4)
            HoldButton(title: "Hold to stop") {}

            SectionCard("Colors") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: Theme.Space.s)], spacing: Theme.Space.s) {
                    swatch("cobalt", Theme.cobalt)
                    swatch("navy", Theme.navy)
                    swatch("yellow", Theme.yellow)
                    swatch("page", Theme.page)
                    swatch("border", Theme.border)
                    swatch("textSecondary", Theme.textSecondary)
                    swatch("cobaltTint", Theme.cobaltTint)
                    swatch("fieldFill", Theme.fieldFill)
                }
            }
        } footer: {
            Button {} label: { Label("Film set 4", systemImage: "video.fill") }
                .buttonStyle(.setechoPrimary)
        }
    }

    private func swatch(_ name: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color)
                .frame(height: 40)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            Text(name).font(.caption).secondaryText()
        }
    }
}

#Preview("Components") {
    ComponentGallery()
}
