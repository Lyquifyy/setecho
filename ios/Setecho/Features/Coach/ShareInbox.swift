import Foundation

/// What the share extension leaves in the app group's `inbox/`: one text file or one audio file
/// per share (HANDOFF.md §7, Coach reply). The app drains it at launch and on every return to the
/// foreground, reads each item through the backend, and opens the Coach reply screen.
enum ShareInbox {
    static let appGroup = "group.com.getsetecho.app"

    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("inbox", isDirectory: true)
    }

    @MainActor
    static func drain(into store: Store) async {
        guard let directory, let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            defer { try? FileManager.default.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url) else { continue }
            let model = CoachReplyModel(store: store)
            if url.pathExtension == "txt" {
                await model.read(text: String(decoding: data, as: UTF8.self))
            } else {
                await model.read(audio: data, filename: url.lastPathComponent)
            }
            if let reply = model.reply {
                AppRouter.shared.openReply = reply
            }
        }
    }
}
