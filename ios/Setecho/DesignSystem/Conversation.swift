import SwiftUI

// The pieces of a spoken conversation on a hands-free screen (Check-in morning, the wrap-up): what
// Setecho said, what the athlete said, each answer the moment it is stored, the steps of the
// morning, and whose turn it is. Tokens only. Read from arm's length and from across the room, so
// nothing on these screens is smaller than `.hudLabel` except the source chip and the voice line.

// MARK: - The transcript

/// One thing in the conversation, in the order it happened.
struct ConversationEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        /// A line Setecho spoke.
        case setecho
        /// What the athlete said, as heard.
        case athlete
        /// An answer stored in the check-in: the field, what went in, and where it came from.
        case answer(label: String, value: String, source: String)
        /// A quiet note in the flow: "Photos are in", "Weight asked again".
        case note
        /// The summary before the send: what is going out, grouped by where it came from.
        case summary([SummarySection])
    }

    let id: UUID
    let kind: Kind
    let text: String

    init(id: UUID = UUID(), kind: Kind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }

    static func setecho(_ text: String) -> ConversationEntry { .init(kind: .setecho, text: text) }
    static func athlete(_ text: String) -> ConversationEntry { .init(kind: .athlete, text: text) }
    static func note(_ text: String) -> ConversationEntry { .init(kind: .note, text: text) }
    static func summary(_ sections: [SummarySection]) -> ConversationEntry { .init(kind: .summary(sections), text: "Summary") }
    static func answer(label: String, value: String, source: String) -> ConversationEntry {
        .init(kind: .answer(label: label, value: value, source: source), text: value)
    }
}

/// The conversation so far, newest at the bottom, scrolled to the latest line as it arrives. The
/// line being asked now is the big one; everything before it has settled into the record.
struct ConversationTranscript: View {
    let entries: [ConversationEntry]
    /// How many lines back to keep on screen: older ones scroll away.
    var visible = 24

    private var shown: [ConversationEntry] { Array(entries.suffix(visible)) }
    private var currentId: UUID? { entries.last { $0.kind == .setecho }?.id }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    // The conversation sits at the bottom of its space, nearest the voice bar, and
                    // grows upward as it goes, the way a chat does.
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        ForEach(shown) { entry in
                            row(entry)
                                .id(entry.id)
                                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: geometry.size.height, alignment: .bottom)
                    .padding(.vertical, Theme.Space.xs)
                }
                .defaultScrollAnchor(.bottom)
                .scrollIndicators(.hidden)
                .onChange(of: entries.count) {
                    withAnimation(.snappy(duration: 0.4)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .animation(.snappy(duration: 0.4), value: entries.count)
    }

    @ViewBuilder private func row(_ entry: ConversationEntry) -> some View {
        switch entry.kind {
        case .setecho:
            SetechoLine(text: entry.text, current: entry.id == currentId)
        case .athlete:
            AthleteLine(text: entry.text)
        case .answer(let label, let value, let source):
            AnswerCard(label: label, value: value, source: source)
        case .note:
            Text(entry.text).font(.hudLabel).secondaryText().frame(maxWidth: .infinity, alignment: .center)
        case .summary(let sections):
            SummaryCard(sections: sections)
        }
    }
}

/// One group of the summary: "From you this morning", "From Apple Health and your log", "Photos".
struct SummarySection: Equatable, Identifiable {
    let title: String
    let rows: [SummaryRow]
    var id: String { title }
}

/// One line of the summary: the field and what is going out.
struct SummaryRow: Equatable, Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

/// The summary before the send, as one card: each group under its own title, one line per field,
/// the value as the coach will read it. Simple and in his order.
struct SummaryCard: View {
    let sections: [SummarySection]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                if index > 0 { Spacer().frame(height: Theme.Space.xxs) }
                Text(section.title).font(.hudLabel.weight(.semibold)).foregroundStyle(Theme.navy)
                CardDivider()
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { rowIndex, row in
                    if rowIndex > 0 { CardDivider() }
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Text(row.label).font(.hudLabel).secondaryText().lineLimit(2)
                        Spacer(minLength: Theme.Space.xs)
                        Text(row.value).font(.hudLabel).monospacedDigit().foregroundStyle(Theme.navy)
                            .multilineTextAlignment(.trailing).lineLimit(3)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// A line Setecho spoke. The one being asked now reads in `.hudState`; earlier lines settle to
/// `.hudLabel` in the secondary color, so the eye lands on the question.
struct SetechoLine: View {
    let text: String
    var current = false

    var body: some View {
        Text(text)
            // A long line (the introduction, a read-back with its fact) steps down one size so it
            // still fits above the voice bar.
            .font(current ? (text.count > 70 ? .hudQuestion : .hudState) : .hudLabel)
            .foregroundStyle(current ? Theme.navy : Theme.textSecondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.snappy(duration: 0.35), value: current)
            .accessibilityLabel("Setecho: \(text)")
    }
}

/// What the athlete said, as heard: his words on the user's cobalt-tint bubble, on the right.
struct AthleteLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.hudLabel)
            .foregroundStyle(Theme.navy)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .background(Theme.cobaltTint, in: UnevenRoundedRectangle(
                topLeadingRadius: Theme.Radius.bubble + 4, bottomLeadingRadius: Theme.Radius.bubble + 4,
                bottomTrailingRadius: Theme.Radius.tag / 2, topTrailingRadius: Theme.Radius.bubble + 4, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, Theme.Space.xl)
            .accessibilityLabel("You said: \(text)")
    }
}

/// An answer the moment it is stored: the check draws itself, then the field, the value as the
/// coach will read it, and where it came from.
struct AnswerCard: View {
    let label: String
    let value: String
    let source: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            AnimatedCheck(size: 30)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(label).font(.hudLabel).secondaryText()
                Text(value)
                    .font(.hudLabel.weight(.semibold))
                    .foregroundStyle(Theme.navy)
                    .fixedSize(horizontal: false, vertical: true)
                SourceChip(source: source)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value). Source: \(source)")
    }
}

// MARK: - The check

/// A check mark that draws itself when it appears: the ring lands, then the stroke sweeps through.
struct AnimatedCheck: View {
    var size: CGFloat = 28
    var color: Color = Theme.cobalt
    @State private var landed = false
    @State private var drawn = false

    var body: some View {
        ZStack {
            Circle().fill(Theme.cobaltTint)
            Circle().strokeBorder(color, lineWidth: max(1.5, size * 0.07))
                .scaleEffect(landed ? 1 : 0.5)
                .opacity(landed ? 1 : 0)
            CheckShape()
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(color, style: StrokeStyle(lineWidth: max(2, size * 0.1), lineCap: .round, lineJoin: .round))
                .padding(size * 0.3)
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.spring(duration: 0.4, bounce: 0.4)) { landed = true }
            withAnimation(.easeOut(duration: 0.35).delay(0.15)) { drawn = true }
        }
        .accessibilityHidden(true)
    }
}

/// The two strokes of a check, drawn left to right.
struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.55))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.05))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.1))
        return p
    }
}

// MARK: - The steps

/// The steps of a flow as one track: done steps in cobalt, the current one on yellow (the one thing
/// waiting on the athlete), the rest as hairlines. Titles sit beneath each segment.
struct StepTrack: View {
    struct Step: Identifiable, Equatable {
        let id: String
        let title: String
    }

    let steps: [Step]
    /// The index of the current step; `steps.count` once every step is done.
    let current: Int

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.xs) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                let state = index < current ? State.done : index == current ? .current : .pending
                VStack(spacing: Theme.Space.xs) {
                    Capsule()
                        .fill(state == .pending ? Theme.border : state == .done ? Theme.cobalt : Theme.yellow)
                        .frame(height: 6)
                    HStack(spacing: 3) {
                        if state == .done {
                            Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Theme.cobalt)
                        }
                        Text(step.title)
                            .font(.subheadline.weight(state == .current ? .semibold : .regular))
                            .foregroundStyle(state == .pending ? Theme.textSecondary : Theme.navy)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(step.title), \(state == .done ? "done" : state == .current ? "now" : "to come")")
            }
        }
        .animation(.snappy(duration: 0.45), value: current)
    }

    private enum State { case done, current, pending }
}

// MARK: - Whose turn

/// What the voice is doing right now.
enum VoicePhase: Equatable {
    /// Setecho is talking; the mic is closed so it never hears itself.
    case speaking
    /// The mic is open for the athlete.
    case listening
    /// A turn was heard and is being read.
    case thinking
    /// He asked for time; the mic stays open, quietly.
    case paused
    /// Nothing to show (the photo session or review is up).
    case idle
}

/// The bar that says whose turn it is: a live waveform while the athlete talks, Setecho's own
/// pulse while it speaks, a thinking beat while a turn is read, and a quiet line while he takes
/// his time. The one place on the screen that moves.
struct VoiceBar: View {
    let phase: VoicePhase
    /// The mic level above the room, 0…1, for the waveform while listening.
    var level: Double = 0

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            ZStack {
                Circle().fill(phase == .paused ? Theme.fieldFill : Theme.cobaltTint)
                switch phase {
                case .speaking:
                    WaveformBars(level: 0.55, animating: true)
                case .listening:
                    WaveformBars(level: level, animating: level > 0.08)
                case .thinking:
                    ThinkingDots()
                case .paused:
                    Image(systemName: "pause.fill").font(.title3.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                case .idle:
                    Image(systemName: "waveform").font(.title3.weight(.semibold)).foregroundStyle(Theme.cobalt)
                }
            }
            .frame(width: 56, height: 56)
            Text(label)
                .font(.hudLabel.weight(phase == .listening ? .semibold : .regular))
                .foregroundStyle(phase == .listening ? Theme.cobalt : Theme.textSecondary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .contentTransition(.opacity)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.xs)
        .frame(maxWidth: .infinity, minHeight: 72)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .animation(.snappy(duration: 0.3), value: phase)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch phase {
        case .speaking: "Setecho"
        case .listening: level > 0.25 ? "Hearing you" : "Your turn"
        case .thinking: "Hearing that…"
        case .paused: "Take your time. Say \"I'm back\" when you're ready."
        case .idle: ""
        }
    }
}

/// Five bars that follow a level, with a little life of their own while something is being said.
struct WaveformBars: View {
    /// 0…1
    var level: Double
    var animating: Bool
    var color: Color = Theme.cobalt

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animating)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    let phase = Double(i) * 1.1
                    let wobble = animating ? 0.5 + 0.5 * sin(t * 7 + phase) : 0
                    let shape = [0.55, 0.85, 1.0, 0.85, 0.55][i]
                    let height = 6 + (0.7 * level + 0.3 * wobble * max(level, 0.35)) * 24 * shape
                    Capsule().fill(color).frame(width: 4, height: height)
                }
            }
            .animation(.easeOut(duration: 0.1), value: level)
        }
        .accessibilityHidden(true)
    }
}

/// Three dots taking turns, while a turn is being read.
struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    let lift = max(0, sin(t * 4 - Double(i) * 0.7))
                    Circle().fill(Theme.cobalt).frame(width: 7, height: 7)
                        .offset(y: -4 * lift)
                        .opacity(0.45 + 0.55 * lift)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Hold to stop

/// The one tap target of a hands-free screen: it fills as it is held, so a brush against the phone
/// never ends anything and a real press shows it is working.
struct HoldButton: View {
    let title: String
    var duration: Double = 1.0
    var accessibilityHint: String?
    let action: () -> Void
    @State private var pressing = false

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.cobalt)
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.cobaltPressed)
                    .frame(width: pressing ? geometry.size.width : 0)
                    .animation(pressing ? .linear(duration: duration) : .easeOut(duration: 0.2), value: pressing)
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 60)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: duration, pressing: { pressing = $0 }, perform: action)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint(accessibilityHint ?? "Press and hold.")
    }
}

#Preview("Conversation") {
    VStack(spacing: Theme.Space.l) {
        StepTrack(steps: [.init(id: "w", title: "Weight"), .init(id: "g", title: "Glucose"), .init(id: "p", title: "Photos"),
                          .init(id: "q", title: "Questions"), .init(id: "r", title: "Review")], current: 2)
        ConversationTranscript(entries: [
            .setecho("Morning, Zander. It's your Thursday check-in."),
            .setecho("Apple Health has you at 180.8, down 0.4 from last week. Should I use that?"),
            .athlete("Yeah, go with that."),
            .answer(label: "Weight", value: "180.8", source: "Apple Health"),
            .setecho("Okay. And your fasted glucose?"),
            .athlete("Ninety one."),
            .answer(label: "Fasted blood glucose", value: "91", source: "You said · Thu"),
            .setecho("Time for photos. Set up the tripod, and tell me when you're ready."),
        ])
        VoiceBar(phase: .listening, level: 0.4)
        VoiceBar(phase: .speaking)
        VoiceBar(phase: .thinking)
        HoldButton(title: "Hold to stop") {}
    }
    .padding(Theme.gutter)
    .background(Theme.page)
}
