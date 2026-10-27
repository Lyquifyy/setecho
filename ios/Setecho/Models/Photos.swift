import CoreGraphics
import Foundation

// Check-in photos (HANDOFF.md §4).

struct PhotoSet: Codable, Equatable, Identifiable {
    var id: UUID
    var takenAt: Date
    var poses: [PosePhoto]
    var collageFile: String
}

struct PosePhoto: Codable, Equatable {
    var pose: Pose
    var file: String
    /// The person box from the SAM mask, in image pixels.
    var bodyBox: CGRect
    var alignedFile: String
}

/// The coach's order.
enum Pose: String, Codable, CaseIterable {
    case front, rightArmsUp, back, leftArmsUp

    var title: String {
        switch self {
        case .front: "Front"
        case .rightArmsUp: "Right side, arms up"
        case .back: "Back"
        case .leftArmsUp: "Left side, arms up"
        }
    }

    /// What the app says before the pose.
    var spokenCue: String {
        switch self {
        case .front: "Face the camera"
        case .rightArmsUp: "Turn right, arms up"
        case .back: "Turn around"
        case .leftArmsUp: "Turn left, arms up"
        }
    }
}
