import SwiftUI

/// Tabs: Today / History / Check-in. Each tab is a placeholder built from the design system.
/// Build the real screens from DESIGN.md (Screens), in the look of design/cobalt-cards/screens/.
struct RootView: View {
    var body: some View {
        TabView {
            Tab("Today", systemImage: "calendar") {
                NavigationStack {
                    PlaceholderScreen(title: "Today",
                                      sections: "Today's session / This week's check-in / Check-in photos")
                }
            }
            Tab("History", systemImage: "list.bullet.rectangle") {
                NavigationStack {
                    PlaceholderScreen(title: "History",
                                      sections: "This week / Previous sessions / Sent check-ins / Photos")
                }
            }
            Tab("Check-in", systemImage: "checklist") {
                NavigationStack {
                    PlaceholderScreen(title: "Check-in",
                                      sections: "Wrap-up / The coach's form, field by field")
                }
            }
        }
        .tint(Theme.cobalt)
    }
}

private struct PlaceholderScreen: View {
    let title: String
    let sections: String

    var body: some View {
        ScreenScaffold {
            TitleBlock(title: title)
            SectionCard("Not built yet") {
                Text("Sections: \(sections)").font(.body).foregroundStyle(Theme.navy)
                CardDivider()
                Text("Spec: DESIGN.md, Screens. Look: design/cobalt-cards/screens/.")
                    .font(.subheadline).secondaryText()
            }
        }
    }
}

#Preview {
    RootView()
}
