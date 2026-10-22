import AppKit
import CoreImage
import PDFKit
import Vision

/// Text and QR codes from pictures, on this Mac only (Vision), never uploaded.
enum TextRecognizer {
    struct Result: Sendable {
        var text: String
        var qrCodes: [String]

        var isEmpty: Bool { text.isEmpty && qrCodes.isEmpty }

        /// What goes on the clipboard: the text, then any QR code contents not already in it.
        var clipboardText: String {
            let extra = qrCodes.filter { !text.contains($0) }
            return ([text] + extra).filter { !$0.isEmpty }.joined(separator: "\n")
        }

        var wordCount: Int { text.split(whereSeparator: { $0.isWhitespace }).count }
    }

    static func recognize(_ image: CGImage) throws -> Result {
        Result(text: try text(in: image), qrCodes: qrCodes(in: image))
    }

    /// Lines of text top to bottom, words left to right.
    static func text(in image: CGImage) throws -> String {
        var source = image
        // Vision reads tiny text (a single line from a non-Retina screen) better a little larger.
        if min(image.width, image.height) < 120, let larger = upscaled(image, by: 2) { source = larger }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: source, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw ConversionError("Couldn't read text: \(error.localizedDescription)")
        }
        let pieces: [(box: CGRect, text: String)] = (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return (observation.boundingBox, candidate.string)
        }
        return assemble(pieces)
    }

    /// Groups Vision's boxes (normalized, bottom-left origin) into lines.
    static func assemble(_ pieces: [(box: CGRect, text: String)]) -> String {
        let sorted = pieces.sorted { $0.box.midY > $1.box.midY }
        var lines: [[(box: CGRect, text: String)]] = []
        for piece in sorted {
            if let last = lines.last?.last, abs(last.box.midY - piece.box.midY) < max(last.box.height, piece.box.height) * 0.5 {
                lines[lines.count - 1].append(piece)
            } else {
                lines.append([piece])
            }
        }
        return lines.map { line in
            line.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// The same detector as the Tools tab's Read QR Codes.
    static func qrCodes(in image: CGImage) -> [String] {
        ImageConverter.qrMessages(in: CIImage(cgImage: image))
    }

    /// Text from an image file, or from every page of a PDF (up to 30 pages).
    static func recognize(fileAt url: URL) throws -> Result {
        if FileKind.of(url) == .pdf {
            guard let document = PDFDocument(url: url) else { throw ConversionError("Couldn't open \(url.lastPathComponent).") }
            var texts: [String] = []
            var codes: [String] = []
            for index in 0..<min(document.pageCount, 30) {
                guard let page = document.page(at: index) else { continue }
                // A PDF that already has text: use it as it is.
                if let existing = page.string?.trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
                    texts.append(existing)
                    continue
                }
                guard let picture = render(page) else { continue }
                let result = try recognize(picture)
                texts.append(result.text)
                codes += result.qrCodes
            }
            return Result(text: texts.filter { !$0.isEmpty }.joined(separator: "\n\n"), qrCodes: codes)
        }
        return try recognize(try ImageConverter.loadCGImage(url))
    }

    /// A PDF page at about 200 dpi on white.
    static func render(_ page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let scale: CGFloat = 200.0 / 72.0
        let width = Int(box.width * scale), height = Int(box.height * scale)
        guard width > 0, height > 0, width < 12000, height < 12000,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    private static func upscaled(_ image: CGImage, by factor: Int) -> CGImage? {
        let width = image.width * factor, height = image.height * factor
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// Copies the result and says so.
    @MainActor
    static func deliver(_ result: Result) {
        guard !result.isEmpty else {
            Toast.show("No text found", detail: "Try a larger area, or text with more contrast.", symbol: "exclamationmark.triangle.fill")
            return
        }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(result.clipboardText, forType: .string)
        let preview = result.clipboardText.replacingOccurrences(of: "\n", with: " ")
        let short = preview.count > 80 ? String(preview.prefix(80)) + "…" : preview
        if result.text.isEmpty {
            Toast.show("QR code copied", detail: short, symbol: "qrcode")
        } else {
            let words = result.wordCount
            Toast.show("Copied \(words) word\(words == 1 ? "" : "s")", detail: short, symbol: "text.viewfinder")
        }
    }
}
