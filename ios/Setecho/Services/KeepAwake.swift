import SwiftUI
import UIKit

/// The screen stays on while any hands-free screen is up: Check-in morning, the wrap-up, the photo
/// session, Review and send, a session. Counted, not toggled (Oct 28: the photo session's exit
/// turned the idle timer back on under the morning that was still running, and the phone locked
/// mid-conversation), so the timer comes back only when the last of them has gone.
@MainActor
enum KeepAwake {
    private static var holders = 0

    static func acquire() {
        holders += 1
        UIApplication.shared.isIdleTimerDisabled = true
    }

    static func release() {
        holders = max(0, holders - 1)
        UIApplication.shared.isIdleTimerDisabled = holders > 0
    }
}

private struct KeepAwakeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear { KeepAwake.acquire() }
            .onDisappear { KeepAwake.release() }
    }
}

extension View {
    /// Keep the screen on for as long as this view is on screen.
    func keepsScreenAwake() -> some View { modifier(KeepAwakeModifier()) }
}
