import CoreGraphics
import Foundation

/// Which body in the frame is him (HANDOFF.md §7, Sets start on his word). Oct 28 gym test: the
/// camera saw other people moving and logged their sets as his. When he arms a set, the body whose
/// box is largest and nearest the centre is him (he's at the station, closest to the phone); from
/// then on that box is followed frame to frame by overlap and centroid distance, and every other
/// body is ignored. Before the first arm it follows the same pick, so the wrist series has history.
/// Pure: boxes in, a choice out. Boxes are normalized, top-left origin, in the upright frame.
struct BodyTracker {
    struct Body: Equatable, Sendable {
        var box: CGRect
        /// Each joint's normalized y (Vision, bottom-up), as `JointSeries` keeps them.
        var joints: [String: Double]
        /// Each wrist's normalized x, for the wrist gap (flyes move the hands sideways).
        var wristX: [String: Double] = [:]
    }

    /// The box being followed, and when it last matched a body.
    private(set) var locked: CGRect?
    private var lastMatchT: Double?

    /// Overlap or nearness that still counts as the same person from one pose frame to the next.
    static let minIoU = 0.2
    static let maxCentroidShift = 0.12
    /// Lost for this long with no arm: follow the best pick again.
    static let reacquireSeconds = 5.0

    /// The largest box nearest the centre.
    static func score(_ box: CGRect) -> Double {
        let dx = box.midX - 0.5, dy = box.midY - 0.5
        let off = min(1, (dx * dx + dy * dy).squareRoot() / 0.71)
        return Double(box.width * box.height) * (1 - 0.8 * off)
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let inter = Double(i.width * i.height)
        return inter / (Double(a.width * a.height) + Double(b.width * b.height) - inter)
    }

    static func centroidShift(_ a: CGRect, _ b: CGRect) -> Double {
        let dx = a.midX - b.midX, dy = a.midY - b.midY
        return Double((dx * dx + dy * dy).squareRoot())
    }

    /// He armed: lock onto the best pick in this frame. Returns it, and whether it is a different
    /// person from the one followed until now (the wrist history is then someone else's).
    mutating func lock(_ bodies: [Body], at t: Double) -> (body: Body?, changed: Bool) {
        guard let best = bodies.max(by: { Self.score($0.box) < Self.score($1.box) }) else { return (nil, false) }
        let changed = locked.map { !Self.sameBody($0, best.box) } ?? false
        locked = best.box
        lastMatchT = t
        return (best, changed)
    }

    /// This frame's reading of him, or nil when he isn't in it. Other bodies are never returned.
    mutating func follow(_ bodies: [Body], at t: Double) -> Body? {
        guard let locked else { return lock(bodies, at: t).body }
        let match = bodies
            .filter { Self.sameBody(locked, $0.box) }
            .max { Self.iou(locked, $0.box) < Self.iou(locked, $1.box) }
        if let match {
            self.locked = match.box
            lastMatchT = t
            return match
        }
        if let lastMatchT, t - lastMatchT >= Self.reacquireSeconds, !bodies.isEmpty {
            return lock(bodies, at: t).body
        }
        return nil
    }

    static func sameBody(_ a: CGRect, _ b: CGRect) -> Bool {
        iou(a, b) >= minIoU || centroidShift(a, b) <= maxCentroidShift
    }

    /// The crop for the count clip: his boxes over the set, joined, with room for the bar and the
    /// plates beyond his hands. Nil when it would be most of the frame anyway.
    static func cropBox(_ boxes: [CGRect]) -> CGRect? {
        guard var union = boxes.first else { return nil }
        for box in boxes.dropFirst() { union = union.union(box) }
        let side = max(union.width, union.height)
        let crop = union.insetBy(dx: -0.5 * side, dy: -0.25 * side)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !crop.isNull, crop.width * crop.height < 0.85 else { return nil }
        return crop
    }
}
