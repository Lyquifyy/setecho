import SwiftUI
import UIKit

// THESIS: The session screen is a cue card held up across the room. It says one thing at a time,
// in type he reads from the bench, and refuses the fitness dashboard of rings, tiles and chat bubbles.
// OWN-WORLD: A full-width band of the state's colour (navy ready, amber armed, red recording, blue
// rest, slate overtime, green done) carries the day's lifts and the audio connection in white. Below
// it, one sheet of white card stock with navy SF Pro: compressed heavy numerals, a yellow highlighter
// stroke under the one thing waiting on him, cobalt only for data sources.
// STORY: From the bench he knows the state by colour, where he is by the strip, what to do by the
// sentence, and that he was heard by the voice line, without walking to the phone.
// FIRST VIEWPORT: Band (top ~190 pt): lifts strip, state word, audio connection. Card: the sentence at
// monumental scale, its supporting line, then the voice line (a disc and the words as they're said).
// FORM: surface structure "the cue card", 4th on the ranked list, seed b397f982.
// SIGNATURE: the rest countdown thins from black to light as the rest drains; a spoken line fills
// word by word as Setecho says it.
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
    /// "145 × 8"
    var target: String
    var lastTime: String?
    var voice: Voice
    /// Rest: the set just done, as facts.
    var result: [Fact] = []
    /// Rest: the next set ("Back-off 145 × 8") and what to say to it.
    var next: String?
    var nextAsk: String?
    var summary: Summary?
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

    var field: Color {
        switch self {
        case .ready: Theme.Session.ready
        case .armed: Theme.Session.armed
        case .recording: Theme.Session.recording
        case .rest(let left, _): left > 0 ? Theme.Session.rest : Theme.Session.overtime
        case .hold: Theme.Session.rest
        case .done: Theme.Session.done
        }
    }
}

// MARK: The screen

struct SessionHUD: View {
    var model: SessionHUDModel

    var body: some View {
        VStack(spacing: 0) {
            StateBand(model: model)
            CueCard(model: model)
                .padding(.top, -26) // the card lifts over the band's lower edge
        }
        .background(model.phase.field.ignoresSafeArea())
        .animation(.smooth(duration: 0.5), value: model.phase)
        .environment(\.colorScheme, .light)
    }
}

/// The state's colour field: the day's lifts, the state's name and the audio connection, in white.
struct StateBand: View {
    var model: SessionHUDModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LiftsStrip(exercises: model.progress)
            HStack(alignment: .center) {
                Text(model.phase.name)
                    .font(.system(size: 32, weight: .heavy).width(.condensed))
                    .foregroundStyle(Theme.Session.onField)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Spacer(minLength: Theme.Space.s)
                if model.pocket {
                    PocketPill()
                } else {
                    AudioConnection(label: model.micLabel, onHim: model.micOnHim)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 26 + 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// Today's lifts across the top, as he asked to keep them: a short name, a dot per set. Done dots
/// filled, the current one ringed, upcoming ones open, a skipped exercise a dash; add-ons after a rule.
struct LiftsStrip: View {
    var exercises: [SessionHUDModel.ExerciseDots]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(exercises.enumerated()), id: \.element.id) { i, ex in
                if ex.isAddOn, i > 0, !exercises[i - 1].isAddOn {
                    Rectangle().fill(Theme.Session.onFieldTrack).frame(width: 1.5, height: 40).padding(.horizontal, 6)
                }
                let current = ex.dots.contains(.current)
                VStack(spacing: 7) {
                    Text(ex.name)
                        .font(.system(size: 17, weight: current ? .bold : .semibold))
                        .foregroundStyle(current ? Theme.Session.onField : Theme.Session.onFieldSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    HStack(spacing: 5) {
                        ForEach(Array(ex.dots.enumerated()), id: \.offset) { _, dot in Dot(dot: dot) }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today: " + exercises.map { "\($0.name), \($0.dots.filter { $0 == .done }.count) of \($0.dots.count)" }.joined(separator: "; "))
    }

    private struct Dot: View {
        var dot: SessionHUDModel.ExerciseDots.Dot
        var body: some View {
            switch dot {
            case .done: Circle().fill(Theme.Session.onField).frame(width: 11, height: 11)
            case .current:
                Circle().strokeBorder(Theme.Session.onField, lineWidth: 2.5).frame(width: 17, height: 17)
                    .overlay(Circle().fill(Theme.Session.onField).frame(width: 6, height: 6))
            case .upcoming: Circle().strokeBorder(Theme.Session.onFieldSecondary, lineWidth: 1.75).frame(width: 11, height: 11)
            case .skipped: Capsule().fill(Theme.Session.onFieldSecondary).frame(width: 12, height: 3)
            }
        }
    }
}

/// What's connected for audio: the mic in use, in white when it's on him, and a plain yellow
/// warning when it's the phone's own mic on the tripod (the one thing he can fix).
struct AudioConnection: View {
    var label: String
    var onHim: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: onHim ? (label.contains("AirPods") ? "airpodspro" : "mic.fill") : "exclamationmark.triangle.fill")
                .font(.system(size: 17, weight: .semibold))
            Text(onHim ? label : "\(label) · too far")
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(onHim ? Theme.Session.onField : Theme.navy)
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(onHim ? Theme.Session.onFieldTrack : Theme.Session.highlighter, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(onHim ? "Listening on \(label)" : "Using the \(label). It's too far to hear you well.")
    }
}

/// In a pocket the screen isn't the point: the pill says the buzzes carry it.
struct PocketPill: View {
    var body: some View {
        Label("Pocket · buzzes on", systemImage: "iphone.radiowaves.left.and.right")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Theme.Session.onField)
            .lineLimit(1)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(Theme.Session.onFieldTrack, in: Capsule())
    }
}

// MARK: The card

/// One sheet of white card stock: the sentence for this moment, its supporting line, the voice line.
struct CueCard: View {
    var model: SessionHUDModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sentence
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 30)
                .id(model.phase.name + (model.pocket ? "-pocket" : ""))
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            if !model.pocket, model.voice != .idle(hints: []) {
                VoiceLine(voice: model.voice, accent: model.phase.field)
            }
            HoldToEnd(label: model.phase == .done ? "Hold to close" : "Hold to end")
                .padding(.top, 10)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30, style: .continuous)
                .fill(Theme.Session.card)
                .shadow(color: Theme.Session.cardShadow, radius: 18, y: -4)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    @ViewBuilder private var sentence: some View {
        switch model.phase {
        case .ready: ReadySentence(model: model)
        case .armed: ArmedSentence(model: model)
        case .recording(let elapsed): RecordingSentence(model: model, elapsed: elapsed)
        case .rest(let remaining, let total): RestSentence(model: model, remaining: remaining, total: total)
        case .hold(let remaining, let total, let index, let count):
            HoldSentence(model: model, remaining: remaining, total: total, index: index, count: count)
        case .done: DoneSentence(summary: model.summary)
        }
    }
}

// MARK: Type

private extension Font {
    /// The card's sentences: heavy, tight, read from the bench.
    static func cue(_ size: CGFloat, _ weight: Font.Weight = .heavy) -> Font { .system(size: size, weight: weight) }
    /// Targets and clocks: compressed black numerals, tabular.
    static func numerals(_ size: CGFloat) -> Font { .system(size: size, weight: .black).width(.compressed).monospacedDigit() }
    /// A clock whose weight follows a value (0 light … 1 black): the rest drains out of the digits.
    static func drainingNumerals(_ size: CGFloat, fullness: Double) -> Font {
        // From black at the start to regular when it runs out: thinner, never too thin to read from the bench.
        let weight = UIFont.Weight(rawValue: CGFloat(0.0 + 0.62 * max(0, min(1, fullness))))
        let base = UIFont.systemFont(ofSize: size, weight: weight, width: .compressed)
        let tabular = base.fontDescriptor.addingAttributes([.featureSettings: [[
            UIFontDescriptor.FeatureKey.type: kNumberSpacingType, UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
        ]]])
        return Font(UIFont(descriptor: tabular, size: size))
    }
}

/// The yellow highlighter stroke behind the one thing waiting on him: slightly skewed, under the
/// lower part of the words, like a real marker.
private struct Highlighted: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .background {
                GeometryReader { proxy in
                    Capsule(style: .continuous)
                        .fill(Theme.Session.highlighter)
                        .frame(height: proxy.size.height * 0.55)
                        .rotationEffect(.degrees(-1.4))
                        .offset(y: proxy.size.height * 0.42)
                }
            }
    }
}

private extension View {
    func highlighted() -> some View { modifier(Highlighted()) }
}

/// The role and set, quietly under the exercise ("Top set · set 1 of 2").
private struct RoleLine: View {
    var model: SessionHUDModel
    var body: some View {
        Text([model.role, model.setLabel].compactMap { $0 }.joined(separator: " · "))
            .font(.cue(24, .semibold))
            .foregroundStyle(Theme.textSecondary)
    }
}

// MARK: Sentences, by state

private struct ReadySentence: View {
    var model: SessionHUDModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.exercise).font(.cue(38)).foregroundStyle(Theme.navy).lineLimit(2).minimumScaleFactor(0.7)
            RoleLine(model: model)
            Text(model.target).font(.numerals(150)).foregroundStyle(Theme.navy).lineLimit(1).minimumScaleFactor(0.5)
            if let last = model.lastTime {
                Text(last).font(.cue(24, .medium)).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Text("Say ")
                Text("go").highlighted()
                Text(" when you lift.")
            }
            .font(.cue(40))
            .foregroundStyle(Theme.navy)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.bottom, 18)
        }
    }
}

private struct ArmedSentence: View {
    var model: SessionHUDModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Lift when\nyou're ready.").font(.cue(58)).foregroundStyle(Theme.navy).lineSpacing(-4)
            Text(model.target).font(.numerals(110)).foregroundStyle(Theme.navy).lineLimit(1).minimumScaleFactor(0.6)
            RoleLine(model: model)
            Spacer(minLength: 0)
            LockedOn(field: Theme.Session.armed)
                .padding(.bottom, 18)
        }
    }
}

/// The camera has him: a figure inside a dashed frame, and the words.
private struct LockedOn: View {
    var field: Color
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(field, style: StrokeStyle(lineWidth: 3, dash: [7, 5]))
                Image(systemName: "figure.strengthtraining.traditional").font(.system(size: 30, weight: .semibold)).foregroundStyle(field)
            }
            .frame(width: 62, height: 62)
            VStack(alignment: .leading, spacing: 2) {
                Text("Watching you").font(.cue(24, .bold)).foregroundStyle(Theme.navy)
                Text("Only your movement starts it.").font(.cue(22, .medium)).foregroundStyle(Theme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RecordingSentence: View {
    var model: SessionHUDModel
    var elapsed: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.exercise).font(.cue(34)).foregroundStyle(Theme.navy).lineLimit(1).minimumScaleFactor(0.7)
            RoleLine(model: model)
            HStack(alignment: .center, spacing: 16) {
                TimelineView(.animation(minimumInterval: 0.5)) { context in
                    let on = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                    Circle().fill(Theme.Session.recording).frame(width: 30, height: 30).opacity(on ? 1 : 0.35)
                }
                Text(Format.duration(TimeInterval(elapsed))).font(.numerals(170)).foregroundStyle(Theme.navy)
            }
            Text("Counting when you rack it.").font(.cue(26, .semibold)).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
    }
}

private struct RestSentence: View {
    var model: SessionHUDModel
    var remaining: Int
    var total: Int

    var body: some View {
        let over = remaining <= 0
        let fullness = over || total <= 0 ? 0 : Double(remaining) / Double(total)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(over ? "+" + Format.duration(TimeInterval(-remaining)) : Format.duration(TimeInterval(remaining)))
                    .font(.drainingNumerals(model.pocket ? 210 : 170, fullness: fullness))
                    .foregroundStyle(over ? Theme.Session.overtime : Theme.navy)
                    .contentTransition(.numericText(countsDown: true))
                Text(over ? "over" : "rest").font(.cue(26, .semibold)).foregroundStyle(Theme.textSecondary)
            }
            if !model.result.isEmpty, !model.pocket {
                FactLine(facts: model.result)
            }
            Spacer(minLength: 0)
            if let next = model.next {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Next").font(.cue(24, .semibold)).foregroundStyle(Theme.textSecondary)
                    Text(next).font(.cue(model.pocket ? 46 : 40)).foregroundStyle(Theme.navy).lineLimit(1).minimumScaleFactor(0.7).highlighted()
                    if let ask = model.nextAsk, !model.pocket {
                        Text(ask).font(.cue(24, .medium)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.bottom, 18)
            }
        }
    }
}

/// "11 reps · measured" over "slowed 46% · failure": the count and where it came from (cobalt, like a
/// source chip), then the effort. Two deliberate lines, never a wrap mid-phrase.
private struct FactLine: View {
    var facts: [SessionHUDModel.Fact]
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            line(Array(facts.prefix(2)))
            if facts.count > 2 { line(Array(facts.dropFirst(2))) }
        }
        .font(.cue(30, .bold))
    }

    private func line(_ items: [SessionHUDModel.Fact]) -> Text {
        items.enumerated().reduce(Text("")) { text, item in
            let piece = Text(item.element.text).foregroundStyle(item.element.source ? Theme.cobalt : Theme.navy)
            return item.offset == 0 ? piece : text + Text("  ·  ").foregroundStyle(Theme.Session.unspoken) + piece
        }
    }
}

private struct HoldSentence: View {
    var model: SessionHUDModel
    var remaining: Int
    var total: Int
    var index: Int
    var count: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.exercise).font(.cue(40)).foregroundStyle(Theme.navy)
            Text("Hold \(index) of \(count)").font(.cue(26, .semibold)).foregroundStyle(Theme.textSecondary)
            Text(Format.duration(TimeInterval(remaining)))
                .font(.drainingNumerals(210, fullness: total > 0 ? Double(remaining) / Double(total) : 0))
                .foregroundStyle(Theme.navy)
            HoldTrack(index: index, count: count)
            Spacer(minLength: 0)
        }
    }
}

/// The holds as segments: done filled, the current one in the rest's blue, upcoming open.
private struct HoldTrack: View {
    var index: Int
    var count: Int
    var body: some View {
        HStack(spacing: 8) {
            ForEach(1...max(1, count), id: \.self) { i in
                Capsule()
                    .fill(i < index ? Theme.navy : i == index ? Theme.Session.rest : Theme.border)
                    .frame(height: 10)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct DoneSentence: View {
    var summary: SessionHUDModel.Summary?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Saved.").font(.cue(64)).foregroundStyle(Theme.navy)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(summary?.lines ?? []) { line in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(line.exercise).font(.cue(24, .semibold)).foregroundStyle(Theme.textSecondary)
                            Spacer(minLength: 10)
                            Text(line.top).font(.numerals(44)).foregroundStyle(Theme.navy)
                        }
                        if let beat = line.beat {
                            Text(beat).font(.cue(22, .bold)).foregroundStyle(Theme.navy).highlighted()
                        }
                    }
                }
            }
            if let notes = summary?.notes, !notes.isEmpty {
                Text(notes.joined(separator: "\n")).font(.cue(22, .medium)).foregroundStyle(Theme.textSecondary).lineSpacing(4)
            }
            Text("Your coach sees all of it on Thursday.").font(.cue(22, .medium)).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
    }
}

// MARK: The voice line

/// The session's talking indicator, the check-in's voice bar at gym scale: a disc that moves with
/// whoever is talking, and the words themselves. His words appear as he says them, in cobalt;
/// Setecho's line fills word by word as it's spoken. Idle, it offers two or three things to say.
struct VoiceLine: View {
    var voice: SessionHUDModel.Voice
    var accent: Color

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            disc
            words.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 16)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        .animation(.snappy(duration: 0.3), value: voice)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }

    private var disc: some View {
        ZStack {
            Circle().fill(discFill)
            switch voice {
            case .idle:
                Image(systemName: "waveform").font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.cobalt)
            case .hearing(_, let level):
                WaveformBars(level: level, animating: true, color: .white)
            case .thinking:
                ThinkingDots()
            case .speaking:
                WaveformBars(level: 0.55, animating: true, color: .white)
            }
        }
        .frame(width: 64, height: 64)
    }

    private var discFill: Color {
        switch voice {
        case .idle, .thinking: Theme.cobaltTint
        case .hearing: Theme.cobalt
        case .speaking: accent
        }
    }

    @ViewBuilder private var words: some View {
        switch voice {
        case .idle(let hints):
            hints.enumerated().reduce(Text("Say ").foregroundStyle(Theme.textSecondary)) { line, item in
                let joiner = item.offset == 0 ? "" : (item.offset == hints.count - 1 ? " or " : ", ")
                return line + Text(joiner).foregroundStyle(Theme.textSecondary)
                    + Text("\u{201C}\(item.element)\u{201D}").foregroundStyle(Theme.navy)
            }
            .font(.cue(24, .semibold))
            .lineLimit(2)
            .minimumScaleFactor(0.8)
        case .hearing(let said, _), .thinking(let said):
            Text("\u{201C}\(said)\u{201D}").font(.cue(28, .bold)).foregroundStyle(Theme.cobalt).lineLimit(2).minimumScaleFactor(0.8)
        case .speaking(let line, let spoken):
            line.split(separator: " ").enumerated().reduce(Text("")) { text, item in
                text + Text((item.offset == 0 ? "" : " ") + item.element)
                    .foregroundStyle(item.offset < spoken ? Theme.navy : Theme.Session.unspoken)
            }
            .font(.cue(28, .bold))
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

/// The long press that ends the session (no tap ends anything): quiet, at the foot of the card.
private struct HoldToEnd: View {
    var label: String
    var body: some View {
        HStack(spacing: 10) {
            Circle().strokeBorder(Theme.border, lineWidth: 3).frame(width: 22, height: 22)
            Text(label).font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .accessibilityLabel("\(label) session")
        .accessibilityHint("Press and hold, or say end session")
    }
}

// MARK: The states, for previews and the screenshots

extension SessionHUDModel {
    private static let day5: [ExerciseDots] = [
        .init(name: "Smith CG", dots: [.done, .done]),
        .init(name: "Incline", dots: [.done, .current]),
        .init(name: "Flyes", dots: [.upcoming, .upcoming]),
        .init(name: "Dips", dots: [.upcoming]),
        .init(name: "Abs", dots: [.upcoming, .upcoming], isAddOn: true),
    ]

    static let ready = SessionHUDModel(
        phase: .ready, progress: day5, micLabel: "AirPods mic", micOnHim: true, exercise: "Incline DB press", role: "Back-off",
        setLabel: "set 2 of 2", target: "65 × 8–10", lastTime: "Last time 60 × 10", voice: .idle(hints: ["what did I do last time?", "where am I?"]))

    static let armed = SessionHUDModel(
        phase: .armed, progress: day5, micLabel: "AirPods mic", micOnHim: true, exercise: "Incline DB press", role: "Back-off",
        setLabel: "set 2 of 2", target: "65 × 8–10", voice: .speaking("Set two. Lift when you're ready.", spoken: 3))

    static let recording = SessionHUDModel(
        phase: .recording(elapsed: 24), progress: day5, micLabel: "AirPods mic", micOnHim: true, exercise: "Incline DB press",
        role: "Back-off", setLabel: "set 2 of 2", target: "65 × 8–10", voice: .idle(hints: ["done", "done, 9"]))

    static let rest = SessionHUDModel(
        phase: .rest(remaining: 100, total: 180), progress: day5, micLabel: "AirPods mic", micOnHim: true, exercise: "Incline DB press",
        role: "Top set", setLabel: "set 1 of 2", target: "80 × 6–8", voice: .hearing("how long left", level: 0.6),
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
        exercise: "Stomach vacuums", setLabel: "hold 2 of 4", target: "20 s", voice: .idle(hints: ["done", "hold on"]))

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
        micLabel: "AirPods mic", micOnHim: true, exercise: "", setLabel: "", target: "", voice: .idle(hints: []),
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
