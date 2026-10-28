import Foundation
import Testing
@testable import Setecho

private func week(_ daysAgo: Double) -> PhotoSet {
    PhotoSet(id: UUID(), takenAt: Date(timeIntervalSinceNow: -daysAgo * 86_400), poses: [], collageFile: "")
}

@Test func compareOpensOnTheWeekBefore() {
    let three = week(21), two = week(14), one = week(7), now = week(0)
    let sets = [one, now, three, two]
    #expect(PhotoViewer.neighbor(of: now, in: sets)?.id == one.id)
    #expect(PhotoViewer.neighbor(of: two, in: sets)?.id == three.id)
    // The oldest week has nothing before it: the week after is the one to compare with.
    #expect(PhotoViewer.neighbor(of: three, in: sets)?.id == two.id)
    #expect(PhotoViewer.neighbor(of: now, in: [now]) == nil)
    #expect(PhotoViewer.others(than: now, in: sets).map(\.id) == [three.id, two.id, one.id].map { $0 })
}

@Test func aFittedPhotoStaysCenteredAndAZoomedOneStopsAtItsEdges() {
    let frame = CGSize(width: 400, height: 800)
    let fitted = PhotoZoom.fitted(CGSize(width: 3000, height: 4000), in: frame)
    #expect(fitted == CGSize(width: 400, height: 533.3333333333334) || abs(fitted.height - 533.33) < 0.01)
    // Not zoomed: any drag goes back to center.
    #expect(PhotoZoom.clamp(CGSize(width: 50, height: -80), scale: 1, fitted: fitted, in: frame) == .zero)
    // At 2x the photo is 800 wide in a 400 frame: 200 pt of travel each way, and none past that.
    let clamped = PhotoZoom.clamp(CGSize(width: 500, height: -500), scale: 2, fitted: fitted, in: frame)
    #expect(clamped.width == 200)
    #expect(abs(clamped.height + (fitted.height * 2 - frame.height) / 2) < 0.01)
}

@Test func doubleTapZoomsAroundTheFingerAndBackToFit() {
    let frame = CGSize(width: 400, height: 800)
    let fitted = CGSize(width: 400, height: 533)
    let centered = PhotoZoom.toggled(PhotoZoom(), at: CGPoint(x: 200, y: 400), fitted: fitted, in: frame)
    #expect(centered.scale == PhotoZoom.doubleTap && centered.offset == .zero)
    // A tap right of center pulls the photo left so that spot stays under the finger.
    let right = PhotoZoom.toggled(PhotoZoom(), at: CGPoint(x: 300, y: 400), fitted: fitted, in: frame)
    #expect(right.offset.width < 0 && right.offset.height == 0)
    #expect(PhotoZoom.toggled(right, at: CGPoint(x: 10, y: 10), fitted: fitted, in: frame) == PhotoZoom())
}
