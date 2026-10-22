import AppKit
import SwiftUI

/// A picture pinned on top of every window: move it, resize it, fade it, or lock it so clicks go
/// through to whatever is underneath. Esc or the close button takes it away.
@MainActor
final class PinController: ObservableObject {
    private(set) static var all: [PinController] = []

    let url: URL?
    let image: NSImage
    let panel: KeyPanel
    @Published var opacity: Double = 1 {
        didSet { panel.alphaValue = CGFloat(opacity) }
    }
    @Published var locked = false {
        didSet {
            panel.ignoresMouseEvents = locked
            PinController.changed()
        }
    }

    static var lockedCount: Int { all.filter(\.locked).count }

    /// Posted when pins come, go, lock or unlock (for the menu and the Capture tab).
    static let didChange = Notification.Name("SpinformPinsChanged")

    private init(url: URL?, image: NSImage) {
        self.url = url
        self.image = image
        panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .resizable, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 60, height: 40)
    }

    @discardableResult
    static func open(url: URL) -> PinController? {
        guard let image = NSImage(contentsOf: url) else {
            Toast.show("Couldn't pin that file", symbol: "exclamationmark.triangle.fill")
            return nil
        }
        return open(image: image, url: url)
    }

    @discardableResult
    static func open(image: NSImage, url: URL? = nil, at origin: CGPoint? = nil) -> PinController {
        let pin = PinController(url: url, image: image)
        pin.show(at: origin)
        all.append(pin)
        changed()
        return pin
    }

    /// A pin that isn't on screen, for the window pictures.
    static func preview(image: NSImage) -> PinController { PinController(url: nil, image: image) }

    /// Asks for a picture, then pins it.
    static func choose() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.prompt = "Pin"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url: url) }
    }

    static func unlockAll() {
        for pin in all { pin.locked = false }
    }

    static func closeAll() {
        for pin in all { pin.close() }
    }

    private static func changed() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    private func show(at origin: CGPoint?) {
        let screen = ScreenGrabber.screenUnderMouse ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let scale = screen?.backingScaleFactor ?? 2
        // Pixel pictures (screenshots) show at their real size, but never bigger than 60% of the screen.
        var size = image.size
        if let rep = image.representations.first, rep.pixelsWide > 0 {
            size = NSSize(width: CGFloat(rep.pixelsWide) / scale, height: CGFloat(rep.pixelsHigh) / scale)
        }
        let fit = min(1, visible.width * 0.6 / max(1, size.width), visible.height * 0.6 / max(1, size.height))
        size = NSSize(width: max(60, size.width * fit), height: max(40, size.height * fit))
        let start = origin ?? CGPoint(x: visible.midX - size.width / 2 + CGFloat(PinController.all.count) * 24,
                                      y: visible.midY - size.height / 2 - CGFloat(PinController.all.count) * 24)
        panel.contentAspectRatio = size
        panel.contentView = FirstClickHostingView(rootView: PinView(pin: self))
        panel.setFrame(NSRect(origin: start, size: size), display: true)
        panel.onEscape = { [weak self] in self?.close() }
        panel.onArrow = { [weak self] dx, dy in self?.nudge(dx: dx, dy: dy) }
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func zoom(by factor: CGFloat) {
        var frame = panel.frame
        let ratio = frame.width / max(1, frame.height)
        let width = min(max(80, frame.width * factor), 4000)
        let height = width / ratio
        frame.origin.x += (frame.width - width) / 2
        frame.origin.y += (frame.height - height) / 2
        frame.size = NSSize(width: width, height: height)
        panel.setFrame(frame, display: true, animate: false)
    }

    /// Moves the pin by whole points (the arrow keys; Shift for ten at a time).
    func nudge(dx: CGFloat, dy: CGFloat) {
        var frame = panel.frame
        frame.origin.x += dx
        frame.origin.y += dy
        panel.setFrame(frame, display: true)
    }

    func copy() {
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([image])
        Toast.show("Pinned picture copied")
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
        PinController.all.removeAll { $0 === self }
        PinController.changed()
    }
}

struct PinView: View {
    @ObservedObject var pin: PinController
    var forceToolbar = false
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .top) {
            WindowDragArea { delta in
                pin.zoom(by: delta > 0 ? 1.04 : 0.96)
            }
            Image(nsImage: pin.image)
                .resizable()
                .interpolation(.high)
                .allowsHitTesting(false)
            if hovering || forceToolbar {
                toolbar
                    .padding(6)
                    .transition(.opacity)
            }
            if pin.locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(Color.black.opacity(0.55), in: Circle())
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(hovering ? Theme.accent.opacity(0.8) : Color.black.opacity(0.15), lineWidth: 1))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            button("xmark", "Close (Esc)") { pin.close() }
            Spacer(minLength: 4)
            Menu {
                ForEach([1.0, 0.8, 0.6, 0.4, 0.25], id: \.self) { level in
                    Button("\(Int(level * 100))%") { pin.opacity = level }
                }
            } label: {
                Image(systemName: "circle.lefthalf.filled")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26, height: 24)
            .help("Opacity")
            button("minus.magnifyingglass", "Smaller") { pin.zoom(by: 0.8) }
            button("plus.magnifyingglass", "Larger") { pin.zoom(by: 1.25) }
            button("doc.on.doc", "Copy") { pin.copy() }
            button("lock", "Lock: clicks pass through. Unlock from the Spinform menu. Arrow keys nudge the pin.") { pin.locked = true }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Theme.surface.opacity(0.94), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
        .tint(Theme.textPrimary)
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
