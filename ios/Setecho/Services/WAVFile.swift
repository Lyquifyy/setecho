import Foundation

/// RIFF/WAVE writer for 16-bit mono PCM, the only format Muse Voice Transcribe accepts (16 kHz or 24 kHz).
/// The phone writes every utterance with this before uploading it to /voice/command or /checkin/answer.
enum WAVFile {
    static let transcribeRates: Set<Int> = [16_000, 24_000]

    static func data(pcm16: [Int16], sampleRate: Int) -> Data {
        precondition(transcribeRates.contains(sampleRate), "Transcribe accepts 16 kHz or 24 kHz only")
        let dataSize = UInt32(pcm16.count * 2)
        var d = Data(capacity: 44 + Int(dataSize))
        d.append(ascii: "RIFF")
        d.append(le: UInt32(36) + dataSize)
        d.append(ascii: "WAVE")
        d.append(ascii: "fmt ")
        d.append(le: UInt32(16))                     // fmt chunk size
        d.append(le: UInt16(1))                      // PCM
        d.append(le: UInt16(1))                      // mono
        d.append(le: UInt32(sampleRate))
        d.append(le: UInt32(sampleRate * 2))         // byte rate
        d.append(le: UInt16(2))                      // block align
        d.append(le: UInt16(16))                     // bits per sample
        d.append(ascii: "data")
        d.append(le: dataSize)
        for sample in pcm16 { d.append(le: sample) }
        return d
    }
}

private extension Data {
    mutating func append(ascii s: String) {
        append(contentsOf: Array(s.utf8))
    }

    mutating func append<T: FixedWidthInteger>(le value: T) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: MemoryLayout<T>.size))
    }
}
