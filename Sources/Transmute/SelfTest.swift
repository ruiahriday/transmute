import AppKit
import CoreImage
import ImageIO

/// Headless check that runs every conversion on a folder of sample files:
///   Transmute.app/Contents/MacOS/Transmute --selftest <folder>
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
