import Compression
import Foundation

// iPhone and iPad apps can't run zip, unzip, ditto or tar, so archives are read and written here.
// Files are streamed in chunks, so large archives don't have to fit in memory.

// MARK: - Deflate

/// Raw DEFLATE (RFC 1951), the compression inside zip and gzip, through Apple's Compression library.
final class DeflateStream {
    private let stream: UnsafeMutablePointer<compression_stream>
    private let buffer: UnsafeMutablePointer<UInt8>
    private let bufferSize = 256 * 1024
    private var finished = false
    private var ready = false

    init(compress: Bool) throws {
        stream = .allocate(capacity: 1)
        buffer = .allocate(capacity: bufferSize)
        let operation = compress ? COMPRESSION_STREAM_ENCODE : COMPRESSION_STREAM_DECODE
        guard compression_stream_init(stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ConversionError("Couldn't start the compressor.")
        }
        ready = true
    }

    deinit {
        if ready { compression_stream_destroy(stream) }
        stream.deallocate()
        buffer.deallocate()
    }

    /// Feeds one chunk and returns whatever output it produced. Pass `final` with the last chunk.
    func process(_ input: Data, final: Bool) throws -> Data {
        guard !finished else { return Data() }
        var output = Data()
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            stream.pointee.src_ptr = bytes.baseAddress.map { UnsafePointer($0) } ?? UnsafePointer(buffer)
            stream.pointee.src_size = bytes.count
            let flags = final ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = bufferSize
                let status = compression_stream_process(stream, flags)
                let produced = bufferSize - stream.pointee.dst_size
                if produced > 0 { output.append(buffer, count: produced) }
                switch status {
                case COMPRESSION_STATUS_END:
                    finished = true
                    return
                case COMPRESSION_STATUS_OK:
                    // Done with this chunk once all input is used and the output buffer wasn't filled.
                    if stream.pointee.src_size == 0 && produced < bufferSize {
                        if final && produced == 0 { throw ConversionError("The compressed data is cut short.") }
                        if !final { return }
                    }
                default:
                    throw ConversionError("The compressed data is damaged.")
                }
            }
        }
        return output
    }
}

// MARK: - CRC-32

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func update(_ crc: UInt32, _ data: Data) -> UInt32 {
        var c = ~crc
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for byte in raw { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        }
        return ~c
    }
}

// MARK: - Little-endian helpers

private extension Data {
    mutating func append16(_ value: UInt16) { append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)]) }
    mutating func append32(_ value: UInt32) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }

    func u16(_ offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}

private let chunkSize = 1 << 20

private func readChunk(_ handle: FileHandle, _ count: Int) throws -> Data {
    try handle.read(upToCount: count) ?? Data()
}

/// Every regular file and folder under `items` (names relative to `base`), folders before their contents.
private func collect(_ items: [String], in base: URL) throws -> [(path: String, url: URL, isDirectory: Bool)] {
    var result: [(path: String, url: URL, isDirectory: Bool)] = []
    let fm = FileManager.default
    for item in items {
        let url = base.appendingPathComponent(item)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ConversionError("\(item) is missing.")
        }
        guard isDir.boolValue else {
            result.append((path: item, url: url, isDirectory: false))
            continue
        }
        result.append((path: item, url: url, isDirectory: true))
        let children = try fm.contentsOfDirectory(atPath: url.path).filter { $0 != ".DS_Store" }.sorted()
        result += try collect(children.map { item + "/" + $0 }, in: base)
    }
    return result
}

/// Rejects names that would land outside the destination folder.
private func safeDestination(_ name: String, in folder: URL) -> URL? {
    let parts = name.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
    guard !parts.isEmpty, !parts.contains(".."), !name.hasPrefix("/") else { return nil }
    return parts.reduce(folder) { $0.appendingPathComponent($1) }
}

// MARK: - Zip

enum ZipArchive {
    /// Zips `items` (names relative to `base`; folders are added with everything in them).
    /// Names in `stored` are kept uncompressed, as EPUB requires for "mimetype".
    static func create(_ out: URL, from base: URL, items: [String], stored: Set<String> = []) throws {
        let fm = FileManager.default
        fm.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        var central = Data()
        var count = 0
        let (dosTime, dosDate) = dosTimestamp(Date())
        do {
            for entry in try collect(items, in: base) {
                let name = entry.isDirectory ? entry.path + "/" : entry.path
                let nameData = Data(name.utf8)
                let offset = try handle.offset()
                guard offset < 0xFFFF_FFFF else { throw ConversionError("The zip would be too big (over 4 GB).") }
                let method: UInt16 = entry.isDirectory || stored.contains(entry.path) ? 0 : 8

                var local = Data()
                local.append32(0x0403_4B50)
                local.append16(20) // version needed
                local.append16(0x0800) // names are UTF-8
                local.append16(method)
                local.append16(dosTime)
                local.append16(dosDate)
                local.append32(0) // CRC, patched below
                local.append32(0) // compressed size
                local.append32(0) // size
                local.append16(UInt16(nameData.count))
                local.append16(0)
                local.append(nameData)
                try handle.write(contentsOf: local)

                var crc: UInt32 = 0
                var size: UInt64 = 0
                var packed: UInt64 = 0
                if !entry.isDirectory {
                    let input = try FileHandle(forReadingFrom: entry.url)
                    defer { try? input.close() }
                    let deflater = method == 8 ? try DeflateStream(compress: true) : nil
                    while true {
                        let chunk = try readChunk(input, chunkSize)
                        let last = chunk.count < chunkSize
                        crc = CRC32.update(crc, chunk)
                        size += UInt64(chunk.count)
                        let output = try deflater?.process(chunk, final: last) ?? chunk
                        packed += UInt64(output.count)
                        try handle.write(contentsOf: output)
                        if last { break }
                    }
                }
                guard size < 0xFFFF_FFFF, packed < 0xFFFF_FFFF else {
                    throw ConversionError("\(entry.path) is too big for a zip (over 4 GB).")
                }
                let end = try handle.offset()
                try handle.seek(toOffset: offset + 14)
                var sizes = Data()
                sizes.append32(crc)
                sizes.append32(UInt32(packed))
                sizes.append32(UInt32(size))
                try handle.write(contentsOf: sizes)
                try handle.seek(toOffset: end)

                central.append32(0x0201_4B50)
                central.append16(0x0314) // made by: Unix, zip 2.0
                central.append16(20)
                central.append16(0x0800)
                central.append16(method)
                central.append16(dosTime)
                central.append16(dosDate)
                central.append(sizes)
                central.append16(UInt16(nameData.count))
                central.append16(0) // extra
                central.append16(0) // comment
                central.append16(0) // disk
                central.append16(0) // internal attributes
                let mode: UInt32 = entry.isDirectory ? 0o040755 : 0o100644
                central.append32(mode << 16 | (entry.isDirectory ? 0x10 : 0))
                central.append32(UInt32(offset))
                central.append(nameData)
                count += 1
            }
            guard count < 0xFFFF else { throw ConversionError("Too many files for one zip.") }
            let centralOffset = try handle.offset()
            try handle.write(contentsOf: central)
            var end = Data()
            end.append32(0x0605_4B50)
            end.append16(0)
            end.append16(0)
            end.append16(UInt16(count))
            end.append16(UInt16(count))
            end.append32(UInt32(central.count))
            end.append32(UInt32(centralOffset))
            end.append16(0)
            try handle.write(contentsOf: end)
            try handle.close()
        } catch {
            try? handle.close()
            try? fm.removeItem(at: out)
            throw error
        }
    }

    /// Unpacks every file into `folder`. Skips the "__MACOSX" folders Macs add.
    static func extract(_ zip: URL, to folder: URL) throws {
        let fm = FileManager.default
        let handle = try FileHandle(forReadingFrom: zip)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()

        // The end-of-central-directory record is in the last 64 KB + 22 bytes.
        let tailLength = min(fileSize, 65_557)
        try handle.seek(toOffset: fileSize - tailLength)
        let tail = try readChunk(handle, Int(tailLength))
        guard tail.count >= 22, let eocd = stride(from: tail.count - 22, through: 0, by: -1)
            .first(where: { tail.u32($0) == 0x0605_4B50 }) else {
            throw ConversionError("\(zip.lastPathComponent) isn't a zip file.")
        }
        let entryCount = Int(tail.u16(eocd + 10))
        let centralSize = Int(tail.u32(eocd + 12))
        let centralOffset = UInt64(tail.u32(eocd + 16))
        guard centralOffset != 0xFFFF_FFFF else { throw ConversionError("Zips over 4 GB can't be opened here yet.") }
        try handle.seek(toOffset: centralOffset)
        let central = try readChunk(handle, centralSize)

        var position = 0
        for _ in 0..<entryCount {
            guard position + 46 <= central.count, central.u32(position) == 0x0201_4B50 else {
                throw ConversionError("\(zip.lastPathComponent) is damaged.")
            }
            let flags = central.u16(position + 8)
            let method = central.u16(position + 10)
            let crc = central.u32(position + 16)
            let packed = UInt64(central.u32(position + 20))
            let nameLength = Int(central.u16(position + 28))
            let extraLength = Int(central.u16(position + 30))
            let commentLength = Int(central.u16(position + 32))
            let localOffset = UInt64(central.u32(position + 42))
            let nameStart = central.startIndex + position + 46
            let nameData = central[nameStart..<(nameStart + nameLength)]
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            position += 46 + nameLength + extraLength + commentLength

            if name.hasPrefix("__MACOSX/") { continue }
            guard let target = safeDestination(name, in: folder) else { continue }
            if name.hasSuffix("/") {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            guard flags & 1 == 0 else { throw ConversionError("\(zip.lastPathComponent) is password-protected.") }
            guard method == 0 || method == 8 else {
                throw ConversionError("\(zip.lastPathComponent) uses a kind of compression Transmute can't read.")
            }

            try handle.seek(toOffset: localOffset)
            let local = try readChunk(handle, 30)
            guard local.count == 30, local.u32(0) == 0x0403_4B50 else {
                throw ConversionError("\(zip.lastPathComponent) is damaged.")
            }
            try handle.seek(toOffset: localOffset + 30 + UInt64(local.u16(26)) + UInt64(local.u16(28)))

            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: target.path, contents: nil)
            let output = try FileHandle(forWritingTo: target)
            defer { try? output.close() }
            let inflater = method == 8 ? try DeflateStream(compress: false) : nil
            var remaining = packed
            var check: UInt32 = 0
            repeat {
                let chunk = try readChunk(handle, Int(min(UInt64(chunkSize), remaining)))
                guard !chunk.isEmpty || remaining == 0 else { throw ConversionError("\(zip.lastPathComponent) is cut short.") }
                remaining -= UInt64(chunk.count)
                let data = try inflater?.process(chunk, final: remaining == 0) ?? chunk
                check = CRC32.update(check, data)
                try output.write(contentsOf: data)
            } while remaining > 0
            guard check == crc else { throw ConversionError("\(name) in \(zip.lastPathComponent) is damaged.") }
        }
    }

    private static func dosTimestamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let hour: Int = c.hour ?? 0, minute: Int = c.minute ?? 0, second: Int = c.second ?? 0
        let year: Int = max(0, (c.year ?? 1980) - 1980), month: Int = c.month ?? 1, dayOfMonth: Int = c.day ?? 1
        let time = UInt16(truncatingIfNeeded: (hour << 11) | (minute << 5) | (second / 2))
        let day = UInt16(truncatingIfNeeded: (year << 9) | (month << 5) | dayOfMonth)
        return (time, day)
    }
}

// MARK: - Gzip

enum Gzip {
    /// Compresses a file into gzip format.
    static func compress(_ input: URL, to out: URL) throws {
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let reader = try FileHandle(forReadingFrom: input)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: out)
        defer { try? writer.close() }
        try writer.write(contentsOf: Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3]))
        let deflater = try DeflateStream(compress: true)
        var crc: UInt32 = 0
        var size: UInt64 = 0
        while true {
            let chunk = try readChunk(reader, chunkSize)
            let last = chunk.count < chunkSize
            crc = CRC32.update(crc, chunk)
            size += UInt64(chunk.count)
            try writer.write(contentsOf: try deflater.process(chunk, final: last))
            if last { break }
        }
        var trailer = Data()
        trailer.append32(crc)
        trailer.append32(UInt32(truncatingIfNeeded: size))
        try writer.write(contentsOf: trailer)
    }

    /// Decompresses a gzip file.
    static func decompress(_ input: URL, to out: URL) throws {
        let reader = try FileHandle(forReadingFrom: input)
        defer { try? reader.close() }
        let header = try readChunk(reader, 10)
        guard header.count == 10, header[header.startIndex] == 0x1F, header[header.startIndex + 1] == 0x8B,
              header[header.startIndex + 2] == 8 else {
            throw ConversionError("\(input.lastPathComponent) isn't a gzip file.")
        }
        let flags = header[header.startIndex + 3]
        var offset: UInt64 = 10
        if flags & 4 != 0 { // extra field
            try reader.seek(toOffset: offset)
            let length = try readChunk(reader, 2)
            guard length.count == 2 else { throw ConversionError("\(input.lastPathComponent) is damaged.") }
            offset += 2 + UInt64(length.u16(0))
        }
        for flag: UInt8 in [8, 16] where flags & flag != 0 { // file name, comment: zero-terminated
            try reader.seek(toOffset: offset)
            while true {
                let byte = try readChunk(reader, 1)
                guard let b = byte.first else { throw ConversionError("\(input.lastPathComponent) is damaged.") }
                offset += 1
                if b == 0 { break }
            }
        }
        if flags & 2 != 0 { offset += 2 } // header CRC
        try reader.seek(toOffset: offset)

        FileManager.default.createFile(atPath: out.path, contents: nil)
        let writer = try FileHandle(forWritingTo: out)
        defer { try? writer.close() }
        let inflater = try DeflateStream(compress: false)
        var chunk = try readChunk(reader, chunkSize)
        while true {
            let next = try readChunk(reader, chunkSize)
            // The 8-byte trailer is read along with the data; the inflater stops at the stream's end.
            try writer.write(contentsOf: try inflater.process(chunk, final: next.isEmpty))
            if next.isEmpty { break }
            chunk = next
        }
    }
}

// MARK: - Tar

enum TarArchive {
    static func create(_ out: URL, from base: URL, items: [String], gzip: Bool) throws {
        let fm = FileManager.default
        let tarURL = gzip ? OutputPaths.temporaryURL(ext: "tar") : out
        defer { if gzip { try? fm.removeItem(at: tarURL) } }
        fm.createFile(atPath: tarURL.path, contents: nil)
        func writeTar() throws {
            let writer = try FileHandle(forWritingTo: tarURL)
            defer { try? writer.close() }
            for entry in try collect(items, in: base) {
                let size = entry.isDirectory ? 0 : OutputPaths.fileSize(entry.url)
                try writer.write(contentsOf: try header(name: entry.isDirectory ? entry.path + "/" : entry.path,
                                                        size: UInt64(size), isDirectory: entry.isDirectory))
                guard !entry.isDirectory else { continue }
                let reader = try FileHandle(forReadingFrom: entry.url)
                defer { try? reader.close() }
                var written: UInt64 = 0
                while true {
                    let chunk = try readChunk(reader, chunkSize)
                    if chunk.isEmpty { break }
                    written += UInt64(chunk.count)
                    try writer.write(contentsOf: chunk)
                }
                let padding = Int((512 - written % 512) % 512)
                if padding > 0 { try writer.write(contentsOf: Data(count: padding)) }
            }
            try writer.write(contentsOf: Data(count: 1024))
        }
        do {
            try writeTar()
            if gzip { try Gzip.compress(tarURL, to: out) }
        } catch {
            try? fm.removeItem(at: out)
            throw error
        }
    }

    static func extract(_ archive: URL, to folder: URL) throws {
        let fm = FileManager.default
        var source = archive
        var temp: URL?
        var head = Data()
        if let peek = try? FileHandle(forReadingFrom: archive) {
            head = (try? peek.read(upToCount: 2)) ?? Data()
            try? peek.close()
        }
        if head.count == 2, head[head.startIndex] == 0x1F, head[head.startIndex + 1] == 0x8B {
            let tar = OutputPaths.temporaryURL(ext: "tar")
            try Gzip.decompress(archive, to: tar)
            source = tar
            temp = tar
        }
        defer { if let temp { try? fm.removeItem(at: temp) } }

        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        var longName: String?
        while true {
            let block = try readChunk(reader, 512)
            guard block.count == 512 else { break }
            if block.allSatisfy({ $0 == 0 }) { break }
            func text(_ start: Int, _ length: Int) -> String {
                let bytes = block[(block.startIndex + start)..<(block.startIndex + start + length)].prefix { $0 != 0 }
                return String(decoding: bytes, as: UTF8.self)
            }
            let size = UInt64(text(124, 12).trimmingCharacters(in: .whitespaces), radix: 8) ?? 0
            let type = block[block.startIndex + 156]
            var name = text(0, 100)
            let prefix = text(345, 155)
            if text(257, 5) == "ustar" && !prefix.isEmpty { name = prefix + "/" + name }
            if let long = longName { name = long; longName = nil }
            let padded = (size + 511) / 512 * 512

            switch type {
            case UInt8(ascii: "L"), UInt8(ascii: "x"): // GNU long name, PAX header
                let data = try readChunk(reader, Int(padded)).prefix(Int(size))
                if type == UInt8(ascii: "L") {
                    longName = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
                } else {
                    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                        if let range = line.range(of: " path=") { longName = String(line[range.upperBound...]) }
                    }
                }
            case UInt8(ascii: "5"):
                if let target = safeDestination(name, in: folder) {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                }
            case 0, UInt8(ascii: "0"), UInt8(ascii: "7"):
                guard let target = safeDestination(name, in: folder), !name.hasPrefix("._") else {
                    try reader.seek(toOffset: try reader.offset() + padded)
                    continue
                }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: target.path, contents: nil)
                let writer = try FileHandle(forWritingTo: target)
                var remaining = size
                while remaining > 0 {
                    let chunk = try readChunk(reader, Int(min(UInt64(chunkSize), remaining)))
                    guard !chunk.isEmpty else { break }
                    remaining -= UInt64(chunk.count)
                    try writer.write(contentsOf: chunk)
                }
                try writer.close()
                try reader.seek(toOffset: try reader.offset() + (padded - size))
            default: // links and other special entries are skipped
                try reader.seek(toOffset: try reader.offset() + padded)
            }
        }
    }

    /// A ustar header block; long paths are split into prefix and name.
    private static func header(name: String, size: UInt64, isDirectory: Bool) throws -> Data {
        var nameField = name
        var prefixField = ""
        if Data(name.utf8).count > 100 {
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            guard let split = (1..<parts.count).first(where: {
                Data(parts[$0...].joined(separator: "/").utf8).count <= 100
                    && Data(parts[..<$0].joined(separator: "/").utf8).count <= 155
            }) else {
                throw ConversionError("\(name) has too long a path for a tar archive.")
            }
            prefixField = parts[..<split].joined(separator: "/")
            nameField = parts[split...].joined(separator: "/")
        }
        var block = Data(count: 512)
        func put(_ text: String, at offset: Int, length: Int) {
            for (i, byte) in Data(text.utf8).prefix(length).enumerated() { block[offset + i] = byte }
        }
        func octal(_ value: UInt64, length: Int) -> String {
            let digits = String(value, radix: 8)
            return String(repeating: "0", count: max(0, length - 1 - digits.count)) + digits
        }
        put(nameField, at: 0, length: 100)
        put(octal(isDirectory ? 0o755 : 0o644, length: 8), at: 100, length: 8)
        put(octal(0, length: 8), at: 108, length: 8)
        put(octal(0, length: 8), at: 116, length: 8)
        put(octal(size, length: 12), at: 124, length: 12)
        put(octal(UInt64(Date().timeIntervalSince1970), length: 12), at: 136, length: 12)
        put("        ", at: 148, length: 8)
        block[156] = isDirectory ? UInt8(ascii: "5") : UInt8(ascii: "0")
        put("ustar", at: 257, length: 6)
        put("00", at: 263, length: 2)
        put(prefixField, at: 345, length: 155)
        let sum = block.reduce(0) { $0 + Int($1) }
        put(octal(UInt64(sum), length: 7), at: 148, length: 7)
        return block
    }
}
