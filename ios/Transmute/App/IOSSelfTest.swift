import AVFoundation
import CoreImage
import ImageIO
import PDFKit
import UIKit

/// Runs every conversion and tool the iPhone and iPad app offers on a folder of sample files
/// (the same fixtures as the Mac self-test) and checks the results:
///   Transmute --selftest <folder>
/// Prints PASS/FAIL lines, also saved to Documents/selftest.log, and exits non-zero on any failure.
@MainActor
enum IOSSelfTest {
    private static var passed = 0
    private static var skipped = 0
    private static var failed: [String] = []
    private static var log = ""

    static func run(inputDir: URL) async -> Int {
        let fm = FileManager.default
        let outDir = fm.temporaryDirectory.appendingPathComponent("selftest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let options = ConversionOptions(quality: 0.8, outputFolder: outDir, stripMetadata: false)
        say("iOS \(UIDevice.current.systemVersion), \(UIDevice.current.model)")
        say("HEIC encoder: \(Mobile.canWriteHEIC ? "available" : "missing, HEIC isn't offered")")
        say("WebP encoder: \(ImageConverter.canWriteWebP ? "available" : "missing, WebP isn't offered")")
        say("input: \(inputDir.path)\noutput: \(outDir.path)\n")

        let inputs = ((try? fm.contentsOfDirectory(at: inputDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if inputs.isEmpty { record("fixtures", nil, "no sample files in \(inputDir.path)") }
        func fixture(_ name: String) throws -> URL {
            guard let url = inputs.first(where: { $0.lastPathComponent == name }) else { throw ConversionError("fixture \(name) missing") }
            return url
        }

        // Pass 1: every sample through everything the app offers for it.
        for input in inputs { await exercise(input, options: options) }

        // Pass 2: a PDF and an EPUB made in pass 1 become inputs.
        let made = ((try? fm.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)) ?? [])
        for (ext, name) in [("pdf", "note.pdf"), ("epub", "note.epub")] {
            let dir = outDir.appendingPathComponent("\(ext)-pass", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var passOptions = options
            passOptions.outputFolder = dir
            if let file = made.first(where: { $0.lastPathComponent == name }) ?? made.first(where: { $0.pathExtension == ext }) {
                await exercise(file, options: passOptions)
            } else {
                record("\(ext.uppercased()) inputs", nil, "no \(ext.uppercased()) was made in pass 1")
            }
        }

        let work = outDir.appendingPathComponent("checks", isDirectory: true)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        var workOptions = options
        workOptions.outputFolder = work
        func convert(_ url: URL, _ format: OutputFormat) async throws -> [URL] {
            try await Engine.perform(.convert(format), on: url, options: workOptions) { _ in }.outputs
        }
        func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
        func expect(_ condition: Bool, _ detail: String) throws {
            if !condition { throw ConversionError(detail) }
        }

        // Content checks: the words have to survive the trip.
        await check("content: report.docx → TXT keeps the text") {
            let out = try await convert(try fixture("report.docx"), .txt)
            let body = try text(out[0])
            try expect(body.contains("Hello from Transmute"), "got: \(body.prefix(80))")
            return out
        }
        await check("content: note.txt → DOCX → TXT round trip") {
            let docx = try await convert(try fixture("note.txt"), .docx)
            let back = try WordDocument.read(docx[0]).string
            try expect(back.contains("Hello from Transmute") && back.contains("Second paragraph."), "got: \(back.prefix(80))")
            return docx
        }
        await check("content: budget.xlsx → CSV") {
            let out = try await convert(try fixture("budget.xlsx"), .csv)
            let csv = try text(out[0])
            try expect(csv.contains("Rent") && csv.contains("1200") && csv.contains("Food & drink"), "got: \(csv)")
            return out
        }
        await check("content: book.epub → TXT has both chapters in order") {
            let out = try await convert(try fixture("book.epub"), .txt)
            let body = try text(out[0])
            guard let one = body.range(of: "First chapter text"), let two = body.range(of: "Second chapter text") else {
                throw ConversionError("got: \(body.prefix(120))")
            }
            try expect(one.lowerBound < two.lowerBound, "chapters out of order")
            return out
        }
        await check("content: report.docx → PDF has the text") {
            let out = try await convert(try fixture("report.docx"), .pdf)
            let pdfText = PDFDocument(url: out[0])?.string ?? ""
            try expect(pdfText.contains("Hello from Transmute"), "got: \(pdfText.prefix(80))")
            return out
        }

        // Archives made by macOS tools open, and archives made here round-trip byte for byte.
        await check("archive: bundle.zip (made by ditto) extracts") {
            let out = try await convert(try fixture("bundle.zip"), .extract)
            let note = out[0].appendingPathComponent("stuff/note.txt")
            let same = try Data(contentsOf: note) == Data(contentsOf: try fixture("note.txt"))
            try expect(same, "note.txt differs")
            return out
        }
        await check("archive: backup.tar.gz (made by tar) extracts") {
            let out = try await convert(try fixture("backup.tar.gz"), .extract)
            let png = out[0].appendingPathComponent("stuff/sample.png")
            let same = try Data(contentsOf: png) == Data(contentsOf: try fixture("sample.png"))
            try expect(same, "sample.png differs")
            return out
        }
        for format in [OutputFormat.zip, .tgz] {
            await check("archive: \(format.label) round trip keeps every byte") {
                let sources = [try fixture("photo.jpg"), try fixture("note.txt"), try fixture("clip.mp4")]
                let archive = try await Engine.batch(.archive(format), urls: sources, options: workOptions)
                let dir = try await ArchiveTool.extract(archive, options: workOptions)
                for source in sources {
                    let copy = dir.appendingPathComponent("Archive").appendingPathComponent(source.lastPathComponent)
                    let found = fm.fileExists(atPath: copy.path) ? copy : dir.appendingPathComponent(source.lastPathComponent)
                    let original = try Data(contentsOf: source)
                    try expect((try? Data(contentsOf: found)) == original, "\(source.lastPathComponent) differs")
                }
                return [archive, dir]
            }
        }

        // Tools that take several files.
        await check("tool: Images → PDF makes one page per image") {
            let out = try await Engine.batch(.imagesToPDF, urls: [try fixture("photo.jpg"), try fixture("sample.png")], options: workOptions)
            let pages = PDFDocument(url: out)?.pageCount ?? 0
            try expect(pages == 2, "page count \(pages)")
            return [out]
        }
        let pdfs = made.filter { $0.pathExtension == "pdf" }.prefix(2)
        if pdfs.count == 2 {
            await check("tool: Merge PDFs") {
                let out = try await Engine.batch(.mergePDFs, urls: Array(pdfs), options: workOptions)
                let total = pdfs.compactMap { PDFDocument(url: $0)?.pageCount }.reduce(0, +)
                try expect(PDFDocument(url: out)?.pageCount == total, "expected \(total) pages")
                return [out]
            }
        }
        await check("tool: Join Videos plays both") {
            let clip = try fixture("clip.mp4")
            let out = try await Engine.batch(.joinVideos, urls: [clip, clip], options: workOptions)
            let length = try await AVURLAsset(url: out).load(.duration).seconds
            try expect(abs(length - 6) < 0.5, "length \(length)")
            return [out]
        }
        await check("tool: Read QR Codes") {
            let qr = work.appendingPathComponent("qr.png")
            try makeQRCode("https://example.com/transmute", at: qr)
            let result = try await Engine.perform(.readQR, on: qr, options: workOptions) { _ in }
            try expect(result.message == "https://example.com/transmute", "read \(result.message ?? "nothing")")
            return [qr]
        }

        // Editors.
        await check("editor: photo crop, turn, text and colour") {
            var edit = ImageEdit()
            edit.crop = NormRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
            edit.quarterTurns = 1
            edit.brightness = 0.1
            edit.annotations = [.text("Hi", at: NormPoint(x: 0.5, y: 0.5))]
            let out = try await Engine.perform(.editImage(edit), on: try fixture("photo.jpg"), options: workOptions) { _ in }.outputs
            let image = try ImageConverter.loadCGImage(out[0])
            try expect(image.width == 240 && image.height == 320, "size \(image.width)×\(image.height), expected 240×320")
            return out
        }
        await check("editor: video trim, speed, square crop and turn") {
            var edit = VideoEdit()
            edit.trimStart = 0.5
            edit.trimEnd = 2.5
            edit.speed = 2
            edit.cropAspect = .square
            edit.quarterTurns = 1
            let out = try await Engine.perform(.editVideo(edit), on: try fixture("clip.mp4"), options: workOptions) { _ in }.outputs
            let asset = AVURLAsset(url: out[0])
            let length = try await asset.load(.duration).seconds
            try expect(abs(length - 1) < 0.25, "length \(length), expected 1 s")
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let size = try await track.load(.naturalSize)
                try expect(Int(size.width) == 240 && Int(size.height) == 240, "frame \(size), expected 240×240")
            }
            return out
        }
        await check("editor: video split and mute") {
            var edit = VideoEdit()
            edit.splitAt = 1.5
            edit.mute = true
            let out = try await Engine.perform(.editVideo(edit), on: try fixture("clip.mp4"), options: workOptions) { _ in }.outputs
            try expect(out.count == 2, "\(out.count) files")
            let audio = try await AVURLAsset(url: out[0]).loadTracks(withMediaType: .audio)
            try expect(audio.isEmpty, "still has sound")
            return out
        }
        await check("editor: video snapshot") {
            try await Engine.perform(.snapshot(seconds: 1), on: try fixture("clip.mp4"), options: workOptions) { _ in }.outputs
        }
        await check("editor: audio trim, fades, bleep, mono and loudness") {
            var edit = AudioEdit()
            edit.trimStart = 0.5
            edit.trimEnd = 2
            edit.fadeIn = 0.2
            edit.fadeOut = 0.2
            edit.bleeps = [AudioEdit.BleepRange(start: 1, end: 1.2)]
            edit.channels = .mono
            edit.normalize = true
            edit.outputFormat = .wav
            let out = try await Engine.perform(.editAudio(edit), on: try fixture("song.mp3"), options: workOptions) { _ in }.outputs
            let file = try AVAudioFile(forReading: out[0])
            let seconds = Double(file.length) / file.fileFormat.sampleRate
            try expect(abs(seconds - 1.5) < 0.1, "length \(seconds), expected 1.5 s")
            try expect(file.fileFormat.channelCount == 1, "\(file.fileFormat.channelCount) channels")
            return out
        }
        for format in [OutputFormat.m4a, .flac, .aiff] {
            await check("editor: audio saved as \(format.label)") {
                var edit = AudioEdit()
                edit.volumeDB = -6
                edit.outputFormat = format
                return try await Engine.perform(.editAudio(edit), on: try fixture("tone.wav"), options: workOptions) { _ in }.outputs
            }
        }
        await check("editor: tags written to MP4 read back") {
            var edit = MetadataEdit()
            edit.changes = ["title": "Transmute Test", "artist": "Self Test"]
            let out = try await Engine.perform(.writeMetadata(edit), on: try fixture("clip.mp4"), options: workOptions) { _ in }.outputs
            let fields = try await MetadataTool.read(out[0])
            try expect(fields.contains { $0.key == "title" && $0.value == "Transmute Test" }, "title missing")
            return out
        }
        await check("editor: photo description written and read back") {
            var edit = MetadataEdit()
            edit.changes = ["description": "Self test photo"]
            let out = try await Engine.perform(.writeMetadata(edit), on: try fixture("photo.jpg"), options: workOptions) { _ in }.outputs
            let fields = try await MetadataTool.read(out[0])
            try expect(fields.contains { $0.key == "description" && $0.value == "Self test photo" }, "description missing")
            return out
        }

        let summary = "\nRESULT: \(passed) passed, \(failed.count) failed, \(skipped) skipped"
        say(summary)
        if !failed.isEmpty { say("Failed:\n" + failed.map { "  - \($0)" }.joined(separator: "\n")) }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? log.write(to: documents.appendingPathComponent("selftest.log"), atomically: true, encoding: .utf8)
        return failed.count
    }

    private static func exercise(_ input: URL, options: ConversionOptions) async {
        let name = input.lastPathComponent
        if !Mobile.canOpen(input) {
            skipped += 1
            say("SKIP  \(name): can't be opened on iPhone; only archiving is offered")
        }
        for format in Mobile.targets(for: input) {
            await check("\(name) → \(format.label)") {
                try await Engine.perform(.convert(format), on: input, options: options) { _ in }.outputs
            }
        }
        if Mobile.canCompress(input) {
            await check("\(name) compress 50%") {
                try await Engine.perform(.compress(.percent(0.5)), on: input, options: options) { _ in }.outputs
            }
        }
        if Mobile.canStripMetadata(input) {
            await check("\(name) remove metadata") {
                try await Engine.perform(.stripMetadata, on: input, options: options) { _ in }.outputs
            }
        }
        if FileKind.of(input) == .pdf {
            await check("\(name) split pages") {
                try await Engine.perform(.splitPDF, on: input, options: options) { _ in }.outputs
            }
        }
        if Mobile.hasInfo(input) {
            await check("\(name) info") {
                let fields = try await MetadataTool.read(input)
                if fields.count < 2 { throw ConversionError("only \(fields.count) fields") }
                return []
            }
        }
    }

    private static func check(_ name: String, _ body: @escaping () async throws -> [URL]) async {
        let started = Date()
        func timed() -> String { "\(name) [\(String(format: "%.1f", Date().timeIntervalSince(started))) s]" }
        do {
            let outputs = try await withTimeout(180, body)
            for url in outputs {
                if let problem = problem(with: url) { throw ConversionError(problem) }
            }
            record(timed(), outputs, nil)
        } catch {
            record(timed(), nil, error.localizedDescription)
        }
    }

    private static func record(_ name: String, _ outputs: [URL]?, _ error: String?) {
        if let error {
            failed.append(name)
            say("FAIL  \(name): \(error)")
        } else {
            passed += 1
            let detail = (outputs ?? []).map { "\($0.lastPathComponent) (\(OutputPaths.fileSize($0).formattedSize))" }
            say("PASS  \(name)\(detail.isEmpty ? "" : " → " + detail.joined(separator: ", "))")
        }
    }

    private static func say(_ line: String) {
        print(line)
        log += line + "\n"
        // Saved after every line, so a run that hangs or crashes still leaves its record.
        try? log.write(to: logFile, atomically: true, encoding: .utf8)
    }

    private static let logFile = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("selftest.log")

    /// Runs `body`, failing it if it takes longer than `seconds` so one stuck check can't stall the rest.
    private static func withTimeout(_ seconds: Double, _ body: @escaping () async throws -> [URL]) async throws -> [URL] {
        let once = Once()
        return try await withCheckedThrowingContinuation { (done: CheckedContinuation<[URL], Error>) in
            let work = Task {
                do {
                    let result = try await body()
                    if once.claim() { done.resume(returning: result) }
                } catch {
                    if once.claim() { done.resume(throwing: error) }
                }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.claim() {
                    work.cancel()
                    done.resume(throwing: ConversionError("still running after \(Int(seconds)) s"))
                }
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    private static func problem(with url: URL) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return "output missing: \(url.lastPathComponent)"
        }
        if isDir.boolValue {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            return contents.isEmpty ? "output folder is empty: \(url.lastPathComponent)" : nil
        }
        if OutputPaths.fileSize(url) == 0 { return "output is empty: \(url.lastPathComponent)" }
        let ext = url.pathExtension.lowercased()
        if ["jpg", "png", "heic", "tiff", "bmp", "gif", "webp"].contains(ext) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                return "output image doesn't decode: \(url.lastPathComponent)"
            }
        }
        if ext == "pdf", PDFDocument(url: url) == nil { return "output PDF doesn't open: \(url.lastPathComponent)" }
        return nil
    }

    private static func makeQRCode(_ text: String, at url: URL) throws {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw ConversionError("no QR generator") }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let small = filter.outputImage else { throw ConversionError("QR generation failed") }
        let image = small.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cg = CIContext().createCGImage(image, from: image.extent) else { throw ConversionError("QR render failed") }
        let pad = 48
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: cg.width + pad * 2, height: cg.height + pad * 2, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ConversionError("QR canvas failed") }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.draw(cg, in: CGRect(x: pad, y: pad, width: cg.width, height: cg.height))
        guard let padded = ctx.makeImage() else { throw ConversionError("QR canvas failed") }
        try ImageConverter.data(from: padded, type: .png).write(to: url)
    }
}
