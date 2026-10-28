import SwiftUI

// Hands-free screens are read from 2–3 m away (DESIGN.md Type). Nothing smaller than .hudLabel on them.

extension Font {
    /// "225 × 8"
    static let hudTarget = Font.system(size: 96, weight: .bold).monospacedDigit()
    /// The state line: Ready · Recording · Saved · Rest 2:14 · Listening
    static let hudState = Font.system(size: 34, weight: .semibold).monospacedDigit()
    /// Everything else on a hands-free screen.
    static let hudLabel = Font.system(size: 22, weight: .regular).monospacedDigit()
}

/// The hands-free state line, with an icon.
struct HUDState: View {
    enum State: Equatable {
        case ready
        case recording
        case saved
        case rest(remaining: Int)
        /// A timed set running (DESIGN.md Session, Hold).
        case hold(remaining: Int)
        /// Warm-up mode: the counter does not move (DESIGN.md Session, Warm-up).
        case warmup(Int)
        case listening
        case paused
        case ended
    }

    let state: State

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            icon
            Text(label).font(.hudState).foregroundStyle(Theme.navy)
        }
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        switch state {
        case .ready: "Ready"
        case .recording: "Recording"
        case .saved: "Saved"
        case .rest(let remaining): "Rest \(Format.duration(TimeInterval(remaining)))"
        case .hold(let remaining): "Hold \(Format.duration(TimeInterval(remaining)))"
        case .warmup(let n): "Warm-up \(n)"
        case .listening: "Listening"
        case .paused: "Paused"
        case .ended: "Session over"
        }
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .recording:
            Circle().fill(Theme.recording).frame(width: 18, height: 18)
        case .listening:
            ListeningIndicator()
        case .saved:
            Image(systemName: "checkmark.circle.fill").font(.hudState).foregroundStyle(Theme.cobalt)
        case .rest:
            Image(systemName: "timer").font(.hudState).foregroundStyle(Theme.cobalt)
        case .hold:
            Image(systemName: "hourglass").font(.hudState).foregroundStyle(Theme.cobalt)
        case .warmup:
            Image(systemName: "flame").font(.hudState).foregroundStyle(Theme.textSecondary)
        case .paused:
            Image(systemName: "pause.circle").font(.hudState).foregroundStyle(Theme.textSecondary)
        case .ready:
            Image(systemName: "figure.strengthtraining.traditional").font(.hudState).foregroundStyle(Theme.cobalt)
        case .ended:
            Image(systemName: "flag.checkered").font(.hudState).foregroundStyle(Theme.navy)
        }
    }
}

/// Which session inputs are live (DESIGN.md Components): camera and watch, cobalt when on,
/// secondary with a slash when not. The watch icon is hidden until a watch has ever connected.
struct InputStatus: View {
    let camera: Bool
    var watch: Bool?

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: camera ? "video.fill" : "video.slash")
                .foregroundStyle(camera ? Theme.cobalt : Theme.textSecondary)
            if let watch {
                Image(systemName: watch ? "applewatch" : "applewatch.slash")
                    .foregroundStyle(watch ? Theme.cobalt : Theme.textSecondary)
            }
        }
        .font(.hudLabel.weight(.semibold))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        var parts = [camera ? "Camera on" : "Camera off"]
        if let watch { parts.append(watch ? "watch on" : "watch off") }
        return parts.joined(separator: ", ")
    }
}

/// A cobalt-tint pulse shown whenever the mic is taking commands, so the athlete knows when they're heard.
struct ListeningIndicator: View {
    /// The mic level above the room, 0…1. Given, the ring follows his voice instead of pulsing.
    var level: Double?
    /// "Your turn" under the ring, read from the tripod (hands-free screens).
    var label: String?
    @State private var pulsing = false

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            ZStack {
                Circle()
                    .fill(Theme.cobaltTint)
                    .frame(width: 72, height: 72)
                    .scaleEffect(level.map { 1 + 0.6 * $0 } ?? (pulsing ? 1.35 : 1))
                    .opacity(level.map { 0.55 + 0.45 * $0 } ?? (pulsing ? 0.4 : 1))
                    .animation(.easeOut(duration: 0.12), value: level ?? 0)
                Image(systemName: "waveform")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.cobalt)
            }
            .frame(width: 96, height: 96)
            if let label {
                Text(label).font(.hudLabel.weight(.semibold)).foregroundStyle(Theme.cobalt)
            }
        }
        .onAppear {
            guard level == nil else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulsing = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label ?? "Listening")
    }
}

/// A transient line under the HUD confirming a voice action: "Set 3 → 7 reps. Say undo to revert."
struct VoiceEcho: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.hudLabel)
            .foregroundStyle(Theme.navy)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .frame(maxWidth: .infinity)
            .background(Theme.cobaltTint, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .transition(.opacity)
    }
}

#Preview {
    VStack(spacing: Theme.gutter) {
        Text("225 × 8").font(.hudTarget).foregroundStyle(Theme.navy)
        HUDState(state: .ready)
        HUDState(state: .recording)
        HUDState(state: .rest(remaining: 134))
        HUDState(state: .listening)
        InputStatus(camera: true, watch: false)
        VoiceEcho(text: "Set 3 → 7 reps. Say undo to revert.")
    }
    .padding(Theme.gutter)
    .background(Theme.page)
}


/// Under a set's result: "~1 left · slowed 38% · estimated" (DESIGN.md Components, `EffortLine`).
struct EffortLine: View {
    let set: LoggedSet

    var body: some View {
        if let text {
            Text(text).font(.hudLabel).secondaryText().accessibilityLabel(text.replacingOccurrences(of: "~", with: "about "))
        }
    }

    private var text: String? {
        var parts: [String] = []
        if let rpe = set.rpe {
            parts.append("RPE \(Format.number(rpe)) · you said")
        } else if let rir = set.repCount.estimatedRIR {
            parts.append(Effort.leftText(rir: rir))
        }
        if let loss = set.repCount.velocityLossPct { parts.append("slowed \(Int(loss.rounded()))%") }
        if set.rpe == nil, set.repCount.estimatedRIR != nil { parts.append("estimated") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// In the HUD during rest: "Next: 215 × 8" on a yellow fill, his rule beneath, and what to say
/// (DESIGN.md Components, `SuggestionTag`).
struct SuggestionTag: View {
    let suggestion: LoadSuggestion
    let reps: String

    var body: some View {
        VStack(spacing: Theme.Space.xxs) {
            TargetTag(text: suggestion.scope == .nextSession ? "Next session: \(Format.number(suggestion.toLb)) × \(reps)" : "Next: \(Format.number(suggestion.toLb)) × \(reps)")
                .scaleEffect(1.3)
                .padding(.vertical, Theme.Space.xs)
            Text("his rule · \(suggestion.reason)").font(.hudLabel).secondaryText().multilineTextAlignment(.center)
            Text(suggestion.role == .backOff ? "Say 'go with it' or a weight" : "Say 'go with it' or 'keep it'").font(.hudLabel).secondaryText()
        }
        .accessibilityElement(children: .combine)
    }
}
