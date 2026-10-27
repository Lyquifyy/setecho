import SwiftUI

/// Compact brand header at the top of every screen: logo + serif wordmark lockup, and a More menu.
struct BrandHeader: View {
    var body: some View {
        HStack {
            Image("Lockup")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: 26)
                .foregroundStyle(Theme.cobalt)
                .accessibilityLabel("Setecho")
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Menu {
                Button("Import program and form", systemImage: "doc.text.viewfinder") {
                    AppRouter.shared.showImport = true
                }
                Button("Settings", systemImage: "gearshape") { AppRouter.shared.showSettings = true }
                Divider()
                // Temporary until M6: the M0 gate probes, testable from TestFlight.
                Button("Gate probes", systemImage: "stethoscope") { ProbesPresenter.shared.isShown = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.navy)
                    .frame(width: 40, height: 40)
                    .background(Theme.surface, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.border, lineWidth: 1))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("More")
        }
        // Room under the header before the screen's title, so the lockup never sits on the content.
        .padding(.bottom, Theme.Space.xs)
    }
}

/// Eyebrow, screen title and subtitle block: "Upper A · Week 4" / "Bench press" / "4 × 8 · Target RPE 8".
struct TitleBlock: View {
    var eyebrow: String?
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            if let eyebrow {
                Text(eyebrow).font(.subheadline).secondaryText()
            }
            Text(title).screenTitleStyle()
            if let subtitle {
                Text(subtitle).font(.body).monospacedDigit().secondaryText()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The title block stands apart from the first card.
        .padding(.bottom, Theme.Space.xs)
    }
}

/// Footer actions sit on their own white surface, separated from the page by a hairline.
struct FooterBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            content
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, Theme.Space.s)
        .padding(.bottom, Theme.Space.xs)
        .frame(maxWidth: .infinity)
        .background(Theme.surface.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { CardDivider() }
    }
}

/// Standard screen: brand header, scrolling content of cards on the page color, optional footer.
struct ScreenScaffold<Content: View, Footer: View>: View {
    private let content: Content
    private let footer: Footer
    private let hasFooter: Bool

    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.content = content()
        self.footer = footer()
        self.hasFooter = true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gutter) {
                BrandHeader()
                content
            }
            .padding(.horizontal, Theme.gutter)
            // Sheets have no top safe area: the lockup needs its own breathing room.
            .padding(.top, Theme.Space.m)
            .padding(.bottom, Theme.gutter)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.page.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if hasFooter { FooterBar { footer } }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

extension ScreenScaffold where Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
        self.footer = EmptyView()
        self.hasFooter = false
    }
}
