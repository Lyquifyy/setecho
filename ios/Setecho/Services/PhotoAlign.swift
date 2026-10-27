import Foundation
import UIKit

/// Crop and scale only (HANDOFF.md §7): the image is never edited beyond that.
enum PhotoAlign {
    /// Crop a JPEG to `rect`, given in the decoded (EXIF-upright) image's pixels, as the backend measures it.
    static func crop(jpeg: Data, to rect: CGRect) -> Data? {
        guard let image = UIImage(data: jpeg), let upright = uprightCGImage(image) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: upright.width, height: upright.height)
        let r = rect.intersection(bounds).integral
        guard !r.isEmpty, let cropped = upright.cropping(to: r) else { return nil }
        return UIImage(cgImage: cropped).jpegData(compressionQuality: 0.92)
    }

    /// Render with the EXIF orientation applied so pixel coordinates match what the backend saw.
    static func uprightCGImage(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up { return image.cgImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return rendered.cgImage
    }

    /// 2×2 collage in the coach's order (front, right / back, left), each tile 3:4, 2400 px wide.
    static func collage(_ tiles: [Pose: UIImage], layout: CollageLayout = .grid2x2, width: CGFloat = 2400) -> UIImage {
        let order = Pose.allCases
        let tileW: CGFloat
        let tileH: CGFloat
        let canvas: CGSize
        switch layout {
        case .grid2x2:
            tileW = width / 2
            tileH = tileW * 4 / 3
            canvas = CGSize(width: width, height: tileH * 2)
        case .strip1x4:
            tileW = width / 4
            tileH = tileW * 4 / 3
            canvas = CGSize(width: width, height: tileH)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: canvas, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: canvas))
            for (i, pose) in order.enumerated() {
                let frame: CGRect
                switch layout {
                case .grid2x2:
                    frame = CGRect(x: CGFloat(i % 2) * tileW, y: CGFloat(i / 2) * tileH, width: tileW, height: tileH)
                case .strip1x4:
                    frame = CGRect(x: CGFloat(i) * tileW, y: 0, width: tileW, height: tileH)
                }
                if let image = tiles[pose] {
                    image.draw(in: aspectFill(image.size, in: frame))
                }
            }
        }
    }

    enum CollageLayout: String, Codable { case grid2x2, strip1x4 }

    /// The rect that fills `frame` with `size`'s aspect, centred (tiles are already 3:4, so this is a no-op crop).
    static func aspectFill(_ size: CGSize, in frame: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return frame }
        let scale = max(frame.width / size.width, frame.height / size.height)
        let w = size.width * scale
        let h = size.height * scale
        return CGRect(x: frame.midX - w / 2, y: frame.midY - h / 2, width: w, height: h)
    }
}
