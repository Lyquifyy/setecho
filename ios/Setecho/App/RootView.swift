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
                NavigationStack { HistoryView() }
            }
            Tab("Check-in", systemImage: "checklist", value: AppRouter.Tab.checkIn) {
                NavigationStack { CheckInView(store: store) }
            }
        }
        .tint(Theme.cobalt)
        .sheet(isPresented: $router.showImport) {
            ImportFlow().environment(store)
        }
        .sheet(isPresented: $router.showSettings) {
            SettingsView()
        }
        .sheet(isPresented: Bindable(ProbesPresenter.shared).isShown) {
            NavigationStack { ProbeHomeView() }
                .tint(Theme.cobalt)
        }
    }
}

#Preview {
    RootView().environment(Store(root: FileManager.default.temporaryDirectory.appendingPathComponent("preview-store")))
}
