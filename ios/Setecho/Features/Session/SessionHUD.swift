import SwiftUI
import UIKit

// THESIS: The session screen is his own picture with one sheet of paper held up in front of it:
// the camera fills the stage, the white sheet carries the set, and everything is said once.
// OWN-WORLD: The app's own colours at hands-free scale: the camera or the navy stage on top, a white
// sheet below (top corners 28 pt), navy SF Pro bold with tabular numbers, the yellow tag for the one
// thing waiting on him, cobalt for the mark, data sources and the tonal end button, the red dot only
// while recording. Half dark, never a dark theme (Oct 29).
// STORY: From the bench he sees where he is (the strip), what to do (the sheet), and that he was
// heard (the voice line), without walking to the phone.
// FIRST VIEWPORT: The lifts strip and the state pill on his picture; the sheet with the exercise,
// its tag, the target, one voice line and the hold-to-end.
// SIGNATURE: the rest countdown thins as the rest drains; a spoken line fills word by word; the
// yellow tag travels from the set to the next set.

/// Everything the session screen shows, as plain values: previews and `SessionHUDRenderTests` draw
/// every state from it before it is wired to the engine.
struct SessionHUDModel: Equatable {
    enum Phase: Equatable {
        case ready
        case armed
        case recording(elapsed: Int)
        /// Seconds left; negative is overtime (+0:40).
        case rest(remaining: Int, total: Int)
        case hold(remaining: Int, total: Int, index: Int, count: Int)
        case done
    }

    struct ExerciseDots: Equatable, Identifiable {
        enum Dot: Equatable { case done, current, upcoming, skipped }
        var id: String { name }
        var name: String
        var dots: [Dot]
        var isAddOn = false
    }

    /// The talking indicator: what's being said right now, by whom.
    enum Voice: Equatable {
        /// Nothing being said: two or three things he could say now.
        case idle(hints: [String])
        /// He's talking; his words as they arrive.
        case hearing(String, level: Double)
        /// His words are in; the turn is being read.
        case thinking(String)
        /// Setecho is saying a line; `spoken` of its words have been said.
        case speaking(String, spoken: Int)
        /// He's talking to someone else: nothing is read or said until "I'm back" (or a tap).
        case quiet
    }

    /// One fact about the last set, and whether it's a data source (cobalt, like a source chip).
    struct Fact: Equatable, Hashable {
        var text: String
        var source = false
    }

    struct Summary: Equatable {
        struct Line: Equatable, Identifiable {
            var id: String { exercise }
            var exercise: String
            var top: String
            var beat: String?
        }
        var lines: [Line]
        var notes: [String]
        /// "52 min · 13 min away": how long the session ran, and the time away from the sets.
        var time: String? = nil
    }

    var phase: Phase
    /// The phone is in a pocket (camera off duty): only the essentials, larger.
    var pocket = false
    var progress: [ExerciseDots]
    var micLabel: String
    var micOnHim: Bool
    var exercise: String
    /// "Top set", "Back-off", "Warm-up 2"…
    var role: String?
    var setLabel: String
    /// The target: pounds (nil for bodyweight or a hold) and reps, "8–10" or "20 s".
    var load: Double?
    var reps: String
    var lastTime: String?
    var voice: Voice
    /// Rest: the set just done, as facts.
    var result: [Fact] = []
    /// The saved set's load, never the upcoming target or an animated invented value.
    var loggedLoadLb: Double? = nil
    /// Rest: the next set ("Back-off 145 × 8") and what to say to it.
    var next: String?
    var nextAsk: String?
    var summary: Summary?
    /// The camera is filming him (the front camera, facing the bench). Off for a morning of holds.
    var camera = true
    /// His lock-on box in the camera's frame, normalized, top-left origin (`BodyTracker`).
    var lockBox: CGRect?
    /// The framing cue on the stage's foot, like the photo session's: "Upper body only · step back"
    /// while the camera sees him from the hips up in Ready or Armed (Oct 31, the deadlifts).
    var framing: String?
}

/// The live camera, injected by the session (the front camera's preview layer, mirrored for him);
/// previews show a placeholder, and the screenshots a sample frame.
extension EnvironmentValues {
    @Entry var sessionCameraFeed: AnyView? = nil
    /// The set he just did, looping, for the camera card during rest.
    @Entry var sessionReplayFeed: AnyView? = nil
}

extension SessionHUDModel {
    /// The camera's upright frame, width over height (1080 × 1920 portrait).
    static let frameAspect: CGFloat = 9.0 / 16.0
}

extension SessionHUDModel.Phase {
    /// The state, always named in text: never colour alone.
    var name: String {
        switch self {
        case .ready: "Ready"
        case .armed: "Armed"
        case .recording: "Recording"
        case .rest(let left, _): left > 0 ? "Resting" : "Rest's up"
        case .hold: "Holding"
        case .done: "Done"
        }
    }
}

// MARK: The screen

/// The session screen on the hands-free layout (`StageSheet`): his camera fills the stage, edge
/// to edge, with the lifts across the top and the state on one pill; the white sheet holds the
/// set, one voice line and the hold-to-end. Without the camera (a hold, the pocket, the end) the
/// stage is navy and carries the one big thing in white. Every state is said once.
struct SessionHUD: View {
    var model: SessionHUDModel
    /// The long press that ends the session (no tap ends anything); nil in previews.
    var onEnd: (() -> Void)?
    /// Developer → Rehearse a session: the typed line field, above the end button.
    var footer: AnyView?
    /// A tap on the voice line: quiet, or back (the voice equivalent is "quiet" / "I'm back").
    var onVoiceTap: (() -> Void)?
    /// A tap on the audio pill: back onto the AirPods mic after they came back.
    var onAudioTap: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The yellow tag travels: the set's tag becomes the next set's tag in rest.
    @Namespace private var tagSpace

    var body: some View {
        StageSheet {
            if showsCamera { CameraStage(model: model) } else { Theme.stage }
        } overlay: {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                LiftsStrip(exercises: model.progress)
                StatusRow(model: model, camera: showsCamera, onAudioTap: onAudioTap)
                Spacer(minLength: 0)
                stageHero
                    .id(stageKey)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            }
        } sheet: {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                sheetContent
                    .id(sheetKey)
                    .transition(arrival)
                // A question waiting on him outside rest (in rest, the voice line carries it).
                if let ask = model.nextAsk, !isRest { AskRow(text: ask) }
                if !model.pocket, model.phase != .done {
                    CardDivider()
                    VoiceLine(voice: model.voice, prompt: idlePrompt)
                        .contentShape(Rectangle())
                        .onTapGesture { onVoiceTap?() }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(model.voice == .quiet ? "Listens again" : "Goes quiet while you talk to someone")
                }
                if let footer { footer }
                EndButton(label: model.phase == .done ? "Hold to close" : "Hold to end session", onEnd: onEnd)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.5, bounce: 0.15), value: model.phase)
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.5, bounce: 0.15), value: model.pocket)
    }

    private var isRest: Bool {
        if case .rest = model.phase { return true }
        return false
    }

    /// He sees himself on the bench whenever the camera is filming him; in a pocket, or for a
    /// morning of holds, the stage is navy.
    private var showsCamera: Bool {
        guard model.camera, !model.pocket else { return false }
        switch model.phase {
        case .ready, .armed, .recording, .rest: return true
        case .hold, .done: return false
        }
    }

    /// A card arriving rises into place, or only fades under Reduce Motion (PRODUCT.md).
    private var arrival: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity)
    }

    private var tag: Namespace.ID? { reduceMotion ? nil : tagSpace }

    /// What the voice line says when nobody is talking: the one thing to say now.
    private var idlePrompt: Text? {
        switch model.phase {
        case .ready: Text("Say ") + Text("\u{201C}go\u{201D}").fontWeight(.bold).foregroundStyle(Theme.navy) + Text(" when you lift.")
        case .rest: model.nextAsk.map { Text($0) }
        default: nil
        }
    }

    private var sheetKey: String {
        switch model.phase {
        case .ready, .armed, .recording: "set"
        case .rest: model.pocket ? "rest-pocket" : "rest"
        case .hold: "hold"
        case .done: "done"
        }
    }

    private var stageKey: String { showsCamera ? "camera-\(sheetKey)" : "stage-\(sheetKey)" }

    // MARK: On the stage

    @ViewBuilder private var stageHero: some View {
        switch model.phase {
        case .rest(let remaining, let total):
            if showsCamera {
                if !model.result.isEmpty {
                    ResultSticker(facts: model.result, loadLb: model.loggedLoadLb)
                        .transition(arrival)
                }
            } else {
                StageClock(remaining: remaining, total: total, caption: "Resting")
            }
        case .hold(let remaining, let total, let index, let count):
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                StageClock(remaining: remaining, total: total, caption: "Holding")
                HoldsTrack(index: index, count: count)
            }
        case .done:
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Label("Done", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(Theme.onStage)
                if let time = model.summary?.time {
                    Text(time).font(.hudLabel).foregroundStyle(Theme.onStageSecondary)
                }
                Text("Your coach sees all of it on Thursday.").font(.hudLabel).foregroundStyle(Theme.onStageSecondary)
            }
        case .ready, .armed, .recording:
            // The camera is off (a set with no tripod): the state, named, is the stage.
            if !showsCamera { StageState(phase: model.phase) }
        }
    }

    // MARK: In the sheet

    @ViewBuilder private var sheetContent: some View {
        switch model.phase {
        case .ready, .armed, .recording:
            SetBlock(model: model, tagSpace: tag)
        case .rest(let remaining, let total):
            RestBlock(model: model, remaining: remaining, total: total, showsClock: showsCamera, tagSpace: tag)
        case .hold(_, _, let index, let count):
            SetHeader(exercise: model.exercise) { HUDTag(text: "Hold \(index) of \(count)") }
        case .done:
            DoneBlock(summary: model.summary)
        }
    }
}

/// A yellow tag at hands-free scale: the next set waiting on him (`TargetTag`, read from the bench).
private struct HUDTag: View {
    var text: String
    /// The tag that moves between the set and the next set (nil under Reduce Motion).
    var travels: Namespace.ID?
    var body: some View {
        Text(text)
            .font(.hudLabel.weight(.semibold))
            .foregroundStyle(Theme.navy)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.yellow, in: RoundedRectangle(cornerRadius: Theme.Radius.tag, style: .continuous))
            .contentTransition(.opacity)
            .travelling(in: travels)
    }
}

private extension View {
    @ViewBuilder func travelling(in space: Namespace.ID?) -> some View {
        if let space { matchedGeometryEffect(id: "next-tag", in: space) } else { self }
    }
}

/// "65 lb × 8–10": tabular digits, the unit and the times sign smaller (`LoadRepsText` at hands-free scale).
private struct TargetText: View {
    var load: Double?
    var reps: String
    var size: CGFloat = 72

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.08) {
            if let load {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Format.number(load)).font(.system(size: size, weight: .bold).monospacedDigit())
                        .contentTransition(.numericText())
                    Text("lb").font(.system(size: size * 0.36, weight: .semibold))
                }
                Text("×").font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            }
            Text(reps).font(.system(size: size, weight: .bold).monospacedDigit())
                .contentTransition(.numericText())
        }
        .foregroundStyle(Theme.navy)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(load.map { "\(Format.number($0)) pounds for \(reps)" } ?? reps)
    }
}

private extension Font {
    /// A clock whose weight follows a value (0 regular … 1 heavy): the rest drains out of the digits.
    static func drainingClock(_ size: CGFloat, fullness: Double) -> Font {
        let weight = UIFont.Weight(rawValue: CGFloat(0.0 + 0.56 * max(0, min(1, fullness))))
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        let tabular = base.fontDescriptor.addingAttributes([.featureSettings: [[
            UIFontDescriptor.FeatureKey.type: kNumberSpacingType, UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
        ]]])
        return Font(UIFont(descriptor: tabular, size: size))
    }
}

// MARK: The top of the stage

/// Today's lifts, as he asked to keep them: a short name, a dot per set, on a white bar across the
/// top. Done dots navy, the current set yellow (waiting on him), upcoming ones open, a skipped
/// exercise a dash; add-ons after a hairline. Every name stays whole: the names step down to fit
/// the day, and a day too long for any size (his real days run to 19 sets) becomes one flexible
/// bar per lift, a segment per set, with only the lift he's on named. That last form always fits,
/// so the strip can never push the screen wider than the phone.
struct LiftsStrip: View {
    var exercises: [SessionHUDModel.ExerciseDots]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(nameSize: 20)
            row(nameSize: 17)
            row(nameSize: 15)
            bars
        }
        .padding(.vertical, Theme.Space.s)
        .padding(.horizontal, Theme.Space.m)
        .frame(maxWidth: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today: " + exercises.map { "\($0.name), \($0.dots.filter { $0 == .done }.count) of \($0.dots.count)" }.joined(separator: "; "))
    }

    private func row(nameSize: CGFloat) -> some View {
        columns { ex, current in
            VStack(spacing: Theme.Space.xs) {
                Text(ex.name)
                    .font(.system(size: nameSize, weight: current ? .bold : .semibold))
                    .foregroundStyle(current ? Theme.navy : Theme.textSecondary)
                    .fixedSize()
                dots(ex)
            }
        }
    }

    /// The longest days: a bar per lift that shares the width, a segment per set, and the name of
    /// the lift he's on (or the next one up) above them. Nothing in it has a fixed width.
    private var bars: some View {
        let focus = exercises.firstIndex { $0.dots.contains(.current) } ?? exercises.firstIndex { $0.dots.contains(.upcoming) }
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if let focus {
                HStack(spacing: Theme.Space.xs) {
                    Text(exercises[focus].name).font(.hudLabel.weight(.bold)).foregroundStyle(Theme.navy)
                    Text("· \(focus + 1) of \(exercises.count)").font(.hudLabel).foregroundStyle(Theme.textSecondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            HStack(spacing: Theme.Space.xs) {
                ForEach(Array(exercises.enumerated()), id: \.element.id) { i, ex in
                    HStack(spacing: 2) {
                        ForEach(Array(ex.dots.enumerated()), id: \.offset) { _, dot in Segment(dot: dot) }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(3)
                    .background(i == focus ? Theme.page : .clear, in: Capsule())
                }
            }
        }
    }

    /// One set in the bars: done navy, current yellow, upcoming open, skipped dim.
    private struct Segment: View {
        var dot: SessionHUDModel.ExerciseDots.Dot
        var body: some View {
            Capsule()
                .fill(fill)
                .overlay { if dot == .upcoming { Capsule().strokeBorder(Theme.textSecondary.opacity(0.45), lineWidth: 1.5) } }
                .frame(maxWidth: .infinity, minHeight: 10, maxHeight: 10)
        }
        private var fill: Color {
            switch dot {
            case .done: Theme.navy
            case .current: Theme.yellow
            case .upcoming: .clear
            case .skipped: Theme.border
            }
        }
    }

    private func columns<Column: View>(@ViewBuilder _ column: @escaping (SessionHUDModel.ExerciseDots, Bool) -> Column) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(Array(exercises.enumerated()), id: \.element.id) { i, ex in
                if i > 0 {
                    if ex.isAddOn, !exercises[i - 1].isAddOn {
                        Spacer(minLength: Theme.Space.xs)
                        VerticalCardDivider().frame(height: 44)
                    }
                    Spacer(minLength: Theme.Space.s)
                }
                column(ex, ex.dots.contains(.current))
            }
        }
    }

    private func dots(_ ex: SessionHUDModel.ExerciseDots) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(ex.dots.enumerated()), id: \.offset) { _, dot in Dot(dot: dot) }
        }
        .frame(height: 20)
        .fixedSize()
    }

    private struct Dot: View {
        var dot: SessionHUDModel.ExerciseDots.Dot
        var body: some View {
            switch dot {
            case .done: Circle().fill(Theme.navy).frame(width: 13, height: 13)
            case .current:
                Circle().fill(Theme.yellow).frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(Theme.navy, lineWidth: 2.5))
            case .upcoming: Circle().strokeBorder(Theme.textSecondary.opacity(0.45), lineWidth: 2.5).frame(width: 13, height: 13)
            case .skipped: Capsule().fill(Theme.textSecondary).frame(width: 14, height: 4)
            }
        }
    }
}

/// Under the strip: the mark, the state as the camera's pill, and what's connected for audio.
/// The longest pills give way to their short forms before anything is cut.
private struct StatusRow: View {
    var model: SessionHUDModel
    /// The state rides on the camera; on the navy stage the stage itself names it.
    var camera: Bool
    var onAudioTap: (() -> Void)?

    var body: some View {
        // The audio pill gives way to its icon first: the state keeps its words longest.
        ViewThatFits(in: .horizontal) {
            row(long: true, audioLabel: true)
            row(long: true, audioLabel: false)
            row(long: false, audioLabel: false)
            row(long: false, audioLabel: false, flexible: true)
        }
    }

    /// `flexible`: the last resort, where the audio pill's words shrink rather than overflow.
    private func row(long: Bool, audioLabel: Bool, flexible: Bool = false) -> some View {
        HStack(spacing: Theme.Space.s) {
            StageMark()
            if camera { StatePill(phase: model.phase, long: long).fixedSize() }
            Spacer(minLength: 0)
            Group {
                if model.pocket {
                    PocketPill(label: audioLabel)
                } else {
                    AudioConnection(label: model.micLabel, onHim: model.micOnHim, showsLabel: audioLabel || !model.micOnHim, wraps: flexible)
                }
            }
            .fixedSize(horizontal: !flexible, vertical: true)
            .contentShape(Capsule())
            .onTapGesture { onAudioTap?() }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Reconnects the mic you prefer")
        }
    }
}

/// What's connected for audio: the mic in use as a source (cobalt on cobalt tint), or a yellow
/// warning when it's the phone's own mic on the tripod (the one thing he can fix).
struct AudioConnection: View {
    var label: String
    var onHim: Bool
    /// Short of room, the icon alone says the mic is on him; the warning always keeps its words.
    var showsLabel = true
    /// The last resort when the warning still doesn't fit beside the state (Oct 31, "Phone mic · t…"
    /// on a 402 pt phone): its words wrap to a second line instead of being cut.
    var wraps = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: onHim ? (label.contains("AirPods") ? "airpodspro" : "mic.fill") : "exclamationmark.triangle.fill")
            if showsLabel {
                Text(warning)
                    .lineLimit(wraps ? 2 : 1)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(onHim ? Theme.cobalt : Theme.navy)
        .font(.hudLabel.weight(.semibold))
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(onHim ? Theme.cobaltTint : Theme.yellow, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(onHim ? "Listening on \(label)" : noMic ? "No mic connected" : "Using the \(label). It's too far to hear you well.")
    }

    private var noMic: Bool { label == "No mic" }

    /// "AirPods mic"; the phone's own mic "Phone mic · too far"; nothing at all "No mic".
    private var warning: String { onHim || noMic ? label : "\(label) · too far" }
}

/// In a pocket the screen isn't the point: the pill says the buzzes carry it.
struct PocketPill: View {
    var label = true
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone.radiowaves.left.and.right")
            if label { Text("Pocket · buzzes on") }
        }
        .font(.hudLabel.weight(.semibold))
        .foregroundStyle(Theme.cobalt)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(Theme.cobaltTint, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pocket mode, buzzes on")
    }
}

/// The state on the camera, as on the Filming board: "○ Ready", yellow "● Armed · lift when
/// ready", "● Recording · 0:24", "▶ Your last set".
private struct StatePill: View {
    var phase: SessionHUDModel.Phase
    var long = true

    var body: some View {
        switch phase {
        case .ready:
            CameraPill { Circle().strokeBorder(.white, lineWidth: 2.5).frame(width: 16, height: 16); Text("Ready") }
        case .armed:
            CameraPill(fill: Theme.yellow, ink: Theme.navy) {
                Circle().fill(Theme.navy).frame(width: 12, height: 12); Text(long ? "Armed · lift when ready" : "Armed")
            }
        case .recording(let elapsed):
            CameraPill {
                RecordingDot()
                Text(long ? "Recording · \(Format.duration(TimeInterval(elapsed)))" : "Rec \(Format.duration(TimeInterval(elapsed)))")
                    .contentTransition(.numericText())
            }
        case .rest:
            CameraPill { Image(systemName: "play.fill"); Text(long ? "Your last set" : "Last set") }
        case .hold, .done:
            EmptyView()
        }
    }
}

/// The red dot, breathing while it records.
private struct RecordingDot: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            Circle().fill(Theme.recording).frame(width: 16, height: 16).opacity(on ? 1 : 0.45)
        }
    }
}

/// The dark pill on the camera ("● Recording · 00:18").
private struct CameraPill<Content: View>: View {
    var fill: Color = Theme.cameraFill.opacity(0.78)
    var ink: Color = .white
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 8) { content }
            .font(.hudLabel.weight(.semibold).monospacedDigit())
            .foregroundStyle(ink)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(fill, in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

// MARK: The stage itself

/// His live image fills the stage (the set he just did, looping, during rest), with yellow
/// corner brackets on him once the camera has locked on.
private struct CameraStage: View {
    var model: SessionHUDModel
    @Environment(\.sessionCameraFeed) private var liveFeed
    @Environment(\.sessionReplayFeed) private var replayFeed

    private var feed: AnyView? {
        if case .rest = model.phase, let replayFeed { return replayFeed }
        return liveFeed
    }

    var body: some View {
        ZStack {
            Theme.cameraFill
            if let feed {
                feed
            } else {
                Image(systemName: "figure.strengthtraining.traditional").font(.system(size: 64)).foregroundStyle(.white.opacity(0.35))
            }
            GeometryReader { proxy in
                if brackets, let box = model.lockBox {
                    // The picture fills the stage (aspect fill): place the box where his image actually is.
                    let size = proxy.size
                    let shown = size.width / size.height > SessionHUDModel.frameAspect
                        ? CGSize(width: size.width, height: size.width / SessionHUDModel.frameAspect)
                        : CGSize(width: size.height * SessionHUDModel.frameAspect, height: size.height)
                    let origin = CGPoint(x: (size.width - shown.width) / 2, y: (size.height - shown.height) / 2)
                    LockBrackets()
                        .frame(width: box.width * shown.width, height: box.height * shown.height)
                        .offset(x: origin.x + box.minX * shown.width, y: origin.y + box.minY * shown.height)
                        .animation(.linear(duration: 0.12), value: box)
                }
            }
            if let cue = model.framing {
                VStack {
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                        Text(cue)
                    }
                    .font(.hudLabel.weight(.semibold))
                    .foregroundStyle(Theme.navy)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(Theme.surface, in: Capsule())
                    .padding(.bottom, Theme.Space.m)
                }
                .transition(.opacity)
            }
        }
        .accessibilityHidden(model.framing == nil)
        .accessibilityLabel(model.framing.map { "Camera: \($0)" } ?? "")
    }

    private var brackets: Bool {
        switch model.phase {
        case .armed, .recording: true
        default: false
        }
    }
}

/// Yellow corner brackets on him: the camera has locked on, and only he starts the set.
private struct LockBrackets: View {
    var body: some View {
        Canvas { context, size in
            let l: CGFloat = min(size.width, size.height) * 0.16
            var path = Path()
            for (x, y, dx, dy) in [(0.0, 0.0, 1.0, 1.0), (size.width, 0, -1, 1), (0, size.height, 1, -1), (size.width, size.height, -1, -1)] {
                path.move(to: CGPoint(x: x, y: y + dy * l))
                path.addLine(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x + dx * l, y: y))
            }
            context.stroke(path, with: .color(Theme.yellow), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityLabel("Locked on you")
    }
}

/// The measured result on the replay: a white sticker at the foot of the stage.
private struct ResultSticker: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var facts: [SessionHUDModel.Fact]
    var loadLb: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            if let loadLb, loadLb > 0 {
                Text("\(Format.number(loadLb)) lb logged")
                    .font(.hudLabel).monospacedDigit().foregroundStyle(Theme.textSecondary)
                    .contentTransition(reduceMotion ? .opacity : .numericText(value: loadLb))
                    .animation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.35), value: loadLb)
            }
            ResultRow(facts: facts)
        }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// The big clock on the navy stage (a hold, the pocket): the time left in white, thinning as it
/// drains, and what it's counting.
private struct StageClock: View {
    var remaining: Int
    var total: Int
    var caption: String

    var body: some View {
        let over = remaining <= 0
        let fullness = over || total <= 0 ? 0 : Double(remaining) / Double(total)
        VStack(alignment: .leading, spacing: 0) {
            Text(caption).font(.hudState).foregroundStyle(Theme.onStageSecondary)
            Text(over ? "+" + Format.duration(TimeInterval(-remaining)) : Format.duration(TimeInterval(remaining)))
                .font(.drainingClock(140, fullness: fullness))
                .foregroundStyle(over ? Theme.onStageSecondary : Theme.onStage)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText(countsDown: true))
            Text(over ? "over your rest of " + Format.duration(TimeInterval(total)) : "of " + Format.duration(TimeInterval(total)))
                .font(.hudLabel).foregroundStyle(Theme.onStageSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The holds as a track on the stage: done white, the current one yellow, the rest dim.
private struct HoldsTrack: View {
    var index: Int
    var count: Int
    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(1...max(1, count), id: \.self) { i in
                Capsule().fill(i < index ? Theme.onStage : i == index ? Theme.yellow : Theme.onStageTrack).frame(height: 10)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The state, named, when the camera isn't on him: "Ready", "Armed", "Recording 0:24".
private struct StageState: View {
    var phase: SessionHUDModel.Phase
    var body: some View {
        HStack(spacing: Theme.Space.s) {
            switch phase {
            case .recording: RecordingDot()
            case .armed: Circle().fill(Theme.yellow).frame(width: 20, height: 20)
            default: Circle().strokeBorder(Theme.onStage, lineWidth: 3).frame(width: 20, height: 20)
            }
            Text(phase.name + (phase.elapsed.map { " " + Format.duration(TimeInterval($0)) } ?? ""))
                .contentTransition(.numericText())
        }
        .font(.system(size: 48, weight: .bold).monospacedDigit())
        .foregroundStyle(Theme.onStage)
        .accessibilityElement(children: .combine)
    }
}

private extension SessionHUDModel.Phase {
    var elapsed: Int? {
        if case .recording(let elapsed) = self { return elapsed }
        return nil
    }
}

// MARK: The sheet, by state

/// The exercise and its tag on one line, the tag dropping below when the name is long.
private struct SetHeader<Tag: View>: View {
    var exercise: String
    @ViewBuilder var tag: Tag

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Theme.Space.s) {
                name.fixedSize()
                Spacer(minLength: 0)
                tag
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                name
                tag
            }
        }
    }

    private var name: some View {
        Text(exercise).font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.navy).lineLimit(2)
    }
}

/// Ready, Armed and Recording share one sheet, so only the camera's pill changes as he lifts:
/// the exercise, the set as the yellow tag, the target, last time.
private struct SetBlock: View {
    var model: SessionHUDModel
    var tagSpace: Namespace.ID?
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            SetHeader(exercise: model.exercise) {
                HUDTag(text: [model.role, model.setLabel].compactMap { $0 }.joined(separator: " · "), travels: tagSpace)
            }
            TargetText(load: model.load, reps: model.reps)
            if let last = model.lastTime {
                Text(last).font(.hudLabel).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
    }
}

/// Rest: the countdown (on the stage instead when the camera's off), then the next set as the
/// yellow tag. What to say to it is the voice line's.
private struct RestBlock: View {
    var model: SessionHUDModel
    var remaining: Int
    var total: Int
    var showsClock: Bool
    var tagSpace: Namespace.ID?

    var body: some View {
        let over = remaining <= 0
        let fullness = over || total <= 0 ? 0 : Double(remaining) / Double(total)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if showsClock {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(over ? "+" + Format.duration(TimeInterval(-remaining)) : Format.duration(TimeInterval(remaining)))
                        .font(.drainingClock(80, fullness: fullness))
                        .foregroundStyle(over ? Theme.textSecondary : Theme.navy)
                        .lineLimit(1)
                        .contentTransition(.numericText(countsDown: true))
                    Text(over ? "over" : "of " + Format.duration(TimeInterval(total)) + " rest")
                        .font(.hudLabel).foregroundStyle(Theme.textSecondary)
                }
            } else if !model.result.isEmpty, !model.pocket {
                ResultRow(facts: model.result)
            }
            if let next = model.next {
                HStack(spacing: Theme.Space.s) {
                    Text("Next").font(.hudLabel.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    HUDTag(text: next, travels: tagSpace)
                }
            }
        }
    }
}

/// The last set as Results shows it: the count, where it came from as a source chip, the effort.
private struct ResultRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var facts: [SessionHUDModel.Fact]
    var body: some View {
        let count = facts.first { !$0.source }
        let source = facts.first { $0.source }
        let effort = facts.filter { !$0.source }.dropFirst().map(\.text)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                if let count {
                    Text(count.text).font(.system(size: 34, weight: .bold).monospacedDigit()).foregroundStyle(Theme.navy)
                        .contentTransition(reduceMotion ? .opacity : .numericText())
                        .animation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.35), value: count.text)
                }
                if let source {
                    Text(source.text.prefix(1).uppercased() + source.text.dropFirst())
                        .font(.hudLabel.weight(.semibold))
                        .foregroundStyle(Theme.cobalt)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Theme.cobaltTint, in: Capsule())
                }
            }
            if !effort.isEmpty {
                Text(effort.joined(separator: " · ")).font(.hudLabel).foregroundStyle(Theme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The end of the session: each exercise's top set, a logbook beaten, then flags and notes.
private struct DoneBlock: View {
    var summary: SessionHUDModel.Summary?
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Today's top sets").font(.hudLabel.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            ForEach(summary?.lines ?? []) { line in
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Text(line.exercise).font(.hudLabel).foregroundStyle(Theme.navy).lineLimit(1).minimumScaleFactor(0.85)
                        Spacer(minLength: Theme.Space.s)
                        Text(line.top).font(.system(size: 30, weight: .bold).monospacedDigit()).foregroundStyle(Theme.navy).fixedSize()
                    }
                    if let beat = line.beat { HUDTag(text: beat) }
                }
            }
            if let notes = summary?.notes, !notes.isEmpty {
                CardDivider()
                ForEach(notes, id: \.self) { note in
                    Text(note).font(.hudLabel).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}

/// The question waiting on his answer, with a yellow tag naming it.
private struct AskRow: View {
    var text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            HUDTag(text: "Asked")
            Text(text).font(.hudLabel.weight(.semibold)).foregroundStyle(Theme.navy)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: The voice line

/// The talking indicator, in the sheet: a cobalt-tint disc that moves with whoever is talking,
/// and the words. His words appear in cobalt as he says them; Setecho's line fills from secondary
/// to navy as it's spoken. Idle, the one thing to say now (`prompt`), or two or three hints.
struct VoiceLine: View {
    var voice: SessionHUDModel.Voice
    var prompt: Text?

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            ZStack {
                Circle().fill(Theme.cobaltTint)
                switch voice {
                case .idle: Image(systemName: "waveform").font(.title2.weight(.semibold)).foregroundStyle(Theme.cobalt)
                case .hearing(_, let level): WaveformBars(level: level, animating: true)
                case .thinking: ThinkingDots()
                case .speaking: WaveformBars(level: 0.55, animating: true)
                case .quiet: Image(systemName: "mic.slash").font(.title2.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(width: 52, height: 52)
            words.frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 56)
        .animation(.snappy(duration: 0.3), value: voice)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }

    @ViewBuilder private var words: some View {
        switch voice {
        case .idle(let hints):
            Group {
                if let prompt {
                    prompt
                } else {
                    hints.enumerated().reduce(Text("Say ")) { line, item in
                        let joiner = item.offset == 0 ? "" : (item.offset == hints.count - 1 ? " or " : ", ")
                        return line + Text(joiner) + Text("\u{201C}\(item.element)\u{201D}").foregroundStyle(Theme.navy).fontWeight(.semibold)
                    }
                }
            }
            .font(.hudLabel)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(2)
            .minimumScaleFactor(0.85)
        case .hearing(let said, _), .thinking(let said):
            Text("\u{201C}\(said)\u{201D}").font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.cobalt)
                .lineLimit(2).minimumScaleFactor(0.85)
        case .quiet:
            (Text("Quiet. ").foregroundStyle(Theme.navy).fontWeight(.semibold) + Text("Say ") + Text("\u{201C}I'm back\u{201D}").foregroundStyle(Theme.navy).fontWeight(.semibold) + Text(" or tap."))
                .font(.hudLabel)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        case .speaking(let line, let spoken):
            line.split(separator: " ").enumerated().reduce(Text("")) { text, item in
                let word = Text((item.offset == 0 ? "" : " ") + item.element)
                return text + (item.offset < spoken ? word.foregroundStyle(Theme.navy).fontWeight(.bold)
                                                    : word.foregroundStyle(Theme.textSecondary).fontWeight(.regular))
            }
            .font(.system(size: 24))
            .lineLimit(2)
            .minimumScaleFactor(0.85)
        }
    }

    private var accessibility: String {
        switch voice {
        case .idle(let hints): prompt != nil ? "Say go when you lift" : "You could say: " + hints.joined(separator: ", ")
        case .hearing(let said, _): "Hearing you: \(said)"
        case .thinking(let said): "Heard: \(said)"
        case .speaking(let line, _): "Setecho: \(line)"
        case .quiet: "Quiet. Say I'm back, or tap, to listen again"
        }
    }
}

/// The long press that ends the session: the hands-free `HoldButton` (tonal, filling as it's held),
/// so a brush against the phone never ends it, and it never outshouts the set.
private struct EndButton: View {
    var label: String
    var onEnd: (() -> Void)?

    var body: some View {
        HoldButton(title: label, duration: 1.2, accessibilityHint: "Press and hold for one second, or say end session") { onEnd?() }
    }
}

// MARK: The states, for previews and the screenshots

extension SessionHUDModel {
    /// Where he is in the sample frame (the full 9:16 picture).
    private static let sampleBox = CGRect(x: 0.04, y: 0.36, width: 0.92, height: 0.3)

    private static let day5: [ExerciseDots] = [
        .init(name: "Smith CG", dots: [.done, .done]),
        .init(name: "Incline", dots: [.done, .current]),
        .init(name: "Flyes", dots: [.upcoming, .upcoming]),
        .init(name: "Dips", dots: [.upcoming]),
        .init(name: "Abs", dots: [.upcoming, .upcoming], isAddOn: true),
    ]

    static let ready = SessionHUDModel(
        phase: .ready, progress: day5, micLabel: "AirPods mic", micOnHim: true, exercise: "Incline DB press", role: "Back-off",
        setLabel: "set 2 of 2", load: 65, reps: "8–10", lastTime: "Last time 60 × 10", voice: .idle(hints: ["what did I do last time?", "where am I?"]))

    /// A long day (his Day 1: five lifts and abs), for the strip: every name whole, or dots.
    static let readyLongDay: SessionHUDModel = {
        var m = ready
        m.progress = [
            .init(name: "Stationary", dots: [.done]), .init(name: "Incline", dots: [.done, .current]),
            .init(name: "Flat", dots: [.upcoming, .upcoming]), .init(name: "Pec", dots: [.upcoming]),
            .init(name: "Lateral", dots: [.upcoming, .upcoming, .upcoming]), .init(name: "Abs", dots: [.upcoming, .upcoming], isAddOn: true),
        ]
        return m
    }()

    /// His real long day as the phone showed it (Oct 29): six lifts, 19 sets, the camera not yet on
    /// him, no mic. Nothing may push the screen wider than the phone.
    static let readyCrowded: SessionHUDModel = {
        var m = ready
        m.progress = [
            .init(name: "Stationary", dots: [.current, .upcoming]), .init(name: "Incline", dots: [.upcoming, .upcoming, .upcoming]),
            .init(name: "Flat", dots: [.upcoming, .upcoming]), .init(name: "Pec", dots: [.upcoming, .upcoming, .upcoming]),
            .init(name: "Lateral", dots: [.upcoming, .upcoming, .upcoming, .upcoming]),
            .init(name: "Abs", dots: [.upcoming, .upcoming, .upcoming, .upcoming, .upcoming], isAddOn: true),
        ]
        m.camera = false
        m.micLabel = "No mic"
        m.micOnHim = false
        m.exercise = "Stationary Bike"
        m.role = nil
        m.setLabel = "set 1 of 2"
        m.load = nil
        m.reps = "5 min"
        m.lastTime = nil
        return m
    }()

    static let armed = SessionHUDModel(
        phase: .armed, progress: day5, micLabel: "AirPods mic", micOnHim: true, exercise: "Incline DB press", role: "Back-off",
        setLabel: "set 2 of 2", load: 65, reps: "8–10", voice: .speaking("Set two. Lift when you're ready.", spoken: 3),
        lockBox: sampleBox)

    static let recording = SessionHUDModel(
        phase: .recording(elapsed: 24), progress: day5, micLabel: "AirPods mic", micOnHim: true, exercise: "Incline DB press",
        role: "Back-off", setLabel: "set 2 of 2", load: 65, reps: "8–10", voice: .idle(hints: ["done", "done, 9"]),
        lockBox: sampleBox)

    static let rest = SessionHUDModel(
        phase: .rest(remaining: 100, total: 180), progress: day5, micLabel: "AirPods mic", micOnHim: true, exercise: "Incline DB press",
        role: "Top set", setLabel: "set 1 of 2", load: 80, reps: "6–8", voice: .hearing("how long left", level: 0.6),
        result: [.init(text: "11 reps"), .init(text: "measured", source: true), .init(text: "slowed 46%"), .init(text: "failure")],
        next: "Back-off 65 × 8–10", nextAsk: "Say \u{201C}go with it\u{201D} or a weight.")

    static let restOvertime: SessionHUDModel = {
        var m = rest
        m.phase = .rest(remaining: -40, total: 180)
        m.voice = .speaking("Rest's up.", spoken: 2)
        return m
    }()

    static let hold = SessionHUDModel(
        phase: .hold(remaining: 14, total: 20, index: 2, count: 4),
        progress: [.init(name: "Vacuums", dots: [.done, .current, .upcoming, .upcoming])], micLabel: "Phone mic", micOnHim: false,
        exercise: "Stomach vacuums", setLabel: "hold 2 of 4", reps: "20 s", voice: .idle(hints: ["done", "hold on"]), camera: false)

    static let pocket: SessionHUDModel = {
        var m = rest
        m.pocket = true
        m.phase = .rest(remaining: 72, total: 180)
        return m
    }()

    static let done = SessionHUDModel(
        phase: .done,
        progress: [.init(name: "Smith CG", dots: [.done, .done]), .init(name: "Incline", dots: [.done, .done]),
                   .init(name: "Flyes", dots: [.done, .done]), .init(name: "Dips", dots: [.skipped]),
                   .init(name: "Abs", dots: [.done, .done], isAddOn: true)],
        micLabel: "AirPods mic", micOnHim: true, exercise: "", setLabel: "", reps: "", voice: .idle(hints: []),
        summary: .init(lines: [.init(exercise: "Smith close-grip", top: "205 × 9", beat: "Beat the logbook"),
                               .init(exercise: "Incline DB press", top: "80 × 11"),
                               .init(exercise: "Cable flyes", top: "30 × 12")],
                       notes: ["Flagged: incline top set", "Noted: left shoulder pinched", "Skipped: dips, bench taken"]))

    /// Every state for the screenshots, in order.
    static let gallery: [(String, SessionHUDModel)] = [
        ("1-ready", ready), ("1b-ready-long-day", readyLongDay), ("1c-ready-crowded", readyCrowded), ("2-armed", armed), ("3-recording", recording), ("4-rest", rest), ("4b-rest-overtime", restOvertime),
        ("5-hold", hold), ("6-pocket", pocket), ("7-session-end", done),
    ]
}

#Preview("Ready") { SessionHUD(model: .ready) }
#Preview("Armed") { SessionHUD(model: .armed) }
#Preview("Recording") { SessionHUD(model: .recording) }
#Preview("Rest") { SessionHUD(model: .rest) }
#Preview("Rest's up") { SessionHUD(model: .restOvertime) }
#Preview("Hold") { SessionHUD(model: .hold) }
#Preview("Pocket") { SessionHUD(model: .pocket) }
#Preview("Session end") { SessionHUD(model: .done) }
