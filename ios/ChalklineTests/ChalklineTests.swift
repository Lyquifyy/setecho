import Testing
@testable import Chalkline

@Test func apiBaseURLResolves() {
    #expect(APIConfig.baseURL.scheme?.hasPrefix("http") == true)
}
