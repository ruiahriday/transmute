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
