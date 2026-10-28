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
    /// The 3:4 crop the aligned file was cut from, in image pixels. Reference for later weeks.
    var cropRect: CGRect
    /// The SAM mask as a PNG, for next week's alignment outline.
    var maskFile: String?

    /// Body box height over crop height: what later weeks match.
    var bodyFraction: Double { cropRect.height > 0 ? bodyBox.height / cropRect.height : 0 }
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
        case .front: "Let's start with the front. Face the camera, arms relaxed."
        case .rightArmsUp: "Now turn so your right side faces the camera, arms up."
        case .back: "Now turn your back to the camera."
        case .leftArmsUp: "Last one. Left side to the camera, arms up."
        }
    }

    /// The short pose name on the HUD.
    var hudTitle: String {
        switch self {
        case .front: "Front"
        case .rightArmsUp: "Right side to camera · arms up"
        case .back: "Back to camera"
        case .leftArmsUp: "Left side to camera · arms up"
        }
    }
}

extension PhotoSet {
    func photo(for pose: Pose) -> PosePhoto? { poses.first { $0.pose == pose } }
}
