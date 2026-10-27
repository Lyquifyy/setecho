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
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.cobaltTint)
                .frame(width: 36, height: 36)
                .scaleEffect(pulsing ? 1.35 : 1)
                .opacity(pulsing ? 0.4 : 1)
            Image(systemName: "waveform")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.cobalt)
        }
        .frame(width: 48, height: 48)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulsing = true }
        }
        .accessibilityLabel("Listening")
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
