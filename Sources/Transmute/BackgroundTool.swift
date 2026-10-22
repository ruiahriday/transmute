import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import Vision

// MARK: - The edit

/// A new background for a picture. Vision finds the subject (any subject on macOS 14 and later,
/// people only on macOS 13); everything around it is made transparent or replaced.
struct BackgroundEdit: Equatable, Hashable, Sendable {
    enum Fill: Equatable, Hashable, Sendable {
        /// Cut out: transparent around the subject.
        case transparent
        case color(RGBAColor)
        /// From the top colour to the bottom colour.
        case gradient(top: RGBAColor, bottom: RGBAColor)
        /// The original picture, blurred. Strength 0…1.
        case blur(Double)
        /// Another picture, scaled to fill and centred.
        case image(URL)
    }

    var fill: Fill = .transparent

    static let remove = BackgroundEdit()

    var isTransparent: Bool { fill == .transparent }

    /// Short description for messages and the wheel ("background removed").
    var summary: String {
        switch fill {
        case .transparent: "background removed"
        case .color: "new background colour"
        case .gradient: "new gradient background"
        case .blur: "background blurred"
        case .image(let url): "background replaced with \(url.lastPathComponent)"
        }
    }
}

/// A two-colour gradient the Background panel and the Tools tab offer.
struct GradientPreset: Identifiable, Hashable {
    let name: String
    let top: RGBAColor
    let bottom: RGBAColor
    var id: String { name }

    var fill: BackgroundEdit.Fill { .gradient(top: top, bottom: bottom) }

    static let all: [GradientPreset] = [
        GradientPreset(name: "Spinform", top: RGBAColor(hex: 0x4338CA), bottom: RGBAColor(hex: 0xEC4899)),
        GradientPreset(name: "Sunrise", top: RGBAColor(hex: 0xFDBA74), bottom: RGBAColor(hex: 0xF43F5E)),
        GradientPreset(name: "Sky", top: RGBAColor(hex: 0xE0F2FE), bottom: RGBAColor(hex: 0x60A5FA)),
        GradientPreset(name: "Mint", top: RGBAColor(hex: 0xECFDF5), bottom: RGBAColor(hex: 0x34D399)),
        GradientPreset(name: "Studio", top: RGBAColor(hex: 0xFAFAF9), bottom: RGBAColor(hex: 0xA8A29E)),
        GradientPreset(name: "Night", top: RGBAColor(hex: 0x312E81), bottom: RGBAColor(hex: 0x0F172A)),
    ]
}

extension RGBAColor {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    /// Plain colours for a new background.
    static let backgroundSwatches: [RGBAColor] = [
        .white, RGBAColor(hex: 0xF1F1F4), RGBAColor(hex: 0x18181B), RGBAColor(hex: 0x8B5CF6),
        RGBAColor(hex: 0xFCE7F3), RGBAColor(hex: 0xDBEAFE), RGBAColor(hex: 0xFEF3C7),
    ]

    /// The sRGB components of any CGColor (from a colour picker).
    init?(cgColor: CGColor) {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
              let c = converted.components, c.count >= 3 else { return nil }
        self.init(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]), alpha: c.count > 3 ? Double(c[3]) : 1)
    }
}

// MARK: - Engine

/// Finds the subject and builds the new picture. CoreImage and Vision only, so it runs off the main thread.
enum BackgroundEngine {
    enum Method: Sendable {
        /// macOS 14+: Vision's foreground instance mask, which works on any subject.
        case anySubject
        /// macOS 13: Vision's person segmentation, which only finds people.
        case peopleOnly
    }

    /// Thrown when there's nothing to keep; the message says what to try.
    struct NoSubject: LocalizedError {
        let method: Method
        var errorDescription: String? {
            switch method {
            case .anySubject:
                "Couldn't find a clear subject. Background removal works best on a photo with one main subject, like a person, a pet or an object."
            case .peopleOnly:
                "No person found. On macOS 13 only people can be cut out; macOS 14 or later finds any subject."
            }
        }
    }

    /// What this Mac can find. SPINFORM_BG_PEOPLE_ONLY=1 forces the macOS 13 way, for testing.
    static var method: Method {
        if ProcessInfo.processInfo.environment["SPINFORM_BG_PEOPLE_ONLY"] == "1" { return .peopleOnly }
        if #available(macOS 14.0, *) { return .anySubject }
        return .peopleOnly
    }

    static var findsAnySubject: Bool { method == .anySubject }

    /// The subject's mask at the image's size, softened a little at the edges: white keeps, black goes.
    static func subjectMask(for image: CGImage, method: Method = BackgroundEngine.method) throws -> CIImage {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        var raw: CIImage?
        do {
            switch method {
            case .anySubject:
                if #available(macOS 14.0, *) {
                    raw = try foregroundMask(handler)
                } else {
                    raw = try personMask(handler)
                }
            case .peopleOnly:
                raw = try personMask(handler)
            }
        } catch let error as NoSubject {
            throw error
        } catch {
            throw ConversionError("Couldn't look for the subject: \(error.localizedDescription)")
        }
        guard let raw, raw.extent.width >= 1, raw.extent.height >= 1 else { throw NoSubject(method: method) }
        let mask = feathered(grey(fitted(raw, width: image.width, height: image.height)), width: image.width, height: image.height)
        // An all-black mask means nothing was found (person segmentation always returns one).
        guard coverage(mask) > 0.002 else { throw NoSubject(method: method) }
        return mask
    }

    @available(macOS 14.0, *)
    private static func foregroundMask(_ handler: VNImageRequestHandler) throws -> CIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
        let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        return CIImage(cvPixelBuffer: buffer)
    }

    private static func personMask(_ handler: VNImageRequestHandler) throws -> CIImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try handler.perform([request])
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }
        return CIImage(cvPixelBuffer: buffer)
    }

    /// Scaled to exactly width × height with its origin at zero.
    private static func fitted(_ mask: CIImage, width: Int, height: Int) -> CIImage {
        let extent = mask.extent
        let sx = CGFloat(width) / extent.width
        let sy = CGFloat(height) / extent.height
        let moved = mask.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        return moved.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
    }

    /// The mask's first channel copied into red, green and blue, fully opaque, so it reads the same
    /// whatever pixel format Vision returned.
    private static func grey(_ mask: CIImage) -> CIImage {
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = mask
        matrix.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        matrix.bVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        matrix.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return matrix.outputImage ?? mask
    }

    /// A slight blur so edges are clean rather than jagged; about a pixel on a phone photo.
    static func feathered(_ mask: CIImage, width: Int, height: Int) -> CIImage {
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let sigma = max(0.6, Double(max(width, height)) / 1600)
        return mask.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
    }

    /// The mask's average brightness, 0…1.
    private static func coverage(_ mask: CIImage) -> Double {
        let average = CIFilter.areaAverage()
        average.inputImage = mask
        average.extent = mask.extent
        guard let output = average.outputImage else { return 1 }
        var pixel = [Float](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        context.render(output, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: nil)
        return Double(pixel[0])
    }

    /// The mask as an 8-bit picture, for the editor to keep between previews.
    static func maskImage(for image: CGImage) throws -> CGImage {
        let mask = try subjectMask(for: image)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let result = context.createCGImage(mask, from: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                                                 format: .RGBA8, colorSpace: srgb) else {
            throw ConversionError("Couldn't prepare the cut-out.")
        }
        return result
    }

    /// A mask kept as a picture (see maskImage), read back without colour conversion.
    static func mask(from picture: CGImage) -> CIImage {
        CIImage(cgImage: picture, options: [.colorSpace: NSNull()])
    }

    /// The subject from `image` over the new background. `preview` loads a background picture small.
    static func compose(_ image: CGImage, mask: CIImage, fill: BackgroundEdit.Fill, preview: Bool = false) throws -> CGImage {
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let foreground = CIImage(cgImage: image)
        let backdrop = try background(fill, behind: foreground, extent: extent, preview: preview)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = foreground
        blend.backgroundImage = backdrop
        blend.maskImage = mask
        guard let output = blend.outputImage?.cropped(to: extent) else {
            throw ConversionError("Couldn't put the new background in.")
        }
        let space = workingSpace(for: image)
        let context = CIContext(options: [.cacheIntermediates: false])
        if let result = context.createCGImage(output, from: extent, format: .RGBA8, colorSpace: space) {
            return result
        }
        throw ConversionError("Couldn't put the new background in.")
    }

    private static func workingSpace(for image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb, space.supportsOutput { return space }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    private static func ciColor(_ color: RGBAColor) -> CIColor { CIColor(cgColor: color.cgColor) }

    private static func background(_ fill: BackgroundEdit.Fill, behind foreground: CIImage, extent: CGRect,
                                   preview: Bool) throws -> CIImage {
        switch fill {
        case .transparent:
            return CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        case .color(let color):
            return CIImage(color: ciColor(color.withAlpha(1))).cropped(to: extent)
        case .gradient(let top, let bottom):
            let gradient = CIFilter.linearGradient()
            // CoreImage's origin is bottom-left.
            gradient.point0 = CGPoint(x: extent.midX, y: extent.maxY)
            gradient.point1 = CGPoint(x: extent.midX, y: extent.minY)
            gradient.color0 = ciColor(top.withAlpha(1))
            gradient.color1 = ciColor(bottom.withAlpha(1))
            return (gradient.outputImage ?? CIImage(color: ciColor(top))).cropped(to: extent)
        case .blur(let strength):
            let longest = Double(max(extent.width, extent.height))
            let sigma = longest * (0.006 + 0.03 * min(max(strength, 0), 1))
            return foreground.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        case .image(let url):
            let picture = preview
                ? try ImageEditEngine.loadPreview(url, maxPixel: 1400).image
                : try ImageConverter.loadCGImage(url)
            let source = CIImage(cgImage: picture)
            // Scale to fill, centred: the shorter side fits and the rest is cut off.
            let scale = max(extent.width / source.extent.width, extent.height / source.extent.height)
            let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let dx = (extent.width - scaled.extent.width) / 2 - scaled.extent.minX
            let dy = (extent.height - scaled.extent.height) / 2 - scaled.extent.minY
            return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: extent)
        }
    }
}

// MARK: - Editor panel

/// Where the editor is with finding the subject.
enum SubjectStatus: Equatable {
    case idle, finding, ready, failed(String)
}

/// The Background panel in the photo editor: what goes behind the subject.
struct BackgroundPanel: View {
    @Binding var background: BackgroundEdit?
    let status: SubjectStatus
    let onRetry: () -> Void

    init(background: Binding<BackgroundEdit?>, status: SubjectStatus, onRetry: @escaping () -> Void) {
        _background = background
        self.status = status
        self.onRetry = onRetry
    }

    @State private var customColor = CGColor(srgbRed: 0.55, green: 0.36, blue: 0.96, alpha: 1)
    @State private var customTop = CGColor(srgbRed: 0.99, green: 0.73, blue: 0.45, alpha: 1)
    @State private var customBottom = CGColor(srgbRed: 0.96, green: 0.25, blue: 0.37, alpha: 1)

    private enum Mode: String, CaseIterable, Identifiable {
        case original = "Original", transparent = "Transparent", color = "Colour", gradient = "Gradient",
             blur = "Blur", image = "Image"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .original: "photo"
            case .transparent: "checkerboard.rectangle"
            case .color: "paintpalette"
            case .gradient: "square.fill.on.square.fill"
            case .blur: "drop"
            case .image: "photo.on.rectangle"
            }
        }
    }

    private var mode: Mode {
        switch background?.fill {
        case nil: .original
        case .transparent: .transparent
        case .color: .color
        case .gradient: .gradient
        case .blur: .blur
        case .image: .image
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusLine
            SectionLabel("Behind the subject")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(Mode.allCases) { tile($0) }
            }
            options
            if !BackgroundEngine.findsAnySubject {
                Label("On macOS 13 only people can be cut out. macOS 14 or later finds any subject: pets, products, objects.",
                      systemImage: "info.circle")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(saveNote)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var saveNote: String {
        background?.isTransparent == true
            ? "Saved as PNG with transparency (HEIC and TIFF stay as they are). Other edits apply on top."
            : "A new background keeps the picture's own format. Other edits apply on top."
    }

    @ViewBuilder private var statusLine: some View {
        switch status {
        case .idle, .finding:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(BackgroundEngine.findsAnySubject ? "Finding the subject…" : "Looking for people…")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .ready:
            Label("Subject found", systemImage: "checkmark.circle.fill")
                .font(Theme.Fonts.bodyStrong)
                .foregroundStyle(Theme.success)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again", action: onRetry).buttonStyle(ChipButtonStyle())
            }
        }
    }

    private func tile(_ tileMode: Mode) -> some View {
        let selected = mode == tileMode
        return Button { choose(tileMode) } label: {
            VStack(spacing: 5) {
                Image(systemName: tileMode.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(height: 18)
                Text(tileMode.rawValue)
                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? Theme.accentText : Theme.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.12) : Theme.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.hairline, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(tileMode != .original && status != .ready)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func choose(_ newMode: Mode) {
        switch newMode {
        case .original: background = nil
        case .transparent: background = BackgroundEdit(fill: .transparent)
        case .color: background = BackgroundEdit(fill: .color(RGBAColor(cgColor: customColor) ?? .white))
        case .gradient: background = BackgroundEdit(fill: GradientPreset.all[0].fill)
        case .blur: background = BackgroundEdit(fill: .blur(0.5))
        case .image: chooseImage()
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as Background"
        if panel.runModal() == .OK, let url = panel.url { background = BackgroundEdit(fill: .image(url)) }
    }

    @ViewBuilder private var options: some View {
        switch background?.fill {
        case .color(let current):
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Colour")
                HStack(spacing: 7) {
                    ForEach(RGBAColor.backgroundSwatches, id: \.self) { swatch in
                        swatchButton(swatch, selected: swatch == current)
                    }
                    ColorPicker("Custom colour", selection: Binding(
                        get: { customColor },
                        set: { customColor = $0; if let c = RGBAColor(cgColor: $0) { background = BackgroundEdit(fill: .color(c)) } }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    .help("Any colour")
                }
            }
        case .gradient(let top, let bottom):
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Gradient")
                HStack(spacing: 7) {
                    ForEach(GradientPreset.all) { preset in
                        gradientButton(preset, selected: preset.top == top && preset.bottom == bottom)
                    }
                }
                HStack(spacing: 10) {
                    Text("Custom").font(Theme.Fonts.body).foregroundStyle(Theme.textSecondary)
                    ColorPicker("Top", selection: Binding(
                        get: { customTop },
                        set: { customTop = $0; applyCustomGradient() }
                    ), supportsOpacity: false)
                    ColorPicker("Bottom", selection: Binding(
                        get: { customBottom },
                        set: { customBottom = $0; applyCustomGradient() }
                    ), supportsOpacity: false)
                }
                .font(Theme.Fonts.body)
            }
        case .blur(let strength):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SectionLabel("Blur strength")
                    Spacer()
                    Text("\(Int(strength * 100))%").font(Theme.Fonts.body).monospacedDigit().foregroundStyle(Theme.textSecondary)
                }
                Slider(value: Binding(get: { strength }, set: { background = BackgroundEdit(fill: .blur($0)) }), in: 0...1)
            }
        case .image(let url):
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Picture")
                HStack {
                    Label(url.lastPathComponent, systemImage: "photo")
                        .font(Theme.Fonts.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Change…") { chooseImage() }.buttonStyle(ChipButtonStyle())
                }
                Text("Scaled to fill the frame, centred.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        default:
            EmptyView()
        }
    }

    private func applyCustomGradient() {
        guard let top = RGBAColor(cgColor: customTop), let bottom = RGBAColor(cgColor: customBottom) else { return }
        background = BackgroundEdit(fill: .gradient(top: top, bottom: bottom))
    }

    private func swatchButton(_ swatch: RGBAColor, selected: Bool) -> some View {
        Button { background = BackgroundEdit(fill: .color(swatch)) } label: {
            Circle()
                .fill(Color(.sRGB, red: swatch.red, green: swatch.green, blue: swatch.blue, opacity: 1))
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(Theme.controlBorder.opacity(0.6), lineWidth: 1))
                .overlay(Circle().strokeBorder(Theme.accent, lineWidth: selected ? 2 : 0).padding(-3))
        }
        .buttonStyle(.plain)
    }

    private func gradientButton(_ preset: GradientPreset, selected: Bool) -> some View {
        Button { background = BackgroundEdit(fill: preset.fill) } label: {
            Circle()
                .fill(LinearGradient(colors: [preset.top.color, preset.bottom.color], startPoint: .top, endPoint: .bottom))
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(Theme.controlBorder.opacity(0.6), lineWidth: 1))
                .overlay(Circle().strokeBorder(Theme.accent, lineWidth: selected ? 2 : 0).padding(-3))
        }
        .buttonStyle(.plain)
        .help(preset.name)
    }
}

extension RGBAColor {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

/// A checkerboard, drawn behind pictures that may be transparent.
struct Checkerboard: View {
    var square: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.98)))
            var dark = Path()
            let columns = Int((size.width / square).rounded(.up))
            let rows = Int((size.height / square).rounded(.up))
            for row in 0..<rows {
                for column in 0..<columns where (row + column) % 2 == 1 {
                    dark.addRect(CGRect(x: CGFloat(column) * square, y: CGFloat(row) * square, width: square, height: square))
                }
            }
            context.fill(dark, with: .color(Color(white: 0.86)))
        }
    }
}
