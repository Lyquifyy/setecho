import AVFoundation
import SwiftUI

/// Photo session (DESIGN.md): the camera fills the screen, last week's outline shows faintly for
/// alignment, the pose name sits in the HUD, the four slots run along the bottom. No taps needed.
struct PhotoSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    @State private var coordinator: PhotoSessionCoordinator

    init(store: Store) {
        _coordinator = State(initialValue: PhotoSessionCoordinator(store: store))
    }

    var body: some View {
        ZStack {
            Theme.cameraFill.ignoresSafeArea()
            if coordinator.phase != .review {
                CameraPreview(session: coordinator.capture.captureSession).ignoresSafeArea()
                if let outline = coordinator.outlineImage {
                    Image(uiImage: outline)
                        .resizable()
                        .scaledToFill()
                        .opacity(0.25)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            switch coordinator.phase {
            case .review:
                if let set = coordinator.photoSet, let collage = coordinator.collage {
                    CollageReviewView(photoSet: set, collage: collage, notes: coordinator.alignmentNotes) { dismiss() }
                }
            case .failed(let message):
                failedView(message)
            default:
                hud
            }
        }
        .task { await coordinator.start() }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    private var hud: some View {
        VStack {
            VStack(spacing: Theme.Space.s) {
                if let pose = coordinator.currentPose {
                    Text("\(Pose.allCases.firstIndex(of: pose)! + 1) of 4").font(.hudLabel).foregroundStyle(Theme.surface)
                    Text(pose.hudTitle).font(.hudState).foregroundStyle(Theme.surface)
                } else if coordinator.phase == .aligning {
                    Text("Lining up with last week…").font(.hudState).foregroundStyle(Theme.surface)
                } else {
                    Text("Starting the camera…").font(.hudState).foregroundStyle(Theme.surface)
                }
                if let cue = coordinator.cue {
                    Text(cue)
                        .font(.hudLabel)
                        .foregroundStyle(Theme.navy)
                        .padding(.horizontal, Theme.Space.m)
                        .padding(.vertical, Theme.Space.xs)
                        .background(Theme.yellow, in: RoundedRectangle(cornerRadius: Theme.Radius.tag, style: .continuous))
                }
                if coordinator.capture.framing == .good, coordinator.capture.stillness.progress > 0 {
                    ProgressView(value: coordinator.capture.stillness.progress)
                        .tint(Theme.cobalt)
                        .frame(width: 160)
                }
            }
            .padding(.top, Theme.Space.xl)
            .padding(.horizontal, Theme.gutter)
            .frame(maxWidth: .infinity)
            .background(Theme.cameraFill.opacity(0.55))

            Spacer()

            VStack(spacing: Theme.Space.s) {
                PoseSlots(slots: coordinator.slots)
                Text("Hold to cancel")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.surface)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 1.0) {
                        coordinator.cancel()
                        dismiss()
                    }
                    .accessibilityLabel("Cancel photo session")
            }
            .padding(Theme.gutter)
            .background(Theme.cameraFill.opacity(0.7))
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: Theme.Space.m) {
            Text(message).font(.hudLabel).foregroundStyle(Theme.surface).multilineTextAlignment(.center)
            Button("Close") {
                coordinator.cancel()
                dismiss()
            }
            .buttonStyle(.setechoPrimary)
        }
        .padding(Theme.gutter)
    }
}

/// AVCaptureVideoPreviewLayer in SwiftUI.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
