import Foundation
import SwiftUI

/// One import step's state: what the athlete gave, the backend's answer, and any error.
/// Three instances live in the flow: the program, the form, and his written instructions.
@MainActor
@Observable
final class ImportModel {
    enum Kind { case program, form, rules }

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
    var formImport: FormImport?
    var rules: RulesImport?
    var template: CheckInTemplate? { formImport?.template }
    /// Which cycle days each add-on joins, proposed from the program and edited on the review.
    var addOnDays: [AddOnDays] = []

    private let api: APIClient

    init(kind: Kind, api: APIClient = APIClient()) {
        self.kind = kind
        self.api = api
    }

    var hasInput: Bool {
        picked != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (kind == .program && !link.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var hasResult: Bool { program != nil || template != nil || rules != nil }

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
            case .program:
                let imported = try await api.importProgram(source)
                program = imported
                addOnDays = imported.addOns.map { AddOnDays(addOnId: $0.id, dayIds: AddOnPlanner.proposedDays(for: $0, in: imported)) }
            case .form:
                formImport = try await api.importForm(source)
            case .rules:
                guard case .text(let pasted) = source else { throw APIError(status: 0, message: "Paste his instructions as text.") }
                rules = try await api.importRules(text: pasted)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func reset() {
        program = nil
        formImport = nil
        rules = nil
        addOnDays = []
        error = nil
    }
}
