import UIKit

/// The session's moments on the body, for when the phone is in a pocket (HANDOFF.md §7, Built for
/// not looking): armed, set ended and rest's up each have their own pattern; a set starting is only
/// a sound (he's already lifting).
@MainActor
enum SessionHaptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let notify = UINotificationFeedbackGenerator()

    static func play(_ sound: SessionEngine.Sound) {
        switch sound {
        case .armed:
            light.impactOccurred(intensity: 0.8)
        case .setStarted:
            break
        case .setEnded:
            rigid.impactOccurred()
            Task {
                try? await Task.sleep(for: .milliseconds(160))
                rigid.impactOccurred(intensity: 0.7)
            }
        case .restUp:
            notify.notificationOccurred(.success)
        }
    }
}
