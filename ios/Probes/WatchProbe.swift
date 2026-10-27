import SwiftUI

/// G8 (HANDOFF.md §9): connect the Venu 4 through Garmin Connect, then do three sets each of bench
/// press, rows and curls. Every message shows with its delay. Pass: messages arrive within 3 s and
/// the wrist counts match the hand count.
struct WatchProbeView: View {
    @State private var watch = WatchService.shared
    @State private var handCounts = ""

    var body: some View {
        ScreenScaffold {
            TitleBlock(eyebrow: "G8", title: "Watch", subtitle: "Wrist sets and reps from the Venu 4, through Garmin Connect.")
            SectionCard("Connection") {
                LabeledRow("Status", statusText)
                if let rtt = watch.roundTripMs { LabeledRow("Round trip", "\(Int(rtt)) ms") }
                if let last = watch.lastMessageAt { LabeledRow("Last message", last.formatted(date: .omitted, time: .standard)) }
                if let error = watch.lastError { Text(error).font(.footnote).foregroundStyle(Theme.navy) }
                HStack(spacing: Theme.Space.s) {
                    Button(isConnected ? "Reconnect" : "Connect") { watch.connect() }.buttonStyle(.setechoOutline)
                    Button("Ping") { watch.ping() }.buttonStyle(.setechoOutline).disabled(!isConnected)
                    Button("Test buzz") { watch.testBuzz() }.buttonStyle(.setechoOutline).disabled(!isConnected)
                }
                if case .appMissing = watch.status {
                    Text("The Setecho watch app isn't on the watch. Build it with `make watch` and copy the .prg into GARMIN/APPS over USB.")
                        .font(.footnote).secondaryText()
                }
            }
            SectionCard("Session messages") {
                Text("Send a target so the watch shows it, then lift. Taps on the watch arrive as messages too.")
                    .font(.footnote).secondaryText()
                HStack(spacing: Theme.Space.s) {
                    Button("Send config") { watch.sendConfig(startStd: 120, endStd: 40) }.buttonStyle(.setechoOutline)
                    Button("Send target") { watch.sendTarget(exercise: "Bench press", load: "225", reps: "8", set: "1 of 3") }.buttonStyle(.setechoOutline)
                }
                .disabled(!isConnected)
                HStack(spacing: Theme.Space.s) {
                    Button("Rest 60 s") { watch.sendRest(endsAt: .now.addingTimeInterval(60)) }.buttonStyle(.setechoOutline)
                    Button("End") { watch.sendEnd() }.buttonStyle(.setechoOutline)
                }
                .disabled(!isConnected)
            }
            SectionCard("Messages", accessory: { Text("\(watch.log.count)").font(.subheadline).monospacedDigit().secondaryText() }) {
                if watch.log.isEmpty {
                    Text("Nothing yet.").font(.subheadline).secondaryText()
                } else {
                    ForEach(watch.log.prefix(40)) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                            Text(entry.direction == "in" ? "←" : "→").font(.footnote.weight(.bold)).foregroundStyle(Theme.cobalt)
                            Text(entry.text).font(.footnote).monospacedDigit().foregroundStyle(Theme.navy)
                            Spacer()
                            if let delay = entry.delay {
                                Text(String(format: "%.2f s", delay)).font(.footnote).monospacedDigit()
                                    .foregroundStyle(delay <= 3 ? Theme.textSecondary : Theme.navy)
                            }
                        }
                    }
                }
            }
            SectionCard("Your hand counts") {
                Text("Write each set's count here as you go, to compare with the setEnd messages.").font(.footnote).secondaryText()
                TextField("8, 8, 7 / 10, 10, 9 / 12, 12, 11", text: $handCounts)
                    .font(.body).foregroundStyle(Theme.navy)
                    .padding(.horizontal, Theme.Space.s).frame(minHeight: 44)
                    .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            }
            PassChecksCard(items: [
                "Every setStart and setEnd arrives within 3 s of the lift (the delay column).",
                "The wrist counts match your hand counts on 3 sets each of bench, rows and curls.",
                "Test buzz vibrates the watch; a tap on the watch shows here as tap=done.",
            ])
        }
        .onAppear { watch.initialize() }
    }

    private var isConnected: Bool {
        if case .connected = watch.status { return true }
        return false
    }

    private var statusText: String {
        switch watch.status {
        case .notConnected: "Not connected"
        case .connecting: "Connecting…"
        case .connected(let name): "\(name) · connected"
        case .appMissing(let name): "\(name) · Setecho app not installed"
        }
    }
}
