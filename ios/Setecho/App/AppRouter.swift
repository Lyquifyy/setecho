import SwiftUI

/// App-level navigation state: the selected tab and the sheets reachable from the More menu.
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    enum Tab: Hashable { case today, history, checkIn }

    var tab: Tab = .today
    var showImport = false
}
