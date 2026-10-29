import AuthenticationServices
import SwiftUI

/// More → Connections (DESIGN.md, Connections): the outside things Setecho reads from. Apple Health,
/// with the sources seen in the last 7 days, and Withings direct (HANDOFF.md §9, P6).
struct ConnectionsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var withings = WithingsService.shared
    @State private var healthSources: [String]?
    @State private var confirmDisconnect = false

    /// Apple Health on its own: the card shows what reaches Setecho through Health.
    private let health = HealthService(direct: nil)

    var body: some View {
        ScreenScaffold(onClose: { dismiss() }) {
            TitleBlock(title: "Connections", subtitle: "Where Setecho reads your numbers from.")
            healthCard
            withingsCard
        }
        .task {
            await loadHealthSources()
            await withings.refreshIfDue()
        }
        .confirmationDialog("Disconnect Withings?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { withings.disconnect() }
        } message: {
            Text("Weight will come through Apple Health again, after the Withings app is opened.")
        }
    }

    // MARK: Apple Health

    private var healthCard: some View {
        SectionCard("Apple Health") {
            if !health.isAvailable {
                Text("Apple Health isn't available on this device.").font(.subheadline).secondaryText()
            } else if let healthSources {
                Text("Reading weight, nutrition, steps, sleep and workouts. Never writing.")
                    .font(.subheadline).foregroundStyle(Theme.navy)
                if healthSources.isEmpty {
                    Text("Nothing from the last 7 days yet.").font(.subheadline).secondaryText()
                } else {
                    Text("Seen in the last 7 days").font(.subheadline).secondaryText()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.Space.xs) {
                            ForEach(healthSources, id: \.self) { SourceChip(source: $0) }
                        }
                    }
                }
            } else {
                Text("Reading Apple Health…").font(.subheadline).secondaryText()
            }
        }
    }

    private func loadHealthSources() async {
        guard health.isAvailable else { return }
        try? await health.requestAuthorization()
        let now = Date.now
        let week = try? await health.read(from: now.addingTimeInterval(-7 * 86_400), to: now)
        let names = (week?.sources ?? [:]).values.flatMap { $0.components(separatedBy: ", ") }
        healthSources = Array(Set(names)).sorted()
    }

    // MARK: Withings

    private var withingsCard: some View {
        SectionCard("Withings") {
            if withings.isConnected {
                Text(connectedLine).font(.subheadline).monospacedDigit().foregroundStyle(Theme.navy)
                if let error = withings.error {
                    Text(error).font(.subheadline).secondaryText()
                }
                CardDivider()
                LinkButton(title: "Disconnect", chevron: .none) { confirmDisconnect = true }
            } else {
                Text(withings.needsReconnect ? WithingsService.refusedMessage : "Until it's connected, weight comes through Apple Health.")
                    .font(.subheadline).secondaryText()
                if let error = withings.error, !withings.needsReconnect {
                    Text(error).font(.subheadline).foregroundStyle(Theme.navy)
                }
                Button {
                    Task { await connect() }
                } label: {
                    Label(withings.isConnecting ? "Signing in to Withings…" : "Connect Withings", systemImage: "scalemass")
                }
                .buttonStyle(.setechoTonalWide)
                .disabled(withings.isConnecting)
            }
        }
    }

    /// "Withings · connected · last weigh-in 7:02 AM"
    private var connectedLine: String {
        guard let last = withings.lastWeighIn else { return "Withings · connected · no weigh-ins yet" }
        let time = last.at.formatted(date: .omitted, time: .shortened)
        let when = Calendar.current.isDateInToday(last.at) ? time : "\(Format.shortDate(last.at)), \(time)"
        return "Withings · connected · last weigh-in \(when)"
    }

    private func connect() async {
        await withings.connect { url in
            try await webAuthenticationSession.authenticate(using: url, callbackURLScheme: "setecho", preferredBrowserSession: .ephemeral)
        }
    }
}

#Preview {
    ConnectionsView()
}
