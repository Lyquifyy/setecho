import SwiftUI

/// Compact brand header at the top of every screen: logo + serif wordmark lockup, then the More menu
/// on a tab, or the close button on a sheet or cover. Never both: the More menu belongs to the tabs.
struct BrandHeader: View {
    @Environment(\.isPresented) private var isPresented
    /// Closes the sheet or cover this screen belongs to. Set on the first screen of a modal and on
    /// every screen pushed inside it, so the whole flow can be left from anywhere in it.
    var onClose: (() -> Void)?

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
            if let onClose {
                CloseButton(action: onClose)
            } else if !isPresented {
                moreMenu
            }
        }
        // Room under the header before the screen's title, so the lockup never sits on the content.
        .padding(.bottom, Theme.Space.xs)
    }

    private var moreMenu: some View {
        Menu {
            Section("From your coach") {
                Button("Import program and form", systemImage: "doc.text.viewfinder") {
                    AppRouter.shared.showImport = true
                }
                Button("Add coach reply", systemImage: "text.bubble") { AppRouter.shared.showAddReply = true }
                Button("Connections", systemImage: "link") { AppRouter.shared.showConnections = true }
            }
            Section {
                Button("Settings", systemImage: "gearshape") { AppRouter.shared.showSettings = true }
            }
        } label: {
            HeaderCircle(systemImage: "ellipsis")
        }
        .accessibilityLabel("More")
    }
}

/// The way out of a sheet or cover: an X in the header's top-right, where the More menu sits on a tab.
/// It leaves without saving anything the screen hasn't already saved; a screen that commits something
/// does it with its footer button ("Confirm", "Save", "Apply").
struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) { HeaderCircle(systemImage: "xmark") }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .keyboardShortcut(.cancelAction)
    }
}

/// The 40 pt white disc both header controls share, inside a 44 pt hit target.
private struct HeaderCircle: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.body.weight(.semibold))
            .foregroundStyle(Theme.navy)
            .frame(width: 40, height: 40)
            .background(Theme.surface, in: Circle())
            .overlay(Circle().strokeBorder(Theme.border, lineWidth: 1))
            .frame(width: 44, height: 44)
            .contentShape(Circle())
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
/// In a sheet or cover, pass `onClose` (usually `{ dismiss() }`) for the header's close button.
struct ScreenScaffold<Content: View, Footer: View>: View {
    private let onClose: (() -> Void)?
    private let content: Content
    private let footer: Footer
    private let hasFooter: Bool

    init(onClose: (() -> Void)? = nil, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.onClose = onClose
        self.content = content()
        self.footer = footer()
        self.hasFooter = true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gutter) {
                BrandHeader(onClose: onClose)
                content
            }
            .padding(.horizontal, Theme.gutter)
            // Sheets have no top safe area: the lockup needs its own breathing room.
            .padding(.top, Theme.Space.m)
            .padding(.bottom, Theme.gutter)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.page.ignoresSafeArea())
        // The page color under the status bar, so cards never scroll beneath the clock.
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: 0).background(Theme.page.ignoresSafeArea(edges: .top))
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if hasFooter { FooterBar { footer } }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

extension ScreenScaffold where Footer == EmptyView {
    init(onClose: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.onClose = onClose
        self.content = content()
        self.footer = EmptyView()
        self.hasFooter = false
    }
}
