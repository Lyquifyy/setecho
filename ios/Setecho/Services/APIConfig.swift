import Foundation

enum APIConfig {
    /// Set per machine in ios/Config/Local.xcconfig (SETECHO_API_BASE).
    static let baseURL: URL = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "SetechoAPIBase") as? String ?? "http://localhost:8000"
        return URL(string: raw) ?? URL(string: "http://localhost:8000")!
    }()
}
