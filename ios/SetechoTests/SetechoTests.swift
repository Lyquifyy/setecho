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

@Test func wavHeaderIs16kMono16Bit() {
    let samples: [Int16] = [0, 1000, -1000, 32767, -32768]
    let d = WAVFile.data(pcm16: samples, sampleRate: 16_000)
    #expect(d.count == 44 + samples.count * 2)
    #expect(String(decoding: d[0..<4], as: UTF8.self) == "RIFF")
    #expect(String(decoding: d[8..<12], as: UTF8.self) == "WAVE")
    #expect(String(decoding: d[12..<16], as: UTF8.self) == "fmt ")
    #expect(le16(d, 20) == 1)          // PCM
    #expect(le16(d, 22) == 1)          // mono
    #expect(le32(d, 24) == 16_000)     // sample rate
    #expect(le32(d, 28) == 32_000)     // byte rate
    #expect(le16(d, 32) == 2)          // block align
    #expect(le16(d, 34) == 16)         // bits per sample
    #expect(String(decoding: d[36..<40], as: UTF8.self) == "data")
    #expect(le32(d, 40) == UInt32(samples.count * 2))
    #expect(Int16(bitPattern: le16(d, 46)) == 1000)
    #expect(Int16(bitPattern: le16(d, 48)) == -1000)
}

private func le16(_ d: Data, _ at: Int) -> UInt16 {
    UInt16(d[at]) | UInt16(d[at + 1]) << 8
}

private func le32(_ d: Data, _ at: Int) -> UInt32 {
    UInt32(d[at]) | UInt32(d[at + 1]) << 8 | UInt32(d[at + 2]) << 16 | UInt32(d[at + 3]) << 24
}
