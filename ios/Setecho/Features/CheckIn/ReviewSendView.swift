import SwiftUI
import UIKit

/// Review and send (DESIGN.md): both messages in the coach's format and order (the plan message,
/// then the check-in), with the collage beneath the check-in. The send runs in his order as
/// steps, one share sheet each (HANDOFF.md §7, Check-in, step 6): the plan message, the check-in
/// with the collage, then the videos (P4). The footer names the next step. If WhatsApp drops the
/// text when an image is shared, step 2 falls back to the image with the text copied.
struct ReviewSendView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    let coordinator: CheckInCoordinator
    @State private var messages: [String] = []
    @State private var error: String?
    @State private var showShare = false
    @State private var includeText = true
    @State private var banner: String?
    /// Which of the steps goes out next: 0 the plan message, 1 the check-in with the collage.
    @State private var sendStep = 0

    private var text: String? { messages.isEmpty ? nil : messages.joined(separator: "\n\n") }
    private var planMessage: String? { messages.count > 1 ? messages[0] : nil }
    private var checkInMessage: String? { messages.last }
    private var stepCount: Int { planMessage == nil ? 1 : 2 }
    private var stepName: String { sendStep == 0 && planMessage != nil ? "the plan message" : "the check-in with the photos" }

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
            if let planMessage {
                SectionCard("Message 1 · the plan", accessory: { if sendStep > 0 { Text("Sent").font(.subheadline.weight(.semibold)).secondaryText() } }) {
                    Text(planMessage).font(.footnote).monospacedDigit().foregroundStyle(Theme.navy)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            SectionCard(planMessage == nil ? "Message" : "Message 2 · the check-in") {
                if let checkInMessage {
                    Text(checkInMessage).font(.footnote).monospacedDigit().foregroundStyle(Theme.navy)
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
            Button(sendStep == 0 ? "Send to WhatsApp" : "Next: \(stepName)") {
                includeText = true
                banner = nil
                showShare = true
            }
            .buttonStyle(.setechoPrimary)
            .disabled(text == nil || sendStep >= stepCount)
            if sendStep == stepCount - 1 || planMessage == nil {
                Button("Photo first, then paste the text") {
                    UIPasteboard.general.string = checkInMessage
                    includeText = false
                    banner = "Paste the check-in text under the photo."
                    showShare = true
                }
                .buttonStyle(.setechoOutline)
                .disabled(text == nil || collage == nil)
            }
            if stepCount > 1, sendStep < stepCount {
                Text("Step \(sendStep + 1) of \(stepCount): \(stepName). One WhatsApp message each, in his order.")
                    .font(.footnote).secondaryText()
            }
        }
        .task { await render() }
        .sheet(isPresented: $showShare) {
            let isPlanStep = sendStep == 0 && planMessage != nil
            let body = isPlanStep ? planMessage : checkInMessage
            if let body {
                ShareSheet(image: isPlanStep ? nil : collage, text: includeText ? body : nil) { completed in
                    guard completed else { return }
                    sendStep += 1
                    if sendStep >= stepCount {
                        coordinator.markSent()
                        banner = "Sent. The check-in is saved under History."
                    } else {
                        banner = "Next: \(stepName)."
                    }
                }
            }
        }
    }

    private func render() async {
        guard let template = coordinator.template, let draft = coordinator.draft else { return }
        error = nil
        do {
            messages = try await APIClient().checkInRenderMessages(template: template, draft: draft).messages
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
