import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Style

/// A capture placed on a background: padding, rounded corners, a shadow and an optional fixed shape.
struct FrameStyle: Codable, Equatable, Hashable {
    enum Background: Codable, Equatable, Hashable {
        /// Diagonal, top-left colour to bottom-right colour (hex RGB).
        case gradient(UInt32, UInt32)
        case solid(UInt32)
        /// A picture, scaled to fill (file path).
        case image(String)
        /// The current desktop picture.
        case desktop
    }

    var background: Background = .gradient(0x4338CA, 0xEC4899)
    /// Space around the picture, as a fraction of its longer side (0…0.25).
    var padding = 0.08
    /// Corner radius, as a fraction of the picture's shorter side (0…0.1).
    var corners = 0.025
    /// 0…1
    var shadow = 0.6
    var aspect: FrameAspect = .auto
    /// Where the picture sits when a fixed shape leaves room around it.
    var alignment: FrameAlignment = .center
    /// Moves the picture so what's in it (not its edges) looks centred.
    var balance = false
}

extension FrameStyle {
    /// Older saved looks have no alignment or balance; they keep the defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        background = try c.decodeIfPresent(Background.self, forKey: .background) ?? .gradient(0x4338CA, 0xEC4899)
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? 0.08
        corners = try c.decodeIfPresent(Double.self, forKey: .corners) ?? 0.025
        shadow = try c.decodeIfPresent(Double.self, forKey: .shadow) ?? 0.6
        aspect = try c.decodeIfPresent(FrameAspect.self, forKey: .aspect) ?? .auto
        alignment = try c.decodeIfPresent(FrameAlignment.self, forKey: .alignment) ?? .center
        balance = try c.decodeIfPresent(Bool.self, forKey: .balance) ?? false
    }
}

enum FrameAlignment: String, Codable, CaseIterable, Identifiable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight

    var id: String { rawValue }

    /// 0 is left/top, 0.5 the middle, 1 right/bottom.
    var factors: (x: CGFloat, y: CGFloat) {
        switch self {
        case .topLeft: (0, 0)
        case .top: (0.5, 0)
        case .topRight: (1, 0)
        case .left: (0, 0.5)
        case .center: (0.5, 0.5)
        case .right: (1, 0.5)
        case .bottomLeft: (0, 1)
        case .bottom: (0.5, 1)
        case .bottomRight: (1, 1)
        }
    }

    var symbol: String {
        switch self {
        case .topLeft: "arrow.up.left"
        case .top: "arrow.up"
        case .topRight: "arrow.up.right"
        case .left: "arrow.left"
        case .center: "circle.fill"
        case .right: "arrow.right"
        case .bottomLeft: "arrow.down.left"
        case .bottom: "arrow.down"
        case .bottomRight: "arrow.down.right"
        }
    }
}

enum FrameAspect: String, Codable, CaseIterable, Identifiable {
    case auto, square, wide, classic, portrait, story

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Fit"
        case .square: "1:1"
        case .wide: "16:9"
        case .classic: "4:3"
        case .portrait: "4:5"
        case .story: "9:16"
        }
    }

    var help: String {
        switch self {
        case .auto: "Just the padding around the picture"
        case .square: "Square, for Instagram posts"
        case .wide: "Widescreen, for X, YouTube and slides"
        case .classic: "4:3, for slides and documents"
        case .portrait: "4:5, for Instagram portrait posts"
        case .story: "9:16, for stories and reels"
        }
    }

    /// Width ÷ height.
    var ratio: Double? {
        switch self {
        case .auto: nil
        case .square: 1
        case .wide: 16.0 / 9.0
        case .classic: 4.0 / 3.0
        case .portrait: 4.0 / 5.0
        case .story: 9.0 / 16.0
        }
    }
}

struct FramePreset: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var style: FrameStyle
    var custom = false

    /// Twenty built-in looks; the first six are the Background tool's gradients.
    static let builtIn: [FramePreset] = {
        var presets = GradientPreset.all.map { preset in
            FramePreset(id: "builtin.\(preset.name)", name: preset.name,
                        style: FrameStyle(background: .gradient(preset.top.hexValue, preset.bottom.hexValue)))
        }
        let more: [(String, FrameStyle.Background)] = [
            ("Lavender", .gradient(0xEDE9FE, 0xA78BFA)),
            ("Peach", .gradient(0xFFEDD5, 0xFB7185)),
            ("Ocean", .gradient(0x38BDF8, 0x1E3A8A)),
            ("Forest", .gradient(0xBBF7D0, 0x166534)),
            ("Paper", .solid(0xFFFFFF)),
            ("Graphite", .solid(0x27272A)),
            ("Aurora", .gradient(0x22D3EE, 0x8B5CF6)),
            ("Candy", .gradient(0xF9A8D4, 0xC084FC)),
            ("Citrus", .gradient(0xFDE68A, 0xF97316)),
            ("Lagoon", .gradient(0x5EEAD4, 0x0E7490)),
            ("Dusk", .gradient(0xFB7185, 0x6D28D9)),
            ("Coral", .gradient(0xFF8A65, 0xF43F5E)),
            ("Slate", .gradient(0x94A3B8, 0x334155)),
            ("Midnight", .solid(0x0B1020)),
        ]
        presets += more.map { FramePreset(id: "builtin.\($0.0)", name: $0.0, style: FrameStyle(background: $0.1)) }
        return presets
    }()
}

extension RGBAColor {
    /// 0xRRGGBB
    var hexValue: UInt32 {
        func byte(_ v: Double) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return (byte(red) << 16) | (byte(green) << 8) | byte(blue)
    }
}

/// Custom presets and the last look used, kept in the user defaults.
enum FramePresetStore {
    private static let customKey = "frameCustomPresets"
    private static let lastKey = "frameLastStyle"

    static func custom(defaults: UserDefaults = .standard) -> [FramePreset] {
        guard let data = defaults.data(forKey: customKey),
              let presets = try? JSONDecoder().decode([FramePreset].self, from: data) else { return [] }
        return presets
    }

    static func save(_ presets: [FramePreset], defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(presets) { defaults.set(data, forKey: customKey) }
    }

    @discardableResult
    static func add(name: String, style: FrameStyle, defaults: UserDefaults = .standard) -> FramePreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = FramePreset(id: "custom.\(UUID().uuidString)", name: trimmed.isEmpty ? "My Preset" : trimmed,
                                 style: style, custom: true)
        save(custom(defaults: defaults) + [preset], defaults: defaults)
        return preset
    }

    static func remove(_ id: String, defaults: UserDefaults = .standard) {
        save(custom(defaults: defaults).filter { $0.id != id }, defaults: defaults)
    }

    static var last: FrameStyle {
        get {
            guard let data = UserDefaults.standard.data(forKey: lastKey),
                  let style = try? JSONDecoder().decode(FrameStyle.self, from: data) else { return FrameStyle() }
            return style
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: lastKey) }
        }
    }
}

// MARK: - Layout and rendering

enum FrameLayout {
    /// The canvas size and where the picture sits on it (top-left origin), in pixels. `focus` is the
    /// visual centre of the picture's content (0…1), used when the style balances it.
    static func layout(imageSize: CGSize, style: FrameStyle, focus: CGPoint? = nil) -> (canvas: CGSize, imageRect: CGRect) {
        let w = max(1, imageSize.width.rounded())
        let h = max(1, imageSize.height.rounded())
        let pad = (CGFloat(min(max(style.padding, 0), 0.5)) * max(w, h)).rounded()
        var canvas = CGSize(width: w + 2 * pad, height: h + 2 * pad)
        // Balancing needs room to move into: up to the content's offset from the middle, on each side.
        var offset = CGPoint.zero
        if style.balance, let focus {
            offset = CGPoint(x: ((0.5 - focus.x) * w).rounded(), y: ((0.5 - focus.y) * h).rounded())
            offset.x = min(max(offset.x, -w * 0.25), w * 0.25)
            offset.y = min(max(offset.y, -h * 0.25), h * 0.25)
            if style.aspect == .auto {
                canvas.width += 2 * abs(offset.x)
                canvas.height += 2 * abs(offset.y)
            }
        }
        if let ratio = style.aspect.ratio.map({ CGFloat($0) }) {
            if canvas.width / canvas.height < ratio {
                canvas.width = (canvas.height * ratio).rounded()
            } else {
                canvas.height = (canvas.width / ratio).rounded()
            }
        }
        let room = CGSize(width: canvas.width - w - 2 * pad, height: canvas.height - h - 2 * pad)
        let factors = style.alignment.factors
        var origin = CGPoint(x: (pad + room.width * factors.x).rounded(), y: (pad + room.height * factors.y).rounded())
        if style.balance, focus != nil {
            // Centre the content, staying inside the padding.
            origin.x = min(max(((canvas.width - w) / 2 + offset.x).rounded(), pad), canvas.width - w - pad)
            origin.y = min(max(((canvas.height - h) / 2 + offset.y).rounded(), pad), canvas.height - h - pad)
        }
        return (canvas, CGRect(origin: origin, size: CGSize(width: w, height: h)))
    }

    static func cornerRadius(imageSize: CGSize, style: FrameStyle) -> CGFloat {
        CGFloat(min(max(style.corners, 0), 0.5)) * min(imageSize.width, imageSize.height)
    }
}

/// Finds where a picture's content is, so it can be centred by what's in it rather than its edges.
enum FrameBalance {
    /// The weighted centre (0…1, top-left origin) of everything that differs from the picture's
    /// border colour, or of its opaque pixels when it has transparency. nil for a plain picture.
    static func visualCentre(of image: CGImage) -> CGPoint? {
        let side = 64
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return nil }
        let p = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        func px(_ x: Int, _ y: Int) -> (Double, Double, Double, Double) {
            let i = (y * side + x) * 4
            return (Double(p[i]), Double(p[i + 1]), Double(p[i + 2]), Double(p[i + 3]))
        }
        // The border's average colour stands for the background.
        var border = (0.0, 0.0, 0.0, 0.0)
        var count = 0.0
        var transparent = false
        for i in 0..<side {
            for (x, y) in [(i, 0), (i, side - 1), (0, i), (side - 1, i)] {
                let c = px(x, y)
                border.0 += c.0; border.1 += c.1; border.2 += c.2; border.3 += c.3
                count += 1
                if c.3 < 250 { transparent = true }
            }
        }
        border = (border.0 / count, border.1 / count, border.2 / count, border.3 / count)
        var total = 0.0, sx = 0.0, sy = 0.0
        for y in 0..<side {
            for x in 0..<side {
                let c = px(x, y)
                let weight: Double
                if transparent {
                    weight = c.3 / 255
                } else {
                    let d = abs(c.0 - border.0) + abs(c.1 - border.1) + abs(c.2 - border.2)
                    weight = d > 24 ? d : 0
                }
                total += weight
                sx += weight * (Double(x) + 0.5)
                sy += weight * (Double(y) + 0.5)
            }
        }
        guard total > 0.0001 else { return nil }
        // Memory row 0 is the top of the picture.
        return CGPoint(x: sx / total / Double(side), y: sy / total / Double(side))
    }
}

/// The current desktop picture, looked up on the main thread for renderers that run elsewhere.
enum DesktopPicture {
    private static let lock = NSLock()
    private static var cachedPath: String?

    @MainActor
    static func refresh() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let path = screen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }?.path
        lock.lock()
        cachedPath = path
        lock.unlock()
    }

    static var path: String? {
        lock.lock()
        defer { lock.unlock() }
        return cachedPath
    }
}

enum FrameRenderer {
    static func render(_ image: CGImage, style: FrameStyle) throws -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        let focus = style.balance ? FrameBalance.visualCentre(of: image) : nil
        let (canvas, placed) = FrameLayout.layout(imageSize: size, style: style, focus: focus)
        let width = Int(canvas.width), height = Int(canvas.height)
        guard width * height < 400_000_000, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError("That picture is too big to frame.")
        }
        let full = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        var background = style.background
        if background == .desktop {
            background = DesktopPicture.path.map { .image($0) } ?? .gradient(0x4338CA, 0xEC4899)
        }
        switch background {
        case .desktop:
            break
        case .image(let path):
            ctx.setFillColor(CGColor(gray: 0.15, alpha: 1))
            ctx.fill(full)
            if let picture = PictureCache.image(atPath: path) {
                // Scaled to fill, centred.
                let scale = max(canvas.width / CGFloat(picture.width), canvas.height / CGFloat(picture.height))
                let size = CGSize(width: CGFloat(picture.width) * scale, height: CGFloat(picture.height) * scale)
                ctx.interpolationQuality = .high
                ctx.draw(picture, in: CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                                             width: size.width, height: size.height))
            }
        case .solid(let hex):
            ctx.setFillColor(RGBAColor(hex: hex).cgColor)
            ctx.fill(full)
        case .gradient(let from, let to):
            let colors = [RGBAColor(hex: from).cgColor, RGBAColor(hex: to).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
                // Top-left to bottom-right; CoreGraphics' y runs up.
                ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas.height), end: CGPoint(x: canvas.width, y: 0),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        }
        // The picture's rectangle in CoreGraphics coordinates.
        let rect = CGRect(x: placed.minX, y: canvas.height - placed.maxY, width: placed.width, height: placed.height)
        let radius = FrameLayout.cornerRadius(imageSize: size, style: style)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let shadow = CGFloat(min(max(style.shadow, 0), 1))
        // The rounded picture goes into a layer, so the shadow follows its shape (and any transparency).
        ctx.saveGState()
        if shadow > 0 {
            let reach = max(size.width, size.height)
            ctx.setShadow(offset: CGSize(width: 0, height: -reach * 0.012 * shadow), blur: reach * 0.045 * shadow,
                          color: CGColor(gray: 0, alpha: 0.45 * shadow))
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(image, in: rect)
        ctx.restoreGState()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        guard let result = ctx.makeImage() else { throw ConversionError("Couldn't draw the frame.") }
        return result
    }

    /// Frames a file and saves "<name> (framed).png" next to it.
    static func save(_ input: URL, style: FrameStyle, to folder: URL? = nil) throws -> URL {
        let image = try ImageConverter.loadCGImage(input)
        let framed = try render(image, style: style)
        let out = OutputPaths.destination(for: input, ext: "png", suffix: "framed", folder: folder)
        try ImageConverter.data(from: framed, type: .png).write(to: out, options: .atomic)
        return out
    }
}

// MARK: - Window

@MainActor
enum FrameToolWindow {
    private static var windows: [NSWindow] = []

    static func open(_ url: URL) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Background Frame"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FrameToolView(url: url) { [weak window] in window?.close() })
        window.center()
        windows.append(window)
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                windows.removeAll { $0 === window }
                if let token { NotificationCenter.default.removeObserver(token) }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Asks for a picture, then opens it.
    static func choose() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Frame"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
}

/// The background frame tool: preview on the left, the look on the right.
struct FrameToolView: View {
    let url: URL
    var onClose: () -> Void = {}

    @State private var style = FramePresetStore.last
    @State private var preview: CGImage?
    @State private var rendered: CGImage?
    @State private var custom: [FramePreset] = FramePresetStore.custom()
    @State private var presetName = ""
    @State private var naming = false
    @State private var saving = false
    @State private var fromColor = CGColor(srgbRed: 0.26, green: 0.22, blue: 0.79, alpha: 1)
    @State private var toColor = CGColor(srgbRed: 0.93, green: 0.28, blue: 0.6, alpha: 1)

    init(url: URL, style: FrameStyle? = nil, onClose: @escaping () -> Void = {}) {
        self.url = url
        self.onClose = onClose
        if let style { _style = State(initialValue: style) }
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.adaptive(light: 0xE6E6EC, dark: 0x0B0B0E)
                if let image = rendered ?? preview {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(28)
                        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                } else {
                    ProgressView()
                }
            }
            Divider()
            sidebar.frame(width: 300).background(Theme.surface)
        }
        .frame(minWidth: 820, minHeight: 560)
        .tint(Theme.accent)
        .task(id: url) { await load() }
        .task(id: style) { await refresh() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "photo.artframe").foregroundStyle(Theme.accentText)
                Text("Background Frame").font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary)
            }
            .padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    presets
                    colours
                    sliders
                    shapes
                }
                .padding(14)
            }
            Divider()
            footer.padding(14)
        }
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Looks")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 10) {
                ForEach(FramePreset.builtIn + custom) { preset in
                    presetButton(preset)
                }
                pictureButton(selected: style.background == .desktop, symbol: "menubar.dock.rectangle", help: "Desktop picture") {
                    DesktopPicture.refresh()
                    style.background = .desktop
                }
                pictureButton(selected: { if case .image = style.background { return true } else { return false } }(),
                              symbol: "photo", help: "A picture of your own…") {
                    choosePicture()
                }
            }
            if naming {
                HStack(spacing: 6) {
                    TextField("Preset name", text: $presetName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(savePreset)
                    Button("Save", action: savePreset).buttonStyle(ChipButtonStyle())
                }
            } else {
                Button { naming = true } label: { Label("Save as Preset", systemImage: "plus") }
                    .buttonStyle(ChipButtonStyle())
            }
        }
    }

    private func presetButton(_ preset: FramePreset) -> some View {
        let selected = preset.style.background == style.background
        return Button {
            style.background = preset.style.background
            if preset.custom {
                style.padding = preset.style.padding
                style.corners = preset.style.corners
                style.shadow = preset.style.shadow
                style.aspect = preset.style.aspect
                style.alignment = preset.style.alignment
                style.balance = preset.style.balance
            }
        } label: {
            swatch(preset.style.background)
                .frame(width: 30, height: 30)
                .overlay(Circle().strokeBorder(Theme.controlBorder.opacity(0.5), lineWidth: 1))
                .overlay(Circle().strokeBorder(Theme.accent, lineWidth: selected ? 2 : 0).padding(-3))
        }
        .buttonStyle(.plain)
        .help(preset.name)
        .contextMenu {
            if preset.custom {
                Button("Delete “\(preset.name)”") {
                    FramePresetStore.remove(preset.id)
                    custom = FramePresetStore.custom()
                }
            }
        }
    }

    private func pictureButton(selected: Bool, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(Theme.surfaceRaised)
                .overlay(Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary))
                .frame(width: 30, height: 30)
                .overlay(Circle().strokeBorder(Theme.controlBorder.opacity(0.5), lineWidth: 1))
                .overlay(Circle().strokeBorder(Theme.accent, lineWidth: selected ? 2 : 0).padding(-3))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Use Picture"
        if panel.runModal() == .OK, let url = panel.url { style.background = .image(url.path) }
    }

    private func swatch(_ background: FrameStyle.Background) -> some View {
        Circle().fill(Self.fill(background))
    }

    static func fill(_ background: FrameStyle.Background) -> AnyShapeStyle {
        switch background {
        case .image, .desktop:
            return AnyShapeStyle(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.25)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
        case .solid(let hex):
            return AnyShapeStyle(RGBAColor(hex: hex).color)
        case .gradient(let a, let b):
            return AnyShapeStyle(LinearGradient(colors: [RGBAColor(hex: a).color, RGBAColor(hex: b).color],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    private var colours: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Custom colours")
            HStack(spacing: 8) {
                ColorPicker("From", selection: Binding(get: { fromColor }, set: { fromColor = $0; applyCustomColours() }),
                            supportsOpacity: false)
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                ColorPicker("To", selection: Binding(get: { toColor }, set: { toColor = $0; applyCustomColours() }),
                            supportsOpacity: false)
                Spacer()
                Button("Solid") {
                    if let c = RGBAColor(cgColor: fromColor) { style.background = .solid(c.hexValue) }
                }
                .buttonStyle(ChipButtonStyle())
                .help("Use the first colour on its own")
            }
            .font(Theme.Fonts.body)
        }
    }

    private func applyCustomColours() {
        guard let a = RGBAColor(cgColor: fromColor), let b = RGBAColor(cgColor: toColor) else { return }
        style.background = .gradient(a.hexValue, b.hexValue)
    }

    private var sliders: some View {
        VStack(alignment: .leading, spacing: 12) {
            slider("Padding", value: $style.padding, range: 0...0.25) { "\(Int(($0 * 100).rounded()))%" }
            slider("Corners", value: $style.corners, range: 0...0.1) { "\(Int(($0 * 1000).rounded()))" }
            slider("Shadow", value: $style.shadow, range: 0...1) { "\(Int(($0 * 100).rounded()))%" }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                        format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(Theme.Fonts.bodyStrong).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(format(value.wrappedValue)).font(Theme.Fonts.body).monospacedDigit().foregroundStyle(Theme.textSecondary)
            }
            Slider(value: value, in: range)
        }
    }

    private var shapes: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Size")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(FrameAspect.allCases) { aspect in
                    let selected = style.aspect == aspect
                    Button { style.aspect = aspect } label: {
                        Text(aspect.label)
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Theme.accentText : Theme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                .fill(selected ? Theme.accent.opacity(0.12) : Theme.surfaceRaised))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                .strokeBorder(selected ? Theme.accent : Theme.hairline, lineWidth: selected ? 1.5 : 1))
                    }
                    .buttonStyle(.plain)
                    .help(aspect.help)
                }
            }
            SectionLabel("Position")
            HStack(alignment: .top, spacing: 14) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 4), count: 3), spacing: 4) {
                    ForEach(FrameAlignment.allCases) { alignment in
                        let selected = style.alignment == alignment && !style.balance
                        Button { style.alignment = alignment; style.balance = false } label: {
                            Image(systemName: alignment.symbol)
                                .font(.system(size: alignment == .center ? 6 : 10, weight: .bold))
                                .foregroundStyle(selected ? Theme.accentText : Theme.textSecondary)
                                .frame(width: 26, height: 22)
                                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(selected ? Theme.accent.opacity(0.14) : Theme.surfaceRaised))
                                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(selected ? Theme.accent : Theme.hairline))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 86)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Auto balance", isOn: $style.balance)
                        .font(Theme.Fonts.bodyStrong)
                    Text("Centres what's in the picture, not just its edges.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let image = preview {
                let layout = FrameLayout.layout(imageSize: CGSize(width: image.width, height: image.height), style: style)
                Text("Preview \(Int(layout.canvas.width)) × \(Int(layout.canvas.height)); saved at full size")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Close", action: onClose).keyboardShortcut(.cancelAction)
            Spacer()
            Button { copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
                .buttonStyle(ChipButtonStyle())
                .disabled(saving)
            Button { save() } label: { Label("Save PNG", systemImage: "square.and.arrow.down") }
                .buttonStyle(GlowButtonStyle())
                .keyboardShortcut("s", modifiers: .command)
                .disabled(saving)
        }
    }

    private func savePreset() {
        FramePresetStore.add(name: presetName, style: style)
        custom = FramePresetStore.custom()
        presetName = ""
        naming = false
    }

    private func load() async {
        DesktopPicture.refresh()
        let url = self.url
        let loaded = await Task.detached(priority: .userInitiated) {
            try? ImageEditEngine.loadPreview(url, maxPixel: 1200)
        }.value
        preview = loaded?.image
        // The look may have been set before the picture finished loading.
        await refresh()
    }

    private func refresh() async {
        guard let base = preview else { return }
        FramePresetStore.last = style
        let style = self.style
        try? await Task.sleep(nanoseconds: 60_000_000)
        guard !Task.isCancelled else { return }
        let box = ImageEditEngine.PreviewImage(image: base, originalSize: .zero)
        let result = await Task.detached(priority: .userInitiated) {
            (try? FrameRenderer.render(box.image, style: style)).map { ImageEditEngine.PreviewImage(image: $0, originalSize: .zero) }
        }.value
        guard !Task.isCancelled else { return }
        rendered = result?.image
    }

    private func save() {
        saving = true
        let url = self.url, style = self.style
        Task {
            do {
                let out = try await Task.detached(priority: .userInitiated) { try FrameRenderer.save(url, style: style) }.value
                Toast.show("Saved \(out.lastPathComponent)", detail: out.deletingLastPathComponent().path)
                NSWorkspace.shared.activateFileViewerSelecting([out])
            } catch {
                Toast.show("Couldn't save", detail: error.localizedDescription, symbol: "exclamationmark.triangle.fill")
            }
            saving = false
        }
    }

    private func copy() {
        saving = true
        let url = self.url, style = self.style
        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) { () throws -> Data in
                    let framed = try FrameRenderer.render(try ImageConverter.loadCGImage(url), style: style)
                    return try ImageConverter.data(from: framed, type: .png)
                }.value
                let board = NSPasteboard.general
                board.clearContents()
                board.setData(data, forType: .png)
                Toast.show("Framed picture copied")
            } catch {
                Toast.show("Couldn't copy", detail: error.localizedDescription, symbol: "exclamationmark.triangle.fill")
            }
            saving = false
        }
    }
}
