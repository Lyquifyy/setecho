import SwiftUI

/// Temporary (M0–M5): the gate probes ride inside the Setecho app behind the More menu, so one
/// TestFlight build carries them. Remove this and the `Probes` sources from the app target in M6.
@MainActor
@Observable
final class ProbesPresenter {
    static let shared = ProbesPresenter()
    var isShown = false
}
