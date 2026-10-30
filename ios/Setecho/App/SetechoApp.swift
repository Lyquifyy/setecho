import SwiftUI

@main
struct SetechoApp: App {
    @State private var store = Store()

    var body: some Scene {
        WindowGroup {
            RootView()
                .modifier(BrandLaunchOverlay())
                .environment(store)
                .preferredColorScheme(.light)
        }
    }
}
