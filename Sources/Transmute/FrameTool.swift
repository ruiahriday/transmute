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
    }

    var background: Background = .gradient(0x4338CA, 0xEC4899)
    /// Space around the picture, as a fraction of its longer side (0…0.25).
    var padding = 0.08
    /// Corner radius, as a fraction of the picture's shorter side (0…0.1).
    var corners = 0.025
    /// 0…1
    var shadow = 0.6
    var aspect: FrameAspect = .auto
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

    /// Twelve built-in looks; the first six are the Background tool's gradients.
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
    /// The canvas size and where the picture sits on it (top-left origin), in pixels.
    static func layout(imageSize: CGSize, style: FrameStyle) -> (canvas: CGSize, imageRect: CGRect) {
        let w = max(1, imageSize.width.rounded())
        let h = max(1, imageSize.height.rounded())
        let pad = (CGFloat(min(max(style.padding, 0), 0.5)) * max(w, h)).rounded()
        var canvas = CGSize(width: w + 2 * pad, height: h + 2 * pad)
        if let ratio = style.aspect.ratio.map({ CGFloat($0) }) {
            if canvas.width / canvas.height < ratio {
                canvas.width = (canvas.height * ratio).rounded()
            } else {
                canvas.height = (canvas.width / ratio).rounded()
            }
        }
        let origin = CGPoint(x: ((canvas.width - w) / 2).rounded(), y: ((canvas.height - h) / 2).rounded())
        return (canvas, CGRect(origin: origin, size: CGSize(width: w, height: h)))
    }

    static func cornerRadius(imageSize: CGSize, style: FrameStyle) -> CGFloat {
        CGFloat(min(max(style.corners, 0), 0.5)) * min(imageSize.width, imageSize.height)
    }
}

enum FrameRenderer {
    static func render(_ image: CGImage, style: FrameStyle) throws -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        let (canvas, placed) = FrameLayout.layout(imageSize: size, style: style)
        let width = Int(canvas.width), height = Int(canvas.height)
        guard width * height < 400_000_000, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError("That picture is too big to frame.")
        }
        let full = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        switch style.background {
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

    private func swatch(_ background: FrameStyle.Background) -> some View {
        Circle().fill(Self.fill(background))
    }

    static func fill(_ background: FrameStyle.Background) -> AnyShapeStyle {
        switch background {
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
        let url = self.url
        let loaded = await Task.detached(priority: .userInitiated) {
            try? ImageEditEngine.loadPreview(url, maxPixel: 1200)
        }.value
        preview = loaded?.image
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
