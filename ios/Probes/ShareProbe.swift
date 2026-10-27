import SwiftUI
import UIKit

/// G6: share one image plus text to WhatsApp. Pass: both arrive in one message. If WhatsApp drops
/// the text, the fallback is the image through the share sheet with the text already on the clipboard.
struct ShareProbeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var includeText = true
    @State private var showShare = false
    @State private var banner: String?
    @State private var log: [String] = []

    static let sampleText = """
    Weekly check-in · Setecho share test (synthetic numbers)
    Weeks away from target date: 12
    Accuracy on plan: 100% (7 of 7 days, 5 of 5 sessions)
    Average daily steps: 10,400
    Current body weight: 181.2 lb
    Notes on sleep: Avg 7.4 h/night
    """

    var body: some View {
        ScreenScaffold {
            LinkButton(title: "Back to probes", chevron: .leading) { dismiss() }
            TitleBlock(eyebrow: "G6", title: "WhatsApp share", subtitle: "Send to your own chat first, not the coach's.")
            SectionCard("Collage stand-in") {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tag, style: .continuous))
                        .accessibilityLabel("Four placeholder pose tiles")
                } else {
                    Text("Rendering…").font(.subheadline).secondaryText()
                }
            }
            SectionCard("Text") {
                Text(Self.sampleText)
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(Theme.navy)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let banner {
                SectionCard {
                    HStack(spacing: Theme.Space.s) {
                        TargetTag(text: "Next")
                        Text(banner).font(.subheadline).foregroundStyle(Theme.navy)
                    }
                }
            }
            PassChecksCard(items: [
                "Share image + text, pick WhatsApp, pick yourself: does one message hold both the image and the text?",
                "If only the image arrives: try the fallback. Long-press the chat field and paste; the text is already copied.",
                "Note the exact behaviour: text as caption, text as a second message, or text dropped.",
            ])
            ProbeLog(lines: log)
        } footer: {
            Button("Share image + text") {
                includeText = true
                banner = nil
                showShare = true
            }
            .buttonStyle(.setechoPrimary)
            .disabled(image == nil)
            Button("Fallback: image only, text copied") {
                UIPasteboard.general.string = Self.sampleText
                includeText = false
                banner = "Paste the check-in text under the photo."
                showShare = true
                log.append("\(Date.now.probeStamp)  Text copied to the clipboard; sharing image only")
            }
            .buttonStyle(.setechoOutline)
            .disabled(image == nil)
        }
        .task {
            if image == nil { image = CollageStandIn.render() }
        }
        .sheet(isPresented: $showShare) {
            if let image {
                ActivitySheet(image: image, text: includeText ? Self.sampleText : nil) { activity, completed in
                    let what = includeText ? "image + text" : "image only"
                    let via = activity ?? "no app"
                    log.append("\(Date.now.probeStamp)  \(completed ? "Shared" : "Cancelled") \(what) via \(via)")
                }
            }
        }
    }
}

/// UIActivityViewController, since ShareLink can't carry an image and a text as two items.
struct ActivitySheet: UIViewControllerRepresentable {
    let image: UIImage
    let text: String?
    let onComplete: @MainActor (String?, Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        var items: [Any] = [image]
        if let text { items.append(text) }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let onComplete = self.onComplete
        controller.completionWithItemsHandler = { activity, completed, _, _ in
            MainActor.assumeIsolated { onComplete(activity?.rawValue, completed) }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// A 3:4, 2×2 stand-in for the check-in collage, 1200×1600 px, in the coach's order.
@MainActor
enum CollageStandIn {
    static func render() -> UIImage? {
        let renderer = ImageRenderer(content: CollageStandInView().frame(width: 600, height: 800))
        renderer.scale = 2
        return renderer.uiImage
    }
}

private struct CollageStandInView: View {
    private let poses = ["Front", "Right · arms up", "Back", "Left · arms up"]

    var body: some View {
        let columns = [GridItem(.flexible(), spacing: Theme.Space.xs), GridItem(.flexible(), spacing: Theme.Space.xs)]
        LazyVGrid(columns: columns, spacing: Theme.Space.xs) {
            ForEach(poses, id: \.self) { pose in
                RoundedRectangle(cornerRadius: Theme.Radius.tag, style: .continuous)
                    .fill(Theme.cameraFill)
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .overlay(alignment: .bottomLeading) {
                        Text(pose)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.surface)
                            .padding(Theme.Space.s)
                    }
            }
        }
        .padding(Theme.Space.xs)
        .background(Theme.page)
    }
}

#Preview {
    NavigationStack { ShareProbeView() }
}
