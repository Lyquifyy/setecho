import SwiftUI
import UIKit

// THESIS: The session screen is a cue card held up across the room: one thing at a time, read from
// the bench, built from the same grouped cards as the rest of Setecho rather than a fitness dashboard.
// OWN-WORLD: The app's own: the cool page, white cards with a hairline and their title inside, navy
// SF Pro bold with tabular numbers, the yellow tag for the one thing waiting on him, cobalt only for
// the brand, data sources ("Measured", the mic in use) and the tonal end button, the red dot only while
// recording. No state colour fields.
// STORY: From the bench he sees where he is (the lifts), what to do (one card), and that he was
// heard (the voice card), without walking to the phone.
// FIRST VIEWPORT: Lockup and audio pill; the lifts card; the state line; one main card at hands-free
// scale; the voice card; the long-press end button.
// FORM: surface structure "the cue card", seed b397f982, re-skinned to the app's grouped cards (Oct 28).
// SIGNATURE: the rest countdown thins as the rest drains; a spoken line fills word by word.
// FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

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
    /// Rest: the next set ("Back-off 145 × 8") and what to say to it.
    var next: String?
    var nextAsk: String?
    var summary: Summary?
    /// The camera is filming him (the front camera, facing the bench). Off for a morning of holds.
    var camera = true
    /// His lock-on box in the camera's frame, normalized, top-left origin (`BodyTracker`).
    var lockBox: CGRect?
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

struct SessionHUD: View {
    var model: SessionHUDModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The yellow tag travels: the set's tag above the camera becomes the next set's tag in rest.
    @Namespace private var tagSpace
    /// The long press that ends the session (no tap ends anything); nil in previews.
    var onEnd: (() -> Void)?
    /// Developer → Rehearse a session: the typed line field, above the end button.
    var footer: AnyView?

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            HStack {
                Image("Lockup")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 26)
                    .foregroundStyle(Theme.cobalt)
                    .accessibilityLabel("Setecho")
                Spacer(minLength: Theme.Space.s)
                if model.pocket {
                    PocketPill()
                } else {
                    AudioConnection(label: model.micLabel, onHim: model.micOnHim)
                }
            }
            LiftsStrip(exercises: model.progress)
            if showsCamera {
                cameraLayout
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                StateLine(phase: model.phase)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Theme.Space.xxs)
                main
                    .frame(maxHeight: .infinity, alignment: .top)
                    .id(model.phase.name + (model.pocket ? "-pocket" : ""))
                    .transition(arrival)
            }
            // A question waiting on him (outside rest, where the next-set card carries it) stays on screen
            // until it's answered or lapses: "End the session? Six sets logged.", a machine-taken offer.
            if let ask = model.nextAsk, !isRest {
                AskCard(text: ask)
            }
            if !model.pocket, model.voice != .idle(hints: []) {
                VoiceCard(voice: model.voice)
            }
            if let footer { footer }
            EndButton(label: model.phase == .done ? "Hold to close" : "Hold to end session", onEnd: onEnd)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, Theme.Space.xs)
        .padding(.bottom, Theme.Space.xs)
        .background(Theme.page.ignoresSafeArea())
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.5, bounce: 0.18), value: model.phase)
    }

    /// A card arriving: it rises into place, or only fades in under Reduce Motion (PRODUCT.md).
    private var arrival: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity)
    }

    private var tag: Namespace.ID? { reduceMotion ? nil : tagSpace }

    private var isRest: Bool {
        if case .rest = model.phase { return true }
        return false
    }

    /// He sees himself on the bench: the camera card is the screen's centre whenever it's filming
    /// him (in a pocket, or for a morning of holds, the cards carry it alone).
    private var showsCamera: Bool {
        guard model.camera, !model.pocket else { return false }
        switch model.phase {
        case .ready, .armed, .recording, .rest: return true
        case .hold, .done: return false
        }
    }

    @ViewBuilder private var cameraLayout: some View {
        switch model.phase {
        case .rest(let remaining, let total):
            VStack(spacing: Theme.Space.s) {
                CameraCard(model: model)
                RestNextCard(model: model, remaining: remaining, total: total, tagSpace: tag)
                    .transition(arrival)
            }
        default:
            VStack(spacing: Theme.Space.s) {
                ThisSetCard(model: model, tagSpace: tag)
                    .transition(arrival)
                CameraCard(model: model)
            }
        }
    }

    @ViewBuilder private var main: some View {
        switch model.phase {
        case .ready: ReadyCard(model: model)
        case .armed: ArmedCard(model: model)
        case .recording(let elapsed): RecordingCard(model: model, elapsed: elapsed)
        case .rest(let remaining, let total): RestCards(model: model, remaining: remaining, total: total)
        case .hold(let remaining, let total, let index, let count):
            HoldCard(model: model, remaining: remaining, total: total, index: index, count: count)
        case .done: DoneCard(summary: model.summary)
        }
    }
}

/// The session's own card: a `SectionCard` at hands-free scale (the title in `.hudLabel`, read
/// from 2-3 m), white with the hairline, title inside.
private struct HUDCard<Content: View>: View {
    var title: String?
    var fill = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let title {
                Text(title).font(.hudLabel.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// A yellow tag at hands-free scale: the next set waiting on him (`TargetTag`, read from the bench).
private struct HUDTag: View {
    var text: String
    /// The tag that moves between the set card and the rest card (nil under Reduce Motion).
    var travels: Namespace.ID?
    var body: some View {
        Text(text)
            .font(.hudLabel.weight(.semibold))
            .foregroundStyle(Theme.navy)
            .lineLimit(1)
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
    var size: CGFloat = 96

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

// MARK: Header

/// Today's lifts, as he asked to keep them: a short name, a dot per set. Done dots navy, the current
/// set yellow (waiting on him), upcoming ones open, a skipped exercise a dash; add-ons after a hairline.
struct LiftsStrip: View {
    var exercises: [SessionHUDModel.ExerciseDots]

    var body: some View {
        // At hands-free size when today's lifts fit (four, or five short ones); a step smaller only
        // when they don't, and never truncated, so every name stays whole.
        ViewThatFits(in: .horizontal) {
            row(nameSize: 22)
            row(nameSize: 20)
            row(nameSize: 18)
        }
        .padding(.vertical, Theme.Space.s)
        .padding(.horizontal, Theme.Space.m)
        .frame(maxWidth: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today: " + exercises.map { "\($0.name), \($0.dots.filter { $0 == .done }.count) of \($0.dots.count)" }.joined(separator: "; "))
    }

    private func row(nameSize: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(exercises.enumerated()), id: \.element.id) { i, ex in
                if i > 0 {
                    if ex.isAddOn, !exercises[i - 1].isAddOn {
                        Spacer(minLength: Theme.Space.xs)
                        VerticalCardDivider().frame(height: 48)
                    }
                    Spacer(minLength: Theme.Space.s)
                }
                let current = ex.dots.contains(.current)
                VStack(spacing: Theme.Space.xs) {
                    Text(ex.name)
                        .font(.system(size: nameSize, weight: current ? .bold : .semibold))
                        .foregroundStyle(current ? Theme.navy : Theme.textSecondary)
                        .fixedSize()
                    HStack(spacing: 6) {
                        ForEach(Array(ex.dots.enumerated()), id: \.offset) { _, dot in Dot(dot: dot) }
                    }
                    .frame(height: 22)
                }
            }
        }
    }

    private struct Dot: View {
        var dot: SessionHUDModel.ExerciseDots.Dot
        var body: some View {
            switch dot {
            case .done: Circle().fill(Theme.navy).frame(width: 15, height: 15)
            case .current:
                Circle().fill(Theme.yellow).frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(Theme.navy, lineWidth: 2.5))
            case .upcoming: Circle().strokeBorder(Theme.textSecondary.opacity(0.45), lineWidth: 2.5).frame(width: 15, height: 15)
            case .skipped: Capsule().fill(Theme.textSecondary).frame(width: 16, height: 4)
            }
        }
    }
}

/// What's connected for audio: the mic in use as a source (cobalt on cobalt tint), or a yellow
/// warning when it's the phone's own mic on the tripod (the one thing he can fix).
struct AudioConnection: View {
    var label: String
    var onHim: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: onHim ? (label.contains("AirPods") ? "airpodspro" : "mic.fill") : "exclamationmark.triangle.fill")
                .foregroundStyle(onHim ? Theme.cobalt : Theme.navy)
            Text(onHim ? label : "\(label) · too far")
                .foregroundStyle(onHim ? Theme.cobalt : Theme.navy)
        }
        .font(.hudLabel.weight(.semibold))
        .lineLimit(1)
        // Beside the full lockup "Phone mic · too far" needs to give a little; never truncate it.
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(onHim ? Theme.cobaltTint : Theme.yellow, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(onHim ? "Listening on \(label)" : "Using the \(label). It's too far to hear you well.")
    }
}

/// In a pocket the screen isn't the point: the pill says the buzzes carry it.
struct PocketPill: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            Label("Pocket · buzzes on", systemImage: "iphone.radiowaves.left.and.right").fixedSize()
            Text("Pocket · buzzes on").lineLimit(1).minimumScaleFactor(0.75)
        }
        .font(.hudLabel.weight(.semibold))
        .foregroundStyle(Theme.cobalt)
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(Theme.cobaltTint, in: Capsule())
    }
}

/// The state, named, with its mark (`HUDState`'s grammar): navy words; the red dot only while
/// recording; yellow while armed (waiting on him); the cobalt check when the session's saved.
struct StateLine: View {
    var phase: SessionHUDModel.Phase

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            mark.frame(width: 26, height: 26)
            Text(phase.name).font(.hudState).foregroundStyle(Theme.navy).contentTransition(.opacity)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var mark: some View {
        switch phase {
        case .ready: Circle().strokeBorder(Theme.navy, lineWidth: 3)
        case .armed: Circle().fill(Theme.yellow).overlay(Circle().strokeBorder(Theme.navy, lineWidth: 2.5))
        case .recording: Circle().fill(Theme.recording).padding(3)
        case .rest(let left, _):
            Image(systemName: left > 0 ? "timer" : "bell.fill").font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.navy)
        case .hold: Image(systemName: "stopwatch").font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.navy)
        case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.cobalt)
        }
    }
}

// MARK: The camera

/// The set up now, compact above the camera: the exercise, the set as the yellow tag, last time,
/// and the target at hands-free scale.
private struct ThisSetCard: View {
    var model: SessionHUDModel
    var tagSpace: Namespace.ID?
    var body: some View {
        HUDCard(title: nil) {
            Text(model.exercise).font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.navy).lineLimit(1).minimumScaleFactor(0.7)
            SetTag(model: model, travels: tagSpace)
            TargetText(load: model.load, reps: model.reps, size: 76)
            if let last = model.lastTime {
                Text(last).font(.hudLabel).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
    }
}

/// His live image in the Filming board's camera card: the state as the dark pill top-left (the
/// red dot while recording, yellow while armed), yellow corner brackets on him once the camera has
/// him, and what to do at the foot of the frame. During rest it plays back the set he just did,
/// with its measured count.
private struct CameraCard: View {
    var model: SessionHUDModel
    @Environment(\.sessionCameraFeed) private var liveFeed
    @Environment(\.sessionReplayFeed) private var replayFeed

    /// During rest, the set he just did; otherwise the live camera.
    private var feed: AnyView? {
        if case .rest = model.phase, let replayFeed { return replayFeed }
        return liveFeed
    }

    var body: some View {
        // The feed fills whatever room the cards leave; it never sizes the card itself.
        Color.clear
            .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
            .overlay {
                if let feed {
                    feed
                } else {
                    ZStack {
                        Theme.cameraFill
                        Image(systemName: "figure.strengthtraining.traditional").font(.system(size: 64)).foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
            .overlay {
                GeometryReader { proxy in
                    if brackets, let box = model.lockBox {
                        // The picture fills the card (aspect fill): place the box where his image actually is.
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
            }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading) {
                    pill
                    Spacer(minLength: 0)
                    foot
                }
                .padding(Theme.Space.s)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .layoutPriority(-1)
            .accessibilityElement(children: .combine)
    }

    private var brackets: Bool {
        switch model.phase {
        case .armed, .recording: true
        default: false
        }
    }

    @ViewBuilder private var pill: some View {
        switch model.phase {
        case .ready:
            CameraPill { Circle().strokeBorder(.white, lineWidth: 2.5).frame(width: 16, height: 16); Text("Ready") }
        case .armed:
            CameraPill(fill: Theme.yellow, ink: Theme.navy) {
                Circle().fill(Theme.navy).frame(width: 12, height: 12); Text("Armed · lift when ready")
            }
        case .recording(let elapsed):
            CameraPill { Circle().fill(Theme.recording).frame(width: 16, height: 16); Text("Recording · \(Format.duration(TimeInterval(elapsed)))") }
        case .rest:
            CameraPill { Image(systemName: "play.fill"); Text("Your last set") }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var foot: some View {
        switch model.phase {
        case .ready:
            CameraCaption {
                SayGo().font(.system(size: 26, weight: .bold))
            }
        case .armed:
            CameraCaption {
                Label("Watching you. Only your movement starts it.", systemImage: "eye")
                    .font(.hudLabel.weight(.semibold))
            }
        case .recording:
            CameraCaption { Text("Counting when you rack it.").font(.hudLabel.weight(.semibold)) }
        case .rest:
            if !model.result.isEmpty { ResultSticker(facts: model.result) }
        default:
            EmptyView()
        }
    }
}

/// The dark pill on the camera, as in the Filming board ("● Recording · 00:18").
private struct CameraPill<Content: View>: View {
    var fill: Color = Theme.cameraFill.opacity(0.78)
    var ink: Color = .white
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 8) { content }
            .font(.hudLabel.weight(.semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(fill, in: Capsule())
    }
}

/// A line at the foot of the frame, on the same dark scrim as the pill.
private struct CameraCaption<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.cameraFill.opacity(0.78), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}

/// The measured result on the replay: a white sticker like the Results card's first row.
private struct ResultSticker: View {
    var facts: [SessionHUDModel.Fact]
    var body: some View {
        ResultRow(facts: facts)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
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

/// Rest under the replay: the countdown, then the next set as the yellow tag.
private struct RestNextCard: View {
    var model: SessionHUDModel
    var remaining: Int
    var total: Int
    var tagSpace: Namespace.ID?
    var body: some View {
        let over = remaining <= 0
        let fullness = over || total <= 0 ? 0 : Double(remaining) / Double(total)
        HUDCard(title: nil) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(over ? "+" + Format.duration(TimeInterval(-remaining)) : Format.duration(TimeInterval(remaining)))
                    .font(.drainingClock(88, fullness: fullness))
                    .foregroundStyle(over ? Theme.textSecondary : Theme.navy)
                    .lineLimit(1)
                    .contentTransition(.numericText(countsDown: true))
                Text(over ? "over" : "of " + Format.duration(TimeInterval(total)) + " rest")
                    .font(.hudLabel).foregroundStyle(Theme.textSecondary)
            }
            if let next = model.next {
                CardDivider()
                HStack(spacing: Theme.Space.s) {
                    Text("Next").font(.hudLabel.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    HUDTag(text: next, travels: tagSpace)
                }
                if let ask = model.nextAsk {
                    Text(ask).font(.hudLabel).foregroundStyle(Theme.navy)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: The main card, by state

/// The role and set as the yellow tag, the way Train shows "Set 4 of 4".
private struct SetTag: View {
    var model: SessionHUDModel
    var travels: Namespace.ID?
    var body: some View {
        HUDTag(text: [model.role, model.setLabel].compactMap { $0 }.joined(separator: " · "), travels: travels)
    }
}

/// "Say "go" when you lift.": the word in bold quotes, like the voice card's hints, so the set's
/// tag stays the only yellow (DESIGN.md rule 3).
private struct SayGo: View {
    var ink: Color = .white
    var body: some View {
        (Text("Say ") + Text("\u{201C}go\u{201D}").fontWeight(.heavy) + Text(" when you lift."))
            .foregroundStyle(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

private struct ReadyCard: View {
    var model: SessionHUDModel
    var body: some View {
        HUDCard(title: nil, fill: true) {
            Text(model.exercise).font(.system(size: 34, weight: .bold)).foregroundStyle(Theme.navy).lineLimit(2).minimumScaleFactor(0.7)
            SetTag(model: model)
            TargetText(load: model.load, reps: model.reps).padding(.top, Theme.Space.xxs)
            if let last = model.lastTime {
                CardDivider()
                Text(last).font(.hudLabel).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: Theme.Space.s)
            SayGo(ink: Theme.navy).font(.system(size: 28, weight: .bold))
        }
    }
}

private struct ArmedCard: View {
    var model: SessionHUDModel
    var body: some View {
        HUDCard(title: nil, fill: true) {
            Text("Lift when you're ready.").font(.system(size: 40, weight: .bold)).foregroundStyle(Theme.navy)
                .fixedSize(horizontal: false, vertical: true)
            SetTag(model: model)
            TargetText(load: model.load, reps: model.reps, size: 84)
            Spacer(minLength: Theme.Space.s)
            CardDivider()
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.cobalt)
                    .frame(width: 48, height: 48)
                    .background(Theme.cobaltTint, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Watching you").font(.hudLabel.weight(.semibold)).foregroundStyle(Theme.navy)
                    Text("Only your movement starts it.").font(.hudLabel).foregroundStyle(Theme.textSecondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

private struct RecordingCard: View {
    var model: SessionHUDModel
    var elapsed: Int
    var body: some View {
        HUDCard(title: nil, fill: true) {
            Text(model.exercise).font(.system(size: 34, weight: .bold)).foregroundStyle(Theme.navy).lineLimit(1).minimumScaleFactor(0.7)
            SetTag(model: model)
            HStack(alignment: .center, spacing: Theme.Space.m) {
                TimelineView(.animation(minimumInterval: 0.5)) { context in
                    let on = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                    Circle().fill(Theme.recording).frame(width: 26, height: 26).opacity(on ? 1 : 0.4)
                }
                Text(Format.duration(TimeInterval(elapsed))).font(.system(size: 120, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.navy)
                    .contentTransition(.numericText())
            }
            .padding(.top, Theme.Space.xs)
            CardDivider()
            Text("Counting when you rack it.").font(.hudLabel).foregroundStyle(Theme.textSecondary)
        }
    }
}

private struct RestCards: View {
    var model: SessionHUDModel
    var remaining: Int
    var total: Int

    var body: some View {
        let over = remaining <= 0
        let fullness = over || total <= 0 ? 0 : Double(remaining) / Double(total)
        VStack(spacing: Theme.Space.s) {
            HUDCard(title: "Rest") {
                VStack(alignment: .leading, spacing: 0) {
                    Text(over ? "+" + Format.duration(TimeInterval(-remaining)) : Format.duration(TimeInterval(remaining)))
                        .font(.drainingClock(model.pocket ? 150 : 112, fullness: fullness))
                        .foregroundStyle(over ? Theme.textSecondary : Theme.navy)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .contentTransition(.numericText(countsDown: true))
                    Text(over ? "over your rest of " + Format.duration(TimeInterval(total)) : "of " + Format.duration(TimeInterval(total)))
                        .font(.hudLabel).foregroundStyle(Theme.textSecondary)
                }
                if !model.result.isEmpty, !model.pocket {
                    CardDivider()
                    ResultRow(facts: model.result)
                }
            }
            .fixedSize(horizontal: false, vertical: true) // the clock keeps its size; the next card gives way
            if let next = model.next {
                HUDCard(title: "Next set", fill: true) {
                    HUDTag(text: next)
                    if let ask = model.nextAsk, !model.pocket {
                        Text(ask).font(.hudLabel).foregroundStyle(Theme.navy)
                    }
                }
            }
        }
    }
}

/// The last set as Results shows it: the count, where it came from as a source chip, the effort.
private struct ResultRow: View {
    var facts: [SessionHUDModel.Fact]
    var body: some View {
        let count = facts.first { !$0.source }
        let source = facts.first { $0.source }
        let effort = facts.filter { !$0.source }.dropFirst().map(\.text)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                if let count { Text(count.text).font(.system(size: 34, weight: .bold).monospacedDigit()).foregroundStyle(Theme.navy) }
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

private struct HoldCard: View {
    var model: SessionHUDModel
    var remaining: Int
    var total: Int
    var index: Int
    var count: Int
    var body: some View {
        HUDCard(title: nil, fill: true) {
            Text(model.exercise).font(.system(size: 34, weight: .bold)).foregroundStyle(Theme.navy)
            HUDTag(text: "Hold \(index) of \(count)")
            Text(Format.duration(TimeInterval(remaining)))
                .font(.drainingClock(150, fullness: total > 0 ? Double(remaining) / Double(total) : 0))
                .foregroundStyle(Theme.navy)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText(countsDown: true))
            HStack(spacing: Theme.Space.xs) {
                ForEach(1...max(1, count), id: \.self) { i in
                    Capsule().fill(i < index ? Theme.navy : i == index ? Theme.yellow : Theme.border).frame(height: 10)
                }
            }
            .accessibilityHidden(true)
        }
    }
}

private struct DoneCard: View {
    var summary: SessionHUDModel.Summary?
    var body: some View {
        HUDCard(title: "Today's top sets", fill: true) {
            ForEach(summary?.lines ?? []) { line in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(line.exercise).font(.hudLabel).foregroundStyle(Theme.navy)
                        Spacer(minLength: Theme.Space.s)
                        Text(line.top).font(.system(size: 30, weight: .bold).monospacedDigit()).foregroundStyle(Theme.navy)
                    }
                    if let beat = line.beat { HUDTag(text: beat) }
                }
                CardDivider()
            }
            ForEach(summary?.notes ?? [], id: \.self) { note in
                Text(note).font(.hudLabel).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: Theme.Space.s)
            Text("Your coach sees all of it on Thursday.").font(.hudLabel.weight(.semibold)).foregroundStyle(Theme.navy)
        }
    }
}

/// The question waiting on his answer, in navy on a white card with a yellow tag naming it.
private struct AskCard: View {
    var text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            HUDTag(text: "Asked")
            Text(text).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.navy)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

// MARK: The voice card

/// The talking indicator, the check-in's `VoiceBar` at hands-free scale: a cobalt-tint disc that
/// moves with whoever is talking, and the words. His words appear in cobalt as he says them;
/// Setecho's line fills from secondary to navy as it's spoken. Idle, two or three things to say.
struct VoiceCard: View {
    var voice: SessionHUDModel.Voice

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            ZStack {
                Circle().fill(Theme.cobaltTint)
                switch voice {
                case .idle: Image(systemName: "waveform").font(.title2.weight(.semibold)).foregroundStyle(Theme.cobalt)
                case .hearing(_, let level): WaveformBars(level: level, animating: true)
                case .thinking: ThinkingDots()
                case .speaking: WaveformBars(level: 0.55, animating: true)
                }
            }
            .frame(width: 60, height: 60)
            words.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.s)
        .frame(minHeight: 84)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .animation(.snappy(duration: 0.3), value: voice)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }

    @ViewBuilder private var words: some View {
        switch voice {
        case .idle(let hints):
            hints.enumerated().reduce(Text("Say ").foregroundStyle(Theme.textSecondary)) { line, item in
                let joiner = item.offset == 0 ? "" : (item.offset == hints.count - 1 ? " or " : ", ")
                return line + Text(joiner).foregroundStyle(Theme.textSecondary)
                    + Text("\u{201C}\(item.element)\u{201D}").foregroundStyle(Theme.navy).fontWeight(.semibold)
            }
            .font(.hudLabel)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
        case .hearing(let said, _), .thinking(let said):
            Text("\u{201C}\(said)\u{201D}").font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.cobalt)
                .lineLimit(2).minimumScaleFactor(0.8)
        case .speaking(let line, let spoken):
            line.split(separator: " ").enumerated().reduce(Text("")) { text, item in
                let word = Text((item.offset == 0 ? "" : " ") + item.element)
                return text + (item.offset < spoken ? word.foregroundStyle(Theme.navy).fontWeight(.bold)
                                                    : word.foregroundStyle(Theme.textSecondary).fontWeight(.regular))
            }
            .font(.system(size: 26))
            .lineLimit(2)
            .minimumScaleFactor(0.8)
        }
    }

    private var accessibility: String {
        switch voice {
        case .idle(let hints): "You could say: " + hints.joined(separator: ", ")
        case .hearing(let said, _): "Hearing you: \(said)"
        case .thinking(let said): "Heard: \(said)"
        case .speaking(let line, _): "Setecho: \(line)"
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
        ("1-ready", ready), ("2-armed", armed), ("3-recording", recording), ("4-rest", rest), ("4b-rest-overtime", restOvertime),
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
