import SwiftUI

struct ProbeHomeView: View {
    var body: some View {
        ScreenScaffold {
            TitleBlock(
                eyebrow: "M0 · Tuesday's gates",
                title: "Probes",
                subtitle: "Run each on the real iPhone, then report what you saw."
            )
            SectionCard("On the phone") {
                ProbeRow(gate: "G2", title: "Audio", detail: "DJI mic in, AirPods out, a ducked callout") {
                    AudioProbeView()
                }
                CardDivider()
                ProbeRow(gate: "G3", title: "Apple Health", detail: "Last 7 days of every check-in type, with sources") {
                    HealthProbeView()
                }
                CardDivider()
                ProbeRow(gate: "G6", title: "WhatsApp share", detail: "One image plus text: do both arrive together?") {
                    ShareProbeView()
                }
            }
            SectionCard("Elsewhere") {
                Text("G1 is a question for office hours. G4 (SAM), G5 (import) and the voice smoke run from backend/scripts on the Mac.")
                    .font(.subheadline)
                    .secondaryText()
            }
        }
    }
}

private struct ProbeRow<Destination: View>: View {
    let gate: String
    let title: String
    let detail: String
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: Theme.Space.s) {
                Text(gate)
                    .font(.columnLabel)
                    .foregroundStyle(Theme.cobalt)
                    .frame(width: Theme.Space.xl, alignment: .leading)
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(Theme.navy)
                    Text(detail).font(.subheadline).secondaryText()
                }
                Spacer(minLength: Theme.Space.xs)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.cobalt)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(gate), \(title)")
    }
}

#Preview {
    NavigationStack { ProbeHomeView() }
}
