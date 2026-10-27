import SwiftUI

/// App-level navigation state: the selected tab and the sheets reachable from the More menu.
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    enum Tab: Hashable { case today, history, checkIn }

    var tab: Tab = .today
    var showImport = false
    var showSettings = false
    var showAddReply = false
    /// The reply the Coach reply screen shows.
    var openReply: CoachReply?
    /// "Hey Siri, start my Setecho check-in" (HANDOFF.md §7, Check-in morning).
    var showCheckInMorning = false
    /// "Hey Siri, start my Setecho morning": the on-waking add-on's own session.
    var showMorningSession = false
}
