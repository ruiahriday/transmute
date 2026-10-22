import AppKit
import SwiftUI

/// Spinform's look: the indigo-violet-pink brand gradient from the icon, slowly drifting colour
/// glows behind glass cards, and small springy animations for things that change.
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
    static let accent = Color.adaptive(light: 0x7C3AED, dark: 0xA78BFA)
    /// Finished, saved, done.
    static let success = Color.adaptive(light: 0x059669, dark: 0x34D399)
    /// The core dot's warm gradient.
    static let core = [coral, rose]
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.78)

    /// A colour per kind of file, for badges and progress bars.
    static func tint(_ kind: FileKind) -> Color {
        switch kind {
        case .image: Color(red: 0.95, green: 0.45, blue: 0.55)
        case .video: Color(red: 0.55, green: 0.42, blue: 0.97)
        case .audio: Color(red: 0.98, green: 0.62, blue: 0.25)
        case .pdf: Color(red: 0.93, green: 0.32, blue: 0.30)
        case .document, .ebook: Color(red: 0.25, green: 0.55, blue: 0.95)
        case .presentation: Color(red: 0.96, green: 0.50, blue: 0.20)
        case .spreadsheet: Color(red: 0.20, green: 0.70, blue: 0.45)
        case .subtitle: Color(red: 0.45, green: 0.60, blue: 0.70)
        case .archive: Color(red: 0.62, green: 0.50, blue: 0.38)
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

/// Soft brand-colour glows (indigo, violet, pink and a little of the core's coral) that drift
/// behind the window's content.
struct AuroraBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                ZStack {
                    glow(Theme.violet, size: geo.size, x: 0.18 + 0.10 * sin(t / 7), y: 0.20 + 0.08 * cos(t / 9),
                         light: 0.20, dark: 0.30)
                    glow(Theme.pink, size: geo.size, x: 0.84 + 0.08 * cos(t / 8), y: 0.28 + 0.10 * sin(t / 6),
                         light: 0.14, dark: 0.20)
                    glow(Theme.indigo, size: geo.size, x: 0.50 + 0.15 * sin(t / 11), y: 0.88 + 0.06 * cos(t / 7),
                         light: 0.16, dark: 0.34)
                    glow(Theme.coral, size: geo.size, x: 0.86 + 0.05 * sin(t / 10), y: 0.84 + 0.05 * cos(t / 12),
                         light: 0.10, dark: 0.08, scale: 0.4)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
    }

    private func glow(_ color: Color, size: CGSize, x: Double, y: Double,
                      light: Double, dark: Double, scale: CGFloat = 0.62) -> some View {
        let diameter = max(size.width, size.height) * scale
        let opacity = scheme == .dark ? dark : light
        return Circle()
            .fill(color.opacity(opacity))
            .frame(width: diameter, height: diameter)
            .blur(radius: diameter * 0.28)
            .position(x: size.width * x, y: size.height * y)
    }
}

// MARK: Glass

struct GlassCard: ViewModifier {
    var radius: CGFloat = 18
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), Theme.violet.opacity(0.10)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
            .shadow(color: Theme.indigo.opacity(0.12), radius: 18, y: 8)
    }
}

extension View {
    func glassCard(radius: CGFloat = 18, padding: CGFloat = 16) -> some View {
        modifier(GlassCard(radius: radius, padding: padding))
    }
}

// MARK: Buttons

/// The big gradient button (Convert, Compress).
struct GlowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(Theme.brand, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.25)))
            .shadow(color: Theme.violet.opacity(isEnabled ? 0.45 : 0), radius: configuration.isPressed ? 4 : 10, y: 4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Small rounded buttons for the Tools tab.
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
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.11 : 0.07))
                )
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.15), value: hovering)
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
        HStack(spacing: 4) {
            ForEach(options) { option in
                segment(option)
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private func segment(_ option: Value) -> some View {
        let selected = option == selection
        return Button {
            withAnimation(Theme.spring) { selection = option }
        } label: {
            Label(title(option), systemImage: symbol(option))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.75))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background {
                    if selected {
                        Capsule().fill(Theme.brand)
                            .matchedGeometryEffect(id: "highlight", in: namespace)
                            .shadow(color: Theme.violet.opacity(0.35), radius: 6, y: 2)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Progress

/// A rounded bar with the brand gradient and a light sweep moving across it while it runs.
struct GlowProgressBar: View {
    var value: Double
    var tint: Color = Theme.violet
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            let width = max(6, geo.size.width * min(1, max(0, value)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.85), Theme.pinkLight], startPoint: .leading, endPoint: .trailing))
                    .frame(width: width)
                    .overlay(alignment: .leading) {
                        LinearGradient(colors: [.clear, .white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 40)
                            .offset(x: sweep ? width : -40)
                    }
                    .clipShape(Capsule())
                    .animation(.easeOut(duration: 0.25), value: value)
            }
        }
        .frame(height: 6)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { sweep = true }
        }
    }
}

// MARK: Badges

/// A rounded square with the kind's symbol, tinted by kind.
struct KindBadge: View {
    let kind: FileKind
    var size: CGFloat = 38

    var body: some View {
        let tint = Theme.tint(kind)
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [tint, tint.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: kind.symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .shadow(color: tint.opacity(0.4), radius: 6, y: 3)
    }
}

/// A check mark that pops in.
struct PopCheck: View {
    @State private var shown = false

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 18))
            .foregroundStyle(.white, Theme.success)
            .scaleEffect(shown ? 1 : 0.2)
            .opacity(shown ? 1 : 0)
            .onAppear { withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) { shown = true } }
    }
}

// MARK: Drop zone

/// The empty window: a glowing drop target with format chips circling it.
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
            VStack(spacing: 6) {
                Text(targeted ? "Let go to add" : "Drop anything here")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .contentTransition(.opacity)
                Text("Images, video, audio, PDFs, documents, e-books, spreadsheets, slides, subtitles and archives")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            Button(action: onChoose) {
                Label("Choose Files", systemImage: "plus")
            }
            .buttonStyle(GlowButtonStyle())
            if let wheelHint {
                Label(wheelHint, systemImage: "circle.dashed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [10, 8], dashPhase: dash))
                .foregroundStyle(targeted ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.secondary.opacity(0.35)))
                .padding(14)
        )
        .scaleEffect(targeted ? 1.015 : 1)
        .animation(Theme.spring, value: targeted)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { pulse = true }
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { dash = -180 }
        }
    }

    private var core: some View {
        ZStack {
            Circle().fill(Theme.brand)
            Circle().fill(RadialGradient(colors: [.white.opacity(0.30), .clear], center: UnitPoint(x: 0.28, y: 0.18),
                                         startRadius: 0, endRadius: 60))
            SpinningMark(style: .onBrand, secondsPerTurn: targeted ? 3 : 14)
                .padding(10)
        }
        .frame(width: 80, height: 80)
        .shadow(color: Theme.violet.opacity(0.5), radius: targeted ? 30 : 18, y: 6)
        .scaleEffect(targeted ? 1.12 : (pulse ? 1.04 : 0.98))
    }

    private var rings: some View {
        ZStack {
            ForEach(0..<2) { i in
                Circle()
                    .stroke(Theme.pinkLight.opacity(pulse ? 0 : 0.40), lineWidth: 2)
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
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Theme.tint(kind)))
            .shadow(color: Theme.tint(kind).opacity(0.4), radius: 4, y: 2)
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
