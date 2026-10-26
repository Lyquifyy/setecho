import Foundation

enum APIConfig {
    /// Set per machine in ios/Config/Local.xcconfig (CHALKLINE_API_BASE).
    static let baseURL: URL = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "ChalklineAPIBase") as? String ?? "http://localhost:8000"
        return URL(string: raw) ?? URL(string: "http://localhost:8000")!
    }()
}
