import SwiftUI

/// Throwaway M0 gate probes (HANDOFF.md §9). Separate target, not part of the Setecho app.
/// It shares the design system so it follows DESIGN.md, but nothing here ships.
@main
struct ProbesApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ProbeHomeView()
            }
            .preferredColorScheme(.light)
            .tint(Theme.cobalt)
        }
    }
}
