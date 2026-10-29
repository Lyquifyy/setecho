import Foundation

/// A folder as one zip, written here (Oct 28: the file coordinator's "upload" zip of a take came
/// out empty). Stored entries, no compression: a take is CAF and WAV audio that would not shrink
/// anyway, and the point is one file AirDrop will carry.
enum ZipWriter {
    /// Zip every regular file under `folder`, paths relative to it, into `destination`.
    static func zip(folder: URL, to destination: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            throw NSError(domain: "Setecho", code: 10, userInfo: [NSLocalizedDescriptionKey: "Couldn't read the folder"])
        }
        var files: [URL] = []
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            files.append(url)
        }
        files.sort { $0.path < $1.path }

        var out = Data()
        var central = Data()
        let base = folder.standardizedFileURL.path + "/"
        for url in files {
            let name = String(url.standardizedFileURL.path.dropFirst(base.count))
            let nameBytes = Array(name.utf8)
            let bytes = try Data(contentsOf: url)
            let crc = crc32(bytes)
            let offset = UInt32(out.count)
            // Local file header.
            out.append(le32(0x0403_4b50))
            out.append(le16(20))          // version needed
            out.append(le16(0x0800))      // flags: UTF-8 names
            out.append(le16(0))           // stored
            out.append(le16(0)); out.append(le16(0x21)) // time 00:00, date 1980-01-01
            out.append(le32(crc))
            out.append(le32(UInt32(bytes.count)))
            out.append(le32(UInt32(bytes.count)))
            out.append(le16(UInt16(nameBytes.count)))
            out.append(le16(0))
            out.append(contentsOf: nameBytes)
            out.append(bytes)
            // Central directory entry.
            central.append(le32(0x0201_4b50))
            central.append(le16(20)); central.append(le16(20))
            central.append(le16(0x0800)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0x21))
            central.append(le32(crc))
            central.append(le32(UInt32(bytes.count)))
            central.append(le32(UInt32(bytes.count)))
            central.append(le16(UInt16(nameBytes.count)))
            central.append(le16(0)); central.append(le16(0)); central.append(le16(0)); central.append(le16(0))
            central.append(le32(0))
            central.append(le32(offset))
            central.append(contentsOf: nameBytes)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        // End of central directory.
        out.append(le32(0x0605_4b50))
        out.append(le16(0)); out.append(le16(0))
        out.append(le16(UInt16(files.count))); out.append(le16(UInt16(files.count)))
        out.append(le32(UInt32(central.count)))
        out.append(le32(centralOffset))
        out.append(le16(0))
        try out.write(to: destination, options: .atomic)
    }

    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
