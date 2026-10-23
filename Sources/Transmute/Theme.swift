import AppKit
import SwiftUI

/// Spinform's look: native macOS. System semantic colours that follow light and dark mode and the
/// accent chosen in System Settings, hairline separators, quiet surfaces and gentle springs.
enum Theme {
    // The accent is the user's own (System Settings → Appearance). The old brand names all map to it,
    // so nothing in the app is purple unless the user picked purple.
    static let indigo = Color.accentColor
    static let violet = Color.accentColor
    static let pink = Color.accentColor
    static let pinkLight = Color.accentColor
    static let indigoLight = Color.accentColor
    static let violetLight = Color.accentColor
    /// Recording, and anything that's live.
    static let rose = Color(nsColor: .systemRed)
    static let coral = Color(nsColor: .systemOrange)

    /// Primary fills (the main button, the selected wheel slice): a flat accent.
    static let brand = LinearGradient(colors: [Color.accentColor, Color.accentColor], startPoint: .top, endPoint: .bottom)
    /// Headline text: plain label colour.
    static let brandText = LinearGradient(colors: [Color(nsColor: .labelColor), Color(nsColor: .labelColor)],
                                          startPoint: .leading, endPoint: .trailing)
    static let accent = Color.accentColor
    static let accentText = Color.accentColor
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)
    /// The core dot of the mark.
    static let core = [Color(nsColor: .systemOrange), Color(nsColor: .systemRed)]
    /// Gentle spring; a quick fade when Reduce Motion is on.
    static var spring: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeOut(duration: 0.12) : .spring(response: 0.38, dampingFraction: 0.86)
    }
    /// A spring that turns into a quick fade when Reduce Motion is on.
    static func motion(_ reduce: Bool) -> Animation {
        reduce ? .easeOut(duration: 0.12) : .spring(response: 0.38, dampingFraction: 0.86)
    }

    // Surfaces, lines and text: the system's own, so they follow the appearance live.
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    /// Wells, chips and tiles inside a card.
    static let surfaceRaised = Color.primary.opacity(0.045)
    static let surfaceHover = Color.primary.opacity(0.08)
    static let hairline = Color(nsColor: .separatorColor)
    static let controlBorder = Color(nsColor: .tertiaryLabelColor)
    static let textPrimary = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)
    /// Behind pictures and video in the editors.
    static let stage = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.09, alpha: 1) : NSColor(white: 0.91, alpha: 1)
    })

    /// Corner radii, so cards, controls and chips agree.
    enum Radius {
        static let card: CGFloat = 10
        static let row: CGFloat = 8
        static let control: CGFloat = 6
        static let chip: CGFloat = 6
    }

    /// The type scale.
    enum Fonts {
        static let wordmark = Font.system(size: 17, weight: .semibold)
        static let title = Font.system(size: 14, weight: .semibold)
        static let bodyStrong = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 13)
        static let caption = Font.system(size: 11)
        static let section = Font.system(size: 11, weight: .semibold)
    }

    /// A muted, system-like colour per kind of file, for badges.
    static func tint(_ kind: FileKind) -> Color {
        let ns: NSColor
        switch kind {
        case .image: ns = .systemPink
        case .video: ns = .systemIndigo
        case .audio: ns = .systemOrange
        case .pdf: ns = .systemRed
        case .document, .ebook: ns = .systemBlue
        case .presentation: ns = .systemOrange
        case .spreadsheet: ns = .systemGreen
        case .subtitle: ns = .systemTeal
        case .archive: ns = .systemBrown
        case .other: ns = .systemGray
        }
        // Blend toward grey so badges stay quiet next to the content.
        return Color(nsColor: ns.blended(withFraction: 0.28, of: .systemGray) ?? ns)
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

/// The window's backdrop: the system window background.
struct AppBackground: View {
    var body: some View {
        Theme.canvas.ignoresSafeArea()
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
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.04), radius: 1, y: 0.5)
    }
}

extension View {
    func crispCard(radius: CGFloat = Theme.Radius.card, padding: CGFloat = 14) -> some View {
        modifier(CrispCard(radius: radius, padding: padding))
    }
}

/// Floating panels (HUD, toasts, capture cards): system material with a hairline edge.
struct FloatingPanel<S: InsettableShape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
    }
}

extension View {
    func floatingPanel(radius: CGFloat = Theme.Radius.card + 2) -> some View {
        modifier(FloatingPanel(shape: RoundedRectangle(cornerRadius: radius, style: .continuous)))
    }

    func floatingCapsule() -> some View {
        modifier(FloatingPanel(shape: Capsule()))
    }
}

/// Fades and settles a view in when it appears (no movement with Reduce Motion).
struct AppearIn: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown || reduceMotion ? 1 : 0.96)
            .onAppear { withAnimation(Theme.motion(reduceMotion)) { shown = true } }
    }
}

extension View {
    func appearIn() -> some View { modifier(AppearIn()) }
}

/// A small heading for a group of controls.
struct SectionLabel: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(Theme.Fonts.section)
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
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Color.black.opacity(configuration.isPressed ? 0.15 : 0)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Color.white.opacity(hovering && !configuration.isPressed ? 0.08 : 0)))
                .shadow(color: .black.opacity(isEnabled ? 0.10 : 0), radius: 0.5, y: 0.5)
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
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
                        .strokeBorder(Theme.hairline, lineWidth: 0.5)
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
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control + 1, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }

    private func segment(_ option: Value) -> some View {
        let selected = option == selection
        return Button {
            withAnimation(Theme.spring) { selection = option }
        } label: {
            Label(title(option), systemImage: symbol(option))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: Theme.Radius.control - 1, style: .continuous)
                            .fill(Theme.surface)
                            .matchedGeometryEffect(id: "highlight", in: namespace)
                            .shadow(color: .black.opacity(0.14), radius: 1, y: 0.5)
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
    var tint: Color = Theme.accent
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            let width = max(4, geo.size.width * min(1, max(0, value)))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline)
                Capsule()
                    .fill(tint)
                    .frame(width: width)
                    .overlay(alignment: .leading) {
                        LinearGradient(colors: [.clear, .white.opacity(0.3), .clear], startPoint: .leading, endPoint: .trailing)
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
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(tint.opacity(0.14))
            .frame(width: size, height: size)
            .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(tint.opacity(0.22), lineWidth: 0.5))
            .overlay(
                Image(systemName: kind.symbol)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(tint)
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
                    .font(.system(size: 22, weight: .semibold))
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
                .foregroundStyle(targeted ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.controlBorder.opacity(0.6)))
                .padding(10)
        )
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card - 2, style: .continuous)
                .fill(Theme.accent.opacity(targeted ? 0.06 : 0))
                .padding(10)
        )
        .animation(Theme.motion(reduceMotion), value: targeted)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { pulse = true }
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { dash = -130 }
        }
    }

    private var core: some View {
        ZStack {
            Circle().fill(Theme.surface)
            SpinningMark(style: .color, secondsPerTurn: targeted ? 3 : 14)
                .padding(14)
        }
        .frame(width: 80, height: 80)
        .overlay(Circle().strokeBorder(targeted ? Theme.accent : Theme.hairline, lineWidth: targeted ? 1.5 : 0.5))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        .scaleEffect(targeted ? 1.1 : (pulse ? 1.03 : 1))
    }

    private var rings: some View {
        ZStack {
            ForEach(0..<2) { i in
                Circle()
                    .stroke(Theme.textTertiary.opacity(pulse ? 0 : 0.35), lineWidth: 1)
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
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
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
                // Monochrome swooshes in the label colour, around the warm core.
                let ink = Color(nsColor: .labelColor)
                bladeColors = [ink.opacity(scheme == .dark ? 0.9 : 0.85), ink.opacity(0.6)]
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
