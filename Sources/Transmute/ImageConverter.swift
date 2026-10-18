import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum ImageConverter {
    static func utType(for format: OutputFormat) -> UTType? {
        switch format {
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        case .bmp: .bmp
        case .gif: .gif
        default: nil
        }
    }

    static func convert(_ input: URL, to format: OutputFormat, options: ConversionOptions) async throws -> URL {
        let out = OutputPaths.destination(for: input, ext: format.fileExtension, folder: options.outputFolder)
        switch format {
        case .webp:
            try await encodeWebP(input, to: out, quality: options.quality)
        case .svg:
            try writeSVG(loadCGImage(input), to: out)
        case .pdf:
            try writePDF(loadCGImage(input), to: out)
        default:
            guard let type = utType(for: format) else {
                throw ConversionError("Images can't be converted to \(format.label).")
            }
            let data = try encode(input, type: type, quality: options.quality, strip: options.stripMetadata, maxPixel: nil)
            try data.write(to: out, options: .atomic)
        }
        return out
    }

    // MARK: Encoding

    static func supportsAlpha(_ type: UTType) -> Bool {
        ![UTType.jpeg, .bmp].contains(type)
    }

    /// Re-encodes an image file. Keeps animation for GIF output, keeps metadata unless `strip`,
    /// and downsizes so the longest side is at most `maxPixel` when given.
    static func encode(_ input: URL, type: UTType, quality: Double, strip: Bool, maxPixel: Int?) throws -> Data {
        let output = NSMutableData()
        let qualityProps: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]

        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            // ImageIO can't read it (SVG, for example) — go through NSImage.
            let image = try loadCGImage(input)
            guard let dest = CGImageDestinationCreateWithData(output as CFMutableData, type.identifier as CFString, 1, nil) else {
                throw ConversionError("This Mac can't write \(type.preferredFilenameExtension ?? "that format") images.")
            }
            let finalImage = supportsAlpha(type) ? image : flatten(image)
            CGImageDestinationAddImage(dest, finalImage, qualityProps as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw ConversionError("Couldn't encode the image.") }
            return output as Data
        }

        let count = CGImageSourceGetCount(source)
        let frames = (type == .gif && count > 1) ? count : 1
        guard let dest = CGImageDestinationCreateWithData(output as CFMutableData, type.identifier as CFString, frames, nil) else {
            throw ConversionError("This Mac can't write \(type.preferredFilenameExtension ?? "that format") images.")
        }

        let needsFlatten = !supportsAlpha(type)
        if !strip && maxPixel == nil && !needsFlatten {
            for index in 0..<frames {
                CGImageDestinationAddImageFromSource(dest, source, index, qualityProps as CFDictionary)
            }
        } else {
            for index in 0..<frames {
                var image = try renderedImage(source, index: index, maxPixel: maxPixel)
                if needsFlatten { image = flatten(image) }
                var props = qualityProps
                if !strip, let original = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] {
                    props.merge(original) { current, _ in current }
                    props[kCGImagePropertyOrientation] = 1 // orientation is baked into the pixels
                    props[kCGImagePropertyPixelWidth] = nil
                    props[kCGImagePropertyPixelHeight] = nil
                } else if frames > 1, let original = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                          let gif = original[kCGImagePropertyGIFDictionary] {
                    props[kCGImagePropertyGIFDictionary] = gif // keep frame timing
                }
                CGImageDestinationAddImage(dest, image, props as CFDictionary)
            }
        }
        if frames > 1, let containerProps = CGImageSourceCopyProperties(source, nil) {
            CGImageDestinationSetProperties(dest, containerProps) // loop count
        }
        guard CGImageDestinationFinalize(dest) else { throw ConversionError("Couldn't encode the image.") }
        return output as Data
    }

    /// Decodes one frame with EXIF orientation applied, optionally downscaled.
    static func renderedImage(_ source: CGImageSource, index: Int, maxPixel: Int?) throws -> CGImage {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let maxPixel { options[kCGImageSourceThumbnailMaxPixelSize] = maxPixel }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw ConversionError("Couldn't decode the image.")
        }
        return image
    }

    /// Loads the first frame of any image macOS can open, orientation applied.
    static func loadCGImage(_ url: URL) throws -> CGImage {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
           let image = try? renderedImage(source, index: 0, maxPixel: nil) {
            return image
        }
        guard let nsImage = NSImage(contentsOf: url) else {
            throw ConversionError("macOS can't open \(url.lastPathComponent) as an image.")
        }
        // Vector images (SVG) have no pixels of their own; render them at 2x.
        let scale: CGFloat = url.pathExtension.lowercased() == "svg" ? 2 : 1
        var rect = CGRect(origin: .zero, size: CGSize(width: nsImage.size.width * scale, height: nsImage.size.height * scale))
        guard let image = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw ConversionError("Couldn't render \(url.lastPathComponent).")
        }
        return image
    }

    /// Puts an image on a white background (for formats without transparency).
    static func flatten(_ image: CGImage) -> CGImage {
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    static func data(from image: CGImage, type: UTType, quality: Double = 0.9) throws -> Data {
        let output = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(output as CFMutableData, type.identifier as CFString, 1, nil) else {
            throw ConversionError("Couldn't create the image encoder.")
        }
        let finalImage = supportsAlpha(type) ? image : flatten(image)
        CGImageDestinationAddImage(dest, finalImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError("Couldn't encode the image.") }
        return output as Data
    }

    // MARK: Special outputs

    /// macOS can read WebP but not write it, so this goes through ffmpeg.
    static func encodeWebP(_ input: URL, to out: URL, quality: Double) async throws {
        let ffmpeg = try Tools.requireFFmpeg(for: "Saving WebP")
        var source = input
        var temp: URL?
        if input.pathExtension.lowercased() != "gif" {
            // Normalise HEIC/SVG/RAW etc. to PNG first so ffmpeg can always read it.
            let png = OutputPaths.temporaryURL(ext: "png")
            try encode(input, type: .png, quality: 1, strip: true, maxPixel: nil).write(to: png)
            source = png
            temp = png
        }
        defer { if let temp { try? FileManager.default.removeItem(at: temp) } }
        do {
            try await Shell.check(ffmpeg, [
                "-hide_banner", "-nostdin", "-y", "-i", source.path,
                "-c:v", "libwebp", "-quality", String(Int(quality * 100)), "-loop", "0",
                out.path,
            ])
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
    }

    /// Wraps the pixels in an SVG file. This doesn't trace the image into vector shapes.
    static func writeSVG(_ image: CGImage, to out: URL) throws {
        let png = try data(from: image, type: .png)
        let w = image.width, h = image.height
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" \
        width="\(w)" height="\(h)" viewBox="0 0 \(w) \(h)">
        <image width="\(w)" height="\(h)" xlink:href="data:image/png;base64,\(png.base64EncodedString())"/>
        </svg>
        """
        try svg.write(to: out, atomically: true, encoding: .utf8)
    }

    static func writePDF(_ image: CGImage, to out: URL) throws {
        var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let ctx = CGContext(out as CFURL, mediaBox: &box, nil) else {
            throw ConversionError("Couldn't create the PDF.")
        }
        ctx.beginPDFPage(nil)
        ctx.draw(image, in: box)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    // MARK: Compression

    static func compress(_ input: URL, goal: Int64, options: ConversionOptions) throws -> JobResult {
        let ext = input.pathExtension.lowercased()
        // ImageIO can't open SVG: rasterise it once and compress the bitmap (saved as JPEG below).
        var readable = input
        var rasterTemp: URL?
        if ext == "svg" {
            let png = OutputPaths.temporaryURL(ext: "png")
            try ImageConverter.data(from: loadCGImage(input), type: .png).write(to: png)
            readable = png
            rasterTemp = png
        }
        defer { if let rasterTemp { try? FileManager.default.removeItem(at: rasterTemp) } }
        guard let source = CGImageSourceCreateWithURL(readable as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw ConversionError("Couldn't read \(input.lastPathComponent).")
        }
        // Keep the format when macOS can write it; otherwise (WebP, RAW…) fall back to JPEG.
        let type: UTType
        let outExt: String
        if let writable = UTType(filenameExtension: ext).flatMap({ utType(forUT: $0) }) {
            type = writable
            outExt = ext
        } else {
            type = .jpeg
            outExt = "jpg"
        }
        // Lossy formats search for a quality; lossless ones get smaller by shrinking dimensions.
        let isLossy = type == .jpeg || type == .heic

        let fullSide = max(props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
        var side = fullSide
        var best: Data?
        var smallest: Data?

        for _ in 0..<10 {
            let maxPixel = side >= fullSide ? nil : side
            if isLossy {
                var lo = 0.05, hi = 0.95
                for _ in 0..<7 {
                    let q = (lo + hi) / 2
                    let data = try encode(readable, type: type, quality: q, strip: options.stripMetadata, maxPixel: maxPixel)
                    if smallest == nil || data.count < smallest!.count { smallest = data }
                    if data.count <= goal { best = data; lo = q } else { hi = q }
                }
            } else {
                let data = try encode(readable, type: type, quality: 1, strip: options.stripMetadata, maxPixel: maxPixel)
                if smallest == nil || data.count < smallest!.count { smallest = data }
                if data.count <= goal { best = data }
            }
            if best != nil { break }
            side = Int(Double(side) * 0.8)
            if side < 64 { break }
        }

        guard let data = best ?? smallest else { throw ConversionError("Couldn't compress the image.") }
        let out = OutputPaths.destination(for: input, ext: outExt, suffix: "compressed", folder: options.outputFolder)
        try data.write(to: out, options: .atomic)
        let message = best == nil
            ? "Couldn't reach \(goal.formattedSize); smallest was \(Int64(data.count).formattedSize)"
            : "\(OutputPaths.fileSize(input).formattedSize) → \(Int64(data.count).formattedSize)"
        return JobResult(outputs: [out], message: message)
    }

    /// Maps a file's UTType to one ImageIO can write, if it can.
    private static func utType(forUT type: UTType) -> UTType? {
        for candidate in [UTType.png, .tiff, .bmp, .gif, .jpeg, .heic] where type.conforms(to: candidate) {
            return candidate
        }
        return nil
    }

    // MARK: Metadata

    /// Removes EXIF/GPS/XMP without re-encoding where ImageIO allows it.
    static func stripMetadata(_ input: URL, options: ConversionOptions) async throws -> URL {
        if input.pathExtension.lowercased() == "svg" {
            // SVG is XML that ImageIO can't open; drop its <metadata> element instead.
            let out = OutputPaths.destination(for: input, ext: "svg", suffix: "clean", folder: options.outputFolder)
            let text = try String(contentsOf: input, encoding: .utf8)
                .replacingOccurrences(of: "<metadata[\\s\\S]*?</metadata>", with: "", options: .regularExpression)
            try text.write(to: out, atomically: true, encoding: .utf8)
            return out
        }
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let typeID = CGImageSourceGetType(source) else {
            throw ConversionError("Couldn't read \(input.lastPathComponent).")
        }
        let out = OutputPaths.destination(for: input, ext: input.pathExtension, suffix: "clean", folder: options.outputFolder)
        if (typeID as String) == UTType.webP.identifier {
            // ImageIO reads WebP but can't write it; go through a metadata-free PNG and ffmpeg.
            try await encodeWebP(input, to: out, quality: 0.95)
            return out
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = props?[kCGImagePropertyOrientation] as? Int ?? 1

        let data = NSMutableData()
        if let dest = CGImageDestinationCreateWithData(data as CFMutableData, typeID, 1, nil) {
            let copyOptions: [CFString: Any] = [
                kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
                kCGImageDestinationMergeMetadata: false,
                kCGImageMetadataShouldExcludeGPS: true,
                kCGImageDestinationOrientation: orientation,
            ]
            if CGImageDestinationCopyImageSource(dest, source, copyOptions as CFDictionary, nil) {
                try (data as Data).write(to: out, options: .atomic)
                return out
            }
        }
        // Fallback: re-encode at high quality with no metadata.
        let type = UTType(typeID as String) ?? .png
        try encode(input, type: type, quality: 0.95, strip: true, maxPixel: nil).write(to: out, options: .atomic)
        return out
    }

    // MARK: QR codes

    static func readQR(_ url: URL) throws -> String {
        guard let image = CIImage(contentsOf: url) else {
            throw ConversionError("Couldn't open \(url.lastPathComponent).")
        }
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let messages = (detector?.features(in: image) ?? []).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        guard !messages.isEmpty else { throw ConversionError("No QR code found.") }
        return messages.joined(separator: "\n")
    }
}
