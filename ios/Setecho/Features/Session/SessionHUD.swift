import SwiftUI

/// The session screen, redesigned after the Oct 28 gym test (HANDOFF.md §7, The session screen;
/// DESIGN.md Session): readable from 3 m, one big thing at a time, friendly rounded cards, a colour
/// per state that is always named in text too. Always on screen: the progress strip, the live
/// mic, the last exchange and two or three things to say. The ear carries the session; this is for
/// a glance.
///
/// Built from a plain model so the six states render as previews (and as screenshots in
/// `SessionHUDRenderTests`) before any of it is wired to the engine.
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

    struct Exchange: Equatable {
        var heard: String
        var said: String?
    }

    struct Summary: Equatable {
        struct Line: Equatable, Identifiable {
            var id: String { exercise }
            var exercise: String
            var top: String
            var note: String?
        }
        /// A flag, a note or a gym change, with its SF Symbol.
        struct Extra: Equatable, Hashable {
            var icon: String
            var text: String
        }
        var lines: [Line]
        var extras: [Extra]
    }

    var phase: Phase
    /// The phone is in a pocket (camera off duty): the same states with no preview, dimmed.
    var pocket = false
    var exercise: String
    var role: String?
    var setLabel: String
    var target: String
    var lastTime: String?
    var hint: String?
    var progress: [ExerciseDots]
    var micLabel: String
    var micOnHim: Bool
    var micLevel: Double
    var exchange: Exchange?
    var phrases: [String]
    /// Rest: the set just done, "11 reps · measured · slowed 46% · failure".
    var result: String?
    /// Rest: what's next, "Back-off 145 × 8–10", and what to say to it.
    var next: String?
    var nextAsk: String?
    var summary: Summary?
}

extension SessionHUDModel.Phase {
    var name: String {
        switch self {
        case .ready: "Ready"
        case .armed: "Armed"
        case .recording: "Recording"
        case .rest(let left, _): left > 0 ? "Rest" : "Rest's up"
        case .hold: "Hold"
        case .done: "Done"
        }
    }

    var color: Color {
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

struct SessionHUD: View {
    var model: SessionHUDModel

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            ProgressStrip(exercises: model.progress)
            HStack {
                StateBadge(phase: model.phase)
                Spacer(minLength: Theme.Space.s)
                MicLevel(label: model.micLabel, onHim: model.micOnHim, level: model.micLevel)
            }
            main
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .id(model.phase.name)
            if let exchange = model.exchange { ExchangeBubbles(exchange: exchange) }
            PhraseChips(phrases: model.phrases)
            Text(model.phase == .done ? "Hold to close" : "Hold to end session")
                .font(.headline)
                .foregroundStyle(Theme.Session.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 52)
                .overlay(Capsule().strokeBorder(Theme.Session.hairline, lineWidth: 1.5))
        }
        .padding(Theme.gutter)
        .background(Theme.Session.page.ignoresSafeArea())
        // In a pocket the screen dims: the dark palette, darker still, and the haptics carry it.
        .overlay { if model.pocket { Color.black.opacity(0.35).ignoresSafeArea().allowsHitTesting(false) } }
        .environment(\.colorScheme, model.pocket ? .dark : colorScheme)
        .animation(.spring(duration: 0.45), value: model.phase)
    }

    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder private var main: some View {
        switch model.phase {
        case .ready: ReadyPanel(model: model)
        case .armed: ArmedPanel(model: model)
        case .recording(let elapsed): RecordingPanel(model: model, elapsed: elapsed)
        case .rest(let remaining, let total): RestPanel(model: model, remaining: remaining, total: total)
        case .hold(let remaining, let total, let index, let count): HoldPanel(model: model, remaining: remaining, total: total, index: index, count: count)
        case .done: SummaryPanel(summary: model.summary)
        }
    }
}

// MARK: Always on screen

/// Today's exercises as short names, a dot per set: done (filled), current (ringed), upcoming
/// (hollow), skipped (a dash). Add-ons after a divider.
struct ProgressStrip: View {
    var exercises: [SessionHUDModel.ExerciseDots]

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            ForEach(Array(exercises.enumerated()), id: \.element.id) { i, ex in
                if ex.isAddOn, i > 0, !exercises[i - 1].isAddOn {
                    Rectangle().fill(Theme.Session.hairline).frame(width: 1.5, height: 38)
                }
                VStack(spacing: 6) {
                    Text(ex.name)
                        .font(.system(size: 15, weight: ex.dots.contains(.current) ? .bold : .medium))
                        .foregroundStyle(ex.dots.contains(.current) ? Theme.Session.text : Theme.Session.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    HStack(spacing: 4) {
                        ForEach(Array(ex.dots.enumerated()), id: \.offset) { _, dot in DotView(dot: dot) }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, Theme.Space.s)
        .padding(.horizontal, Theme.Space.s)
        .background(Theme.Session.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(exercises.map { "\($0.name), \($0.dots.filter { $0 == .done }.count) of \($0.dots.count) done" }.joined(separator: "; "))
    }

    private struct DotView: View {
        var dot: SessionHUDModel.ExerciseDots.Dot
        var body: some View {
            switch dot {
            case .done: Circle().fill(Theme.Session.text).frame(width: 10, height: 10)
            case .current:
                Circle().strokeBorder(Theme.Session.text, lineWidth: 2).frame(width: 14, height: 14)
                    .overlay(Circle().fill(Theme.Session.text).frame(width: 5, height: 5))
            case .upcoming: Circle().strokeBorder(Theme.Session.textSecondary, lineWidth: 1.5).frame(width: 10, height: 10)
            case .skipped: Capsule().fill(Theme.Session.textSecondary).frame(width: 10, height: 2.5)
            }
        }
    }
}

/// The state, named and coloured: never colour alone.
struct StateBadge: View {
    var phase: SessionHUDModel.Phase

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Circle().fill(phase.color).frame(width: 14, height: 14)
            Text(phase.name).font(.system(size: 22, weight: .bold))
        }
        .foregroundStyle(phase.color)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.xs)
        .background(Theme.Session.tint(phase.color), in: Capsule())
        .accessibilityLabel("State: \(phase.name)")
    }
}

/// A small live waveform that moves when he talks. Red with "Can't hear you, phone mic" when the
/// only input is the phone's own mic, far away on the tripod.
struct MicLevel: View {
    var label: String
    var onHim: Bool
    var level: Double

    var body: some View {
        let color = onHim ? Theme.Session.text : Theme.Session.recording
        HStack(spacing: Theme.Space.xs) {
            WaveformBars(level: onHim ? level : min(level, 0.2), animating: level > 0.05, color: color)
                .frame(height: 30)
            Text(onHim ? label : "Can't hear you, \(label.lowercased())")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(onHim ? "Listening on \(label)" : "Can't hear you well: \(label)")
    }
}

/// What he said and what Setecho said, as two small chat bubbles (they fade after 10 s).
struct ExchangeBubbles: View {
    var exchange: SessionHUDModel.Exchange

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            HStack {
                Spacer(minLength: 60)
                Text(exchange.heard)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Theme.Session.text)
                    .padding(.horizontal, Theme.Space.m).padding(.vertical, 10)
                    .background(Theme.Session.tint(Theme.Session.rest), in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
            }
            if let said = exchange.said {
                HStack {
                    Text(said)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(Theme.Session.text)
                        .padding(.horizontal, Theme.Space.m).padding(.vertical, 10)
                        .background(Theme.Session.card, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
                    Spacer(minLength: 60)
                }
            }
        }
    }
}

/// Two or three things he could say now (`VoiceGuide.hints`).
struct PhraseChips: View {
    var phrases: [String]

    var body: some View {
        // One row when they fit, else two: a chip is never cut short.
        ViewThatFits(in: .horizontal) {
            row(phrases)
            VStack(spacing: Theme.Space.xs) {
                row(Array(phrases.prefix(2)))
                row(Array(phrases.dropFirst(2)))
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("You could say: " + phrases.joined(separator: ", "))
    }

    private func row(_ items: [String]) -> some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(items, id: \.self) { phrase in
                Text("\u{201C}\(phrase)\u{201D}")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.Session.text)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, Theme.Space.s).padding(.vertical, 9)
                    .background(Theme.Session.card, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.Session.hairline, lineWidth: 1))
            }
        }
    }
}

// MARK: The main area, by state

private struct HUDCard<Content: View>: View {
    var accent: Color?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.cardPadding)
            .background(Theme.Session.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(alignment: .leading) {
                if let accent { Capsule().fill(accent).frame(width: 5).padding(.vertical, 16) }
            }
    }
}

/// The exercise, the set's role and the target, then last time and the hint.
private struct ReadyPanel: View {
    var model: SessionHUDModel

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Spacer(minLength: 0)
            Text(model.exercise).font(.system(size: 32, weight: .bold)).foregroundStyle(Theme.Session.text)
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
            Text([model.role, model.setLabel].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.navy)
                .padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
                .background(Theme.yellow, in: RoundedRectangle(cornerRadius: Theme.Radius.tag, style: .continuous))
            Text(model.target).font(.hudTarget).foregroundStyle(Theme.Session.text).lineLimit(1).minimumScaleFactor(0.5)
            if let last = model.lastTime { Text(last).font(.hudLabel).foregroundStyle(Theme.Session.textSecondary) }
            Spacer(minLength: 0)
            if let hint = model.hint {
                Label(hint, systemImage: "waveform")
                    .font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.Session.text)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A pulsing amber ring, "Lift when you're ready", and the camera's small view with his outline.
private struct ArmedPanel: View {
    var model: SessionHUDModel

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Spacer(minLength: 0)
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let pulse = 0.5 + 0.5 * sin(t * 3)
                ZStack {
                    Circle().stroke(Theme.Session.tint(Theme.Session.armed), lineWidth: 26)
                    Circle().stroke(Theme.Session.armed, lineWidth: 10).scaleEffect(0.92 + 0.06 * pulse).opacity(0.55 + 0.45 * pulse)
                    VStack(spacing: 6) {
                        Text("Lift when").font(.system(size: 30, weight: .bold))
                        Text("you're ready").font(.system(size: 30, weight: .bold))
                        Text(model.target).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.Session.textSecondary)
                    }
                    .foregroundStyle(Theme.Session.text)
                }
                .frame(width: 250, height: 250)
            }
            if !model.pocket { CameraThumbnail() }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The camera's view, small, with an outline on him (the lock-on). A placeholder in previews.
private struct CameraThumbnail: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.cameraFill)
            Image(systemName: "figure.strengthtraining.traditional")
                .font(.system(size: 54)).foregroundStyle(.white.opacity(0.55))
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.Session.armed, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                .frame(width: 70, height: 84)
            Text("Locked on you").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.Session.armed, in: Capsule())
                .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 8)
        }
        .frame(width: 150, height: 120)
        .accessibilityLabel("Camera locked on you")
    }
}

/// A red dot and the elapsed time. No rep number until it's measured.
private struct RecordingPanel: View {
    var model: SessionHUDModel
    var elapsed: Int

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Spacer(minLength: 0)
            Text(model.exercise).font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.Session.text).lineLimit(1).minimumScaleFactor(0.7)
            Text([model.role, model.setLabel].compactMap { $0 }.joined(separator: " · "))
                .font(.hudLabel).foregroundStyle(Theme.Session.textSecondary)
            HStack(spacing: Theme.Space.m) {
                TimelineView(.animation(minimumInterval: 1 / 2)) { context in
                    let on = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                    Circle().fill(Theme.Session.recording).frame(width: 34, height: 34).opacity(on ? 1 : 0.55)
                }
                Text(Format.duration(TimeInterval(elapsed))).font(.hudTarget).foregroundStyle(Theme.Session.text)
            }
            Text("Counting after the set").font(.hudLabel).foregroundStyle(Theme.Session.textSecondary)
            Spacer(minLength: 0)
            if !model.pocket {
                HStack {
                    Spacer()
                    CameraThumbnail().scaleEffect(0.8)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A big countdown ring (overtime +0:40 in a calmer colour), then the result card and the next card.
private struct RestPanel: View {
    var model: SessionHUDModel
    var remaining: Int
    var total: Int

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            // The ring gives way to the cards: as big as the screen allows, never pushing anything off it.
            CountdownRing(remaining: remaining, total: total, color: remaining > 0 ? Theme.Session.rest : Theme.Session.overtime,
                          caption: remaining > 0 ? "rest" : "over")
                .aspectRatio(1, contentMode: .fit)
                .frame(minWidth: 120, maxWidth: 230, minHeight: 120, maxHeight: 230)
                .layoutPriority(-1)
            if let result = model.result {
                HUDCard(accent: nil) {
                    Text("Last set").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.Session.textSecondary)
                    Text(result).font(.system(size: 21, weight: .semibold)).foregroundStyle(Theme.Session.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let next = model.next {
                HUDCard(accent: nil) {
                    Text("Next").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.Session.textSecondary)
                    Text(next).font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.navy)
                        .padding(.horizontal, Theme.Space.xs).padding(.vertical, 4)
                        .background(Theme.yellow, in: RoundedRectangle(cornerRadius: Theme.Radius.tag, style: .continuous))
                    if let ask = model.nextAsk {
                        Text(ask).font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.Session.textSecondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A big countdown ring with the hold's name and "2 of 4".
private struct HoldPanel: View {
    var model: SessionHUDModel
    var remaining: Int
    var total: Int
    var index: Int
    var count: Int

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Spacer(minLength: 0)
            Text(model.exercise).font(.system(size: 32, weight: .bold)).foregroundStyle(Theme.Session.text)
            CountdownRing(remaining: remaining, total: total, color: Theme.Session.rest, caption: "hold")
                .frame(width: 260, height: 260)
            Text("\(index) of \(count)").font(.hudState).foregroundStyle(Theme.Session.textSecondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The ring: the share of the time left, the time in the middle, "+0:40" once it runs over.
struct CountdownRing: View {
    var remaining: Int
    var total: Int
    var color: Color
    var caption: String

    var body: some View {
        let share = remaining > 0 && total > 0 ? Double(remaining) / Double(total) : 0
        ZStack {
            Circle().stroke(Theme.Session.tint(color), lineWidth: 18)
            Circle().trim(from: 0, to: share)
                .stroke(color, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: share)
            VStack(spacing: 0) {
                Text(remaining >= 0 ? Format.duration(TimeInterval(remaining)) : "+" + Format.duration(TimeInterval(-remaining)))
                    .font(.system(size: 72, weight: .bold).monospacedDigit())
                    .foregroundStyle(remaining > 0 ? Theme.Session.text : color)
                    .minimumScaleFactor(0.6)
                Text(caption).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.Session.textSecondary)
            }
            .padding(Theme.Space.l)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(remaining > 0 ? "\(Format.duration(TimeInterval(remaining))) \(caption) left" : "Rest's up, \(Format.duration(TimeInterval(-remaining))) over")
    }
}

/// Session end: each exercise's top set, any logbook beaten, flags and notes, then "Saved."
private struct SummaryPanel: View {
    var summary: SessionHUDModel.Summary?

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(Theme.Session.done)
            HUDCard(accent: nil) {
                ForEach(summary?.lines ?? []) { line in
                    HStack(alignment: .firstTextBaseline) {
                        Text(line.exercise).font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.Session.text)
                        Spacer(minLength: Theme.Space.s)
                        Text(line.top).font(.system(size: 19, weight: .bold).monospacedDigit()).foregroundStyle(Theme.Session.text)
                    }
                    if let note = line.note {
                        Text(note).font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.Session.done)
                    }
                    if line != summary?.lines.last { Rectangle().fill(Theme.Session.hairline).frame(height: 1) }
                }
            }
            ForEach(summary?.extras ?? [], id: \.self) { extra in
                Label(extra.text, systemImage: extra.icon).font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.Session.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Saved.").font(.hudState).foregroundStyle(Theme.Session.done)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: The six states, for previews and the screenshots

extension SessionHUDModel {
    private static let day5: [ExerciseDots] = [
        .init(name: "Smith CG", dots: [.done, .done]),
        .init(name: "Incline", dots: [.done, .current]),
        .init(name: "Flyes", dots: [.upcoming, .upcoming]),
        .init(name: "Dips", dots: [.upcoming]),
        .init(name: "Abs", dots: [.upcoming, .upcoming], isAddOn: true),
    ]

    static let ready = SessionHUDModel(
        phase: .ready, exercise: "Incline DB press", role: "Back-off", setLabel: "Set 2 of 2", target: "65 × 8–10",
        lastTime: "Last time 60 × 10", hint: "Say go when you lift.", progress: day5, micLabel: "AirPods mic", micOnHim: true,
        micLevel: 0.1, exchange: .init(heard: "what's next?", said: "Back-off at 65, his rule."), phrases: ["go", "what did I do last time?"])

    static let armed = SessionHUDModel(
        phase: .armed, exercise: "Incline DB press", role: "Back-off", setLabel: "Set 2 of 2", target: "65 × 8–10",
        progress: day5, micLabel: "AirPods mic", micOnHim: true, micLevel: 0.7, exchange: .init(heard: "go", said: nil),
        phrases: ["done, 9", "where am I?"])

    static let recording = SessionHUDModel(
        phase: .recording(elapsed: 24), exercise: "Incline DB press", role: "Back-off", setLabel: "Set 2 of 2", target: "65 × 8–10",
        progress: day5, micLabel: "AirPods mic", micOnHim: true, micLevel: 0.3, phrases: ["done", "done, 9"])

    static let rest = SessionHUDModel(
        phase: .rest(remaining: 100, total: 180), exercise: "Incline DB press", role: "Top set", setLabel: "Set 1 of 2", target: "80 × 6–8",
        progress: day5, micLabel: "AirPods mic", micOnHim: true, micLevel: 0.05,
        exchange: .init(heard: "how long left?", said: "One forty left."), phrases: ["that was 9", "how long left?", "the bench is taken"],
        result: "11 reps · measured · slowed 46% · failure", next: "Back-off 65 × 8–10", nextAsk: "Say \u{201C}go with it\u{201D} or a weight.")

    static let restOvertime: SessionHUDModel = {
        var m = rest
        m.phase = .rest(remaining: -40, total: 180)
        m.exchange = nil
        return m
    }()

    static let hold = SessionHUDModel(
        phase: .hold(remaining: 14, total: 20, index: 2, count: 4), exercise: "Stomach vacuums", setLabel: "Hold 2 of 4", target: "20 s",
        progress: [.init(name: "Vacuums", dots: [.done, .current, .upcoming, .upcoming])], micLabel: "Phone mic", micOnHim: false,
        micLevel: 0.1, phrases: ["done", "hold on"])

    static let pocket: SessionHUDModel = {
        var m = rest
        m.pocket = true
        m.micLabel = "Phone mic"
        m.micOnHim = false
        m.exchange = nil
        return m
    }()

    static let done = SessionHUDModel(
        phase: .done, exercise: "", setLabel: "", target: "",
        progress: [.init(name: "Smith CG", dots: [.done, .done]), .init(name: "Incline", dots: [.done, .done]),
                   .init(name: "Flyes", dots: [.done, .done]), .init(name: "Dips", dots: [.skipped]),
                   .init(name: "Abs", dots: [.done, .done], isAddOn: true)],
        micLabel: "AirPods mic", micOnHim: true, micLevel: 0, phrases: [],
        summary: .init(lines: [.init(exercise: "Smith close-grip", top: "205 × 9", note: "Beat the logbook: 200 × 9"),
                               .init(exercise: "Incline DB press", top: "80 × 11"),
                               .init(exercise: "Cable flyes", top: "30 × 12")],
                       extras: [.init(icon: "flag.fill", text: "Flagged for your coach: incline top set"),
                                .init(icon: "text.bubble.fill", text: "Note: left shoulder pinched"),
                                .init(icon: "arrow.uturn.right", text: "Skipped: dips (bench taken)")]))

    /// Every state for the screenshots, in order.
    static let gallery: [(String, SessionHUDModel)] = [
        ("1-ready", ready), ("2-armed", armed), ("3-recording", recording), ("4-rest", rest), ("4b-rest-overtime", restOvertime),
        ("5-hold", hold), ("6-pocket", pocket), ("7-session-end", done),
    ]
}

#Preview("Ready") { SessionHUD(model: .ready) }
#Preview("Ready, dark") { SessionHUD(model: .ready).preferredColorScheme(.dark) }
#Preview("Armed") { SessionHUD(model: .armed) }
#Preview("Armed, dark") { SessionHUD(model: .armed).preferredColorScheme(.dark) }
#Preview("Recording") { SessionHUD(model: .recording) }
#Preview("Recording, dark") { SessionHUD(model: .recording).preferredColorScheme(.dark) }
#Preview("Rest") { SessionHUD(model: .rest) }
#Preview("Rest, dark") { SessionHUD(model: .rest).preferredColorScheme(.dark) }
#Preview("Rest overtime") { SessionHUD(model: .restOvertime) }
#Preview("Hold") { SessionHUD(model: .hold) }
#Preview("Hold, dark") { SessionHUD(model: .hold).preferredColorScheme(.dark) }
#Preview("Pocket") { SessionHUD(model: .pocket) }
#Preview("Pocket, dark") { SessionHUD(model: .pocket).preferredColorScheme(.dark) }
#Preview("Session end") { SessionHUD(model: .done) }
#Preview("Session end, dark") { SessionHUD(model: .done).preferredColorScheme(.dark) }
