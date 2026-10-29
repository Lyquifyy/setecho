import AVFoundation
import SwiftUI

/// Photo session (DESIGN.md): the hands-free stage and sheet, his camera on the stage and the pose,
/// the hold-still meter and the four slots on the sheet. No taps needed.
struct PhotoSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    @State private var coordinator: PhotoSessionCoordinator

    /// With `existing`, it opens on that set's review: retake a pose by tap or by voice.
    init(store: Store, existing: PhotoSet? = nil) {
        _coordinator = State(initialValue: PhotoSessionCoordinator(store: store, existing: existing))
    }

    var body: some View {
        ZStack {
            Theme.cameraFill.ignoresSafeArea()
            switch coordinator.phase {
            case .review:
                if let set = coordinator.photoSet {
                    PhotoReviewView(photoSet: set, thumbnails: coordinator.thumbnails, onRetake: { coordinator.retake($0) }) { dismiss() }
                }
            case .failed(let message):
                failedView(message)
            default:
                hud
            }
        }
        .task { await coordinator.start() }
        // "We're done": the session closes itself. Leaving any way stops the camera and the mic.
        .onChange(of: coordinator.finished) { _, finished in if finished { dismiss() } }
        .onDisappear { coordinator.cancel() }
        .keepsScreenAwake()
        // The screen locked or the app left the front: stop, rather than cue an empty frame on repeat.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            if coordinator.phase != .review {
                coordinator.cancel()
                dismiss()
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    private var hud: some View {
        PhotoSessionHUD(
            model: PhotoSessionHUDModel(
                pose: coordinator.currentPose,
                status: coordinator.phase == .aligning ? "Lining up with last week…" : "Starting the camera…",
                cue: coordinator.cue,
                heard: coordinator.heard,
                holding: coordinator.capture.framing == .good ? coordinator.stillProgress : nil,
                slots: coordinator.slots),
            // The whole frame, not a crop of it: the framing check judges the full picture.
            camera: AnyView(CameraPreview(session: coordinator.capture.captureSession, gravity: .resizeAspect))
        ) {
            coordinator.cancel()
            dismiss()
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

/// What the photo session shows, as plain values: the live view fills it from the coordinator,
/// and the screen renders draw it without a camera.
struct PhotoSessionHUDModel {
    /// The pose being taken; nil while the camera starts or lines up with last week.
    var pose: Pose?
    /// What's happening before the first pose: "Starting the camera…".
    var status: String
    /// The framing check's line, said and shown: "Step back a little".
    var cue: String?
    /// What he just said, as heard.
    var heard: String?
    /// The hold-still meter, 0…1, once he's framed; nil until then.
    var holding: Double?
    var slots: [(pose: Pose, slot: PoseSlots.Slot)]
}

/// The photo session on the hands-free `StageSheet`: his camera fills the stage (the whole of him
/// has to fit, so the sheet stays short), with the pose count on a pill and the framing cue on a
/// white pill where he can read it from the tripod. The sheet names the pose in `.hudState`, then
/// the hold-still meter or what was heard, the four slots and "Hold to cancel".
struct PhotoSessionHUD: View {
    var model: PhotoSessionHUDModel
    var camera: AnyView?
    var onCancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        StageSheet {
            ZStack {
                Theme.cameraFill
                if let camera { camera }
            }
        } overlay: {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    StageMark()
                    if let pose = model.pose {
                        Text("\(Pose.allCases.firstIndex(of: pose)! + 1) of 4")
                            .font(.hudLabel.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(Theme.cameraFill.opacity(0.78), in: Capsule())
                            .contentTransition(.numericText())
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                if let cue = model.cue {
                    // The one correction to make, where he's looking: white, so the current slot
                    // stays the one yellow.
                    Label(cue, systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                        .font(.hudState)
                        .foregroundStyle(Theme.navy)
                        .padding(.horizontal, Theme.Space.m)
                        .padding(.vertical, Theme.Space.s)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                        .frame(maxWidth: .infinity)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity))
                }
            }
        } sheet: {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(model.pose?.hudTitle ?? model.status)
                    .font(.hudState)
                    .foregroundStyle(Theme.navy)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                if let holding = model.holding {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text("Hold still").font(.hudLabel.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.cobaltTint)
                                Capsule().fill(Theme.cobalt).frame(width: proxy.size.width * max(0, min(1, holding)))
                            }
                        }
                        .frame(height: 12)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Holding still")
                    .accessibilityValue("\(Int(holding * 100)) percent")
                } else if let heard = model.heard {
                    Text("\u{201C}\(heard)\u{201D}").font(.hudLabel.weight(.semibold)).foregroundStyle(Theme.cobalt).lineLimit(1)
                }
                PoseSlots(slots: model.slots)
                HoldButton(title: "Hold to cancel", accessibilityHint: "Press and hold to stop the photo session.", action: onCancel)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.45, bounce: 0.12), value: model.cue)
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.45, bounce: 0.12), value: model.pose)
    }
}

/// AVCaptureVideoPreviewLayer in SwiftUI.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// Fill by default; the photo session fits, so he sees all of what the framing check sees.
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = gravity
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}


/// The four photos as taken, in his order (DESIGN.md Photo session). A retake per pose; nothing else.
struct PhotoReviewView: View {
    @Environment(Store.self) private var store
    let photoSet: PhotoSet
    let thumbnails: [Pose: UIImage]
    let onRetake: (Pose) -> Void
    let onDone: () -> Void
    /// A photo open full screen, to check it before deciding on a retake.
    @State private var viewing: PhotoViewing?

    var body: some View {
        // The set is saved before this screen opens: the X and Done both just leave.
        ScreenScaffold(onClose: onDone) {
            TitleBlock(eyebrow: Format.shortDate(photoSet.takenAt), title: "Check-in photos",
                       subtitle: "Exactly as taken, full resolution, in your coach's order. Nothing is cropped or changed.")
            SectionCard("This week") {
                Text("Tap a photo to see it full screen. Tap Retake, or say \"retake the front\", to redo one; only that photo changes.")
                    .font(.footnote).secondaryText()
                ForEach(Pose.allCases, id: \.self) { pose in
                    CardDivider()
                    HStack(spacing: Theme.Space.s) {
                        if let image = thumbnails[pose] ?? loaded(pose) {
                            Button {
                                viewing = PhotoViewing(photoSet: photoSet, pose: pose)
                            } label: {
                                Image(uiImage: image).resizable().scaledToFill().frame(width: 72, height: 96)
                                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tag, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(pose.title). Opens full screen")
                        } else {
                            SetThumbnail(width: 72, height: 96)
                        }
                        Text(pose.title).font(.body).foregroundStyle(Theme.navy)
                        Spacer()
                        LinkButton(title: "Retake", chevron: .none) { onRetake(pose) }
                    }
                }
            }
        } footer: {
            Button("Done", action: onDone).buttonStyle(.setechoPrimary)
        }
        .fullScreenCover(item: $viewing) { viewing in
            PhotoViewer(viewing: viewing).environment(store)
        }
    }

    private func loaded(_ pose: Pose) -> UIImage? {
        guard let file = photoSet.photo(for: pose)?.file,
              let data = try? Data(contentsOf: store.mediaDirectory.appendingPathComponent(file)) else { return nil }
        return UIImage(data: data)
    }
}
