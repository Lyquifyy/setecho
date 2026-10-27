import Foundation
import Testing
@testable import Setecho

@Test func apiBaseURLResolves() {
    #expect(APIConfig.baseURL.scheme?.hasPrefix("http") == true)
}

@Test func formatsLoadsAndTimes() {
    #expect(Format.load(220) == "220 lb")
    #expect(Format.load(222.5) == "222.5 lb")
    #expect(Format.percent(31.4) == "31%")
    #expect(Format.duration(29) == "0:29")
    #expect(Format.timer(18) == "00:18")
}
