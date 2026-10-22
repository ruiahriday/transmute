import AppKit
import SwiftUI

/// Transmute's look: the teal-to-blue brand gradient, slowly drifting colour glows behind glass
/// cards, and small springy animations for things that change.
enum Theme {
    static let teal = Color(red: 0.26, green: 0.78, blue: 0.67)
    static let blue = Color(red: 0.16, green: 0.37, blue: 0.85)
    static let violet = Color(red: 0.49, green: 0.36, blue: 0.93)
    static let brand = LinearGradient(colors: [teal, blue], startPoint: .topLeading, endPoint: .bottomTrailing)
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

// MARK: Background

/// Three soft colour glows that drift behind the window's content.
struct AuroraBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                ZStack {
                    glow(Theme.teal, size: geo.size, x: 0.18 + 0.10 * sin(t / 7), y: 0.20 + 0.08 * cos(t / 9))
                    glow(Theme.blue, size: geo.size, x: 0.82 + 0.08 * cos(t / 8), y: 0.30 + 0.10 * sin(t / 6))
                    glow(Theme.violet, size: geo.size, x: 0.50 + 0.15 * sin(t / 11), y: 0.88 + 0.06 * cos(t / 7))
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
    }

    private func glow(_ color: Color, size: CGSize, x: Double, y: Double) -> some View {
        let diameter = max(size.width, size.height) * 0.62
        return Circle()
            .fill(color.opacity(scheme == .dark ? 0.30 : 0.22))
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
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
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
            .shadow(color: Theme.blue.opacity(isEnabled ? 0.45 : 0), radius: configuration.isPressed ? 4 : 10, y: 4)
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
                            .shadow(color: Theme.blue.opacity(0.35), radius: 6, y: 2)
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
    var tint: Color = Theme.blue
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            let width = max(6, geo.size.width * min(1, max(0, value)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.8), Theme.teal], startPoint: .leading, endPoint: .trailing))
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
            .foregroundStyle(.white, Theme.teal)
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
        Circle()
            .fill(Theme.brand)
            .frame(width: 80, height: 80)
            .overlay(
                Image(systemName: targeted ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(targeted ? 0 : (pulse ? 12 : -12)))
            )
            .shadow(color: Theme.blue.opacity(0.5), radius: targeted ? 30 : 18, y: 6)
            .scaleEffect(targeted ? 1.12 : (pulse ? 1.04 : 0.98))
    }

    private var rings: some View {
        ZStack {
            ForEach(0..<2) { i in
                Circle()
                    .stroke(Theme.teal.opacity(pulse ? 0 : 0.35), lineWidth: 2)
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
