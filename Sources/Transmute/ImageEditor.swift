import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared geometry (also used by the video editor)

/// A point in normalized image coordinates: 0…1 on both axes, origin at the top-left.
struct NormPoint: Equatable, Hashable, Sendable {
    var x: Double
    var y: Double

    var clamped: NormPoint { NormPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1)) }
}

/// A rectangle in normalized image coordinates: 0…1 on both axes, origin at the top-left.
/// Editors store positions this way so they don't depend on the preview's size.
struct NormRect: Equatable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    static let full = NormRect(x: 0, y: 0, width: 1, height: 1)

    var minX: Double { x }
    var minY: Double { y }
    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }
}

extension NormRect {
    /// The rectangle spanned by two corners, whichever way the drag went.
    init(from a: NormPoint, to b: NormPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Clipped to the image.
    var clamped: NormRect {
        let x0 = min(max(minX, 0), 1), y0 = min(max(minY, 0), 1)
        let x1 = min(max(maxX, 0), 1), y1 = min(max(maxY, 0), 1)
        return NormRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    /// Covers (practically) the whole image, so cropping to it changes nothing.
    var isFull: Bool { minX <= 0.0005 && minY <= 0.0005 && maxX >= 0.9995 && maxY >= 0.9995 }

    func contains(_ p: NormPoint) -> Bool {
        p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }

    /// Whole-pixel rectangle in an image of the given size, top-left origin (the same
    /// convention as CGImage.cropping). Never empty and never outside the image.
    func pixelRect(width: Int, height: Int) -> CGRect {
        let c = clamped
        let w = Double(width), h = Double(height)
        let x0 = min(Int((c.minX * w).rounded()), max(0, width - 1))
        let y0 = min(Int((c.minY * h).rounded()), max(0, height - 1))
        let x1 = max(x0 + 1, min(Int((c.maxX * w).rounded()), width))
        let y1 = max(y0 + 1, min(Int((c.maxY * h).rounded()), height))
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// An sRGB colour with components in 0…1.
struct RGBAColor: Equatable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    static let black = RGBAColor(red: 0, green: 0, blue: 0)
    static let white = RGBAColor(red: 1, green: 1, blue: 1)
    // Not named red/green/blue, which are the components.
    static let brightRed = RGBAColor(red: 0.93, green: 0.19, blue: 0.16)
    static let orange = RGBAColor(red: 1, green: 0.58, blue: 0)
    static let yellow = RGBAColor(red: 1, green: 0.84, blue: 0.04)
    static let brightGreen = RGBAColor(red: 0.2, green: 0.78, blue: 0.35)
    static let brightBlue = RGBAColor(red: 0.0, green: 0.48, blue: 1)

    /// The editor's colour choices.
    static let swatches: [RGBAColor] = [.brightRed, .orange, .yellow, .brightGreen, .brightBlue, .white, .black]

    func withAlpha(_ alpha: Double) -> RGBAColor {
        RGBAColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }

    /// "RRGGBB", e.g. for ffmpeg's `color=0xRRGGBB`.
    var hexString: String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}

// MARK: - The edit

/// Everything the photo editor can do to one image. Positions are normalized to the
/// original image after its EXIF orientation is applied (what the user sees), origin top-left.
struct ImageEdit: Equatable, Sendable {
    enum RedactionStyle: String, CaseIterable, Identifiable, Sendable {
        case blackout, pixelate, blur

        var id: String { rawValue }

        var label: String {
            switch self {
            case .blackout: "Black box"
            case .pixelate: "Pixelate"
            case .blur: "Blur"
            }
        }

        var symbol: String {
            switch self {
            case .blackout: "rectangle.fill"
            case .pixelate: "squareshape.split.3x3"
            case .blur: "drop"
            }
        }
    }

    struct Redaction: Equatable, Sendable, Identifiable {
        var id = UUID()
        var rect: NormRect
        var style: RedactionStyle
    }

    enum AnnotationKind: Equatable, Sendable {
        /// `at` is the top-left corner of the text.
        case text(String, at: NormPoint)
        case rectangle(NormRect)
        case arrow(from: NormPoint, to: NormPoint)
        /// A semi-transparent filled box, like a highlighter pen.
        case highlight(NormRect)
        /// An oval drawn inside the rectangle.
        case ellipse(NormRect)
        case line(from: NormPoint, to: NormPoint)
        /// A numbered circle; `at` is its centre and the size is its diameter.
        case step(Int, at: NormPoint)
        /// Dims everything outside the rectangle.
        case spotlight(NormRect)
    }

    struct Annotation: Equatable, Sendable, Identifiable {
        var id = UUID()
        var kind: AnnotationKind
        var color: RGBAColor
        /// Text: font size. Rectangle and arrow: line width. Both as a fraction of the image height.
        var size: Double
    }

    /// Area to keep, or nil for the whole image.
    var crop: NormRect?
    /// Clockwise quarter turns, 0…3.
    var quarterTurns = 0
    /// Mirror after rotating, so "horizontal" means horizontal on screen.
    var flipHorizontal = false
    var flipVertical = false
    /// -0.5…0.5
    var brightness = 0.0
    /// 0.5…2
    var contrast = 1.0
    /// 0…2
    var saturation = 1.0
    /// -2…2 EV
    var exposure = 0.0
    var redactions: [Redaction] = []
    var annotations: [Annotation] = []
    /// Resize after everything else: 1 keeps the size, 0.5 halves it.
    var scale = 1.0
    /// Cut out the subject and make the rest transparent or something else (BackgroundTool.swift); nil leaves it.
    var background: BackgroundEdit?
    /// nil keeps the input format when macOS can write it, otherwise PNG.
    var outputFormat: OutputFormat?

    static let identity = ImageEdit()

    /// Just the background taken away: the drag wheel's and the Tools tab's one-click cut-out.
    static var removingBackground: ImageEdit {
        var edit = ImageEdit()
        edit.background = .remove
        return edit
    }

    /// quarterTurns folded into 0…3.
    var turns: Int { ((quarterTurns % 4) + 4) % 4 }

    var hasColorAdjustments: Bool {
        brightness != 0 || contrast != 1 || saturation != 1 || exposure != 0
    }

    var changesPixels: Bool {
        crop.map { !$0.clamped.isFull } == true || turns != 0 || flipHorizontal || flipVertical
            || hasColorAdjustments || !redactions.isEmpty || !annotations.isEmpty || background != nil || isResized
    }

    var isResized: Bool { abs(scale - 1) > 0.0001 }

    /// Only the background changes, so the copy is named for that ("photo no-bg.png").
    var onlyBackground: Bool {
        background != nil && crop.map { !$0.clamped.isFull } != true && turns == 0 && !flipHorizontal && !flipVertical
            && !hasColorAdjustments && redactions.isEmpty && annotations.isEmpty && !isResized
    }

    /// Nothing to do: saving would only copy the image.
    var isEmpty: Bool { !changesPixels && outputFormat == nil }
}

extension ImageEdit.Annotation {
    static func text(_ string: String, at point: NormPoint, size: Double = 0.05,
                     color: RGBAColor = .brightRed) -> ImageEdit.Annotation {
        ImageEdit.Annotation(kind: .text(string, at: point), color: color, size: size)
    }

    static func rectangle(_ rect: NormRect, lineWidth: Double = 0.008,
                          color: RGBAColor = .brightRed) -> ImageEdit.Annotation {
        ImageEdit.Annotation(kind: .rectangle(rect), color: color, size: lineWidth)
    }

    static func arrow(from start: NormPoint, to end: NormPoint, lineWidth: Double = 0.008,
                      color: RGBAColor = .brightRed) -> ImageEdit.Annotation {
        ImageEdit.Annotation(kind: .arrow(from: start, to: end), color: color, size: lineWidth)
    }

    static func highlight(_ rect: NormRect, color: RGBAColor = .yellow) -> ImageEdit.Annotation {
        ImageEdit.Annotation(kind: .highlight(rect), color: color, size: 0)
    }

    static func ellipse(_ rect: NormRect, lineWidth: Double = 0.008, color: RGBAColor = .brightRed) -> ImageEdit.Annotation {
        ImageEdit.Annotation(kind: .ellipse(rect), color: color, size: lineWidth)
    }

    static func line(from start: NormPoint, to end: NormPoint, lineWidth: Double = 0.008,
                     color: RGBAColor = .brightRed) -> ImageEdit.Annotation {
        ImageEdit.Annotation(kind: .line(from: start, to: end), color: color, size: lineWidth)
    }

    static func step(_ number: Int, at point: NormPoint, diameter: Double = 0.06,
                     color: RGBAColor = .brightRed) -> ImageEdit.Annotation {
        ImageEdit.Annotation(kind: .step(number, at: point), color: color, size: diameter)
    }

    static func spotlight(_ rect: NormRect) -> ImageEdit.Annotation {
        ImageEdit.Annotation(kind: .spotlight(rect), color: .black, size: 0)
    }
}

// MARK: - Rendering

/// Applies an ImageEdit. Runs off the main thread (CoreImage, CoreGraphics and CoreText only).
enum ImageEditEngine {
    /// A decoded image handed between threads. CGImage is immutable, so sharing it is safe.
    struct PreviewImage: @unchecked Sendable {
        let image: CGImage
        /// Pixel size of the full-resolution oriented original.
        let originalSize: CGSize
    }

    /// `subjectMask` replaces Vision's subject detection (the self-test uses a known shape).
    static func apply(_ edit: ImageEdit, to input: URL, options: ConversionOptions,
                      subjectMask: ((CGImage) throws -> CIImage)? = nil) async throws -> JobResult {
        guard FileKind.of(input) == .image else {
            throw ConversionError("Only images can be edited in the photo editor.")
        }
        let original = try ImageConverter.loadCGImage(input)
        try Task.checkCancellation()
        let image = try render(edit, on: original, subjectMask: subjectMask)
        try Task.checkCancellation()

        // Keep the input's format (and its extension spelling) unless another was chosen.
        var kept = keptFormat(of: input)
        let transparent = edit.background?.isTransparent == true
        // A cut-out needs transparency: PNG, unless the input is HEIC or TIFF, which keep it too.
        if transparent, let format = kept, ![.png, .heic, .tiff].contains(format) { kept = nil }
        var format = kept ?? .png
        var ext = kept != nil ? input.pathExtension.lowercased() : OutputFormat.png.fileExtension
        if let chosen = edit.outputFormat, canWrite(chosen) {
            format = chosen
            ext = chosen.fileExtension
        }
        let suffix = edit.onlyBackground ? (transparent ? "no-bg" : "new-bg") : "edited"
        var notes: [String] = []
        if let background = edit.background { notes.append(background.summary) }
        let frames = CGImageSourceCreateWithURL(input as CFURL, nil).map { CGImageSourceGetCount($0) } ?? 1
        if frames > 1 && ["gif", "webp"].contains(input.pathExtension.lowercased()) {
            notes.append("first frame only")
        }

        if format == .webp {
            // macOS can't write WebP; ImageConverter goes through ffmpeg.
            let png = OutputPaths.temporaryURL(ext: "png")
            defer { try? FileManager.default.removeItem(at: png) }
            try ImageConverter.data(from: image, type: .png, quality: 1).write(to: png)
            let out = OutputPaths.destination(for: input, ext: "webp", suffix: suffix, folder: options.outputFolder)
            try await ImageConverter.encodeWebP(png, to: out, quality: options.quality)
            return JobResult(outputs: [out], message: message(for: image, notes: notes))
        }

        guard let type = ImageConverter.utType(for: format) else {
            throw ConversionError("Edited images can't be saved as \(format.label).")
        }
        // Redacted copies never carry the original's metadata (location, camera, captions).
        let metadataSource = (!options.stripMetadata && edit.redactions.isEmpty) ? input : nil
        var data = Data()
        do {
            data = try encode(image, type: type, quality: options.quality, metadataFrom: metadataSource)
        } catch {
            guard format == .heic else { throw error }
            // Macs without a hardware HEVC encoder (virtual machines) can't write HEIC.
            guard edit.outputFormat == nil else {
                throw ConversionError("This Mac can't encode HEIC images. Choose JPEG or PNG instead.")
            }
            // A cut-out falls back to PNG so it stays transparent.
            let fallback: UTType = transparent ? .png : .jpeg
            data = try encode(image, type: fallback, quality: options.quality, metadataFrom: metadataSource)
            ext = transparent ? "png" : "jpg"
            notes.append("saved as \(transparent ? "PNG" : "JPEG"): this Mac can't encode HEIC")
        }
        let out = OutputPaths.destination(for: input, ext: ext, suffix: suffix, folder: options.outputFolder)
        try data.write(to: out, options: .atomic)
        return JobResult(outputs: [out], message: message(for: image, notes: notes))
    }

    private static func message(for image: CGImage, notes: [String]) -> String {
        let size = "\(image.width)×\(image.height)"
        return notes.isEmpty ? size : "\(size) (\(notes.joined(separator: "; ")))"
    }

    /// The input's own format, if it can be written back.
    private static func keptFormat(of input: URL) -> OutputFormat? {
        switch input.pathExtension.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "png": return .png
        case "heic", "heif": return .heic
        case "tif", "tiff": return .tiff
        case "bmp": return .bmp
        case "gif": return .gif
        case "webp": return Tools.ffmpeg != nil ? .webp : nil
        default: return nil
        }
    }

    private static func canWrite(_ format: OutputFormat) -> Bool {
        ImageConverter.utType(for: format) != nil || (format == .webp && Tools.ffmpeg != nil)
    }

    /// The whole pipeline, in the order the editor's overlays assume: background → redactions →
    /// annotations → colour → crop → rotate/flip. Everything before the crop uses the oriented original's coordinates.
    static func render(_ edit: ImageEdit, on original: CGImage,
                       subjectMask: ((CGImage) throws -> CIImage)? = nil) throws -> CGImage {
        let context = CIContext(options: [.cacheIntermediates: false])
        let width = original.width, height = original.height
        var image = original

        if let background = edit.background {
            let mask = try subjectMask?(original) ?? BackgroundEngine.subjectMask(for: original)
            image = try BackgroundEngine.compose(original, mask: mask, fill: background.fill)
        }
        if !edit.redactions.isEmpty {
            let redacted = redact(CIImage(cgImage: image), edit.redactions, width: width, height: height)
            image = try ciRender(redacted, width: width, height: height, like: original, context: context)
        }
        if !edit.annotations.isEmpty {
            image = try drawAnnotations(edit.annotations, on: image)
        }
        if edit.hasColorAdjustments {
            let adjusted = adjustColors(CIImage(cgImage: image), edit)
            image = try ciRender(adjusted, width: width, height: height, like: original, context: context)
        }
        if let crop = edit.crop?.clamped, !crop.isFull {
            let rect = crop.pixelRect(width: image.width, height: image.height)
            guard let cropped = image.cropping(to: rect) else { throw ConversionError("The crop area is empty.") }
            image = cropped
        }
        if edit.turns != 0 || edit.flipHorizontal || edit.flipVertical {
            image = try transformed(image, turns: edit.turns,
                                    flipHorizontal: edit.flipHorizontal, flipVertical: edit.flipVertical)
        }
        if edit.isResized {
            image = try resized(image, scale: edit.scale)
        }
        return image
    }

    /// Scaled by `scale` with high-quality interpolation (at least 1 × 1 pixel).
    static func resized(_ image: CGImage, scale: Double) throws -> CGImage {
        let factor = min(max(scale, 0.01), 8)
        let w = max(1, Int((Double(image.width) * factor).rounded()))
        let h = max(1, Int((Double(image.height) * factor).rounded()))
        guard let ctx = makeContext(width: w, height: h, like: image) else { throw ConversionError("Couldn't resize the image.") }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let result = ctx.makeImage() else { throw ConversionError("Couldn't resize the image.") }
        return result
    }

    /// How dark the spotlight makes everything around it.
    static let spotlightDim = 0.55

    /// Corner radius of a spotlight hole, in pixels of an image of the given size.
    static func spotlightRadius(width: CGFloat, height: CGFloat) -> CGFloat { min(width, height) * 0.012 }

    /// The text colour on a step circle: white, or black on light colours.
    static func stepTextColor(_ color: RGBAColor) -> RGBAColor {
        let luminance = 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
        return luminance > 0.62 ? .black : .white
    }

    /// The editor's live preview: background, redactions and colour (SwiftUI draws the rest on top).
    /// `mask` is the subject found on this preview. nil means "unchanged, show the plain preview".
    static func previewRender(_ edit: ImageEdit, on image: CGImage, mask: CGImage? = nil) -> CGImage? {
        var base = image
        var changed = false
        if let background = edit.background, let mask,
           let composed = try? BackgroundEngine.compose(image, mask: BackgroundEngine.mask(from: mask),
                                                        fill: background.fill, preview: true) {
            base = composed
            changed = true
        }
        guard !edit.redactions.isEmpty || edit.hasColorAdjustments else { return changed ? base : nil }
        let context = CIContext(options: [.cacheIntermediates: false])
        var ci = CIImage(cgImage: base)
        if !edit.redactions.isEmpty { ci = redact(ci, edit.redactions, width: image.width, height: image.height) }
        if edit.hasColorAdjustments { ci = adjustColors(ci, edit) }
        return try? ciRender(ci, width: image.width, height: image.height, like: image, context: context)
    }

    /// Downscaled, oriented copy for the editor plus the original's pixel size.
    static func loadPreview(_ url: URL, maxPixel: Int = 1400) throws -> PreviewImage {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
           let image = try? ImageConverter.renderedImage(source, index: 0, maxPixel: maxPixel) {
            var size = CGSize(width: image.width, height: image.height)
            if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
                // Orientations 5…8 are rotated a quarter turn, so width and height swap.
                let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
                size = orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
            }
            return PreviewImage(image: downscaled(image, maxPixel: maxPixel), originalSize: size)
        }
        // SVG and other files only NSImage can open.
        let full = try ImageConverter.loadCGImage(url)
        return PreviewImage(image: downscaled(full, maxPixel: maxPixel),
                            originalSize: CGSize(width: full.width, height: full.height))
    }

    /// Reads one pixel as sRGB. The self-test uses it to check edits landed where expected.
    static func samplePixel(_ url: URL, at point: NormPoint) throws -> RGBAColor {
        let image = try ImageConverter.loadCGImage(url)
        let x = min(image.width - 1, max(0, Int(point.x * Double(image.width))))
        let y = min(image.height - 1, max(0, Int(point.y * Double(image.height))))
        guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ConversionError("Couldn't read a pixel of \(url.lastPathComponent).")
        }
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { throw ConversionError("Couldn't read a pixel of \(url.lastPathComponent).") }
        return RGBAColor(red: Double(bytes[0]) / 255, green: Double(bytes[1]) / 255,
                         blue: Double(bytes[2]) / 255, alpha: Double(bytes[3]) / 255)
    }

    // MARK: Steps

    /// Covers each rectangle with black, a pixelated or a blurred copy of what's under it.
    /// Block size and blur radius scale with the image, so the preview looks like the result.
    static func redact(_ image: CIImage, _ redactions: [ImageEdit.Redaction], width: Int, height: Int) -> CIImage {
        var result = image
        let longest = Double(max(width, height))
        for redaction in redactions {
            let px = redaction.rect.pixelRect(width: width, height: height)
            // CoreImage's origin is bottom-left.
            let box = CGRect(x: px.minX, y: CGFloat(height) - px.maxY, width: px.width, height: px.height)
            let shortSide = Double(min(px.width, px.height))
            let cover: CIImage
            switch redaction.style {
            case .blackout:
                cover = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: box)
            case .pixelate:
                let filter = CIFilter.pixellate()
                filter.inputImage = result.clampedToExtent()
                filter.center = box.origin // align the blocks with the box
                filter.scale = Float(max(2, longest / 80, shortSide / 8))
                cover = (filter.outputImage ?? CIImage(color: CIColor(red: 0, green: 0, blue: 0))).cropped(to: box)
            case .blur:
                let filter = CIFilter.gaussianBlur()
                filter.inputImage = result.clampedToExtent() // no dark fringe at the image edges
                filter.radius = Float(max(2, longest / 100, shortSide / 4))
                cover = (filter.outputImage ?? CIImage(color: CIColor(red: 0, green: 0, blue: 0))).cropped(to: box)
            }
            result = cover.composited(over: result)
        }
        return result
    }

    static func adjustColors(_ image: CIImage, _ edit: ImageEdit) -> CIImage {
        var result = image
        if edit.brightness != 0 || edit.contrast != 1 || edit.saturation != 1 {
            let controls = CIFilter.colorControls()
            controls.inputImage = result
            controls.brightness = Float(min(max(edit.brightness, -1), 1))
            controls.contrast = Float(min(max(edit.contrast, 0.25), 4))
            controls.saturation = Float(min(max(edit.saturation, 0), 2))
            result = controls.outputImage ?? result
        }
        if edit.exposure != 0 {
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = result
            exposure.ev = Float(min(max(edit.exposure, -4), 4))
            result = exposure.outputImage ?? result
        }
        return result.cropped(to: image.extent)
    }

    /// Draws shapes and text with CoreGraphics. Normalized coordinates have a top-left origin
    /// and CoreGraphics' is bottom-left, so every y is flipped through point()/rect() here.
    static func drawAnnotations(_ annotations: [ImageEdit.Annotation], on image: CGImage) throws -> CGImage {
        guard let ctx = makeContext(width: image.width, height: image.height, like: image) else {
            throw ConversionError("Couldn't create a drawing canvas.")
        }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        func point(_ p: NormPoint) -> CGPoint {
            CGPoint(x: CGFloat(p.x) * w, y: (1 - CGFloat(p.y)) * h)
        }
        func rect(_ r: NormRect) -> CGRect {
            let c = r.clamped
            return CGRect(x: CGFloat(c.minX) * w, y: (1 - CGFloat(c.maxY)) * h,
                          width: CGFloat(c.width) * w, height: CGFloat(c.height) * h)
        }

        // Spotlights first, as one dimmed layer with a hole for each, so markup stays bright.
        let spots = annotations.compactMap { annotation -> NormRect? in
            if case .spotlight(let r) = annotation.kind { return r }
            return nil
        }
        if !spots.isEmpty {
            let radius = spotlightRadius(width: w, height: h)
            let path = CGMutablePath()
            path.addRect(CGRect(x: 0, y: 0, width: w, height: h))
            for spot in spots {
                let box = rect(spot)
                guard box.width > 1, box.height > 1 else { continue }
                path.addPath(CGPath(roundedRect: box, cornerWidth: min(radius, box.width / 2), cornerHeight: min(radius, box.height / 2),
                                    transform: nil))
            }
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 0, alpha: CGFloat(spotlightDim)))
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
        }

        for annotation in annotations {
            let color = annotation.color.cgColor
            let lineWidth = max(1, CGFloat(annotation.size) * h)
            ctx.saveGState()
            switch annotation.kind {
            case .spotlight:
                break
            case .ellipse(let r):
                let box = rect(r)
                if box.width > lineWidth && box.height > lineWidth {
                    ctx.setStrokeColor(color)
                    ctx.setLineWidth(lineWidth)
                    ctx.strokeEllipse(in: box.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
                }
            case .line(let from, let to):
                ctx.setStrokeColor(color)
                ctx.setLineWidth(lineWidth)
                ctx.setLineCap(.round)
                ctx.beginPath()
                ctx.move(to: point(from))
                ctx.addLine(to: point(to))
                ctx.strokePath()
            case .step(let number, let at):
                let diameter = max(8, CGFloat(annotation.size) * h)
                let centre = point(at)
                let circle = CGRect(x: centre.x - diameter / 2, y: centre.y - diameter / 2, width: diameter, height: diameter)
                ctx.setFillColor(color)
                ctx.fillEllipse(in: circle)
                ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
                ctx.setLineWidth(max(1, diameter * 0.06))
                ctx.strokeEllipse(in: circle.insetBy(dx: diameter * 0.03, dy: diameter * 0.03))
                drawCentredText("\(number)", centre: centre, fontSize: diameter * 0.56,
                                color: stepTextColor(annotation.color).cgColor, in: ctx)
            case .rectangle(let r):
                let box = rect(r)
                if box.width > lineWidth && box.height > lineWidth {
                    // Stroke inside the box, matching SwiftUI's strokeBorder in the editor.
                    ctx.setStrokeColor(color)
                    ctx.setLineJoin(.miter)
                    ctx.stroke(box.insetBy(dx: lineWidth / 2, dy: lineWidth / 2), width: lineWidth)
                } else {
                    ctx.setFillColor(color)
                    ctx.fill(box)
                }
            case .highlight(let r):
                ctx.setFillColor(highlightColor(annotation.color).cgColor)
                ctx.fill(rect(r))
            case .arrow(let from, let to):
                let start = point(from)
                if let shape = arrowShape(from: start, to: point(to), lineWidth: lineWidth) {
                    ctx.setStrokeColor(color)
                    ctx.setFillColor(color)
                    ctx.setLineWidth(lineWidth)
                    ctx.setLineCap(.round)
                    ctx.beginPath()
                    ctx.move(to: start)
                    ctx.addLine(to: shape.shaftEnd)
                    ctx.strokePath()
                    ctx.beginPath()
                    ctx.addLines(between: shape.head)
                    ctx.closePath()
                    ctx.fillPath()
                }
            case .text(let string, let at):
                drawText(string, topLeft: point(at), fontSize: max(4, CGFloat(annotation.size) * h), color: color, in: ctx)
            }
            ctx.restoreGState()
        }
        guard let result = ctx.makeImage() else { throw ConversionError("Couldn't draw the annotations.") }
        return result
    }

    /// Bold text centred on a point (CoreGraphics coordinates), for step numbers.
    private static func drawCentredText(_ string: String, centre: CGPoint, fontSize: CGFloat, color: CGColor, in ctx: CGContext) {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
        guard let attributed = CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary) else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: centre.x - bounds.midX, y: centre.y - bounds.midY)
        CTLineDraw(line, ctx)
    }

    /// One line of bold system text. `topLeft` is in CoreGraphics coordinates (y up),
    /// so the baseline sits one ascent below it.
    private static func drawText(_ string: String, topLeft: CGPoint, fontSize: CGFloat, color: CGColor, in ctx: CGContext) {
        guard !string.isEmpty else { return }
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
        guard let attributed = CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary) else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: topLeft.x, y: topLeft.y - ascent)
        CTLineDraw(line, ctx)
    }

    /// The highlighter's see-through fill.
    static func highlightColor(_ color: RGBAColor) -> RGBAColor { color.withAlpha(color.alpha * 0.4) }

    /// Shaft end and arrowhead triangle for an arrow, in whatever coordinates the points use.
    /// Shared by the renderer and the editor so both draw the same arrow.
    static func arrowShape(from a: CGPoint, to b: CGPoint, lineWidth: CGFloat) -> (shaftEnd: CGPoint, head: [CGPoint])? {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.5 else { return nil }
        let ux = dx / length, uy = dy / length
        let headLength = min(lineWidth * 4.5, length)
        let halfWidth = headLength * 0.55
        let base = CGPoint(x: b.x - ux * headLength, y: b.y - uy * headLength)
        let left = CGPoint(x: base.x - uy * halfWidth, y: base.y + ux * halfWidth)
        let right = CGPoint(x: base.x + uy * halfWidth, y: base.y - ux * halfWidth)
        // End the shaft just inside the head so the round cap doesn't poke out.
        let shaftEnd = CGPoint(x: b.x - ux * headLength * 0.9, y: b.y - uy * headLength * 0.9)
        return (shaftEnd, [b, left, right])
    }

    /// Rotates clockwise by quarter turns, then mirrors in the rotated frame (as the editor shows it).
    static func transformed(_ image: CGImage, turns: Int, flipHorizontal: Bool, flipVertical: Bool) throws -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let swap = turns % 2 == 1
        let outWidth = swap ? image.height : image.width
        let outHeight = swap ? image.width : image.height
        guard let ctx = makeContext(width: outWidth, height: outHeight, like: image) else {
            throw ConversionError("Couldn't create a canvas to rotate the image.")
        }
        // CoreGraphics is y-up, so a clockwise turn on screen maps (x, y) to (y, w - x).
        var transform: CGAffineTransform
        switch turns {
        case 1: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 2: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 3: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: transform = .identity
        }
        if flipHorizontal {
            transform = transform.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: CGFloat(outWidth), ty: 0))
        }
        if flipVertical {
            transform = transform.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(outHeight)))
        }
        ctx.interpolationQuality = .none // whole-pixel moves only
        ctx.concatenate(transform)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let result = ctx.makeImage() else { throw ConversionError("Couldn't rotate the image.") }
        return result
    }

    // MARK: Helpers

    /// The image's own RGB colour space when it can be drawn into, so wide-gamut photos stay wide.
    private static func workingSpace(for image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb, space.supportsOutput { return space }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    private static func makeContext(width: Int, height: Int, like image: CGImage) -> CGContext? {
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        if let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                               space: workingSpace(for: image), bitmapInfo: info) {
            return ctx
        }
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: srgb, bitmapInfo: info)
    }

    private static func ciRender(_ image: CIImage, width: Int, height: Int, like source: CGImage,
                                 context: CIContext) throws -> CGImage {
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if let result = context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: workingSpace(for: source)) {
            return result
        }
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB),
           let result = context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: srgb) {
            return result
        }
        throw ConversionError("Couldn't process the image.")
    }

    private static func downscaled(_ image: CGImage, maxPixel: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxPixel, maxPixel > 0 else { return image }
        let scale = Double(maxPixel) / Double(longest)
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        guard let ctx = makeContext(width: w, height: h, like: image) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    /// Encodes one image, copying the original's metadata (with orientation reset, since
    /// it's baked into the pixels) when `metadataFrom` is given.
    private static func encode(_ image: CGImage, type: UTType, quality: Double, metadataFrom input: URL?) throws -> Data {
        let output = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(output as CFMutableData, type.identifier as CFString, 1, nil) else {
            throw ConversionError("This Mac can't write \(type.preferredFilenameExtension ?? "that format") images.")
        }
        var props: [CFString: Any] = [:]
        if let input, let source = CGImageSourceCreateWithURL(input as CFURL, nil),
           let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            props = original
            props[kCGImagePropertyOrientation] = 1
            props[kCGImagePropertyPixelWidth] = nil
            props[kCGImagePropertyPixelHeight] = nil
            // Describe the new pixels, not the old ones (a cut-out JPEG gains transparency).
            for key in [kCGImagePropertyHasAlpha, kCGImagePropertyDepth, kCGImagePropertyIsIndexed, kCGImagePropertyIsFloat] {
                props[key] = nil
            }
            if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                props[kCGImagePropertyTIFFDictionary] = tiff
            }
            if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif[kCGImagePropertyExifPixelXDimension] = image.width
                exif[kCGImagePropertyExifPixelYDimension] = image.height
                props[kCGImagePropertyExifDictionary] = exif
            }
        }
        props[kCGImageDestinationLossyCompressionQuality] = quality
        let finalImage = ImageConverter.supportsAlpha(type) ? image : ImageConverter.flatten(image)
        CGImageDestinationAddImage(dest, finalImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError("Couldn't encode the image.") }
        return output as Data
    }
}

// MARK: - Editor

/// Sheet for editing one photo. Overlays are drawn by SwiftUI on a downscaled preview; Save hands
/// the finished ImageEdit back and ImageEditEngine renders it at full size, so nothing here touches
/// the original file.
@MainActor
struct ImageEditorView: View {
    let url: URL
    let onSave: (ImageEdit) -> Void
    let onCancel: () -> Void

    /// `showcase` opens on the Background panel with that background chosen (for the window pictures).
    /// `startOnMarkup` opens on the Markup tools (for captures); `markup` adds annotations to start with.
    init(url: URL, showcase: BackgroundEdit? = nil, startOnMarkup: Bool = false, markup: [ImageEdit.Annotation] = [],
         onSave: @escaping (ImageEdit) -> Void, onCancel: @escaping () -> Void) {
        self.url = url
        self.onSave = onSave
        self.onCancel = onCancel
        if let showcase {
            var edit = ImageEdit()
            edit.background = showcase
            _edit = State(initialValue: edit)
            _tool = State(initialValue: .background)
        } else if startOnMarkup || !markup.isEmpty {
            var edit = ImageEdit()
            edit.annotations = markup
            _edit = State(initialValue: edit)
            _addedOrder = State(initialValue: markup.map(\.id))
            _tool = State(initialValue: .annotate)
            _markup = State(initialValue: .arrow)
        }
    }

    private enum Tool: String, CaseIterable, Identifiable {
        case crop = "Crop", redact = "Redact", annotate = "Markup", adjust = "Adjust", background = "Background"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .crop: "crop"
            case .redact: "eye.slash"
            case .annotate: "pencil.tip.crop.circle"
            case .adjust: "slider.horizontal.3"
            case .background: "scissors"
            }
        }
    }

    private enum CropAspect: String, CaseIterable, Identifiable {
        case free = "Free", square = "1:1", fourThree = "4:3", threeTwo = "3:2", sixteenNine = "16:9", nineSixteen = "9:16"
        var id: String { rawValue }

        /// Width ÷ height of the saved image.
        var ratio: Double? {
            switch self {
            case .free: return nil
            case .square: return 1
            case .fourThree: return 4.0 / 3.0
            case .threeTwo: return 3.0 / 2.0
            case .sixteenNine: return 16.0 / 9.0
            case .nineSixteen: return 9.0 / 16.0
            }
        }
    }

    private enum Markup: String, CaseIterable, Identifiable {
        case arrow = "Arrow", rectangle = "Box", ellipse = "Oval", line = "Line",
             text = "Text", step = "Steps", highlight = "Highlight", spotlight = "Spotlight"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .arrow: "arrow.up.right"
            case .rectangle: "rectangle"
            case .ellipse: "circle"
            case .line: "line.diagonal"
            case .text: "textformat"
            case .step: "1.circle.fill"
            case .highlight: "highlighter"
            case .spotlight: "light.max"
            }
        }
    }

    private struct DragState {
        var start: NormPoint
        var current: NormPoint
        /// Set when a crop drag starts inside the crop box: the box moves instead of being redrawn.
        var movingCrop: NormRect?
    }

    /// What the rendered preview depends on; changing it re-renders (debounced).
    private struct PreviewKey: Equatable {
        var redactions: [ImageEdit.Redaction]
        var brightness: Double
        var contrast: Double
        var saturation: Double
        var exposure: Double
        var background: BackgroundEdit?
        var loaded: Bool
        var maskReady: Bool
    }

    /// Slider level (1…10) → fraction of the image height.
    private static let textScale = 0.012
    private static let lineScale = 0.002
    private static let stepScale = 0.014
    private static let formats: [OutputFormat] = [.jpeg, .png, .heic, .tiff]

    @State private var edit = ImageEdit()
    /// Oriented original, downscaled to at most 1400 px.
    @State private var preview: CGImage? = nil
    /// `preview` with redactions and colour applied; nil when there are none.
    @State private var rendered: CGImage? = nil
    @State private var originalSize = CGSize.zero
    @State private var loadError: String? = nil
    @State private var tool: Tool = .crop
    @State private var aspect: CropAspect = .free
    @State private var redactionStyle: ImageEdit.RedactionStyle = .blackout
    @State private var markup: Markup = .rectangle
    @State private var color: RGBAColor = .brightRed
    @State private var sizeLevel = 4.0
    @State private var drag: DragState? = nil
    @State private var textDraft = ""
    @State private var pendingText: NormPoint? = nil
    /// Ids of added redactions and annotations, oldest first, for Undo.
    @State private var addedOrder: [UUID] = []
    /// The subject found on `preview`, for the Background panel; found the first time it's needed.
    @State private var subjectMask: CGImage? = nil
    @State private var subjectStatus: SubjectStatus = .idle
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                canvasArea
                Divider()
                transformBar
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.surface)
            }
            Divider()
            sidebar
                .frame(width: 324)
                .background(Theme.surface)
        }
        .frame(minWidth: 800, idealWidth: 1000, minHeight: 560, idealHeight: 700)
        .task(id: url) { await loadPreview() }
        .task(id: previewKey) { await refreshRendered() }
        .task(id: wantsSubject) { await findSubject() }
    }

    private var previewKey: PreviewKey {
        PreviewKey(redactions: edit.redactions, brightness: edit.brightness, contrast: edit.contrast,
                   saturation: edit.saturation, exposure: edit.exposure, background: edit.background,
                   loaded: preview != nil, maskReady: subjectMask != nil)
    }

    private var wantsSubject: Bool { (tool == .background || edit.background != nil) && preview != nil }

    // MARK: Canvas

    private var canvasArea: some View {
        GeometryReader { proxy in
            ZStack {
                Color.adaptive(light: 0xE6E6EC, dark: 0x0B0B0E)
                if let image = rendered ?? preview {
                    let size = canvasSize(imageWidth: image.width, imageHeight: image.height, in: proxy.size)
                    // Turns and flips are only shown here; drawing still happens in the
                    // unrotated canvas, whose local coordinates SwiftUI maps through the effects.
                    editorCanvas(image: image, size: size)
                        .rotationEffect(.degrees(Double(edit.turns) * 90))
                        .scaleEffect(x: edit.flipHorizontal ? -1 : 1, y: edit.flipVertical ? -1 : 1)
                } else if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ProgressView()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    /// Size of the unrotated canvas: the image aspect-fitted into the space as it's turned on
    /// screen. The canvas is exactly the image, so the letterbox margins sit outside it and
    /// view → normalized coordinates is a plain division.
    private func canvasSize(imageWidth: Int, imageHeight: Int, in space: CGSize) -> CGSize {
        let available = CGSize(width: max(1, space.width - 32), height: max(1, space.height - 32))
        let imageAspect = CGFloat(max(1, imageWidth)) / CGFloat(max(1, imageHeight))
        let sideways = edit.turns % 2 == 1
        let shownAspect = sideways ? 1 / imageAspect : imageAspect
        var shown = CGSize(width: available.width, height: available.width / shownAspect)
        if shown.height > available.height {
            shown = CGSize(width: available.height * shownAspect, height: available.height)
        }
        return sideways ? CGSize(width: shown.height, height: shown.width) : shown
    }

    private func editorCanvas(image: CGImage, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            // Shows through where the picture is transparent (a cut-out, or a PNG with no background).
            Checkerboard()
                .frame(width: size.width, height: size.height)
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
            Canvas { context, area in
                drawOverlays(in: &context, size: area)
            }
            .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in dragChanged(value, canvas: size) }
                .onEnded { value in dragEnded(value, canvas: size) }
        )
    }

    private static func viewRect(_ r: NormRect, in size: CGSize) -> CGRect {
        CGRect(x: CGFloat(r.x) * size.width, y: CGFloat(r.y) * size.height,
               width: CGFloat(r.width) * size.width, height: CGFloat(r.height) * size.height)
    }

    private static func viewPoint(_ p: NormPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(p.x) * size.width, y: CGFloat(p.y) * size.height)
    }

    private static func normalized(_ p: CGPoint, in size: CGSize) -> NormPoint {
        NormPoint(x: Double(p.x / max(size.width, 1)), y: Double(p.y / max(size.height, 1))).clamped
    }

    private func drawOverlays(in context: inout GraphicsContext, size: CGSize) {
        if let crop = edit.crop {
            let box = Self.viewRect(crop, in: size)
            var outside = Path(CGRect(origin: .zero, size: size))
            outside.addRect(box)
            context.fill(outside, with: .color(.black.opacity(tool == .crop ? 0.55 : 0.35)), style: FillStyle(eoFill: true))
            context.stroke(Path(box), with: .color(.white), lineWidth: 1.5)
            if tool == .crop {
                var thirds = Path()
                for i in 1...2 {
                    let fx = box.minX + box.width * CGFloat(i) / 3
                    let fy = box.minY + box.height * CGFloat(i) / 3
                    thirds.move(to: CGPoint(x: fx, y: box.minY))
                    thirds.addLine(to: CGPoint(x: fx, y: box.maxY))
                    thirds.move(to: CGPoint(x: box.minX, y: fy))
                    thirds.addLine(to: CGPoint(x: box.maxX, y: fy))
                }
                context.stroke(thirds, with: .color(.white.opacity(0.45)), lineWidth: 0.5)
            }
        }
        // Redactions are already rendered into the preview; outline them so they can be found.
        for redaction in edit.redactions {
            outline(Self.viewRect(redaction.rect, in: size), in: &context, shaded: false)
        }
        var spots = edit.annotations.compactMap { annotation -> NormRect? in
            if case .spotlight(let r) = annotation.kind { return r }
            return nil
        }
        if let drag, tool == .annotate, markup == .spotlight {
            spots.append(NormRect(from: drag.start, to: drag.current))
        }
        if !spots.isEmpty {
            var dim = Path(CGRect(origin: .zero, size: size))
            let radius = ImageEditEngine.spotlightRadius(width: size.width, height: size.height)
            for spot in spots {
                dim.addRoundedRect(in: Self.viewRect(spot.clamped, in: size), cornerSize: CGSize(width: radius, height: radius))
            }
            context.fill(dim, with: .color(.black.opacity(ImageEditEngine.spotlightDim)), style: FillStyle(eoFill: true))
        }
        for annotation in edit.annotations {
            drawAnnotation(annotation, in: &context, size: size)
        }
        if let drag {
            let box = NormRect(from: drag.start, to: drag.current)
            if tool == .redact {
                outline(Self.viewRect(box, in: size), in: &context, shaded: true)
            } else if tool == .annotate, markup != .spotlight, let kind = draftKind(for: drag) {
                let draft = ImageEdit.Annotation(kind: kind, color: color, size: annotationSize(for: kind))
                drawAnnotation(draft, in: &context, size: size)
            }
        }
        if tool == .annotate, markup == .text, let pendingText {
            let p = Self.viewPoint(pendingText, in: size)
            let fontSize = max(4, CGFloat(sizeLevel * Self.textScale) * size.height)
            let placeholder = textDraft.isEmpty ? "Type your text…" : textDraft
            context.draw(Text(placeholder).font(.system(size: fontSize, weight: .bold)).foregroundColor(color.swiftUI.opacity(0.6)),
                         at: p, anchor: .topLeading)
            var marker = Path()
            marker.addEllipse(in: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
            context.fill(marker, with: .color(Theme.accent))
        }
    }

    private func outline(_ box: CGRect, in context: inout GraphicsContext, shaded: Bool) {
        if shaded { context.fill(Path(box), with: .color(.black.opacity(0.3))) }
        context.stroke(Path(box), with: .color(.black.opacity(0.6)), lineWidth: 2)
        context.stroke(Path(box), with: .color(.white), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
    }

    /// Mirrors ImageEditEngine.drawAnnotations, in view coordinates (y down, so no flipping).
    private func drawAnnotation(_ annotation: ImageEdit.Annotation, in context: inout GraphicsContext, size: CGSize) {
        let shade = annotation.color.swiftUI
        let lineWidth = max(1, CGFloat(annotation.size) * size.height)
        switch annotation.kind {
        case .spotlight:
            break
        case .ellipse(let r):
            let box = Self.viewRect(r.clamped, in: size)
            if box.width > lineWidth && box.height > lineWidth {
                context.stroke(Path(ellipseIn: box.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)), with: .color(shade),
                               lineWidth: lineWidth)
            }
        case .line(let from, let to):
            var path = Path()
            path.move(to: Self.viewPoint(from, in: size))
            path.addLine(to: Self.viewPoint(to, in: size))
            context.stroke(path, with: .color(shade), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        case .step(let number, let at):
            let diameter = max(8, CGFloat(annotation.size) * size.height)
            let centre = Self.viewPoint(at, in: size)
            let circle = CGRect(x: centre.x - diameter / 2, y: centre.y - diameter / 2, width: diameter, height: diameter)
            context.fill(Path(ellipseIn: circle), with: .color(shade))
            context.stroke(Path(ellipseIn: circle.insetBy(dx: diameter * 0.03, dy: diameter * 0.03)),
                           with: .color(.white.opacity(0.9)), lineWidth: max(1, diameter * 0.06))
            let textColor = ImageEditEngine.stepTextColor(annotation.color).swiftUI
            context.draw(Text("\(number)").font(.system(size: diameter * 0.56, weight: .bold)).foregroundColor(textColor),
                         at: centre, anchor: .center)
        case .rectangle(let r):
            let box = Self.viewRect(r.clamped, in: size)
            if box.width > lineWidth && box.height > lineWidth {
                context.stroke(Path(box.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)), with: .color(shade),
                               style: StrokeStyle(lineWidth: lineWidth, lineJoin: .miter))
            } else {
                context.fill(Path(box), with: .color(shade))
            }
        case .highlight(let r):
            let fill = ImageEditEngine.highlightColor(annotation.color).swiftUI
            context.fill(Path(Self.viewRect(r.clamped, in: size)), with: .color(fill))
        case .arrow(let from, let to):
            let start = Self.viewPoint(from, in: size)
            guard let shape = ImageEditEngine.arrowShape(from: start, to: Self.viewPoint(to, in: size),
                                                         lineWidth: lineWidth) else { return }
            var shaft = Path()
            shaft.move(to: start)
            shaft.addLine(to: shape.shaftEnd)
            context.stroke(shaft, with: .color(shade), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            var head = Path()
            head.addLines(shape.head)
            head.closeSubpath()
            context.fill(head, with: .color(shade))
        case .text(let string, let at):
            let fontSize = max(4, CGFloat(annotation.size) * size.height)
            context.draw(Text(string).font(.system(size: fontSize, weight: .bold)).foregroundColor(shade),
                         at: Self.viewPoint(at, in: size), anchor: .topLeading)
        }
    }

    // MARK: Dragging

    private func dragChanged(_ value: DragGesture.Value, canvas: CGSize) {
        let current = Self.normalized(value.location, in: canvas)
        var state = drag ?? DragState(start: Self.normalized(value.startLocation, in: canvas), current: current)
        if drag == nil, tool == .crop, let crop = edit.crop, crop.contains(state.start) {
            state.movingCrop = crop
        }
        state.current = current
        drag = state
        if tool == .crop { updateCrop(with: state) }
    }

    private func dragEnded(_ value: DragGesture.Value, canvas: CGSize) {
        let end = Self.normalized(value.location, in: canvas)
        var state = drag ?? DragState(start: Self.normalized(value.startLocation, in: canvas), current: end)
        state.current = end
        drag = nil
        let box = NormRect(from: state.start, to: state.current)
        let isClick = box.width < 0.004 && box.height < 0.004
        switch tool {
        case .crop:
            updateCrop(with: state)
            // A click (or a sliver) outside the box clears the crop.
            if let crop = edit.crop, crop.width < 0.01 || crop.height < 0.01 { edit.crop = nil }
        case .redact:
            if !isClick { add(ImageEdit.Redaction(rect: box, style: redactionStyle)) }
        case .annotate:
            if markup == .text {
                placeText(at: state.start)
            } else if markup == .step {
                add(ImageEdit.Annotation(kind: .step(nextStep, at: state.current), color: color, size: sizeLevel * Self.stepScale))
            } else if !isClick, let kind = draftKind(for: state) {
                add(ImageEdit.Annotation(kind: kind, color: color, size: annotationSize(for: kind)))
            }
        case .adjust, .background:
            break
        }
    }

    private func updateCrop(with state: DragState) {
        if let moving = state.movingCrop {
            let dx = min(max(state.current.x - state.start.x, -moving.minX), 1 - moving.maxX)
            let dy = min(max(state.current.y - state.start.y, -moving.minY), 1 - moving.maxY)
            edit.crop = NormRect(x: moving.x + dx, y: moving.y + dy, width: moving.width, height: moving.height)
        } else {
            edit.crop = constrainedRect(from: state.start, to: state.current)
        }
    }

    /// The crop box from a drag, held to the chosen aspect ratio and inside the image.
    private func constrainedRect(from s: NormPoint, to c: NormPoint) -> NormRect {
        guard let ratio = normalizedAspect(for: aspect) else { return NormRect(from: s, to: c) }
        let dx = c.x - s.x, dy = c.y - s.y
        var w = abs(dx), h = abs(dy)
        if h == 0 || w / h > ratio { h = w / ratio } else { w = h * ratio }
        let maxW = dx < 0 ? s.x : 1 - s.x
        let maxH = dy < 0 ? s.y : 1 - s.y
        if w > maxW { w = maxW; h = w / ratio }
        if h > maxH { h = maxH; w = h * ratio }
        return NormRect(x: dx < 0 ? s.x - w : s.x, y: dy < 0 ? s.y - h : s.y, width: w, height: h)
    }

    /// An aspect preset as normalized width ÷ normalized height in the original's coordinates.
    private func normalizedAspect(for preset: CropAspect) -> Double? {
        guard let ratio = preset.ratio else { return nil }
        let size = originalSize.width > 0
            ? originalSize
            : CGSize(width: preview?.width ?? 1, height: preview?.height ?? 1)
        guard size.width > 0, size.height > 0 else { return nil }
        // A sideways image is cropped before it's turned, so the box is the other way round.
        let pixelRatio = edit.turns % 2 == 1 ? 1 / ratio : ratio
        return pixelRatio * Double(size.height) / Double(size.width)
    }

    private func choose(_ preset: CropAspect) {
        aspect = preset
        fitCrop(to: preset, within: edit.crop ?? .full)
    }

    /// Largest box of the preset's shape centred in `bounds`.
    private func fitCrop(to preset: CropAspect, within bounds: NormRect) {
        guard let ratio = normalizedAspect(for: preset) else { return }
        var w = bounds.width, h = bounds.width / ratio
        if h > bounds.height { h = bounds.height; w = h * ratio }
        edit.crop = NormRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    private func draftKind(for state: DragState) -> ImageEdit.AnnotationKind? {
        let box = NormRect(from: state.start, to: state.current)
        switch markup {
        case .text, .step:
            return nil
        case .rectangle:
            return .rectangle(box)
        case .ellipse:
            return .ellipse(box)
        case .spotlight:
            return .spotlight(box)
        case .line:
            let dx = state.current.x - state.start.x, dy = state.current.y - state.start.y
            return (dx * dx + dy * dy).squareRoot() > 0.005 ? .line(from: state.start, to: state.current) : nil
        case .highlight:
            return .highlight(box)
        case .arrow:
            let dx = state.current.x - state.start.x, dy = state.current.y - state.start.y
            return (dx * dx + dy * dy).squareRoot() > 0.005 ? .arrow(from: state.start, to: state.current) : nil
        }
    }

    private func annotationSize(for kind: ImageEdit.AnnotationKind) -> Double {
        switch kind {
        case .text: return sizeLevel * Self.textScale
        case .step: return sizeLevel * Self.stepScale
        case .spotlight, .highlight: return 0
        default: return sizeLevel * Self.lineScale
        }
    }

    /// The number the next step circle gets.
    private var nextStep: Int {
        let numbers = edit.annotations.compactMap { annotation -> Int? in
            if case .step(let n, _) = annotation.kind { return n }
            return nil
        }
        return (numbers.max() ?? 0) + 1
    }

    // MARK: Items

    /// Text goes where the user clicked: straight away if it's typed already, else after Return.
    private func placeText(at point: NormPoint) {
        let text = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            pendingText = point
            textFieldFocused = true
        } else {
            add(ImageEdit.Annotation(kind: .text(text, at: point), color: color, size: sizeLevel * Self.textScale))
            textDraft = ""
            pendingText = nil
        }
    }

    private func commitPendingText() {
        let text = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let point = pendingText else { return }
        add(ImageEdit.Annotation(kind: .text(text, at: point), color: color, size: sizeLevel * Self.textScale))
        textDraft = ""
        pendingText = nil
    }

    private func add(_ redaction: ImageEdit.Redaction) {
        edit.redactions.append(redaction)
        addedOrder.append(redaction.id)
    }

    private func add(_ annotation: ImageEdit.Annotation) {
        edit.annotations.append(annotation)
        addedOrder.append(annotation.id)
    }

    private func remove(_ id: UUID) {
        edit.redactions.removeAll { $0.id == id }
        edit.annotations.removeAll { $0.id == id }
        addedOrder.removeAll { $0 == id }
    }

    private func undoLast() {
        guard let id = addedOrder.last else { return }
        remove(id)
    }

    private func rotate(clockwise: Bool) {
        // One mirror reverses the direction a turn appears to go on screen.
        let mirrored = edit.flipHorizontal != edit.flipVertical
        let step = clockwise != mirrored ? 1 : 3
        edit.quarterTurns = (edit.turns + step) % 4
        // The saved image's shape flipped, so a locked aspect needs a fresh box.
        if aspect != .free, edit.crop != nil { fitCrop(to: aspect, within: .full) }
    }

    private func save() {
        var result = edit
        if let crop = result.crop?.clamped {
            result.crop = (crop.isFull || crop.width < 0.001 || crop.height < 0.001) ? nil : crop
        }
        onSave(result)
    }

    // MARK: Loading

    private func loadPreview() async {
        let url = self.url
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try ImageEditEngine.loadPreview(url, maxPixel: 1400)
            }.value
            preview = loaded.image
            originalSize = loaded.originalSize
        } catch {
            loadError = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Re-renders redactions and colour on the preview. `.task(id:)` cancels this when the key
    /// changes again, which debounces slider drags.
    private func refreshRendered() async {
        guard let base = preview else { return }
        let edit = self.edit
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard !Task.isCancelled else { return }
        let box = ImageEditEngine.PreviewImage(image: base, originalSize: .zero)
        let maskBox = subjectMask.map { ImageEditEngine.PreviewImage(image: $0, originalSize: .zero) }
        let result = await Task.detached(priority: .userInitiated) {
            ImageEditEngine.previewRender(edit, on: box.image, mask: maskBox?.image)
                .map { ImageEditEngine.PreviewImage(image: $0, originalSize: .zero) }
        }.value
        guard !Task.isCancelled else { return }
        rendered = result?.image
    }

    /// Finds the subject on the preview once; the Background panel waits for it.
    private func findSubject() async {
        guard wantsSubject, subjectMask == nil, let base = preview else { return }
        if case .failed = subjectStatus { return } // only again from Try Again
        subjectStatus = .finding
        let box = ImageEditEngine.PreviewImage(image: base, originalSize: .zero)
        do {
            let mask = try await Task.detached(priority: .userInitiated) {
                ImageEditEngine.PreviewImage(image: try BackgroundEngine.maskImage(for: box.image), originalSize: .zero)
            }.value
            subjectMask = mask.image
            subjectStatus = .ready
        } catch {
            subjectStatus = .failed(error.localizedDescription)
        }
    }

    // MARK: Bottom bar

    private var transformBar: some View {
        HStack(spacing: 6) {
            Button { rotate(clockwise: false) } label: { Image(systemName: "rotate.left") }
                .help("Rotate left")
            Button { rotate(clockwise: true) } label: { Image(systemName: "rotate.right") }
                .help("Rotate right")
            Button { edit.flipHorizontal.toggle() } label: {
                Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            .help("Flip horizontally")
            Button { edit.flipVertical.toggle() } label: {
                Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
            }
            .help("Flip vertically")
            Divider().frame(height: 18)
            Button { undoLast() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(addedOrder.isEmpty)
                .help("Remove the last box, arrow or text")
            Spacer()
            Text(outputSizeText)
                .font(Theme.Fonts.body)
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var outputSizeText: String {
        guard originalSize.width > 0, originalSize.height > 0 else { return "" }
        let fullWidth = Int(originalSize.width), fullHeight = Int(originalSize.height)
        var w = fullWidth, h = fullHeight
        if let crop = edit.crop {
            let rect = crop.pixelRect(width: fullWidth, height: fullHeight)
            w = Int(rect.width)
            h = Int(rect.height)
        }
        if edit.turns % 2 == 1 { swap(&w, &h) }
        if edit.isResized {
            w = max(1, Int((Double(w) * edit.scale).rounded()))
            h = max(1, Int((Double(h) * edit.scale).rounded()))
        }
        return "\(w) × \(h)"
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolBar
                .padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tool {
                    case .crop: cropControls
                    case .redact: redactControls
                    case .annotate: annotateControls
                    case .adjust: adjustControls
                    case .background:
                        BackgroundPanel(background: $edit.background, status: subjectStatus) {
                            subjectStatus = .idle
                            Task { await findSubject() }
                        }
                    }
                    if tool == .redact || tool == .annotate {
                        Divider()
                        itemList
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer.padding(12)
        }
    }

    /// The editor's tools as a row of symbol tabs.
    private var toolBar: some View {
        HStack(spacing: 2) {
            ForEach(Tool.allCases) { item in
                let selected = tool == item
                Button { tool = item } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 14, weight: selected ? .semibold : .regular))
                            .frame(height: 17)
                        Text(item.rawValue)
                            .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .foregroundStyle(selected ? Theme.accentText : Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(selected ? Theme.accent.opacity(0.12) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .strokeBorder(selected ? Theme.accent.opacity(0.55) : Color.clear, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.rawValue)
            }
        }
    }

    private var cropControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            hint("Drag on the photo to choose what to keep. Drag inside the box to move it; click outside it to start over.")
            SectionLabel("Aspect ratio")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 6)], spacing: 6) {
                ForEach(CropAspect.allCases) { preset in
                    Button { choose(preset) } label: {
                        HStack(spacing: 3) {
                            if aspect == preset { Image(systemName: "checkmark") }
                            Text(preset.rawValue)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(aspect == preset ? Theme.accent : nil)
                }
            }
            Button("Reset Crop") { edit.crop = nil }
                .disabled(edit.crop == nil)
            SectionLabel("Resize")
            Picker("Resize", selection: $edit.scale) {
                Text("100%").tag(1.0)
                Text("75%").tag(0.75)
                Text("50%").tag(0.5)
                Text("25%").tag(0.25)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Saved at \(outputSizeText) pixels.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var redactControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            hint("Drag over anything you want to hide: faces, names, addresses, card numbers.")
            Picker("Style", selection: $redactionStyle) {
                ForEach(ImageEdit.RedactionStyle.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Black boxes are the safest choice for text: blur and pixelation can sometimes be partly undone.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var annotateControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(Markup.allCases) { item in markupTile(item) }
            }
            hint(markupHint)
            if markup == .text {
                TextField("Text", text: $textDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($textFieldFocused)
                    .onSubmit { commitPendingText() }
            }
            if markup != .spotlight {
            SectionLabel("Colour")
            HStack(spacing: 8) {
                ForEach(RGBAColor.swatches, id: \.self) { swatch in
                    Button { color = swatch } label: {
                        Circle()
                            .fill(swatch.swiftUI)
                            .frame(width: 22, height: 22)
                            .overlay {
                                Circle().strokeBorder(swatch == color ? Theme.accent : Color.secondary.opacity(0.5),
                                                      lineWidth: swatch == color ? 3 : 1)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            }
            if markup != .highlight && markup != .spotlight {
                SectionLabel(markup == .text ? "Text size" : (markup == .step ? "Circle size" : "Line width"))
                Slider(value: $sizeLevel, in: 1...10)
            }
        }
    }

    private func markupTile(_ item: Markup) -> some View {
        let selected = markup == item
        return Button { markup = item } label: {
            VStack(spacing: 4) {
                Image(systemName: item.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(height: 17)
                Text(item.rawValue)
                    .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? Theme.accentText : Theme.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.12) : Theme.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.hairline, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var markupHint: String {
        switch markup {
        case .text:
            return pendingText == nil
                ? "Click where the text should start, then type it below and press Return."
                : "Type the text below and press Return to place it."
        case .rectangle:
            return "Drag to draw a box around something."
        case .arrow:
            return "Drag from where the arrow starts to what it points at."
        case .highlight:
            return "Drag over something to highlight it."
        case .ellipse:
            return "Drag to draw an oval around something."
        case .line:
            return "Drag to draw a straight line."
        case .step:
            return "Click to place numbered steps: 1, 2, 3…"
        case .spotlight:
            return "Drag over what matters; everything else is dimmed."
        }
    }

    private var adjustControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            adjustmentSlider("Brightness", value: $edit.brightness, range: -0.5...0.5, neutral: 0) {
                String(format: "%+.0f", $0 * 200)
            }
            adjustmentSlider("Contrast", value: $edit.contrast, range: 0.5...2, neutral: 1) {
                String(format: "%.2f×", $0)
            }
            adjustmentSlider("Saturation", value: $edit.saturation, range: 0...2, neutral: 1) {
                String(format: "%.0f%%", $0 * 100)
            }
            adjustmentSlider("Exposure", value: $edit.exposure, range: -2...2, neutral: 0) {
                String(format: "%+.1f EV", $0)
            }
            Button("Reset Adjustments") {
                edit.brightness = 0
                edit.contrast = 1
                edit.saturation = 1
                edit.exposure = 0
            }
            .disabled(!edit.hasColorAdjustments)
        }
    }

    private func adjustmentSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                                  neutral: Double, format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(Theme.Fonts.bodyStrong).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(format(value.wrappedValue))
                    .font(Theme.Fonts.body)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                Button { value.wrappedValue = neutral } label: { Image(systemName: "arrow.uturn.backward.circle") }
                    .buttonStyle(.borderless)
                    .disabled(value.wrappedValue == neutral)
                    .help("Reset \(title.lowercased())")
            }
            Slider(value: value, in: range)
        }
    }

    private var itemList: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Added")
            if edit.redactions.isEmpty && edit.annotations.isEmpty {
                Text("Nothing yet.").font(Theme.Fonts.body).foregroundStyle(Theme.textSecondary)
            }
            ForEach(edit.redactions) { redaction in
                itemRow(redaction.style.label, symbol: redaction.style.symbol, tint: .primary) { remove(redaction.id) }
            }
            ForEach(edit.annotations) { annotation in
                let info = Self.describe(annotation)
                itemRow(info.title, symbol: info.symbol, tint: annotation.color.swiftUI) { remove(annotation.id) }
            }
        }
    }

    private func itemRow(_ title: String, symbol: String, tint: Color, onDelete: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Remove")
        }
    }

    private static func describe(_ annotation: ImageEdit.Annotation) -> (title: String, symbol: String) {
        switch annotation.kind {
        case .text(let string, _): return ("“\(string)”", "textformat")
        case .rectangle: return ("Box", "rectangle")
        case .arrow: return ("Arrow", "arrow.up.right")
        case .highlight: return ("Highlight", "highlighter")
        case .ellipse: return ("Oval", "circle")
        case .line: return ("Line", "line.diagonal")
        case .step(let n, _): return ("Step \(n)", "\(min(max(n, 1), 50)).circle.fill")
        case .spotlight: return ("Spotlight", "light.max")
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.body)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Save as", selection: $edit.outputFormat) {
                Text("Same as original").tag(OutputFormat?.none)
                ForEach(Self.formats) { format in
                    Text(format.label).tag(Optional(format))
                }
            }
            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Copy") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(preview == nil || edit.isEmpty)
                    .help("Saves an edited copy; the original isn't changed")
            }
        }
    }
}

fileprivate extension RGBAColor {
    var swiftUI: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}
