import Foundation
import Testing
import UIKit
@testable import Setecho

private func mask(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, grid: [UInt8] = [1, 1, 0, 0]) -> PersonMask {
    PersonMask(box: CGRect(x: x, y: y, width: w, height: h), grid: grid, gridWidth: 2, gridHeight: 2)
}

@Test func framingCuesFollowTheMargins() {
    #expect(Framing.judge(nil) == .noPerson)
    #expect(Framing.judge(mask(x: 0.3, y: 0.1, w: 0.4, h: 0.8)) == .good)
    #expect(Framing.judge(mask(x: 0.3, y: 0.0, w: 0.4, h: 0.9)) == .stepBack)   // head cut off
    #expect(Framing.judge(mask(x: 0.3, y: 0.1, w: 0.4, h: 0.88)) == .stepBack)  // feet cut off
    #expect(Framing.judge(mask(x: 0.01, y: 0.1, w: 0.4, h: 0.8)) == .moveLeft)
    #expect(Framing.judge(mask(x: 0.6, y: 0.1, w: 0.38, h: 0.8)) == .moveRight)
    #expect(Framing.stepBack.spoken == "Step back a little" && Framing.good.spoken == nil)
}

@Test func iouAndStillness() {
    let a = mask(x: 0, y: 0, w: 1, h: 1, grid: [1, 1, 0, 0])
    let b = mask(x: 0, y: 0, w: 1, h: 1, grid: [1, 1, 1, 0])
    #expect(abs(PersonMask.iou(a, a) - 1) < 1e-9)
    #expect(abs(PersonMask.iou(a, b) - 2.0 / 3.0) < 1e-9)

    var tracker = StillnessTracker()
    tracker.update(a, at: 0)        // first mask: nothing to compare with yet
    tracker.update(a, at: 0.5)      // first matching pair: the clock starts here
    #expect(!tracker.isStill && tracker.progress == 0)
    tracker.update(a, at: 1.0)
    #expect(!tracker.isStill && tracker.progress > 0.4)
    tracker.update(a, at: 1.8)
    #expect(tracker.isStill)
    tracker.update(b, at: 1.9)   // moved
    #expect(!tracker.isStill && tracker.progress == 0)
    tracker.update(nil, at: 2.0)
    #expect(!tracker.isStill)
}

@Test func cropAndCollageMath() {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let photo = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800), format: format).image { ctx in
        UIColor.red.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
        UIColor.blue.setFill()
        ctx.fill(CGRect(x: 150, y: 100, width: 300, height: 400))
    }
    let jpeg = photo.jpegData(compressionQuality: 0.9)!
    let cropped = PhotoAlign.crop(jpeg: jpeg, to: CGRect(x: 150, y: 100, width: 300, height: 400))
    let image = UIImage(data: cropped!)!
    #expect(image.size == CGSize(width: 300, height: 400))

    let collage = PhotoAlign.collage([.front: image, .rightArmsUp: image, .back: image, .leftArmsUp: image])
    #expect(collage.size == CGSize(width: 2400, height: 3200))
    let strip = PhotoAlign.collage([.front: image], layout: .strip1x4)
    #expect(strip.size == CGSize(width: 2400, height: 800))

    let fill = PhotoAlign.aspectFill(CGSize(width: 300, height: 400), in: CGRect(x: 0, y: 0, width: 1200, height: 1600))
    #expect(fill == CGRect(x: 0, y: 0, width: 1200, height: 1600))
}

@Test func bodyFractionIsBoxOverCrop() {
    let photo = PosePhoto(pose: .front, file: "a.jpg", bodyBox: CGRect(x: 0, y: 0, width: 100, height: 400),
                          alignedFile: "b.jpg", cropRect: CGRect(x: 0, y: 0, width: 375, height: 500), maskFile: nil)
    #expect(abs(photo.bodyFraction - 0.8) < 1e-9)
}

@Test func segmentResponseRects() throws {
    let json = """
    {"width":1200,"height":1600,"box":[400,200,300,900],"crop":[128,88,844,1125],"bodyFraction":0.8,
     "clamped":false,"maskPng":"","maskWidth":960,"maskHeight":1280}
    """
    let r = try JSONCoding.decoder.decode(SegmentResponse.self, from: Data(json.utf8))
    #expect(r.boxRect == CGRect(x: 400, y: 200, width: 300, height: 900))
    #expect(r.cropRect == CGRect(x: 128, y: 88, width: 844, height: 1125))
    #expect(r.maskData == Data())
}
