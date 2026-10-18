import AppKit
import CoreText
import PDFKit
import UniformTypeIdentifiers

enum PDFTools {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw ConversionError("Couldn't open \(url.lastPathComponent) as a PDF.") }
        if doc.isLocked { throw ConversionError("\(url.lastPathComponent) is password-protected.") }
        return doc
    }

    /// One image per page. Several pages go into a folder.
    static func rasterize(_ input: URL, format: OutputFormat, options: ConversionOptions) throws -> [URL] {
        let doc = try open(input)
        let type: UTType = format == .png ? .png : .jpeg
        let count = doc.pageCount
        guard count > 0 else { throw ConversionError("The PDF has no pages.") }

        var folder: URL?
        if count > 1 {
            let dir = OutputPaths.destination(for: input, ext: "", suffix: "pages", folder: options.outputFolder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            folder = dir
        }
        var outputs: [URL] = []
        for index in 0..<count {
            guard let page = doc.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let rotated = page.rotation % 180 != 0
            let scale: CGFloat = 2 // 144 dpi
            let size = NSSize(width: (rotated ? bounds.height : bounds.width) * scale,
                              height: (rotated ? bounds.width : bounds.height) * scale)
            let thumb = page.thumbnail(of: size, for: .mediaBox)
            var rect = CGRect(origin: .zero, size: thumb.size)
            guard let image = thumb.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { continue }
            let out = folder.map { $0.appendingPathComponent("Page \(index + 1).\(format.fileExtension)") }
                ?? OutputPaths.destination(for: input, ext: format.fileExtension, folder: options.outputFolder)
            try ImageConverter.data(from: image, type: type, quality: options.quality).write(to: out, options: .atomic)
            outputs.append(out)
        }
        return folder.map { [$0] } ?? outputs
    }

    static func split(_ input: URL, options: ConversionOptions) throws -> URL {
        let doc = try open(input)
        let dir = OutputPaths.destination(for: input, ext: "", suffix: "pages", folder: options.outputFolder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            single.write(to: dir.appendingPathComponent("Page \(index + 1).pdf"))
        }
        return dir
    }

    static func merge(_ urls: [URL], options: ConversionOptions) throws -> URL {
        let merged = PDFDocument()
        for url in urls {
            let doc = try open(url)
            for index in 0..<doc.pageCount {
                if let page = doc.page(at: index)?.copy() as? PDFPage {
                    merged.insert(page, at: merged.pageCount)
                }
            }
        }
        let dir = options.outputFolder ?? urls[0].deletingLastPathComponent()
        let out = OutputPaths.unique(in: dir, base: "Merged", ext: "pdf")
        guard merged.write(to: out) else { throw ConversionError("Couldn't save the merged PDF.") }
        return out
    }

    /// One page per image, each sized to fit an A4 page.
    static func imagesToPDF(_ urls: [URL], options: ConversionOptions) throws -> URL {
        let doc = PDFDocument()
        let a4 = CGSize(width: 595, height: 842)
        for url in urls {
            let cg = try ImageConverter.loadCGImage(url)
            let w = CGFloat(cg.width), h = CGFloat(cg.height)
            let fit = min(a4.width / w, a4.height / h, 1)
            let image = NSImage(cgImage: cg, size: NSSize(width: w * fit, height: h * fit))
            if let page = PDFPage(image: image) { doc.insert(page, at: doc.pageCount) }
        }
        guard doc.pageCount > 0 else { throw ConversionError("None of the images could be read.") }
        let dir = options.outputFolder ?? urls[0].deletingLastPathComponent()
        let out = OutputPaths.unique(in: dir, base: "Images", ext: "pdf")
        guard doc.write(to: out) else { throw ConversionError("Couldn't save the PDF.") }
        return out
    }

    /// Recompresses embedded images. Text-only PDFs usually can't get much smaller.
    static func compress(_ input: URL, options: ConversionOptions) throws -> JobResult {
        let doc = try open(input)
        if options.stripMetadata { doc.documentAttributes = [:] }
        let out = OutputPaths.destination(for: input, ext: "pdf", suffix: "compressed", folder: options.outputFolder)
        var writeOptions: [PDFDocumentWriteOption: Any] = [:]
        if #available(macOS 13.4, *) {
            writeOptions[.saveImagesAsJPEGOption] = true
            writeOptions[.optimizeImagesForScreenOption] = true
        }
        guard doc.write(to: out, withOptions: writeOptions) else { throw ConversionError("Couldn't save the PDF.") }
        let before = OutputPaths.fileSize(input), after = OutputPaths.fileSize(out)
        let message = after < before
            ? "\(before.formattedSize) → \(after.formattedSize)"
            : "Already about as small as it gets (\(after.formattedSize))"
        return JobResult(outputs: [out], message: message)
    }

    static func stripMetadata(_ input: URL, options: ConversionOptions) throws -> URL {
        let doc = try open(input)
        doc.documentAttributes = [:]
        let out = OutputPaths.destination(for: input, ext: "pdf", suffix: "clean", folder: options.outputFolder)
        guard doc.write(to: out) else { throw ConversionError("Couldn't save the PDF.") }
        return out
    }
}

/// Text documents through NSAttributedString, which reads and writes
/// TXT, RTF, DOC, DOCX, ODT and HTML natively. Runs on the main thread
/// because the HTML importer requires it.
@MainActor
enum DocumentConverter {
    static func load(_ url: URL, kind: FileKind) throws -> NSAttributedString {
        if kind == .pdf {
            let doc = try PDFTools.open(url)
            return doc.selectionForEntireDocument?.attributedString ?? NSAttributedString(string: doc.string ?? "")
        }
        if ["txt", "md", "markdown"].contains(url.pathExtension.lowercased()) {
            var encoding = String.Encoding.utf8
            let text: String
            if let decoded = try? String(contentsOf: url, usedEncoding: &encoding) {
                text = decoded
            } else {
                text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            }
            return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        }
        return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
    }

    static func convert(_ input: URL, kind: FileKind, to format: OutputFormat, options: ConversionOptions) throws -> URL {
        let text = try load(input, kind: kind)
        let out = OutputPaths.destination(for: input, ext: format.fileExtension, folder: options.outputFolder)
        switch format {
        case .txt:
            try text.string.write(to: out, atomically: true, encoding: .utf8)
        case .pdf:
            try renderPDF(text, to: out)
        case .rtf, .docx, .html, .odt:
            let type: NSAttributedString.DocumentType = switch format {
            case .rtf: .rtf
            case .docx: .officeOpenXML
            case .html: .html
            default: .openDocument
            }
            let data = try text.data(from: NSRange(location: 0, length: text.length),
                                     documentAttributes: [.documentType: type])
            try data.write(to: out, options: .atomic)
        default:
            throw ConversionError("Documents can't be converted to \(format.label).")
        }
        return out
    }

    /// Lays text out over US Letter pages with Core Text.
    static func renderPDF(_ text: NSAttributedString, to out: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(out as CFURL, mediaBox: &mediaBox, nil) else {
            throw ConversionError("Couldn't create the PDF.")
        }
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let path = CGPath(rect: mediaBox.insetBy(dx: 54, dy: 54), transform: nil)
        var start = 0
        repeat {
            ctx.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length == 0 { break }
            start += visible.length
        } while start < text.length
        ctx.closePDF()
    }
}

enum SubtitleConverter {
    static func convert(_ input: URL, to format: OutputFormat, options: ConversionOptions) throws -> URL {
        let data = try Data(contentsOf: input)
        var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }

        let source = input.pathExtension.lowercased()
        let result: String
        switch (source, format) {
        case ("srt", .vtt): result = srtToVTT(text)
        case ("vtt", .srt): result = vttToSRT(text)
        case ("srt", .srt), ("vtt", .vtt): result = text
        default: throw ConversionError("Can't convert \(source.uppercased()) to \(format.label).")
        }
        let out = OutputPaths.destination(for: input, ext: format.fileExtension, folder: options.outputFolder)
        try result.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    static func srtToVTT(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").map { line in
            line.contains("-->") ? line.replacingOccurrences(of: ",", with: ".") : line
        }
        return (["WEBVTT", ""] + lines).joined(separator: "\n")
    }

    static func vttToSRT(_ text: String) -> String {
        let tags = try? NSRegularExpression(pattern: "<(?!/?[ibu]>)[^>]*>")
        var cues: [String] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n").map(String.init)
            // Header, NOTE and STYLE blocks have no timing line and are skipped.
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            var body = lines[(timingIndex + 1)...].joined(separator: "\n")
            if let tags {
                body = tags.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "")
            }
            cues.append("\(cues.count + 1)\n\(srtTiming(lines[timingIndex]))\n\(body)")
        }
        return cues.joined(separator: "\n\n") + "\n"
    }

    /// "01:02.500 --> 01:04.000 align:start" → "00:01:02,500 --> 00:01:04,000"
    private static func srtTiming(_ line: String) -> String {
        func fix(_ raw: String) -> String {
            var stamp = String(raw.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "")
            if stamp.filter({ $0 == ":" }).count == 1 { stamp = "00:" + stamp }
            return stamp.replacingOccurrences(of: ".", with: ",")
        }
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return line }
        return "\(fix(parts[0])) --> \(fix(parts[1]))"
    }
}

enum ArchiveTool {
    /// Packs files or folders into one archive.
    static func compress(_ inputs: [URL], to format: OutputFormat, name: String?, options: ConversionOptions) async throws -> URL {
        guard let first = inputs.first else { throw ConversionError("Nothing to archive.") }
        let dir = options.outputFolder ?? first.deletingLastPathComponent()
        let base = name ?? (first.hasDirectoryPath ? first.lastPathComponent : OutputPaths.baseName(of: first))
        let out = OutputPaths.unique(in: dir, base: base, ext: format.fileExtension)

        // Archive tools want one working directory, so files from different folders are staged together.
        var parent = first.deletingLastPathComponent()
        var names = inputs.map(\.lastPathComponent)
        var staging: URL?
        if Set(inputs.map { $0.deletingLastPathComponent().standardizedFileURL }).count > 1 {
            let stage = FileManager.default.temporaryDirectory.appendingPathComponent("transmute-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            names = []
            for url in inputs {
                let target = OutputPaths.unique(in: stage, base: OutputPaths.baseName(of: url), ext: url.pathExtension)
                try FileManager.default.copyItem(at: url, to: target) // APFS clones, so this is cheap
                names.append(target.lastPathComponent)
            }
            parent = stage
            staging = stage
        }
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }

        switch format {
        case .zip where inputs.count == 1:
            try await Shell.check("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, out.path])
        case .zip:
            try await Shell.check("/usr/bin/zip", ["-r", "-q", "-y", out.path] + names, currentDirectory: parent)
        case .tar:
            try await Shell.check("/usr/bin/tar", ["-cf", out.path, "-C", parent.path] + names)
        case .tgz:
            try await Shell.check("/usr/bin/tar", ["-czf", out.path, "-C", parent.path] + names)
        default:
            throw ConversionError("\(format.label) isn't an archive format.")
        }
        return out
    }

    /// Unpacks into a folder named after the archive. Handles zip, tar, gz, bz2, xz, rar and 7z
    /// through the system's libarchive-based `tar`.
    static func extract(_ input: URL, options: ConversionOptions) async throws -> URL {
        let name = input.lastPathComponent.lowercased()
        if name.hasSuffix(".gz") && !name.hasSuffix(".tar.gz") {
            // A single gzipped file, not a folder.
            let out = OutputPaths.destination(for: input, ext: "", folder: options.outputFolder)
            try await Shell.check("/usr/bin/gunzip", ["-c", input.path], stdoutFile: out)
            return out
        }
        let dir = OutputPaths.destination(for: input, ext: "", folder: options.outputFolder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if name.hasSuffix(".zip") {
            try await Shell.check("/usr/bin/ditto", ["-x", "-k", input.path, dir.path])
        } else {
            try await Shell.check("/usr/bin/tar", ["-xf", input.path, "-C", dir.path])
        }
        return dir
    }

    /// Converts one archive format to another by unpacking to a temporary folder.
    static func repack(_ input: URL, to format: OutputFormat, options: ConversionOptions) async throws -> URL {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("transmute-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let extracted = try await extract(input, options: ConversionOptions(outputFolder: temp))
        var repackOptions = options
        repackOptions.outputFolder = options.outputFolder ?? input.deletingLastPathComponent()
        return try await compress([extracted], to: format, name: OutputPaths.baseName(of: input), options: repackOptions)
    }
}
