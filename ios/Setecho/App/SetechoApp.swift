import SwiftUI

@main
struct SetechoApp: App {
    /// The athlete's store, or the sample coach's while that's on (`StoreHolder`). A swap rebuilds the
    /// tabs: every screen holds the store it was made with.
    @State private var holder = StoreHolder.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .id(holder.store.root)
                .modifier(BrandLaunchOverlay())
                .environment(holder.store)
                .preferredColorScheme(.light)
        }
    }
}
