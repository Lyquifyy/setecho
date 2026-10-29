import AVFoundation
import SwiftUI
import UIKit

/// The session's live camera in the camera card: the set detector's own capture session (no second
/// camera), filling the card. The front camera is shown mirrored, the way a mirror is; the clips
/// it records stay unmirrored.
struct SessionCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var mirrored: Bool

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.mirrored = mirrored
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.mirrored = mirrored
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var mirrored = false { didSet { orient() } }

        override func layoutSubviews() {
            super.layoutSubviews()
            orient()
        }

        /// Portrait, as he sees the phone on the tripod; mirrored for the front camera.
        private func orient() {
            guard let connection = previewLayer.connection else { return }
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = mirrored
            }
        }
    }
}

/// The set he just did, looping and silent, during rest: the full-quality clip kept for his coach.
/// The clip is stored the way the sensor sees it (landscape, so SAM's 720p copy keeps its width);
/// the player turns it upright here (the back camera's frames turn right, the front camera's left)
/// and mirrors the front camera's, like the live picture.
struct ReplayView: UIViewRepresentable {
    let url: URL
    var front: Bool

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.play(url, front: front)
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        view.play(url, front: front)
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
        view.stop()
    }

    final class PlayerView: UIView {
        private let playerLayer = AVPlayerLayer()
        private var looper: AVPlayerLooper?
        private var current: URL?
        /// Quarter turns to stand the picture upright: +1 right, -1 left, 0 already upright.
        private var turns = 0
        private var front = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            playerLayer.videoGravity = .resizeAspectFill
            layer.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func play(_ url: URL, front: Bool) {
            guard url != current else { return }
            current = url
            self.front = front
            let asset = AVURLAsset(url: url)
            let player = AVQueuePlayer()
            player.isMuted = true
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset))
            playerLayer.player = player
            player.play()
            Task { [weak self] in
                guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                      let size = try? await track.load(.naturalSize),
                      let transform = try? await track.load(.preferredTransform) else { return }
                let shown = size.applying(transform)
                let landscape = abs(shown.width) > abs(shown.height)
                await MainActor.run {
                    self?.turns = landscape ? (front ? -1 : 1) : 0
                    self?.setNeedsLayout()
                }
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let size = turns == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
            playerLayer.bounds = CGRect(origin: .zero, size: size)
            playerLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            var t = CGAffineTransform(rotationAngle: CGFloat(turns) * .pi / 2)
            if front { t = t.concatenating(CGAffineTransform(scaleX: -1, y: 1)) }
            playerLayer.setAffineTransform(t)
            CATransaction.commit()
        }

        func stop() {
            playerLayer.player?.pause()
            looper = nil
        }
    }
}
