import SwiftUI

/// Tabs: Today / History / Check-in. Settings and imports live in the More menu.
struct RootView: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var router = AppRouter.shared
        TabView(selection: $router.tab) {
            Tab("Today", systemImage: "calendar", value: AppRouter.Tab.today) {
                NavigationStack { TodayView() }
            }
            Tab("History", systemImage: "list.bullet.rectangle", value: AppRouter.Tab.history) {
                NavigationStack {
                    PlaceholderScreen(title: "History",
                                      sections: "This week / Previous sessions / Sent check-ins / Photos")
                }
            }
            Tab("Check-in", systemImage: "checklist", value: AppRouter.Tab.checkIn) {
                NavigationStack {
                    PlaceholderScreen(title: "Check-in",
                                      sections: "Wrap-up / The coach's form, field by field")
                }
            }
        }
        .tint(Theme.cobalt)
        .sheet(isPresented: $router.showImport) {
            ImportFlow().environment(store)
        }
        .sheet(isPresented: Bindable(ProbesPresenter.shared).isShown) {
            NavigationStack { ProbeHomeView() }
                .tint(Theme.cobalt)
        }
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
    RootView().environment(Store(root: FileManager.default.temporaryDirectory.appendingPathComponent("preview-store")))
}
