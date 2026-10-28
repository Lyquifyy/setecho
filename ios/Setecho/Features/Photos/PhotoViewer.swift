import ImageIO
import SwiftUI

/// What opens the viewer: the week, the pose to land on, and whether it starts side by side.
struct PhotoViewing: Identifiable {
    let photoSet: PhotoSet
    var pose: Pose = .front
    var compare = false
    var id: UUID { photoSet.id }
}

/// Photo viewer (DESIGN.md): one pose at a time on the camera fill, pinch or double-tap to zoom,
/// swipe or tap a pose tab for the next one. "Compare" puts another week beside it, same pose, and
/// the two zoom and pan together; the other week steps with the arrows or the date menu. A tap on
/// the photo hides the bars. Viewing only: the files are shown exactly as taken and never changed.
struct PhotoViewer: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let viewing: PhotoViewing

    @State private var pose: Pose
    @State private var compare: Bool
    @State private var other: PhotoSet?
    @State private var zoom = PhotoZoom()
    @State private var chrome = true

    init(viewing: PhotoViewing) {
        self.viewing = viewing
        _pose = State(initialValue: viewing.pose)
        _compare = State(initialValue: viewing.compare)
    }

    /// Every other week, oldest first.
    nonisolated static func others(than set: PhotoSet, in sets: [PhotoSet]) -> [PhotoSet] {
        sets.filter { $0.id != set.id }.sorted { $0.takenAt < $1.takenAt }
    }

    /// The week to compare with first: the one taken just before, else the one just after.
    nonisolated static func neighbor(of set: PhotoSet, in sets: [PhotoSet]) -> PhotoSet? {
        let others = others(than: set, in: sets)
        return others.last { $0.takenAt < set.takenAt } ?? others.first
    }

    private var others: [PhotoSet] { Self.others(than: viewing.photoSet, in: store.photoSets) }
    private var otherIndex: Int? { other.flatMap { o in others.firstIndex { $0.id == o.id } } }

    /// The two weeks on screen in compare, older on the left.
    private var pair: (left: PhotoSet, right: PhotoSet)? {
        guard let other else { return nil }
        return other.takenAt < viewing.photoSet.takenAt ? (other, viewing.photoSet) : (viewing.photoSet, other)
    }

    var body: some View {
        VStack(spacing: 0) {
            if chrome { topBar }
            TabView(selection: $pose) {
                ForEach(Pose.allCases, id: \.self) { pose in
                    page(pose).tag(pose)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            if chrome { bottomBar }
        }
        .background(Theme.cameraFill.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .animation(.snappy(duration: 0.2), value: chrome)
        .onChange(of: pose) { zoom = PhotoZoom() }
        .onChange(of: compare) { zoom = PhotoZoom() }
        .onChange(of: other?.id) { zoom = PhotoZoom() }
        .onAppear { if other == nil { other = Self.neighbor(of: viewing.photoSet, in: store.photoSets) } }
    }

    @ViewBuilder
    private func page(_ pose: Pose) -> some View {
        if compare, let pair {
            HStack(spacing: 2) {
                pane(pair.left, pose, labeled: true)
                pane(pair.right, pose, labeled: true)
            }
        } else {
            pane(viewing.photoSet, pose, labeled: false)
        }
    }

    private func pane(_ set: PhotoSet, _ pose: Pose, labeled: Bool) -> some View {
        ZoomableImage(url: url(set, pose), zoom: $zoom) { chrome.toggle() }
            .overlay(alignment: .bottom) {
                if labeled, chrome {
                    Text(set.id == viewing.photoSet.id ? "\(Format.shortDate(set.takenAt)) · this one" : Format.shortDate(set.takenAt))
                        .font(.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(Theme.surface)
                        .padding(.horizontal, Theme.Space.xs)
                        .padding(.vertical, Theme.Space.xxs)
                        .background(Theme.cameraFill.opacity(0.75), in: Capsule())
                        .padding(.bottom, Theme.Space.xs)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(pose.title), \(Format.shortDate(set.takenAt))")
    }

    private func url(_ set: PhotoSet, _ pose: Pose) -> URL? {
        guard let file = set.photo(for: pose)?.file else { return nil }
        let url = store.mediaDirectory.appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var topBar: some View {
        HStack(spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pose.title).font(.headline).foregroundStyle(Theme.surface).lineLimit(1)
                Text(compare ? "Side by side, as taken" : Format.shortDate(viewing.photoSet.takenAt))
                    .font(.subheadline).monospacedDigit().foregroundStyle(Theme.surface.opacity(0.7)).lineLimit(1)
            }
            Spacer(minLength: Theme.Space.xs)
            if !others.isEmpty {
                Button(compare ? "One week" : "Compare", systemImage: compare ? "rectangle.portrait" : "rectangle.split.2x1") {
                    compare.toggle()
                }
                .buttonStyle(.setechoTonal)
            }
            CloseButton { dismiss() }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, Theme.Space.xs)
    }

    private var bottomBar: some View {
        VStack(spacing: Theme.Space.s) {
            if compare, let other, let pair, let index = otherIndex {
                HStack(spacing: Theme.Space.xs) {
                    if others.count > 1 {
                        IconButton(systemImage: "chevron.left", accessibilityLabel: "Earlier week") { step(-1) }
                            .disabled(index == 0).opacity(index == 0 ? 0.45 : 1)
                    }
                    Menu {
                        ForEach(others) { set in
                            Button {
                                self.other = set
                            } label: {
                                if set.id == other.id {
                                    Label(Format.shortDate(set.takenAt), systemImage: "checkmark")
                                } else {
                                    Text(Format.shortDate(set.takenAt))
                                }
                            }
                        }
                    } label: {
                        Label("\(Format.shortDate(pair.left.takenAt)) vs \(Format.shortDate(pair.right.takenAt))", systemImage: "calendar")
                            .font(.subheadline.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(Theme.cobalt)
                            .lineLimit(1)
                            .padding(.horizontal, Theme.Space.s)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Theme.cobaltTint, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Comparing \(Format.shortDate(pair.left.takenAt)) with \(Format.shortDate(pair.right.takenAt)). Pick another week")
                    if others.count > 1 {
                        IconButton(systemImage: "chevron.right", accessibilityLabel: "Later week") { step(1) }
                            .disabled(index == others.count - 1).opacity(index == others.count - 1 ? 0.45 : 1)
                    }
                }
            }
            SegmentTabs(items: Pose.allCases.map { .init(value: $0, title: $0.shortTitle) }, selection: $pose)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, Theme.Space.xs)
    }

    private func step(_ by: Int) {
        guard let index = otherIndex, others.indices.contains(index + by) else { return }
        other = others[index + by]
    }
}

/// Zoom and pan, shared by every pane on screen so two weeks move together.
struct PhotoZoom: Equatable {
    var scale: CGFloat = 1
    var offset: CGSize = .zero

    static let max: CGFloat = 4
    static let doubleTap: CGFloat = 2.5

    /// The size of an image aspect-fit in a frame.
    static func fitted(_ image: CGSize, in frame: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, frame.width > 0, frame.height > 0 else { return frame }
        let k = Swift.min(frame.width / image.width, frame.height / image.height)
        return CGSize(width: image.width * k, height: image.height * k)
    }

    /// Keeps the photo over the frame: no edge is dragged inside it, and a photo that fits stays centered.
    static func clamp(_ offset: CGSize, scale: CGFloat, fitted: CGSize, in frame: CGSize) -> CGSize {
        let maxX = Swift.max(0, (fitted.width * scale - frame.width) / 2)
        let maxY = Swift.max(0, (fitted.height * scale - frame.height) / 2)
        return CGSize(width: Swift.min(maxX, Swift.max(-maxX, offset.width)),
                      height: Swift.min(maxY, Swift.max(-maxY, offset.height)))
    }

    /// A double tap: zoomed in around the finger when fit, back to fit when zoomed.
    static func toggled(_ zoom: PhotoZoom, at point: CGPoint, fitted: CGSize, in frame: CGSize) -> PhotoZoom {
        guard zoom.scale <= 1.01 else { return PhotoZoom() }
        let center = CGPoint(x: frame.width / 2, y: frame.height / 2)
        let raw = CGSize(width: (point.x - center.x) * (1 - doubleTap), height: (point.y - center.y) * (1 - doubleTap))
        return PhotoZoom(scale: doubleTap, offset: clamp(raw, scale: doubleTap, fitted: fitted, in: frame))
    }
}

/// One photo that pinches, pans and double-taps. The pan is only taken when zoomed in, so a swipe at
/// fit size still turns the page.
private struct ZoomableImage: View {
    let url: URL?
    @Binding var zoom: PhotoZoom
    let onTap: () -> Void

    @State private var image: UIImage?
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            let frame = geometry.size
            let fitted = PhotoZoom.fitted(image?.size ?? CGSize(width: 3, height: 4), in: frame)
            let scale = min(PhotoZoom.max, max(1, zoom.scale * pinch))
            let offset = PhotoZoom.clamp(zoom.offset.adding(drag), scale: scale, fitted: fitted, in: frame)
            content
                .frame(width: frame.width, height: frame.height)
                .scaleEffect(scale)
                .offset(offset)
                .contentShape(Rectangle())
                .highPriorityGesture(pan(fitted: fitted, frame: frame), including: zoom.scale > 1 ? .all : .subviews)
                .simultaneousGesture(magnify(fitted: fitted, frame: frame))
                .onTapGesture(count: 2) { point in
                    withAnimation(.snappy(duration: 0.25)) {
                        zoom = PhotoZoom.toggled(zoom, at: point, fitted: fitted, in: frame)
                    }
                }
                .onTapGesture { onTap() }
        }
        .clipped()
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = await PhotoFiles.image(at: url, maxPixel: 2000)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFit()
        } else if url == nil {
            Text("No photo").font(.subheadline).foregroundStyle(Theme.surface.opacity(0.7))
        } else {
            ProgressView().tint(Theme.surface)
        }
    }

    private func pan(fitted: CGSize, frame: CGSize) -> some Gesture {
        DragGesture()
            .updating($drag) { value, state, _ in state = value.translation }
            .onEnded { value in
                zoom.offset = PhotoZoom.clamp(zoom.offset.adding(value.translation), scale: zoom.scale, fitted: fitted, in: frame)
            }
    }

    private func magnify(fitted: CGSize, frame: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in
                let scale = min(PhotoZoom.max, max(1, zoom.scale * value.magnification))
                zoom = PhotoZoom(scale: scale, offset: scale > 1 ? PhotoZoom.clamp(zoom.offset, scale: scale, fitted: fitted, in: frame) : .zero)
            }
    }
}

private extension CGSize {
    func adding(_ other: CGSize) -> CGSize { CGSize(width: width + other.width, height: height + other.height) }
}

/// Photos on disk, decoded at a size the screen can use rather than the full 12 MP, and kept for the
/// next look. The files themselves are never touched.
enum PhotoFiles {
    nonisolated(unsafe) private static let cache = NSCache<NSString, UIImage>()

    static func image(at url: URL, maxPixel: CGFloat) async -> UIImage? {
        let key = "\(url.path)#\(Int(maxPixel))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let decoded = await Task.detached(priority: .userInitiated) { Decoded(image: decode(url, maxPixel: maxPixel)) }.value
        if let image = decoded.image { cache.setObject(image, forKey: key) }
        return decoded.image
    }

    private struct Decoded: @unchecked Sendable { let image: UIImage? }

    nonisolated private static func decode(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
