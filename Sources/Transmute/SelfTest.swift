import AppKit
import CoreImage
import ImageIO
import PDFKit

/// Headless check that runs every conversion on a folder of sample files:
///   Spinform.app/Contents/MacOS/Spinform --selftest <folder>
/// Prints PASS/FAIL per conversion and exits non-zero if anything failed.
/// The build server runs this; it's also handy after changing a converter.
@MainActor
enum SelfTest {
    static func start(inputDir: URL) -> Never {
        _ = NSApplication.shared
        Task { @MainActor in
            let failures = await run(inputDir: inputDir)
            exit(failures == 0 ? 0 : 1)
        }
        // Not dispatchMain(): that exits the main thread, so @MainActor work (like the HTML
        // importer, which needs the real main thread) would run on a background thread.
        RunLoop.main.run()
        exit(1)
    }

    private static var passed = 0
    private static var skipped = 0
    private static var failed: [String] = []

    /// HEIC encoding needs a hardware HEVC encoder, which macOS virtual machines
    /// (like GitHub's Apple-silicon runners) don't have.
    private static let canWriteHEIC: Bool = {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        guard let image = ctx.makeImage() else { return false }
        return (try? ImageConverter.data(from: image, type: .heic)) != nil
    }()

    static func run(inputDir: URL) async -> Int {
        let fm = FileManager.default
        let outDir = fm.temporaryDirectory.appendingPathComponent("transmute-selftest-\(UUID().uuidString)")
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let options = ConversionOptions(quality: 0.8, outputFolder: outDir, stripMetadata: false)
        print("ffmpeg: \(Tools.ffmpeg ?? "not available")")
        print("HEIC encoder: \(canWriteHEIC ? "available" : "missing, HEIC cases skipped")")
        print("output: \(outDir.path)\n")

        let inputs = ((try? fm.contentsOfDirectory(at: inputDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        wheelLayoutChecks()
        brandChecks()

        // Pass 1: every input through every operation it supports.
        for input in inputs {
            await exercise(input, options: options)
        }

        // Pass 2: PDFs made in pass 1 become inputs (the fixtures don't include one).
        let madePDFs = ((try? fm.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "pdf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let pdfDir = outDir.appendingPathComponent("pdf-pass")
        try? fm.createDirectory(at: pdfDir, withIntermediateDirectories: true)
        var pdfOptions = options
        pdfOptions.outputFolder = pdfDir
        let textNames = ["note", "readme", "letter", "report", "page"]
        let textPDF = madePDFs.first { textNames.contains($0.deletingPathExtension().lastPathComponent) } ?? madePDFs.first
        if let pdf = textPDF {
            await exercise(pdf, options: pdfOptions)
        } else {
            record("PDF inputs", nil, "no PDF was produced in pass 1")
        }

        // The same for an EPUB made from a document in pass 1.
        let madeEPUB = ((try? fm.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "epub" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
        let epubDir = outDir.appendingPathComponent("epub-pass")
        try? fm.createDirectory(at: epubDir, withIntermediateDirectories: true)
        var epubOptions = options
        epubOptions.outputFolder = epubDir
        if let epub = madeEPUB {
            await exercise(epub, options: epubOptions)
        } else {
            record("EPUB inputs", nil, "no EPUB was produced in pass 1")
        }

        // A 30 MB-style PDF of photos must really shrink (beta testers got "already as small as it gets").
        await check("Photo PDF compress 50% is at most 60% of the original") {
            let pdf = outDir.appendingPathComponent("photo scan.pdf")
            try makePhotoPDF(pdf, pages: 3, width: 2400, height: 3200)
            let before = OutputPaths.fileSize(pdf)
            let result = try await Engine.perform(.compress(.percent(0.5)), on: pdf, options: options) { _ in }
            guard let out = result.outputs.first else { throw ConversionError("no output") }
            let after = OutputPaths.fileSize(out)
            guard Double(after) <= Double(before) * 0.6 else {
                throw ConversionError("\(before.formattedSize) → \(after.formattedSize): \(result.message ?? "")")
            }
            guard PDFDocument(url: out)?.pageCount == 3 else { throw ConversionError("pages went missing") }
            print("      \(result.message ?? "")")
            return result.outputs
        }

        // Office / e-book content checks (OfficeConverter.swift).
        let officeDir = outDir.appendingPathComponent("office-content")
        try? FileManager.default.createDirectory(at: officeDir, withIntermediateDirectories: true)
        var officeOptions = options
        officeOptions.outputFolder = officeDir
        func officeConvert(_ url: URL, _ f: OutputFormat) async throws -> [URL] {
            try await Engine.perform(.convert(f), on: url, options: officeOptions) { _ in }.outputs
        }
        func officeText(_ url: URL) throws -> String {
            try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
        }
        func officeFixture(_ name: String) throws -> URL {
            guard let u = inputs.first(where: { $0.lastPathComponent == name }) else { throw ConversionError("fixture \(name) missing") }
            return u
        }
        func unzipMember(_ zip: URL, _ member: String) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-p", zip.path, member]
            let pipe = Pipe()
            p.standardOutput = pipe
            try p.run()
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: d, as: UTF8.self)
        }

        await check("office: budget.xlsx → csv content") {
            let out = try await officeConvert(try officeFixture("budget.xlsx"), .csv)
            guard let f = out.first else { throw ConversionError("no output") }
            let got = try officeText(f)
            guard got == "Item,Cost,\nRent,1200,\nFood & drink,,310.5\n" else { throw ConversionError("CSV was \(got.debugDescription)") }
            return out
        }
        await check("office: table.csv → xlsx → csv keeps quoted comma") {
            let xlsx = try await officeConvert(try officeFixture("table.csv"), .xlsx)
            let sheet = try unzipMember(xlsx[0], "xl/worksheets/sheet1.xml")
            guard sheet.contains("<v>12</v>"), sheet.contains("Pears, green") else { throw ConversionError("sheet XML: \(sheet.prefix(300))") }
            let back = try await officeConvert(xlsx[0], .csv)
            guard try officeText(back[0]).contains("\"Pears, green\",12,0.8") else { throw ConversionError("round trip lost the quoted comma") }
            return xlsx + back
        }
        await check("office: note.txt → epub → txt") {
            let epub = try await officeConvert(try officeFixture("note.txt"), .epub)
            let bytes = try Data(contentsOf: epub[0])
            guard bytes.count > 58,
                  String(decoding: bytes[30..<38], as: UTF8.self) == "mimetype",
                  String(decoding: bytes[38..<58], as: UTF8.self) == "application/epub+zip" else { throw ConversionError("bad OCF header") }
            let txt = try await officeConvert(epub[0], .txt)
            let s = try officeText(txt[0])
            guard s.contains("Hello from Transmute"), s.contains("Second paragraph.") else { throw ConversionError("text was: \(s.prefix(200))") }
            return epub + txt
        }
        await check("office: html → epub markup") {
            let html = officeDir.appendingPathComponent("styled.html")
            try "<html><body><h1>Title</h1><p>Some <b>bold</b> and <i>italic</i> &amp; more.</p></body></html>"
                .write(to: html, atomically: true, encoding: .utf8)
            let epub = try await officeConvert(html, .epub)
            let chapter = try unzipMember(epub[0], "OEBPS/chapter1.xhtml")
            for needle in ["<h1", "<strong>bold</strong>", "<em>italic</em>", "&amp;"] where !chapter.contains(needle) {
                throw ConversionError("chapter1.xhtml lacks \(needle)")
            }
            for member in ["META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml", "OEBPS/chapter1.xhtml"] {
                let parser = XMLParser(data: Data(try unzipMember(epub[0], member).utf8))
                guard parser.parse() else { throw ConversionError("\(member) is not well-formed") }
            }
            return epub
        }
        await check("office: book.epub → txt/html") {
            let book = try officeFixture("book.epub")
            let txt = try await officeConvert(book, .txt)
            let html = try await officeConvert(book, .html)
            let s = try officeText(txt[0])
            let h = try officeText(html[0])
            guard let a = s.range(of: "First chapter text."), let b = s.range(of: "Second chapter text."),
                  a.lowerBound < b.lowerBound else { throw ConversionError("chapters out of order") }
            guard h.contains("data:image/png;base64,"), h.contains("href=\"#end\"") else { throw ConversionError("HTML missing image/link") }
            return txt + html
        }
        await check("office: tsv → csv/xlsx") {
            let tsv = officeDir.appendingPathComponent("tabs.tsv")
            try "A\tB\n1\tx, y\n".write(to: tsv, atomically: true, encoding: .utf8)
            let csv = try await officeConvert(tsv, .csv)
            let got = try officeText(csv[0])
            guard got == "A,B\n1,\"x, y\"\n" else { throw ConversionError("TSV→CSV: \(got.debugDescription)") }
            let xlsx = try await officeConvert(tsv, .xlsx)
            return csv + xlsx
        }
        await check("office: .pages preview → txt (no Pages needed)") {
            let pdf = try await officeConvert(try officeFixture("note.txt"), .pdf)
            let pkg = officeDir.appendingPathComponent("preview.pages")
            try FileManager.default.createDirectory(at: pkg.appendingPathComponent("QuickLook"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: pdf[0], to: pkg.appendingPathComponent("QuickLook/Preview.pdf"))
            let txt = try await officeConvert(pkg, .txt)
            guard try officeText(txt[0]).contains("Hello from Transmute") else { throw ConversionError("preview text missing") }
            return txt
        }
        await check("office: missing iWork app gives a clear error") {
            let note = try officeFixture("note.txt")
            guard OfficeConverter.requiredApp(for: note, to: .pages) != nil else { return [] } // Pages installed: nothing to test
            do {
                _ = try await officeConvert(note, .pages)
            } catch {
                guard error.localizedDescription.contains("Pages") else { throw error }
                return []
            }
            throw ConversionError("expected an error without Pages")
        }

        // Multi-file tools.
        let images = inputs.filter { FileKind.of($0) == .image }
        await check("Merge PDFs") {
            guard madePDFs.count >= 2 else { throw ConversionError("need two PDFs, got \(madePDFs.count)") }
            let merged = try await Engine.batch(.mergePDFs, urls: Array(madePDFs.prefix(2)), options: pdfOptions)
            return [merged]
        }
        await check("Images → PDF") {
            let pdf = try await Engine.batch(.imagesToPDF, urls: images, options: options)
            return [pdf]
        }
        await check("Zip several files") {
            let zip = try await Engine.batch(.archive(.zip), urls: Array(inputs.prefix(3)), options: options)
            return [zip]
        }

        // Photo editor: every image fixture through the whole pipeline.
        for image in inputs where FileKind.of(image) == .image {
            await check("\(image.lastPathComponent) photo edit") {
                let keep = NormRect(x: 0.1, y: 0.1, width: 0.6, height: 0.7)
                var edit = ImageEdit()
                edit.crop = keep
                edit.quarterTurns = 1
                edit.flipHorizontal = true
                edit.brightness = 0.05
                edit.contrast = 1.1
                edit.saturation = 0.8
                edit.exposure = 0.2
                edit.redactions = [
                    ImageEdit.Redaction(rect: NormRect(x: 0.15, y: 0.15, width: 0.2, height: 0.1), style: .blackout),
                    ImageEdit.Redaction(rect: NormRect(x: 0.4, y: 0.15, width: 0.2, height: 0.2), style: .pixelate),
                    ImageEdit.Redaction(rect: NormRect(x: 0.15, y: 0.4, width: 0.2, height: 0.2), style: .blur),
                ]
                edit.annotations = [
                    .text("Transmute", at: NormPoint(x: 0.2, y: 0.6), size: 0.06),
                    .rectangle(NormRect(x: 0.3, y: 0.3, width: 0.3, height: 0.2)),
                    .arrow(from: NormPoint(x: 0.6, y: 0.7), to: NormPoint(x: 0.4, y: 0.4)),
                    .highlight(NormRect(x: 0.2, y: 0.5, width: 0.4, height: 0.05)),
                ]
                let result = try await Engine.perform(.editImage(edit), on: image, options: options) { _ in }
                guard let out = result.outputs.first else { throw ConversionError("no output") }
                let original = try ImageConverter.loadCGImage(image)
                let kept = keep.pixelRect(width: original.width, height: original.height)
                let edited = try ImageConverter.loadCGImage(out)
                // Cropped, then turned sideways.
                guard edited.width == Int(kept.height), edited.height == Int(kept.width) else {
                    throw ConversionError("expected \(Int(kept.height))×\(Int(kept.width)), got \(edited.width)×\(edited.height)")
                }
                return result.outputs
            }
        }

        // Photo editor: exact geometry, redaction, annotation and colour on a canvas we draw.
        await check("Photo editor: turn, flip, black box, box outline, brightness") {
            let canvas = outDir.appendingPathComponent("editor-canvas.png")
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw ConversionError("no canvas")
            }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
            guard let white = ctx.makeImage() else { throw ConversionError("no canvas") }
            try ImageConverter.data(from: white, type: .png).write(to: canvas)

            func isBlack(_ c: RGBAColor) -> Bool { c.red < 0.1 && c.green < 0.1 && c.blue < 0.1 }
            func isWhite(_ c: RGBAColor) -> Bool { c.red > 0.9 && c.green > 0.9 && c.blue > 0.9 }
            var outputs: [URL] = []

            // Black box over the top-left quarter, turned clockwise: 400×200 → 200×400, box ends up top-right.
            var edit = ImageEdit()
            edit.redactions = [ImageEdit.Redaction(rect: NormRect(x: 0, y: 0, width: 0.25, height: 0.5), style: .blackout)]
            edit.quarterTurns = 1
            let turned = try await Engine.perform(.editImage(edit), on: canvas, options: options) { _ in }.outputs
            guard let a = turned.first else { throw ConversionError("no output") }
            let turnedImage = try ImageConverter.loadCGImage(a)
            guard turnedImage.width == 200, turnedImage.height == 400 else {
                throw ConversionError("turned size \(turnedImage.width)×\(turnedImage.height)")
            }
            let topRight = try ImageEditEngine.samplePixel(a, at: NormPoint(x: 0.75, y: 0.125))
            let topLeft = try ImageEditEngine.samplePixel(a, at: NormPoint(x: 0.25, y: 0.125))
            guard isBlack(topRight), isWhite(topLeft) else { throw ConversionError("rotation went the wrong way") }
            outputs += turned

            // Then mirrored on screen: the box moves to the top-left.
            edit.flipHorizontal = true
            let flipped = try await Engine.perform(.editImage(edit), on: canvas, options: options) { _ in }.outputs
            guard let b = flipped.first else { throw ConversionError("no output") }
            let flippedLeft = try ImageEditEngine.samplePixel(b, at: NormPoint(x: 0.25, y: 0.125))
            let flippedRight = try ImageEditEngine.samplePixel(b, at: NormPoint(x: 0.75, y: 0.125))
            guard isBlack(flippedLeft), isWhite(flippedRight) else { throw ConversionError("flip went the wrong way") }
            outputs += flipped

            // A box outline along the top edge must land at the top (catches a y-axis flip).
            var marked = ImageEdit()
            marked.annotations = [.rectangle(NormRect(x: 0.5, y: 0, width: 0.25, height: 0.25), lineWidth: 0.05, color: .black)]
            let boxed = try await Engine.perform(.editImage(marked), on: canvas, options: options) { _ in }.outputs
            guard let c = boxed.first else { throw ConversionError("no output") }
            let edge = try ImageEditEngine.samplePixel(c, at: NormPoint(x: 0.625, y: 0.01))
            let inside = try ImageEditEngine.samplePixel(c, at: NormPoint(x: 0.625, y: 0.125))
            let bottom = try ImageEditEngine.samplePixel(c, at: NormPoint(x: 0.625, y: 0.99))
            guard isBlack(edge), isWhite(inside), isWhite(bottom) else { throw ConversionError("annotation landed in the wrong place") }
            outputs += boxed

            // Crop to the right half, darken, save as JPEG.
            var dim = ImageEdit()
            dim.crop = NormRect(x: 0.5, y: 0, width: 0.5, height: 1)
            dim.brightness = -0.5
            dim.outputFormat = .jpeg
            let dimmed = try await Engine.perform(.editImage(dim), on: canvas, options: options) { _ in }.outputs
            guard let d = dimmed.first, d.pathExtension == "jpg" else { throw ConversionError("expected a JPEG") }
            let dimmedImage = try ImageConverter.loadCGImage(d)
            guard dimmedImage.width == 200, dimmedImage.height == 200 else {
                throw ConversionError("cropped size \(dimmedImage.width)×\(dimmedImage.height)")
            }
            let centre = try ImageEditEngine.samplePixel(d, at: NormPoint(x: 0.5, y: 0.5))
            guard centre.red < 0.85, centre.red > 0.2 else { throw ConversionError("brightness not applied (\(centre.red))") }
            outputs += dimmed
            return outputs
        }

        // Video editor, snapshots and joining (need ffmpeg and the clip.mp4 / movie.mkv fixtures).
        let editClip = inputs.first { $0.lastPathComponent == "clip.mp4" }
        let editMovie = inputs.first { $0.lastPathComponent == "movie.mkv" }
        if let ffmpeg = Tools.ffmpeg, let editClip, let editMovie {
            /// Checks length (within 0.3 s), frame size and whether there's a sound track.
            func expectVideo(_ url: URL, seconds: Double, width: Int, height: Int, audio: Bool) async throws {
                let length = await MediaInfo.duration(of: url)
                guard abs(length - seconds) < 0.3 else {
                    throw ConversionError("\(url.lastPathComponent) is \(length) s long, expected \(seconds) s")
                }
                guard let size = await VideoEditEngine.frameSize(of: url, ffmpeg: ffmpeg),
                      size.width == width, size.height == height else {
                    throw ConversionError("\(url.lastPathComponent) isn't \(width)×\(height)")
                }
                let hasAudio = await VideoEditEngine.hasAudioTrack(url, ffmpeg: ffmpeg)
                guard hasAudio == audio else {
                    throw ConversionError("\(url.lastPathComponent) \(audio ? "lost its sound" : "still has sound")")
                }
            }
            await check("clip.mp4 edit: trim, 2× speed, 9:16 crop, rotate, flip, louder") {
                var edit = VideoEdit()
                edit.trimStart = 0.5
                edit.trimEnd = 2.5
                edit.speed = 2
                edit.cropAspect = .portrait9x16
                edit.quarterTurns = 1
                edit.flipHorizontal = true
                edit.volume = 1.5
                let outputs = try await Engine.perform(.editVideo(edit), on: editClip, options: options) { _ in }.outputs
                guard outputs.count == 1, let out = outputs.first else { throw ConversionError("expected 1 file, got \(outputs.count)") }
                // 320×240 cropped to 9:16 is 134×240; a quarter turn makes it 240×134. 2 s at 2× is 1 s.
                try await expectVideo(out, seconds: 1, width: 240, height: 134, audio: true)
                return outputs
            }
            await check("movie.mkv edit: split at 1 s, half speed, muted, WebM") {
                var edit = VideoEdit()
                edit.speed = 0.5
                edit.mute = true
                edit.splitAt = 1
                edit.outputFormat = .webm
                let outputs = try await Engine.perform(.editVideo(edit), on: editMovie, options: options) { _ in }.outputs
                guard outputs.count == 2 else { throw ConversionError("expected 2 parts, got \(outputs.count)") }
                // 0–1 s and 1–3 s, each played at half speed.
                try await expectVideo(outputs[0], seconds: 2, width: 320, height: 240, audio: false)
                try await expectVideo(outputs[1], seconds: 4, width: 320, height: 240, audio: false)
                return outputs
            }
            await check("clip.mp4 edit: 4× speed keeps the sound") {
                var edit = VideoEdit()
                edit.speed = 4
                let outputs = try await Engine.perform(.editVideo(edit), on: editClip, options: options) { _ in }.outputs
                guard let out = outputs.first else { throw ConversionError("no output") }
                try await expectVideo(out, seconds: 0.75, width: 320, height: 240, audio: true)
                return outputs
            }
            await check("Video edit rejects a split point outside the trim") {
                var edit = VideoEdit()
                edit.trimEnd = 1
                edit.splitAt = 2
                do {
                    _ = try await Engine.perform(.editVideo(edit), on: editClip, options: options) { _ in }
                } catch {
                    return []
                }
                throw ConversionError("expected an error")
            }
            await check("clip.mp4 snapshot at 1.25 s (AVFoundation)") {
                let outputs = try await Engine.perform(.snapshot(seconds: 1.25), on: editClip, options: options) { _ in }.outputs
                guard let png = outputs.first, try ImageConverter.loadCGImage(png).width == 320 else {
                    throw ConversionError("snapshot isn't 320 px wide")
                }
                return outputs
            }
            await check("movie.mkv snapshot at 2 s (ffmpeg fallback)") {
                let outputs = try await Engine.perform(.snapshot(seconds: 2), on: editMovie, options: options) { _ in }.outputs
                guard let png = outputs.first, try ImageConverter.loadCGImage(png).width == 320 else {
                    throw ConversionError("snapshot isn't 320 px wide")
                }
                return outputs
            }
            await check("Join three videos of different sizes, one silent") {
                let silent = outDir.appendingPathComponent("silent portrait.mov")
                try await Shell.check(ffmpeg, ["-hide_banner", "-nostdin", "-y", "-f", "lavfi",
                                               "-i", "testsrc=duration=2:size=240x320:rate=30",
                                               "-c:v", "libx264", "-pix_fmt", "yuv420p", silent.path])
                let joined = try await Engine.batch(.joinVideos, urls: [editClip, silent, editMovie], options: options)
                // 3 + 2 + 3 s in the first clip's 320×240 frame, with sound.
                try await expectVideo(joined, seconds: 8, width: 320, height: 240, audio: true)
                return [joined]
            }
        } else {
            skipped += 1
            print("SKIP  video editor: needs ffmpeg and the clip.mp4 / movie.mkv fixtures")
        }

        // Audio editor. The waveform also works without ffmpeg (AVAssetReader), so it runs in both passes.
        let audioTone = inputs.first { $0.lastPathComponent == "tone.wav" }
        let audioSong = inputs.first { $0.lastPathComponent == "song.mp3" }
        let audioClip = inputs.first { $0.lastPathComponent == "clip.mp4" }
        if let audioTone {
            await check("tone.wav waveform") {
                let levels = try await AudioEditEngine.waveform(of: audioTone, buckets: 50)
                // A steady 440 Hz tone at 1/8 of full scale: every bar about 0.125.
                guard levels.count == 50, let low = levels.min(), let high = levels.max(), low > 0.08, high < 0.2 else {
                    throw ConversionError("expected 50 even bars near 0.125, got \(levels.count) from \(levels.min() ?? 0) to \(levels.max() ?? 0)")
                }
                return []
            }
        } else {
            skipped += 1
            print("SKIP  waveform: no tone.wav fixture")
        }
        if let ffmpeg = Tools.ffmpeg, let audioTone, let audioSong, let audioClip {
            /// Checks there's one output with the right extension, length (within `slack` s) and channel count.
            func expectAudio(_ outputs: [URL], ext: String, seconds: Double, channels: Int,
                             slack: Double = 0.1) async throws -> URL {
                guard outputs.count == 1, let out = outputs.first else {
                    throw ConversionError("expected 1 file, got \(outputs.count)")
                }
                guard out.pathExtension == ext else { throw ConversionError("\(out.lastPathComponent) isn't .\(ext)") }
                let length = await MediaInfo.duration(of: out)
                guard abs(length - seconds) <= slack else {
                    throw ConversionError("\(out.lastPathComponent) is \(length) s long, expected \(seconds) s")
                }
                let found = await AudioEditEngine.soundTrack(of: out, ffmpeg: ffmpeg)?.channels
                guard found == channels else {
                    let count = found.map { String($0) } ?? "no"
                    throw ConversionError("\(out.lastPathComponent) has \(count) channels, expected \(channels)")
                }
                return out
            }
            /// Peak level 0…1 of one channel (0 is left).
            func channelPeak(_ url: URL, channel: Int) async throws -> Float {
                let raw = outDir.appendingPathComponent("channel \(UUID().uuidString).pcm")
                defer { try? FileManager.default.removeItem(at: raw) }
                try await Shell.check(ffmpeg, ["-hide_banner", "-nostdin", "-loglevel", "error", "-i", url.path,
                                               "-af", "pan=mono|c0=c\(channel)", "-f", "s16le", "-"], stdoutFile: raw)
                let data = try Data(contentsOf: raw)
                return AudioEditEngine.peaks(ofPCM16: data, buckets: 1).first ?? 0
            }
            await check("tone.wav audio edit: trim, fade in and out, −6 dB") {
                var edit = AudioEdit()
                edit.trimStart = 0.5
                edit.trimEnd = 2.5
                edit.fadeIn = 0.5
                edit.fadeOut = 0.5
                edit.volumeDB = -6
                let outputs = try await Engine.perform(.editAudio(edit), on: audioTone, options: options) { _ in }.outputs
                let out = try await expectAudio(outputs, ext: "wav", seconds: 2, channels: 1)
                // 0.1 s bars: quiet at both ends, half the original 1/8 level in the middle.
                let levels = try await AudioEditEngine.waveform(of: out, buckets: 20)
                guard levels.count == 20, levels[0] < 0.03, levels[19] < 0.03, levels[10] > 0.05, levels[10] < 0.075 else {
                    throw ConversionError("unexpected levels \(levels)")
                }
                return outputs
            }
            await check("song.mp3 audio edit: two bleeps, stereo, FLAC") {
                var edit = AudioEdit()
                edit.bleeps = [AudioEdit.BleepRange(start: 0.5, end: 1), AudioEdit.BleepRange(start: 2, end: 2.5)]
                edit.channels = .stereo
                edit.outputFormat = .flac
                let outputs = try await Engine.perform(.editAudio(edit), on: audioSong, options: options) { _ in }.outputs
                let out = try await expectAudio(outputs, ext: "flac", seconds: 3, channels: 2, slack: 0.15)
                // The bleeps are a tone at twice the song's level; everything else is untouched.
                let levels = try await AudioEditEngine.waveform(of: out, buckets: 30)
                guard levels.count == 30, levels[7] > 0.2, levels[22] > 0.2,
                      levels[2] < 0.16, levels[15] < 0.16, levels[27] < 0.16 else {
                    throw ConversionError("bleeps not where expected: \(levels)")
                }
                return outputs
            }
            await check("clip.mp4 audio edit: trim, bleep, stereo WAV") {
                var edit = AudioEdit()
                edit.trimStart = 0.5
                edit.trimEnd = 2.5
                edit.bleeps = [AudioEdit.BleepRange(start: 1, end: 1.5)]  // on the original timeline
                edit.channels = .stereo
                edit.outputFormat = .wav
                let outputs = try await Engine.perform(.editAudio(edit), on: audioClip, options: options) { _ in }.outputs
                let out = try await expectAudio(outputs, ext: "wav", seconds: 2, channels: 2)
                // So the tone is 0.5–1.0 s into the trimmed result.
                let levels = try await AudioEditEngine.waveform(of: out, buckets: 20)
                guard levels.count == 20, levels[7] > 0.2, levels[2] < 0.16, levels[14] < 0.16 else {
                    throw ConversionError("bleep not where expected: \(levels)")
                }
                return outputs
            }
            await check("clip.mp4 audio edit: normalize to −16 LUFS (M4A)") {
                var edit = AudioEdit()
                edit.normalize = true
                let outputs = try await Engine.perform(.editAudio(edit), on: audioClip, options: options) { _ in }.outputs
                let out = try await expectAudio(outputs, ext: "m4a", seconds: 3, channels: 1, slack: 0.15)
                let report = try await Shell.run(ffmpeg, ["-hide_banner", "-nostdin", "-nostats", "-i", out.path,
                                                          "-af", "ebur128", "-f", "null", "-"])
                let summary = report.stderr.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .last { $0.hasPrefix("I:") && $0.hasSuffix("LUFS") }
                guard let summary, let lufs = Double(summary.dropFirst(2).dropLast(4).trimmingCharacters(in: .whitespaces)),
                      abs(lufs + 16) < 1.5 else {
                    throw ConversionError("integrated loudness \(summary ?? "unknown"), expected −16 LUFS")
                }
                return outputs
            }
            for format in AudioEditEngine.editableFormats {
                await check("tone.wav audio edit → \(format.label)") {
                    var edit = AudioEdit()
                    edit.trimEnd = 1.5
                    edit.outputFormat = format
                    let outputs = try await Engine.perform(.editAudio(edit), on: audioTone, options: options) { _ in }.outputs
                    _ = try await expectAudio(outputs, ext: format.fileExtension, seconds: 1.5, channels: 1)
                    return outputs
                }
            }
            await check("Audio edit: swap left and right, then mono") {
                let rightOnly = outDir.appendingPathComponent("right only.wav")
                try await Shell.check(ffmpeg, ["-hide_banner", "-nostdin", "-y", "-f", "lavfi",
                                               "-i", "aevalsrc=0|0.25*sin(2*PI*440*t):s=44100:d=2", rightOnly.path])
                var edit = AudioEdit()
                edit.channels = .swapLeftRight
                let swapped = try await Engine.perform(.editAudio(edit), on: rightOnly, options: options) { _ in }.outputs
                let a = try await expectAudio(swapped, ext: "wav", seconds: 2, channels: 2)
                let left = try await channelPeak(a, channel: 0)
                let right = try await channelPeak(a, channel: 1)
                guard left > 0.2, right < 0.01 else { throw ConversionError("left \(left), right \(right) after swapping") }
                edit.channels = .mono
                let mono = try await Engine.perform(.editAudio(edit), on: rightOnly, options: options) { _ in }.outputs
                let b = try await expectAudio(mono, ext: "wav", seconds: 2, channels: 1)
                let level = try await channelPeak(b, channel: 0)
                guard level > 0.1, level < 0.15 else { throw ConversionError("mono level \(level), expected about 0.125") }
                return swapped + mono
            }
            await check("song.mp3 and clip.mp4 waveforms") {
                for url in [audioSong, audioClip] {
                    let levels = try await AudioEditEngine.waveform(of: url, buckets: 100)
                    guard levels.count == 100, let high = levels.max(), high > 0.08, high < 0.2 else {
                        throw ConversionError("\(url.lastPathComponent): unexpected waveform peak \(levels.max() ?? 0)")
                    }
                }
                return []
            }
            await check("Audio edit rejects a start past the end") {
                var edit = AudioEdit()
                edit.trimStart = 10
                do {
                    _ = try await Engine.perform(.editAudio(edit), on: audioTone, options: options) { _ in }
                } catch {
                    return []
                }
                throw ConversionError("expected an error")
            }
            await check("Audio edit rejects a video without sound") {
                let silent = outDir.appendingPathComponent("no sound.mp4")
                try await Shell.check(ffmpeg, ["-hide_banner", "-nostdin", "-y", "-f", "lavfi",
                                               "-i", "testsrc=duration=1:size=160x120:rate=10",
                                               "-c:v", "libx264", "-pix_fmt", "yuv420p", silent.path])
                do {
                    _ = try await Engine.perform(.editAudio(AudioEdit()), on: silent, options: options) { _ in }
                } catch {
                    return []
                }
                throw ConversionError("expected an error")
            }
        } else {
            skipped += 1
            print("SKIP  audio editor: needs ffmpeg and the tone.wav / song.mp3 / clip.mp4 fixtures")
        }

        // Metadata viewer and editor (MetadataEditor.swift).
        let metaPhoto = inputs.first { $0.lastPathComponent == "photo.jpg" }
        let metaPNG = inputs.first { $0.lastPathComponent == "sample.png" }
        let metaWebP = inputs.first { $0.lastPathComponent == "web.webp" }
        let metaSong = inputs.first { $0.lastPathComponent == "song.mp3" }
        let metaClip = inputs.first { $0.lastPathComponent == "clip.mp4" }
        let metaTone = inputs.first { $0.lastPathComponent == "tone.wav" }
        let metaNote = inputs.first { $0.lastPathComponent == "note.txt" }

        /// Reads `url` back and fails unless each key has exactly that value ("" means absent or empty).
        func expectMetadata(_ url: URL, _ expected: [String: String]) async throws {
            let fields = try await MetadataTool.read(url)
            for key in expected.keys.sorted() {
                let found = MetadataTool.value(of: key, in: fields) ?? ""
                guard found == expected[key] else {
                    throw ConversionError("\(url.lastPathComponent): \(key) reads “\(found)”, expected “\(expected[key] ?? "")”")
                }
            }
        }

        await check("Metadata: date taken parsing") {
            let cases: [(String, String?)] = [
                ("2024:05:31 14:30:00", "2024:05:31 14:30:00"), ("2024-05-31 14:30", "2024:05:31 14:30:00"),
                ("2024-05-31", "2024:05:31 00:00:00"), ("2024-05-31T08:05:09Z", "2024:05:31 08:05:09"),
                ("31/05/2024", nil), ("2024-13-01", nil), ("2024-05-31 2:30 PM", nil),
            ]
            for (text, expected) in cases where MetadataTool.exifDate(from: text) != expected {
                throw ConversionError("“\(text)” parsed as \(MetadataTool.exifDate(from: text) ?? "nothing")")
            }
            return []
        }

        if let metaPhoto {
            await check("photo.jpg metadata: write, read back, clear a field") {
                var edit = MetadataEdit()
                edit.changes = ["description": "Harbour at dawn", "artist": "Transmute Test",
                                "copyright": "(c) 2024 Transmute", "dateTaken": "2024-05-31 14:30"]
                let written = try await Engine.perform(.writeMetadata(edit), on: metaPhoto, options: options) { _ in }.outputs
                guard let out = written.first, out.pathExtension == "jpg" else { throw ConversionError("expected a JPEG copy") }
                try await expectMetadata(out, ["description": "Harbour at dawn", "artist": "Transmute Test",
                                               "copyright": "(c) 2024 Transmute", "dateTaken": "2024:05:31 14:30:00"])
                let before = try ImageConverter.loadCGImage(metaPhoto)
                let after = try ImageConverter.loadCGImage(out)
                guard before.width == after.width, before.height == after.height else {
                    throw ConversionError("the picture changed size")
                }
                let cleared = try await Engine.perform(.writeMetadata(MetadataEdit(changes: ["artist": ""])), on: out,
                                                       options: options) { _ in }.outputs
                guard let clean = cleared.first else { throw ConversionError("no output") }
                try await expectMetadata(clean, ["artist": "", "description": "Harbour at dawn"])
                return written + cleared
            }
            await check("Photo metadata: GPS is shown and can be removed") {
                let gpsPhoto = outDir.appendingPathComponent("gps-photo.jpg")
                let pixels = try ImageConverter.loadCGImage(metaPhoto)
                guard let destination = CGImageDestinationCreateWithURL(gpsPhoto as CFURL, "public.jpeg" as CFString, 1, nil) else {
                    throw ConversionError("no JPEG encoder")
                }
                let gps: [CFString: Any] = [
                    kCGImagePropertyGPSLatitude: 51.5007, kCGImagePropertyGPSLatitudeRef: "N",
                    kCGImagePropertyGPSLongitude: 0.1246, kCGImagePropertyGPSLongitudeRef: "W",
                ]
                let tiff: [CFString: Any] = [kCGImagePropertyTIFFMake: "TestCam", kCGImagePropertyTIFFArtist: "Old Artist"]
                let properties: [CFString: Any] = [kCGImagePropertyGPSDictionary: gps, kCGImagePropertyTIFFDictionary: tiff]
                CGImageDestinationAddImage(destination, pixels, properties as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw ConversionError("couldn't write the GPS photo") }
                let fields = try await MetadataTool.read(gpsPhoto)
                guard MetadataTool.hasLocation(fields),
                      MetadataTool.value(of: "gps.longitude", in: fields)?.hasSuffix("W") == true else {
                    throw ConversionError("GPS not read:\n\(MetadataTool.plainText(fields, title: gpsPhoto.lastPathComponent))")
                }
                try await expectMetadata(gpsPhoto, ["artist": "Old Artist", "camera.make": "TestCam"])
                let edit = MetadataEdit(changes: ["artist": "New Artist"], removeLocation: true)
                let outputs = try await Engine.perform(.writeMetadata(edit), on: gpsPhoto, options: options) { _ in }.outputs
                guard let out = outputs.first else { throw ConversionError("no output") }
                let after = try await MetadataTool.read(out)
                guard !MetadataTool.hasLocation(after) else { throw ConversionError("the location is still there") }
                try await expectMetadata(out, ["artist": "New Artist", "camera.make": "TestCam"])
                return outputs
            }
        }

        if let metaPNG {
            await check("sample.png metadata: description and artist") {
                let edit = MetadataEdit(changes: ["description": "Test card", "artist": "Transmute Test"])
                let outputs = try await Engine.perform(.writeMetadata(edit), on: metaPNG, options: options) { _ in }.outputs
                guard let out = outputs.first, out.pathExtension == "png" else { throw ConversionError("expected a PNG copy") }
                try await expectMetadata(out, ["description": "Test card", "artist": "Transmute Test"])
                return outputs
            }
            await check("PDF metadata: title, author, subject, keywords") {
                let pdf = outDir.appendingPathComponent("metadata-test.pdf")
                let picture = try ImageConverter.loadCGImage(metaPNG)
                try ImageConverter.writePDF(picture, to: pdf)
                let edit = MetadataEdit(changes: ["title": "Quarterly Report", "author": "Transmute Test",
                                                  "subject": "Self-test", "keywords": "alpha, beta"])
                let outputs = try await Engine.perform(.writeMetadata(edit), on: pdf, options: options) { _ in }.outputs
                guard let out = outputs.first, out.pathExtension == "pdf" else { throw ConversionError("expected a PDF copy") }
                try await expectMetadata(out, ["title": "Quarterly Report", "author": "Transmute Test",
                                               "subject": "Self-test", "pdf.pages": "1"])
                let fields = try await MetadataTool.read(out)
                let keywords = MetadataTool.value(of: "keywords", in: fields) ?? ""
                guard keywords.contains("alpha"), keywords.contains("beta") else {
                    throw ConversionError("keywords read back as “\(keywords)”")
                }
                return outputs
            }
        }

        if let metaWebP {
            await check("web.webp metadata: readable, writing refused with a clear error") {
                let fields = try await MetadataTool.read(metaWebP)
                guard MetadataTool.value(of: "image.size", in: fields) == "640 × 480 pixels" else {
                    throw ConversionError("size reads “\(MetadataTool.value(of: "image.size", in: fields) ?? "nothing")”")
                }
                guard !fields.contains(where: \.editable) else { throw ConversionError("WebP fields shouldn't be editable") }
                do {
                    _ = try await Engine.perform(.writeMetadata(MetadataEdit(changes: ["artist": "x"])), on: metaWebP,
                                                 options: options) { _ in }
                } catch {
                    guard error.localizedDescription.contains("WEBP") else { throw error }
                    return []
                }
                throw ConversionError("expected an error")
            }
        }

        if let metaNote {
            await check("note.txt info: file facts only") {
                let fields = try await MetadataTool.read(metaNote)
                guard MetadataTool.value(of: "file.size", in: fields) != nil, !fields.contains(where: \.editable) else {
                    throw ConversionError(MetadataTool.plainText(fields, title: "note.txt"))
                }
                return []
            }
        }

        if let metaFFmpeg = Tools.ffmpeg, let metaSong, let metaClip, let metaTone {
            await check("clip.mp4 info: codec, frame size, frame rate, sound") {
                let fields = try await MetadataTool.read(metaClip)
                try await expectMetadata(metaClip, ["video.resolution": "320 × 240", "video.fps": "25 fps",
                                                    "audio.sampleRate": "44.1 kHz", "audio.channels": "Mono",
                                                    "media.duration": "0:03.0", "media.container": "MPEG-4"])
                guard MetadataTool.value(of: "video.codec", in: fields)?.hasPrefix("H.264") == true,
                      MetadataTool.plainText(fields, title: "clip.mp4").contains("Resolution: 320 × 240") else {
                    throw ConversionError(MetadataTool.plainText(fields, title: "clip.mp4"))
                }
                return []
            }
            await check("song.mp3 tags: write, read back, clear one") {
                let edit = MetadataEdit(changes: ["title": "Test Tone", "artist": "Transmute", "album": "Fixtures",
                                                  "track": "3/12", "comment": "Line one\nLine two"])
                let written = try await Engine.perform(.writeMetadata(edit), on: metaSong, options: options) { _ in }.outputs
                guard let out = written.first, out.pathExtension == "mp3" else { throw ConversionError("expected an MP3 copy") }
                try await expectMetadata(out, ["title": "Test Tone", "artist": "Transmute", "album": "Fixtures",
                                               "track": "3/12", "comment": "Line one\nLine two"])
                let cleared = try await Engine.perform(.writeMetadata(MetadataEdit(changes: ["title": ""])), on: out,
                                                       options: options) { _ in }.outputs
                guard let clean = cleared.first else { throw ConversionError("no output") }
                try await expectMetadata(clean, ["title": "", "artist": "Transmute"])
                let length = await MediaInfo.duration(of: clean)
                guard abs(length - 3) < 0.2 else { throw ConversionError("the song is \(length) s long after tagging") }
                return written + cleared
            }
            await check("clip.mp4 tags: title, comment and year keep the video intact") {
                let edit = MetadataEdit(changes: ["title": "Test Card", "comment": "Made by the self-test", "date": "2024"])
                let outputs = try await Engine.perform(.writeMetadata(edit), on: metaClip, options: options) { _ in }.outputs
                guard let out = outputs.first, out.pathExtension == "mp4" else { throw ConversionError("expected an MP4 copy") }
                try await expectMetadata(out, ["title": "Test Card", "comment": "Made by the self-test", "date": "2024",
                                               "video.resolution": "320 × 240"])
                let length = await MediaInfo.duration(of: out)
                guard abs(length - 3) < 0.2 else { throw ConversionError("the video is \(length) s long after tagging") }
                return outputs
            }
            await check("Ogg tags (kept on the audio track): replace, remove, add") {
                let ogg = outDir.appendingPathComponent("tag-me.ogg")
                try await Shell.check(metaFFmpeg, ["-hide_banner", "-nostdin", "-y", "-i", metaTone.path, "-c:a", "libvorbis",
                                                   "-metadata", "title=Old Title", "-metadata", "artist=Old Artist", ogg.path])
                try await expectMetadata(ogg, ["title": "Old Title", "artist": "Old Artist"])
                let edit = MetadataEdit(changes: ["title": "New Title", "artist": "", "genre": "Test"])
                let outputs = try await Engine.perform(.writeMetadata(edit), on: ogg, options: options) { _ in }.outputs
                guard let out = outputs.first, out.pathExtension == "ogg" else { throw ConversionError("expected an Ogg copy") }
                try await expectMetadata(out, ["title": "New Title", "artist": "", "genre": "Test"])
                return outputs
            }
        } else {
            skipped += 1
            print("SKIP  metadata tags: need ffmpeg and the song.mp3 / clip.mp4 / tone.wav fixtures")
        }

        // Floating files open on a shake while dragging, but not on a slow drag.
        await check("Shake detection") {
            func shakes(_ xs: [CGFloat], every step: TimeInterval) -> Bool {
                var detector = ShakeDetector()
                var shaken = false
                for (index, x) in xs.enumerated() where detector.add(x: x, at: Double(index) * step) { shaken = true }
                return shaken
            }
            var quick: [CGFloat] = []
            for turn in 0..<6 { for step in 0...4 { quick.append(CGFloat(turn % 2 == 0 ? step : 4 - step) * 20) } }
            guard shakes(quick, every: 1.0 / 60) else { throw ConversionError("a quick shake wasn't noticed") }
            guard !shakes(quick, every: 0.2) else { throw ConversionError("a slow back and forth counted as a shake") }
            let straight = (0..<60).map { CGFloat($0) * 10 }
            guard !shakes(straight, every: 1.0 / 60) else { throw ConversionError("a straight drag counted as a shake") }
            let wobble = (0..<60).map { CGFloat($0 % 2) * 15 }
            guard !shakes(wobble, every: 1.0 / 60) else { throw ConversionError("a small wobble counted as a shake") }
            return []
        }

        // QR round trip with a code we generate ourselves.
        await check("QR code read") {
            let qr = outDir.appendingPathComponent("qr-fixture.png")
            try makeQRCode("https://example.com/transmute", at: qr)
            let result = try await Engine.perform(.readQR, on: qr, options: options) { _ in }
            guard result.message == "https://example.com/transmute" else {
                throw ConversionError("read \(result.message ?? "nothing")")
            }
            return []
        }

        print("\n\(passed) passed, \(failed.count) failed, \(skipped) skipped")
        for name in failed { print("  FAILED: \(name)") }
        return failed.count
    }

    /// The app is called Spinform but keeps its old bundle identifier, so testers keep their settings.
    private static func brandChecks() {
        let info = Bundle.main.infoDictionary ?? [:]
        let display = info["CFBundleDisplayName"] as? String ?? ""
        let name = info["CFBundleName"] as? String ?? ""
        record("Bundle: display name is Spinform", [], display == "Spinform" && name == "Spinform"
               ? nil : "CFBundleDisplayName \(display), CFBundleName \(name)")
        let identifier = Bundle.main.bundleIdentifier ?? ""
        record("Bundle: identifier unchanged", [], identifier == "local.personal.transmute" ? nil : "got \(identifier)")
        let blade = MarkGeometry.blade(0, side: 100).boundingRect
        record("Brand mark: swoosh fits its box", [],
               blade.width > 10 && blade.minX >= 0 && blade.maxX <= 100 && blade.minY >= 0 && blade.maxY <= 100
               ? nil : "swoosh bounds \(blade)")
    }

    private static func wheelLayoutChecks() {
        func same(_ name: String, _ got: [String], _ want: [String]) {
            record("Drag wheel: \(name)", [], got == want ? nil : "got \(got), expected \(want)")
        }
        same("documents default to PDF first", WheelLayout.resolve(.convert, [.document], custom: nil),
             WheelLayout.defaultLayout(.convert, .document))
        same("default document wheel starts with PDF", Array(WheelLayout.resolve(.convert, [.document], custom: nil).prefix(1)), ["convert:pdf"])
        same("one PDF has no Merge", WheelLayout.resolve(.tools, [.pdf], custom: nil),
             ["tool:half", "tool:quarter", "tool:clean", "tool:split", "tool:zip"])
        same("two PDFs get Merge", WheelLayout.resolve(.tools, [.pdf, .pdf], custom: nil),
             ["tool:half", "tool:quarter", "tool:clean", "tool:split", "tool:merge", "tool:zip"])
        same("mixed files share formats", WheelLayout.resolve(.convert, [.image, .video], custom: nil), ["convert:gif"])
        same("images get Edit first on the tools wheel", Array(WheelLayout.resolve(.tools, [.image], custom: nil).prefix(2)),
             ["tool:edit", "tool:half"])
        same("videos get Edit first on the actions wheel", Array(WheelLayout.resolve(.actions, [.video], custom: nil).prefix(1)),
             ["tool:edit"])
        same("a photo and a PDF have no Edit", WheelLayout.resolve(.tools, [.image, .pdf], custom: nil).filter { $0 == "tool:edit" }, [])
        same("Edit has a bubble", [WheelItem(id: "tool:edit")?.label ?? "-"], ["Edit"])
        var custom = ["convert.document": ["gap", "convert:pdf", "gap", "convert:docx", "action:float", "tool:zip"]]
        same("customized order, spaces and mixed-in items", WheelLayout.resolve(.convert, [.document], custom: custom),
             ["gap", "convert:pdf", "gap", "convert:docx", "action:float", "tool:zip"])
        same("other kinds keep the default", WheelLayout.resolve(.convert, [.pdf], custom: custom),
             WheelLayout.defaultLayout(.convert, .pdf))
        same("items that don't suit every file leave a space", WheelLayout.resolve(.convert, [.document, .audio], custom: custom),
             ["gap", "gap", "gap", "gap", "action:float", "tool:zip"])
        custom["tools.pdf"] = ["tool:merge"]
        same("nothing usable means no wheel", WheelLayout.resolve(.tools, [.pdf], custom: custom), [])
        let many = ["convert:pdf"] + Array(repeating: "gap", count: 20) + ["tool:qr", "convert:pdf", "nonsense"]
        let cleaned = WheelLayout.clean(many, .document)
        same("saved layouts are cleaned up", [String(cleaned.count), cleaned[0]], [String(WheelLayout.maxSlots), "convert:pdf"])
        same("unknown ids have no bubble", ["tool:zip", "action:airdrop", "convert:pdf", "gap", "nope"].map { WheelItem(id: $0) == nil ? "-" : "ok" },
             ["ok", "ok", "ok", "-", "-"])
    }

    private static func exercise(_ input: URL, options: ConversionOptions) async {
        let kind = FileKind.of(input)
        let name = input.lastPathComponent
        for format in kind.convertTargets {
            if format == .heic && !canWriteHEIC {
                skipped += 1
                print("SKIP  \(name) → HEIC: this Mac can't encode HEIC")
                continue
            }
            if let app = OfficeConverter.requiredApp(for: input, to: format) {
                skipped += 1
                print("SKIP  \(name) → \(format.label): needs \(app), which isn't installed")
                continue
            }
            await check("\(name) → \(format.label)") {
                try await Engine.perform(.convert(format), on: input, options: options) { _ in }.outputs
            }
        }
        if kind.canCompress {
            await check("\(name) compress 50%") {
                try await Engine.perform(.compress(.percent(0.5)), on: input, options: options) { _ in }.outputs
            }
        }
        if kind.canStripMetadata {
            await check("\(name) remove metadata") {
                try await Engine.perform(.stripMetadata, on: input, options: options) { _ in }.outputs
            }
        }
        if kind == .pdf {
            await check("\(name) split pages") {
                try await Engine.perform(.splitPDF, on: input, options: options) { _ in }.outputs
            }
        }
    }

    /// A PDF with one big photo-like picture per page, stored losslessly so it is large.
    private static func makePhotoPDF(_ url: URL, pages: Int, width: Int, height: Int) throws {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let pdf = CGContext(url as CFURL, mediaBox: nil, nil) else { throw ConversionError("no PDF context") }
        var generator = SystemRandomNumberGenerator()
        for page in 0..<pages {
            guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let pixels = ctx.data?.assumingMemoryBound(to: UInt8.self) else { throw ConversionError("no bitmap") }
            let row = ctx.bytesPerRow
            for y in 0..<height {
                for x in 0..<width {
                    let i = y * row + x * 4
                    let grain = UInt8.random(in: 0...40, using: &generator)
                    pixels[i] = UInt8((x * 200 / width + page * 20) % 216) &+ grain
                    pixels[i + 1] = UInt8(y * 200 / height) &+ grain
                    pixels[i + 2] = UInt8(((x + y) * 100 / (width + height)) + 60) &+ grain
                }
            }
            guard let image = ctx.makeImage() else { throw ConversionError("no image") }
            var box = CGRect(x: 0, y: 0, width: 595, height: 842)
            pdf.beginPage(mediaBox: &box)
            pdf.draw(image, in: box)
            pdf.endPage()
        }
        pdf.closePDF()
    }

    /// Runs one operation and checks every output exists, isn't empty, and (for images) decodes.
    private static func check(_ name: String, _ body: () async throws -> [URL]) async {
        do {
            let outputs = try await body()
            for url in outputs {
                if let problem = problem(with: url) { throw ConversionError(problem) }
            }
            record(name, outputs, nil)
        } catch {
            record(name, nil, error.localizedDescription)
        }
    }

    private static func record(_ name: String, _ outputs: [URL]?, _ error: String?) {
        if let error {
            failed.append(name)
            print("FAIL  \(name): \(error)")
        } else {
            passed += 1
            let detail = (outputs ?? []).map { "\($0.lastPathComponent) (\(OutputPaths.fileSize($0).formattedSize))" }
            print("PASS  \(name)\(detail.isEmpty ? "" : " → " + detail.joined(separator: ", "))")
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
        return nil
    }

    private static func makeQRCode(_ text: String, at url: URL) throws {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw ConversionError("no QR generator") }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let small = filter.outputImage else { throw ConversionError("QR generation failed") }
        let image = small.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cg = context.createCGImage(image, from: image.extent) else { throw ConversionError("QR render failed") }
        // Add a white quiet zone around the code so detectors find it reliably.
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
