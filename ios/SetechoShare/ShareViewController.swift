import UIKit
import UniformTypeIdentifiers

/// WhatsApp → Share → Setecho. Accepts text or one audio file, writes it to the app group's
/// `inbox/`, and says "Sent to Setecho." The app reads the inbox when it next comes to the front
/// (HANDOFF.md §7, Coach reply, step 1). No network, no model: the extension only hands over.
final class ShareViewController: UIViewController {
    private static let appGroup = "group.com.getsetecho.app"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.933, green: 0.949, blue: 0.976, alpha: 1) // page #EEF2F9
        let label = UILabel()
        label.text = "Sending to Setecho…"
        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = UIColor(red: 0.09, green: 0.114, blue: 0.212, alpha: 1) // navy #171D36
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        Task { await handOver(label) }
    }

    private func handOver(_ label: UILabel) async {
        guard let inbox = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)?
            .appendingPathComponent("inbox", isDirectory: true)
        else { return finish(label, "Setecho isn't installed.") }
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let attachments = (extensionContext?.inputItems as? [NSExtensionItem])?.flatMap { $0.attachments ?? [] } ?? []
        var saved = false
        for provider in attachments {
            if provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) || provider.hasItemConformingToTypeIdentifier("org.xiph.opus")
                || provider.hasItemConformingToTypeIdentifier("org.xiph.ogg-audio") || provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
                let type = [UTType.audio.identifier, "org.xiph.opus", "org.xiph.ogg-audio", UTType.data.identifier].first { provider.hasItemConformingToTypeIdentifier($0) }!
                if let url = try? await provider.loadFileURL(for: type), let data = try? Data(contentsOf: url), !data.isEmpty {
                    let ext = url.pathExtension.isEmpty ? "opus" : url.pathExtension
                    if ext.lowercased() != "txt" {
                        try? data.write(to: inbox.appendingPathComponent("reply-\(stamp).\(ext)"))
                        saved = true
                        break
                    }
                }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let text = try? await provider.loadText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try? Data(text.utf8).write(to: inbox.appendingPathComponent("reply-\(stamp).txt"))
                    saved = true
                    break
                }
            }
        }
        finish(label, saved ? "Sent to Setecho." : "Nothing to send. Share his text or one voice note.")
    }

    private func finish(_ label: UILabel, _ message: String) {
        label.text = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}

private extension NSItemProvider {
    func loadFileURL(for type: String) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            loadItem(forTypeIdentifier: type) { item, error in
                if let error { continuation.resume(throwing: error); return }
                if let url = item as? URL { continuation.resume(returning: url); return }
                if let data = item as? Data {
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString).opus")
                    try? data.write(to: tmp)
                    continuation.resume(returning: tmp)
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }

    func loadText() async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, error in
                if let error { continuation.resume(throwing: error); return }
                if let text = item as? String { continuation.resume(returning: text); return }
                if let data = item as? Data { continuation.resume(returning: String(data: data, encoding: .utf8)); return }
                if let url = item as? URL { continuation.resume(returning: try? String(contentsOf: url, encoding: .utf8)); return }
                continuation.resume(returning: nil)
            }
        }
    }
}
