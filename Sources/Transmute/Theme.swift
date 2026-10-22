import AppKit
import SwiftUI

/// Spinform's look: the indigo-violet-pink brand gradient from the icon on crisp, solid
/// surfaces with hairline borders, a clear type scale, and small springy animations.
enum Theme {
    // Brand palette (the icon's colours).
    static let indigo = Color(hex: 0x4338CA)
    static let violet = Color(hex: 0x8B5CF6)
    static let pink = Color(hex: 0xEC4899)
    static let pinkLight = Color(hex: 0xF472B6)
    static let coral = Color(hex: 0xFDBA74)
    static let rose = Color(hex: 0xF43F5E)
    // Lighter steps of the same hues, for text and lines on dark backgrounds.
    static let indigoLight = Color(hex: 0x818CF8)
    static let violetLight = Color(hex: 0xA78BFA)

    /// Fills: buttons, the selected mode, the drop target. Same gradient as the icon's tile.
    static let brand = LinearGradient(colors: [indigo, violet, pinkLight], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// For gradient text, which needs lighter colours in dark mode to stay readable.
    static let brandText = LinearGradient(
        colors: [.adaptive(light: 0x4338CA, dark: 0x818CF8), .adaptive(light: 0x7C3AED, dark: 0xA78BFA),
                 .adaptive(light: 0xDB2777, dark: 0xF472B6)],
        startPoint: .leading, endPoint: .trailing)
    /// The app's accent for controls (toggles, sliders, selection rings).
    static let accent = Color.adaptive(light: 0x6D28D9, dark: 0x8B5CF6)
    /// Accent-coloured text and symbols, readable on the surfaces below.
    static let accentText = Color.adaptive(light: 0x5B21B6, dark: 0xC4B5FD)
    /// Finished, saved, done.
    static let success = Color.adaptive(light: 0x047857, dark: 0x34D399)
    static let warning = Color.adaptive(light: 0xB45309, dark: 0xFBBF24)
    static let danger = Color.adaptive(light: 0xB91C1C, dark: 0xF87171)
    /// The core dot's warm gradient.
    static let core = [coral, rose]
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.78)

    // Surfaces, lines and text: solid and crisp, with enough contrast in light mode.
    /// The window behind everything.
    static let canvas = Color.adaptive(light: 0xF3F3F6, dark: 0x0F0F12)
    /// Cards and rows.
    static let surface = Color.adaptive(light: 0xFFFFFF, dark: 0x1B1B20)
    /// Chips, tiles and wells inside a card.
    static let surfaceRaised = Color.adaptive(light: 0xF5F5F8, dark: 0x26262C)
    static let surfaceHover = Color.adaptive(light: 0xEDEDF2, dark: 0x303037)
    /// One-pixel borders on cards and controls.
    static let hairline = Color.adaptive(light: 0xDCDCE3, dark: 0x34343C)
    /// Borders of things you click: checkboxes, swatches.
    static let controlBorder = Color.adaptive(light: 0x7C7C8A, dark: 0x8A8A96)
    static let textPrimary = Color.adaptive(light: 0x111118, dark: 0xF4F4F6)
    static let textSecondary = Color.adaptive(light: 0x4B4B57, dark: 0xB0B0BB)
    static let textTertiary = Color.adaptive(light: 0x6B6B78, dark: 0x8C8C98)

    /// Corner radii, so cards, controls and chips agree.
    enum Radius {
        static let card: CGFloat = 12
        static let row: CGFloat = 10
        static let control: CGFloat = 8
        static let chip: CGFloat = 7
    }

    /// The type scale.
    enum Fonts {
        static let wordmark = Font.system(size: 20, weight: .bold, design: .rounded)
        static let title = Font.system(size: 15, weight: .semibold)
        static let bodyStrong = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 13)
        static let caption = Font.system(size: 11.5)
        static let section = Font.system(size: 10.5, weight: .semibold)
    }

    /// A colour per kind of file, for badges and progress bars.
    static func tint(_ kind: FileKind) -> Color {
        switch kind {
        case .image: Color(red: 0.91, green: 0.36, blue: 0.48)
        case .video: Color(red: 0.49, green: 0.36, blue: 0.93)
        case .audio: Color(red: 0.95, green: 0.55, blue: 0.16)
        case .pdf: Color(red: 0.88, green: 0.26, blue: 0.25)
        case .document, .ebook: Color(red: 0.20, green: 0.49, blue: 0.91)
        case .presentation: Color(red: 0.93, green: 0.45, blue: 0.15)
        case .spreadsheet: Color(red: 0.13, green: 0.62, blue: 0.40)
        case .subtitle: Color(red: 0.36, green: 0.52, blue: 0.63)
        case .archive: Color(red: 0.55, green: 0.44, blue: 0.33)
        case .other: Color.gray
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    /// A colour that follows the window's light or dark appearance.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        func ns(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        let color = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light)
        }
        return Color(nsColor: color)
    }
}

// MARK: Background

/// The window's backdrop: a flat, solid canvas with a faint brand tint along the top edge.
/// No blurred glows, so everything on it stays sharp.
struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .top) {
            Theme.canvas
            LinearGradient(colors: [Theme.violet.opacity(scheme == .dark ? 0.10 : 0.07), Theme.canvas.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 160)
        }
        .ignoresSafeArea()
    }
}

// MARK: Cards

/// A solid card with a one-pixel border and a tight shadow.
struct CrispCard: ViewModifier {
    var radius: CGFloat = Theme.Radius.card
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
    }
}

extension View {
    func crispCard(radius: CGFloat = Theme.Radius.card, padding: CGFloat = 14) -> some View {
        modifier(CrispCard(radius: radius, padding: padding))
    }
}

/// A small upper-case heading for a group of controls.
struct SectionLabel: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(Theme.Fonts.section)
            .tracking(0.6)
            .foregroundStyle(Theme.textSecondary)
    }
}

/// The filename heading at the top of the video, audio and info editors.
struct EditorTitle: View {
    let url: URL

    var body: some View {
        HStack(spacing: 10) {
            KindBadge(kind: FileKind.of(url), size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(Theme.Fonts.title)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Edits are saved as a copy; the original stays as it is.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

// MARK: Buttons

/// The main action button (Convert, Compress): the brand gradient, crisp edges, no glow.
struct GlowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryBody(configuration: configuration)
    }

    private struct PrimaryBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Color.black.opacity(configuration.isPressed ? 0.16 : 0)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Color.white.opacity(hovering && !configuration.isPressed ? 0.10 : 0)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.12), lineWidth: 1))
                .shadow(color: Theme.indigo.opacity(isEnabled ? 0.22 : 0), radius: 2, y: 1)
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// Small buttons for the Tools tab and rows: solid, with a border that firms up on hover.
struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration)
    }

    private struct ChipBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .fill(configuration.isPressed ? Theme.hairline : hovering ? Theme.surfaceHover : Theme.surfaceRaised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .strokeBorder(hovering && isEnabled ? Theme.controlBorder.opacity(0.7) : Theme.hairline, lineWidth: 1)
                )
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// A checkbox that stays easy to see on white: a firm border when off, the accent when on.
struct CrispCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        CheckboxBody(configuration: configuration)
    }

    private struct CheckboxBody: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let on = configuration.isOn
            Button { configuration.isOn.toggle() } label: {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(on ? Theme.accent : Theme.surface)
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(on ? Theme.accent : (hovering ? Theme.textSecondary : Theme.controlBorder), lineWidth: 1.25))
                        .overlay {
                            if on {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                            }
                        }
                        .frame(width: 15, height: 15)
                    configuration.label
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.textPrimary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
            .accessibilityValue(on ? "on" : "off")
        }
    }
}

// MARK: Mode picker

/// A segmented control whose highlight slides between the choices.
struct SlidingPicker<Value: Hashable & Identifiable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    let symbol: (Value) -> String
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                segment(option)
            }
        }
        .padding(3)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.control + 1, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control + 1, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private func segment(_ option: Value) -> some View {
        let selected = option == selection
        return Button {
            withAnimation(Theme.spring) { selection = option }
        } label: {
            Label(title(option), systemImage: symbol(option))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: Theme.Radius.control - 2, style: .continuous)
                            .fill(Theme.brand)
                            .matchedGeometryEffect(id: "highlight", in: namespace)
                            .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Progress

/// A thin rounded bar in the file's colour, with a light sweep moving across it while it runs.
struct GlowProgressBar: View {
    var value: Double
    var tint: Color = Theme.violet
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            let width = max(4, geo.size.width * min(1, max(0, value)))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline)
                Capsule()
                    .fill(LinearGradient(colors: [tint, Theme.pink], startPoint: .leading, endPoint: .trailing))
                    .frame(width: width)
                    .overlay(alignment: .leading) {
                        LinearGradient(colors: [.clear, .white.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 32)
                            .offset(x: sweep ? width : -32)
                    }
                    .clipShape(Capsule())
                    .animation(.easeOut(duration: 0.25), value: value)
            }
        }
        .frame(height: 5)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { sweep = true }
        }
    }
}

// MARK: Badges

/// A rounded square with the kind's symbol, tinted by kind.
struct KindBadge: View {
    let kind: FileKind
    var size: CGFloat = 36

    var body: some View {
        let tint = Theme.tint(kind)
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [tint, tint.opacity(0.82)], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(Color.black.opacity(0.08)))
            .overlay(
                Image(systemName: kind.symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

/// A check mark that pops in.
struct PopCheck: View {
    @State private var shown = false

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white, Theme.success)
            .scaleEffect(shown ? 1 : 0.2)
            .opacity(shown ? 1 : 0)
            .onAppear { withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) { shown = true } }
    }
}

// MARK: Drop zone

/// The empty window: a drop target with the spinning mark and format chips circling it.
struct DropHero: View {
    let targeted: Bool
    let wheelHint: String?
    let onChoose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var dash: CGFloat = 0

    private let chips: [(String, FileKind)] = [
        ("JPG", .image), ("MP4", .video), ("PDF", .pdf), ("MP3", .audio),
        ("DOCX", .document), ("PNG", .image), ("ZIP", .archive), ("MOV", .video),
    ]

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                orbit
                rings
                core
            }
            .frame(width: 210, height: 160)
            VStack(spacing: 5) {
                Text(targeted ? "Let go to add" : "Drop anything here")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.opacity)
                Text("Images, video, audio, PDFs, documents, e-books, spreadsheets, slides, subtitles and archives")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            Button(action: onChoose) {
                Label("Choose Files", systemImage: "plus")
            }
            .buttonStyle(GlowButtonStyle())
            if let wheelHint {
                Label(wheelHint, systemImage: "circle.dashed")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).strokeBorder(Theme.hairline))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card - 2, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6], dashPhase: dash))
                .foregroundStyle(targeted ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.controlBorder.opacity(0.45)))
                .padding(10)
        )
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card - 2, style: .continuous)
                .fill(Theme.violet.opacity(targeted ? 0.06 : 0))
                .padding(10)
        )
        .animation(Theme.spring, value: targeted)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { pulse = true }
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { dash = -130 }
        }
    }

    private var core: some View {
        ZStack {
            Circle().fill(Theme.brand)
            SpinningMark(style: .onBrand, secondsPerTurn: targeted ? 3 : 14)
                .padding(10)
        }
        .frame(width: 80, height: 80)
        .overlay(Circle().strokeBorder(Color.black.opacity(0.08)))
        .shadow(color: Theme.indigo.opacity(0.25), radius: 3, y: 2)
        .scaleEffect(targeted ? 1.1 : (pulse ? 1.03 : 1))
    }

    private var rings: some View {
        ZStack {
            ForEach(0..<2) { i in
                Circle()
                    .stroke(Theme.violet.opacity(pulse ? 0 : 0.35), lineWidth: 1.5)
                    .frame(width: 80, height: 80)
                    .scaleEffect(pulse ? 1.9 + CGFloat(i) * 0.3 : 1)
            }
        }
    }

    private var orbit: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(Array(chips.enumerated()), id: \.offset) { index, chip in
                    chipView(chip.0, chip.1)
                        .offset(orbitOffset(index: index, time: t))
                }
            }
        }
    }

    private func orbitOffset(index: Int, time: Double) -> CGSize {
        let angle = Double(index) / Double(chips.count) * 2 * .pi + time / 9
        let radius = targeted ? 104.0 : 94.0
        return CGSize(width: cos(angle) * radius, height: sin(angle) * radius * 0.68)
    }

    private func chipView(_ label: String, _ kind: FileKind) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.tint(kind)))
    }
}

// MARK: Mark

/// The Spinform mark: three tapered swooshes spinning clockwise around a warm core (the "spin" of
/// the drag wheel plus "transform"). Same geometry as the icon, which is drawn on a 560-unit box.
enum MarkGeometry {
    /// One swoosh's outline in a square of side `side`, thin at the tail and round at the head.
    static func blade(_ index: Int, side: CGFloat) -> Path {
        let unit = side / 560
        let center = CGPoint(x: side / 2, y: side / 2)
        let radius = 205 * unit
        let widest = 92 * unit
        let start = -90.0 + Double(index) * 120 + 8
        let sweep = 104.0
        let steps = 48
        var outer: [CGPoint] = []
        var inner: [CGPoint] = []
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let angle = (start + sweep * t) * .pi / 180
            let grow = pow(sin(t * .pi / 2), 1.4)
            let half = widest * CGFloat(0.015 + 0.985 * grow) / 2
            let dx = CGFloat(cos(angle))
            let dy = CGFloat(sin(angle))
            outer.append(CGPoint(x: center.x + (radius + half) * dx, y: center.y + (radius + half) * dy))
            inner.append(CGPoint(x: center.x + (radius - half) * dx, y: center.y + (radius - half) * dy))
        }
        // The rounded head: half a circle from the outer edge, around the front, to the inner edge.
        let headAngle = (start + sweep) * .pi / 180
        let head = CGPoint(x: center.x + radius * CGFloat(cos(headAngle)), y: center.y + radius * CGFloat(sin(headAngle)))
        var cap: [CGPoint] = []
        for j in 1..<16 {
            let a = headAngle + Double.pi * Double(j) / 16
            cap.append(CGPoint(x: head.x + widest / 2 * CGFloat(cos(a)), y: head.y + widest / 2 * CGFloat(sin(a))))
        }
        var path = Path()
        path.addLines(outer + cap + inner.reversed())
        path.closeSubpath()
        return path
    }

    /// Radius of the core dot.
    static func coreRadius(side: CGFloat) -> CGFloat { 78 * side / 560 }

    /// The whole mark as one black template image, for the menu bar.
    static func templateImage(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)
            for index in 0..<3 {
                context.addPath(blade(index, side: size).cgPath)
            }
            let core = coreRadius(side: size) * 1.15
            context.addEllipse(in: CGRect(x: size / 2 - core, y: size / 2 - core, width: core * 2, height: core * 2))
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The mark drawn in SwiftUI. `.color` is the full-colour mark for light or dark backgrounds;
/// `.onBrand` has white swooshes and a ringed core, for drawing on the brand gradient like the icon.
struct SpinformMark: View {
    enum Style { case color, onBrand }
    var style: Style = .color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            context.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2)
            let bladeColors: [Color]
            switch style {
            case .color:
                bladeColors = scheme == .dark
                    ? [Theme.indigoLight, Theme.violetLight, Theme.pinkLight]
                    : [Theme.indigo, Theme.violet, Theme.pink]
            case .onBrand:
                bladeColors = [.white, Color(hex: 0xFDE7F3)]
            }
            for index in 0..<3 {
                let blade = MarkGeometry.blade(index, side: side)
                let box = blade.boundingRect
                context.fill(blade, with: .linearGradient(Gradient(colors: bladeColors),
                                                         startPoint: CGPoint(x: box.minX, y: box.minY),
                                                         endPoint: CGPoint(x: box.maxX, y: box.maxY)))
            }
            let r = MarkGeometry.coreRadius(side: side)
            let core = Path(ellipseIn: CGRect(x: side / 2 - r, y: side / 2 - r, width: r * 2, height: r * 2))
            let shine = CGPoint(x: side / 2 - r * 0.3, y: side / 2 - r * 0.4)
            context.fill(core, with: .radialGradient(Gradient(colors: Theme.core), center: shine,
                                                     startRadius: 0, endRadius: r * 1.6))
            if style == .onBrand {
                context.stroke(core, with: .color(.white), lineWidth: max(1, side * 14 / 560))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Spinform")
    }
}

/// The mark turning slowly (it stays still when Reduce Motion is on).
struct SpinningMark: View {
    var style: SpinformMark.Style = .color
    var secondsPerTurn: Double = 14
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let turns = reduceMotion ? 0 : t / secondsPerTurn
            SpinformMark(style: style)
                .rotationEffect(.degrees(turns.truncatingRemainder(dividingBy: 1) * 360))
        }
    }
}
