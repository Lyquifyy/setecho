import SwiftUI
import UIKit

/// Review and send (DESIGN.md): the exact message the coach receives, with the collage beneath it.
/// Footer: Send to WhatsApp. Fallback: the image through the share sheet with the text copied.
struct ReviewSendView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    let coordinator: CheckInCoordinator
    @State private var text: String?
    @State private var error: String?
    @State private var showShare = false
    @State private var includeText = true
    @State private var banner: String?

    private var collage: UIImage? {
        guard let id = coordinator.draft?.photoSetId ?? store.lastPhotoSet?.id,
              let set = store.photoSets.first(where: { $0.id == id }),
              let data = try? Data(contentsOf: store.mediaDirectory.appendingPathComponent(set.collageFile))
        else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        ScreenScaffold {
            LinkButton(title: "Back to check-in", chevron: .leading) { dismiss() }
            TitleBlock(title: "Review and send", subtitle: "Exactly what your coach receives, in his format.")
            if let banner {
                SectionCard {
                    HStack(spacing: Theme.Space.s) {
                        TargetTag(text: "Next")
                        Text(banner).font(.subheadline).foregroundStyle(Theme.navy)
                    }
                }
            }
            SectionCard("Message") {
                if let text {
                    Text(text).font(.footnote).monospacedDigit().foregroundStyle(Theme.navy)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                } else if let error {
                    Text(error).font(.subheadline).foregroundStyle(Theme.navy)
                    LinkButton(title: "Try again", chevron: .none) { Task { await render() } }
                } else {
                    HStack(spacing: Theme.Space.xs) {
                        ProgressView().tint(Theme.cobalt)
                        Text("Rendering…").font(.subheadline).secondaryText()
                    }
                }
                CardDivider()
                Text("Every number comes from Apple Health, the training log or what you said. Tap a field on the Check-in tab to see its source.")
                    .font(.footnote).secondaryText()
            }
            SectionCard("Photos") {
                if let collage {
                    Image(uiImage: collage).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tag, style: .continuous))
                } else {
                    Text("No photo set this week yet. Take photos from Today.").font(.subheadline).secondaryText()
                }
            }
            let missing = coordinator.questions.count
            if missing > 0 {
                SectionCard("Still to answer") {
                    Text("\(missing) question\(missing == 1 ? "" : "s") left for the wrap-up. They go out blank if you send now.")
                        .font(.subheadline).foregroundStyle(Theme.navy)
                }
            }
        } footer: {
            Button("Send to WhatsApp") {
                includeText = true
                banner = nil
                showShare = true
            }
            .buttonStyle(.setechoPrimary)
            .disabled(text == nil)
            Button("Photo first, then paste the text") {
                UIPasteboard.general.string = text
                includeText = false
                banner = "Paste the check-in text under the photo."
                showShare = true
            }
            .buttonStyle(.setechoOutline)
            .disabled(text == nil || collage == nil)
        }
        .task { await render() }
        .sheet(isPresented: $showShare) {
            if let text {
                ShareSheet(image: collage, text: includeText ? text : nil) { completed in
                    if completed {
                        coordinator.markSent()
                        banner = "Sent. The check-in is saved under History."
                    }
                }
            }
        }
    }

    private func render() async {
        guard let template = coordinator.template, let draft = coordinator.draft else { return }
        error = nil
        do {
            text = try await APIClient().checkInRender(template: template, draft: draft)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// UIActivityViewController with an optional image and an optional text.
struct ShareSheet: UIViewControllerRepresentable {
    let image: UIImage?
    let text: String?
    let onComplete: @MainActor (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        var items: [Any] = []
        if let image { items.append(image) }
        if let text { items.append(text) }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let onComplete = self.onComplete
        controller.completionWithItemsHandler = { _, completed, _, _ in
            MainActor.assumeIsolated { onComplete(completed) }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
