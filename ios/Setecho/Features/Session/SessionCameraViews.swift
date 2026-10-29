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
struct ReplayView: UIViewRepresentable {
    let url: URL
    var mirrored: Bool

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.play(url)
        view.transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        view.play(url)
        view.transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
        view.stop()
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        private var looper: AVPlayerLooper?
        private var current: URL?

        func play(_ url: URL) {
            guard url != current else { return }
            current = url
            let player = AVQueuePlayer()
            player.isMuted = true
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspectFill
            player.play()
        }

        func stop() {
            playerLayer.player?.pause()
            looper = nil
        }
    }
}
