import AppKit
import SwiftUI

/// What the all-in-one chooser picked.
enum CaptureChoice: Equatable {
    case action(CaptureAction)
    /// An area of exactly this many pixels.
    case exactSize(CGSize)
    /// An area dragged at this width ÷ height.
    case lockedAspect(CGFloat)
}

/// The all-in-one chooser's memory: the last mode, the size typed and whether the shape is locked.
enum CaptureChooserMemory {
    private static let modeKey = "allInOneLastMode"
    private static let widthKey = "allInOneWidth"
    private static let heightKey = "allInOneHeight"
    private static let lockKey = "allInOneLockAspect"

    static func lastMode(defaults: UserDefaults = .standard) -> CaptureAction {
        CaptureAction(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .area
    }

    static func size(defaults: UserDefaults = .standard) -> CGSize {
        let w = defaults.integer(forKey: widthKey), h = defaults.integer(forKey: heightKey)
        return CGSize(width: w > 0 ? w : 1280, height: h > 0 ? h : 720)
    }

    static func lockAspect(defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: lockKey) }

    static func remember(_ choice: CaptureChoice, size: CGSize, lock: Bool, defaults: UserDefaults = .standard) {
        if case .action(let action) = choice { defaults.set(action.rawValue, forKey: modeKey) }
        defaults.set(Int(size.width), forKey: widthKey)
        defaults.set(Int(size.height), forKey: heightKey)
        defaults.set(lock, forKey: lockKey)
    }

    /// Whole pixels between 8 and 16384, from what was typed.
    static func parse(_ text: String) -> Int? {
        let digits = text.trimmingCharacters(in: .whitespaces).filter(\.isNumber)
        guard let value = Int(digits), value >= 8 else { return nil }
        return min(value, 16_384)
    }
}

/// One shortcut for every capture: a panel in the middle of the screen with each mode, an exact
/// size and a shape lock. Return repeats the last mode.
@MainActor
final class CaptureChooser {
    private static var panel: KeyPanel?
    private static var continuation: CheckedContinuation<CaptureChoice?, Never>?

    static func choose() async -> CaptureChoice? {
        finish(nil)
        return await withCheckedContinuation { (continuation: CheckedContinuation<CaptureChoice?, Never>) in
            self.continuation = continuation
            let size = CGSize(width: 520, height: 330)
            let screen = ScreenGrabber.screenUnderMouse?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            let frame = NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2 + 60,
                               width: size.width, height: size.height)
            let panel = KeyPanel.floating(frame, level: .modalPanel)
            panel.contentView = FirstClickHostingView(rootView: CaptureChooserView(onChoose: { finish($0) }))
            panel.onEscape = { finish(nil) }
            panel.setFrame(frame, display: true)
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            self.panel = panel
        }
    }

    static func finish(_ choice: CaptureChoice?) {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        continuation?.resume(returning: choice)
        continuation = nil
    }
}

struct CaptureChooserView: View {
    var onChoose: (CaptureChoice?) -> Void = { _ in }
    @State private var last = CaptureChooserMemory.lastMode()
    @State private var widthText = "\(Int(CaptureChooserMemory.size().width))"
    @State private var heightText = "\(Int(CaptureChooserMemory.size().height))"
    @State private var lock = CaptureChooserMemory.lockAspect()

    private static let modes: [CaptureAction] = [.area, .window, .fullscreen, .previous, .scrolling,
                                                 .text, .recordArea, .recordWindow, .recordScreen, .history]

    private var typedSize: CGSize? {
        guard let w = CaptureChooserMemory.parse(widthText), let h = CaptureChooserMemory.parse(heightText) else { return nil }
        return CGSize(width: w, height: h)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: CaptureAction.allInOne.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                Text("Capture").font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("Return repeats \(last.title.lowercased()) · Esc closes")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                ForEach(Self.modes) { action in modeButton(action) }
            }
            Divider()
            HStack(spacing: 8) {
                Text("Exact size").font(Theme.Fonts.bodyStrong).foregroundStyle(Theme.textPrimary)
                TextField("Width", text: $widthText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .onChange(of: widthText) { _ in matchHeight() }
                Text("×").foregroundStyle(Theme.textSecondary)
                TextField("Height", text: $heightText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Text("px").font(Theme.Fonts.caption).foregroundStyle(Theme.textSecondary)
                Toggle("Lock shape", isOn: $lock).toggleStyle(CrispCheckboxStyle())
                    .help("Areas you drag keep this width-to-height shape")
                Spacer()
            }
            HStack(spacing: 8) {
                Button {
                    if let size = typedSize { choose(.exactSize(size)) }
                } label: { Label("Capture This Size", systemImage: "rectangle.dashed").lineLimit(1).fixedSize() }
                    .buttonStyle(ChipButtonStyle())
                    .disabled(typedSize == nil)
                Button {
                    if let size = typedSize { choose(.lockedAspect(size.width / size.height)) }
                } label: { Label("Drag at This Shape", systemImage: "aspectratio").lineLimit(1).fixedSize() }
                    .buttonStyle(ChipButtonStyle())
                    .disabled(typedSize == nil)
                Spacer()
                Button("Cancel") { onChoose(nil) }
                    .buttonStyle(ChipButtonStyle())
                Button { choose(.action(last)) } label: { Label(last.shortTitle, systemImage: last.symbol) }
                    .buttonStyle(GlowButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
        .padding(10)
        .tint(Theme.accent)
    }

    /// With the shape locked, the height follows the width.
    private func matchHeight() {
        guard lock, let w = CaptureChooserMemory.parse(widthText) else { return }
        let size = CaptureChooserMemory.size()
        heightText = "\(max(8, Int((CGFloat(w) * size.height / max(size.width, 1)).rounded())))"
    }

    private func choose(_ choice: CaptureChoice) {
        let size = typedSize ?? CaptureChooserMemory.size()
        CaptureChooserMemory.remember(choice, size: size, lock: lock)
        if lock, case .action(.area) = choice {
            onChoose(.lockedAspect(size.width / size.height))
            return
        }
        onChoose(choice)
    }

    private func modeButton(_ action: CaptureAction) -> some View {
        let selected = action == last
        let recording = [CaptureAction.recordArea, .recordWindow, .recordScreen].contains(action)
        return Button { choose(.action(action)) } label: {
            VStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(recording ? AnyShapeStyle(LinearGradient(colors: [Theme.pink, Theme.rose], startPoint: .topLeading,
                                                                   endPoint: .bottomTrailing)) : AnyShapeStyle(Theme.brand))
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: action.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white))
                Text(recording ? "Record \(action.shortTitle)" : action.shortTitle)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(HotkeyStore.hotkey(for: action)?.display ?? " ")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.12) : Theme.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.hairline, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(action.title)
    }
}
