import Compression
import Foundation

/// Reads a zip on the phone: WhatsApp's Export Chat → Attach Media (HANDOFF.md §9, WhatsApp history
/// import). Stored and deflated entries, from the central directory; no Zip64, since a coach chat's
/// photos and voice notes stay well under 4 GB. The file is memory-mapped and an entry is only
/// inflated when it's asked for, so the videos in the export are never read.
struct ZipReader {
    struct Entry: Equatable {
        var name: String
        var method: UInt16
        var crc: UInt32
        var compressedSize: Int
        var size: Int
        var localHeaderOffset: Int
        /// The file name without the folders above it.
        var fileName: String { (name as NSString).lastPathComponent }
    }

    enum ReadError: LocalizedError {
        case notAZip, zip64, unsupported(String), corrupt(String)
        var errorDescription: String? {
            switch self {
            case .notAZip: "That file isn't a zip."
            case .zip64: "That export is too large to read here."
            case .unsupported(let name): "\(name) is compressed in a way Setecho can't read."
            case .corrupt(let name): "\(name) is damaged in the export."
            }
        }
    }

    let entries: [Entry]
    private let data: Data

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    init(data: Data) throws {
        self.data = data
        entries = try Self.centralDirectory(data)
    }

    /// The first entry with this file name, in any folder.
    func entry(named fileName: String) -> Entry? {
        entries.first { $0.fileName == fileName }
    }

    func extract(_ entry: Entry) throws -> Data {
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, Self.u32(data, header) == 0x0403_4b50 else { throw ReadError.corrupt(entry.fileName) }
        let start = header + 30 + Int(Self.u16(data, header + 26)) + Int(Self.u16(data, header + 28))
        guard start + entry.compressedSize <= data.count else { throw ReadError.corrupt(entry.fileName) }
        let raw = data.subdata(in: start..<(start + entry.compressedSize))
        let out: Data
        switch entry.method {
        case 0:
            out = raw
        case 8:
            out = try Self.inflate(raw, size: entry.size, name: entry.fileName)
        default:
            throw ReadError.unsupported(entry.fileName)
        }
        guard ZipWriter.crc32(out) == entry.crc else { throw ReadError.corrupt(entry.fileName) }
        return out
    }

    // MARK: Format

    private static func centralDirectory(_ data: Data) throws -> [Entry] {
        // The end-of-central-directory record sits in the last 22 bytes plus at most a 64 KB comment.
        guard data.count >= 22 else { throw ReadError.notAZip }
        var eocd: Int?
        var i = data.count - 22
        let floor = max(0, data.count - 22 - 65_535)
        while i >= floor {
            if u32(data, i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard let eocd else { throw ReadError.notAZip }
        let count = Int(u16(data, eocd + 10))
        let offset = u32(data, eocd + 16)
        guard count != 0xFFFF, offset != 0xFFFF_FFFF else { throw ReadError.zip64 }

        var entries: [Entry] = []
        var p = Int(offset)
        for _ in 0..<count {
            guard p + 46 <= data.count, u32(data, p) == 0x0201_4b50 else { throw ReadError.notAZip }
            let nameLength = Int(u16(data, p + 28))
            let extra = Int(u16(data, p + 30))
            let comment = Int(u16(data, p + 32))
            guard p + 46 + nameLength <= data.count else { throw ReadError.notAZip }
            let nameBytes = data.subdata(in: (p + 46)..<(p + 46 + nameLength))
            let compressed = u32(data, p + 20), size = u32(data, p + 24), local = u32(data, p + 42)
            guard compressed != 0xFFFF_FFFF, size != 0xFFFF_FFFF, local != 0xFFFF_FFFF else { throw ReadError.zip64 }
            let name = String(decoding: nameBytes, as: UTF8.self)
            if !name.hasSuffix("/") {
                entries.append(Entry(name: name, method: u16(data, p + 10), crc: u32(data, p + 16),
                                     compressedSize: Int(compressed), size: Int(size), localHeaderOffset: Int(local)))
            }
            p += 46 + nameLength + extra + comment
        }
        return entries
    }

    /// Raw DEFLATE (RFC 1951), which is what Compression's ZLIB algorithm decodes.
    private static func inflate(_ raw: Data, size: Int, name: String) throws -> Data {
        guard size > 0 else { return Data() }
        guard !raw.isEmpty else { throw ReadError.corrupt(name) }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst in
            raw.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw ReadError.corrupt(name) }
        return out
    }

    private static func u16(_ data: Data, _ at: Int) -> UInt16 {
        let i = data.startIndex + at
        return UInt16(data[i]) | UInt16(data[i + 1]) << 8
    }

    private static func u32(_ data: Data, _ at: Int) -> UInt32 {
        let i = data.startIndex + at
        return UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
    }
}
