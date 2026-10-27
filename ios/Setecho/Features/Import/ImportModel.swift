import Foundation
import SwiftUI

/// One import step's state: what the athlete gave, the backend's answer, and any error.
/// Two instances live in the flow, one for the program and one for the form.
@MainActor
@Observable
final class ImportModel {
    enum Kind { case program, form }

    enum Picked: Equatable {
        case file(Data, filename: String, mime: String)
        case screenshot(Data)

        var label: String {
            switch self {
            case .file(_, let filename, _): filename
            case .screenshot: "Screenshot"
            }
        }
    }

    let kind: Kind
    var link = ""
    var text = ""
    var picked: Picked?
    var isLoading = false
    var error: String?
    var program: Program?
    var template: CheckInTemplate?

    private let api: APIClient

    init(kind: Kind, api: APIClient = APIClient()) {
        self.kind = kind
        self.api = api
    }

    var hasInput: Bool {
        picked != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (kind == .program && !link.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var hasResult: Bool { program != nil || template != nil }

    private var source: APIClient.ImportSource? {
        if let picked {
            switch picked {
            case .file(let data, let filename, let mime): return .file(data, filename: filename, mime: mime)
            case .screenshot(let data): return .file(data, filename: "screenshot.jpg", mime: "image/jpeg")
            }
        }
        let trimmedLink = link.trimmingCharacters(in: .whitespaces)
        if kind == .program, !trimmedLink.isEmpty { return .link(trimmedLink) }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedText.isEmpty ? nil : .text(trimmedText)
    }

    func run() async {
        guard let source, !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            switch kind {
            case .program: program = try await api.importProgram(source)
            case .form: template = try await api.importForm(source)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func reset() {
        program = nil
        template = nil
        error = nil
    }
}
