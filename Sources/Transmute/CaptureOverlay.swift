import AppKit
import SwiftUI

enum SelectionMode { case area, window }

/// Limits on the area being chosen (from the all-in-one chooser).
enum SelectionConstraint: Equatable {
    /// A box of exactly this many pixels follows the pointer; a click takes it.
    case fixedSize(CGSize)
    /// Dragging keeps this width ÷ height.
    case aspect(CGFloat)
}

/// How the crosshair looks, from Settings.
struct SelectionLook {
    var frozen = true
    var crosshair = true
    var magnifier = true

    @MainActor static var fromSettings: SelectionLook {
        SelectionLook(frozen: CaptureSettings.freezeScreen, crosshair: CaptureSettings.showCrosshair,
                      magnifier: CaptureSettings.showMagnifier)
    }
}

enum SelectionOutcome {
    /// A rectangle in global AppKit points, and the frozen picture of its screen.
    case area(CGRect, DisplayShot)
    case window(WindowInfo)
}

/// The crosshair: a frozen picture of every screen where the user drags out an area or clicks a window.
@MainActor
final class SelectionOverlay {
    private static var active: SelectionOverlay?
    private var panels: [KeyPanel] = []
    private var continuation: CheckedContinuation<SelectionOutcome?, Never>?

    /// nil when the user pressed Esc.
    static func select(mode: SelectionMode, shots: [DisplayShot], windows: [WindowInfo],
                       hint: String? = nil, constraint: SelectionConstraint? = nil,
                       look: SelectionLook = SelectionLook()) async -> SelectionOutcome? {
        active?.finish(nil)
        let overlay = SelectionOverlay()
        active = overlay
        return await withCheckedContinuation { (continuation: CheckedContinuation<SelectionOutcome?, Never>) in
            overlay.continuation = continuation
            overlay.show(mode: mode, shots: shots, windows: windows, hint: hint, constraint: constraint, look: look)
        }
    }

    private func show(mode: SelectionMode, shots: [DisplayShot], windows: [WindowInfo], hint: String?,
                      constraint: SelectionConstraint?, look: SelectionLook) {
        let mouse = NSEvent.mouseLocation
        for shot in shots {
            let panel = KeyPanel.floating(shot.frame, level: .screenSaver)
            // Frozen: the picture taken a moment ago covers the screen. Live: the real screen shows through.
            panel.isOpaque = look.frozen
            panel.backgroundColor = look.frozen ? .black : .clear
            panel.acceptsMouseMovedEvents = true
            let view = SelectionView(frame: NSRect(origin: .zero, size: shot.frame.size), shot: shot, mode: mode,
                                     windows: windows, hint: hint)
            view.constraint = constraint
            view.look = look
            view.onFinish = { [weak self] outcome in self?.finish(outcome) }
            panel.contentView = view
            panel.onEscape = { [weak self] in self?.finish(nil) }
            panel.setFrame(shot.frame, display: false)
            panel.orderFrontRegardless()
            if NSMouseInRect(mouse, shot.frame, false) {
                panel.makeKey()
                panel.makeFirstResponder(view)
            }
            panels.append(panel)
        }
        if panels.allSatisfy({ !$0.isKeyWindow }), let first = panels.first {
            first.makeKey()
            first.makeFirstResponder(first.contentView)
        }
        NSCursor.crosshair.push()
    }

    func finish(_ outcome: SelectionOutcome?) {
        guard let continuation else { return }
        self.continuation = nil
        for panel in panels {
            panel.orderOut(nil)
            panel.close()
        }
        panels.removeAll()
        NSCursor.pop()
        if SelectionOverlay.active === self { SelectionOverlay.active = nil }
        continuation.resume(returning: outcome)
    }
}

/// Draws the frozen screen, the dimmed surroundings, the selection with its size, and a magnifier.
final class SelectionView: NSView {
    var onFinish: ((SelectionOutcome?) -> Void)?
    var constraint: SelectionConstraint?
    var look = SelectionLook()

    private let shot: DisplayShot
    private let picture: NSImage
    private var mode: SelectionMode
    private let windows: [WindowInfo]
    private let hint: String?
    private var mouse: CGPoint?
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var hovered: WindowInfo?

    init(frame: NSRect, shot: DisplayShot, mode: SelectionMode, windows: [WindowInfo], hint: String?) {
        self.shot = shot
        self.picture = NSImage(cgImage: shot.image, size: shot.frame.size)
        self.mode = mode
        self.windows = windows
        self.hint = hint
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// For the window pictures: a selection in progress with the pointer at its corner.
    func showcase(selection: CGRect) {
        dragStart = CGPoint(x: selection.minX, y: selection.minY)
        dragCurrent = CGPoint(x: selection.maxX, y: selection.maxY)
        mouse = dragCurrent
        needsDisplay = true
    }

    // MARK: Coordinates

    private func global(_ p: CGPoint) -> CGPoint {
        CGPoint(x: shot.frame.minX + p.x, y: shot.frame.maxY - p.y)
    }

    private func globalRect(_ r: CGRect) -> CGRect {
        CGRect(x: shot.frame.minX + r.minX, y: shot.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    private func localRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX - shot.frame.minX, y: shot.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    private func window(at p: CGPoint?) -> WindowInfo? {
        guard let p else { return nil }
        let g = global(p)
        return windows.first { $0.frame.contains(g) }
    }

    /// The fixed-size box around the pointer, in view points.
    private var fixedBox: CGRect? {
        guard case .fixedSize(let pixels) = constraint, let mouse else { return nil }
        let s = max(1, shot.scale)
        let size = CGSize(width: min(pixels.width / s, bounds.width), height: min(pixels.height / s, bounds.height))
        let x = min(max(mouse.x - size.width / 2, 0), bounds.width - size.width)
        let y = min(max(mouse.y - size.height / 2, 0), bounds.height - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// A drag end point moved so the box keeps the chosen shape.
    static func constrained(start a: CGPoint, end b: CGPoint, ratio: CGFloat) -> CGPoint {
        guard ratio > 0 else { return b }
        let dx = b.x - a.x, dy = b.y - a.y
        var w = abs(dx), h = abs(dy)
        if h == 0 || w / h > ratio { h = w / ratio } else { w = h * ratio }
        return CGPoint(x: a.x + (dx < 0 ? -w : w), y: a.y + (dy < 0 ? -h : h))
    }

    private var selection: CGRect? {
        if let fixedBox { return fixedBox }
        guard let a = dragStart, let b = dragCurrent else { return nil }
        let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        let clipped = r.intersection(bounds)
        return clipped.width >= 1 && clipped.height >= 1 ? clipped : nil
    }

    // MARK: Events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
    }

    override func mouseExited(with event: NSEvent) {
        mouse = nil
        if mode == .window { hovered = nil }
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        mouse = convert(event.locationInWindow, from: nil)
        if mode == .window { hovered = window(at: mouse) }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragStart = p
        dragCurrent = p
    }

    override func mouseDragged(with event: NSEvent) {
        NSCursor.crosshair.set()
        var p = convert(event.locationInWindow, from: nil)
        if case .aspect(let ratio) = constraint, let start = dragStart {
            p = Self.constrained(start: start, end: p, ratio: ratio)
        }
        dragCurrent = CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
        if case .fixedSize = constraint { mouse = p } else { mouse = dragCurrent }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let fixedBox {
            onFinish?(.area(globalRect(snap(fixedBox)), shot))
            return
        }
        let start = dragStart ?? p
        let moved = abs(start.x - p.x) > 3 || abs(start.y - p.y) > 3
        if moved, let selection {
            let snapped = snap(selection)
            onFinish?(.area(globalRect(snapped), shot))
        } else if mode == .window, let hovered = window(at: p) {
            onFinish?(.window(hovered))
        } else {
            dragStart = nil
            dragCurrent = nil
            needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onFinish?(nil)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            onFinish?(nil)
        case 49:
            mode = mode == .area ? .window : .area
            hovered = mode == .window ? window(at: mouse) : nil
            needsDisplay = true
        case 36, 76:
            if mode == .window, let hovered { onFinish?(.window(hovered)) }
        default:
            super.keyDown(with: event)
        }
    }

    /// Whole pixels, so the saved picture is exactly what was framed.
    private func snap(_ r: CGRect) -> CGRect {
        let s = max(1, shot.scale)
        let x0 = (r.minX * s).rounded() / s, y0 = (r.minY * s).rounded() / s
        let x1 = (r.maxX * s).rounded() / s, y1 = (r.maxY * s).rounded() / s
        return CGRect(x: x0, y: y0, width: max(1 / s, x1 - x0), height: max(1 / s, y1 - y0))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if look.frozen {
            picture.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            NSColor.clear.setFill()
            bounds.fill(using: .copy)
        }
        let dim = NSColor.black.withAlphaComponent(0.4)
        if let selection {
            fill(dim, outside: selection)
            drawSelection(selection)
            drawLabel(sizeText(selection), near: selection)
        } else if mode == .window, let hovered {
            let r = localRect(hovered.frame).intersection(bounds)
            fill(dim, outside: r)
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            r.fill()
            let border = NSBezierPath(rect: r.insetBy(dx: 1.5, dy: 1.5))
            border.lineWidth = 3
            NSColor.controlAccentColor.setStroke()
            border.stroke()
            let name = hovered.owner.isEmpty ? "" : "\(hovered.owner)  ·  "
            drawLabel(name + sizeText(r), near: r)
        } else {
            NSColor.black.withAlphaComponent(0.16).setFill()
            bounds.fill()
            if let mouse, look.crosshair { drawGuides(at: mouse) }
        }
        if mode == .area, look.magnifier, let mouse { drawMagnifier(at: mouse) }
        if dragStart == nil || selection == nil || fixedBox != nil { drawHint() }
    }

    private func fill(_ color: NSColor, outside r: CGRect) {
        let path = NSBezierPath(rect: bounds)
        path.append(NSBezierPath(rect: r))
        path.windingRule = .evenOdd
        color.setFill()
        path.fill()
    }

    private func drawSelection(_ r: CGRect) {
        let outline = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
        outline.lineWidth = 1
        NSColor.white.setStroke()
        outline.stroke()
        let outer = NSBezierPath(rect: r.insetBy(dx: -1.5, dy: -1.5))
        outer.lineWidth = 1
        NSColor.black.withAlphaComponent(0.35).setStroke()
        outer.stroke()
        for corner in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                       CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)] {
            let handle = NSBezierPath(ovalIn: CGRect(x: corner.x - 4, y: corner.y - 4, width: 8, height: 8))
            NSColor.white.setFill()
            handle.fill()
            handle.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            handle.stroke()
        }
    }

    private func drawGuides(at p: CGPoint) {
        let guides = NSBezierPath()
        guides.move(to: CGPoint(x: p.x, y: 0))
        guides.line(to: CGPoint(x: p.x, y: bounds.height))
        guides.move(to: CGPoint(x: 0, y: p.y))
        guides.line(to: CGPoint(x: bounds.width, y: p.y))
        guides.lineWidth = 1
        NSColor.white.withAlphaComponent(0.55).setStroke()
        guides.setLineDash([4, 4], count: 2, phase: 0)
        guides.stroke()
    }

    private func sizeText(_ r: CGRect) -> String {
        let s = shot.scale
        return "\(Int((r.width * s).rounded())) × \(Int((r.height * s).rounded()))"
    }

    private func pill(_ text: String, font: NSFont) -> (NSAttributedString, CGSize) {
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = attributed.size()
        return (attributed, CGSize(width: size.width + 16, height: size.height + 8))
    }

    private func drawPill(_ attributed: NSAttributedString, size: CGSize, at origin: CGPoint) {
        let box = CGRect(origin: origin, size: size)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        attributed.draw(at: CGPoint(x: box.minX + 8, y: box.minY + 4))
    }

    private func drawLabel(_ text: String, near r: CGRect) {
        let (attributed, size) = pill(text, font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold))
        var origin = CGPoint(x: r.minX, y: r.maxY + 8)
        if origin.y + size.height > bounds.maxY - 4 { origin.y = r.minY - size.height - 8 }
        if origin.y < 4 { origin.y = r.minY + 8 }
        origin.x = min(max(origin.x, 4), bounds.maxX - size.width - 4)
        drawPill(attributed, size: size, at: origin)
    }

    private func drawHint() {
        let first: String
        if let hint {
            first = hint
        } else {
            first = mode == .area ? "Drag to capture an area" : "Click a window to capture it"
        }
        var second = mode == .area ? "Space: pick a window" : "Space: drag an area"
        if case .fixedSize(let size) = constraint {
            second = "Click to take \(Int(size.width)) × \(Int(size.height))"
        }
        let (attributed, size) = pill("\(first)   ·   \(second)   ·   Esc: cancel", font: .systemFont(ofSize: 13, weight: .medium))
        drawPill(attributed, size: size, at: CGPoint(x: (bounds.width - size.width) / 2, y: 36))
    }

    private func drawMagnifier(at p: CGPoint) {
        let image = shot.image
        let scale = shot.scale
        let count = 15
        let half = count / 2
        let cx = min(max(Int(p.x * scale), half), max(half, image.width - half - 1))
        let cy = min(max(Int(p.y * scale), half), max(half, image.height - half - 1))
        guard let crop = image.cropping(to: CGRect(x: cx - half, y: cy - half, width: count, height: count)) else { return }
        let side: CGFloat = 120
        var origin = CGPoint(x: p.x + 26, y: p.y + 26)
        if origin.x + side > bounds.maxX - 8 { origin.x = p.x - 26 - side }
        if origin.y + side + 30 > bounds.maxY - 8 { origin.y = p.y - 26 - side - 30 }
        let box = CGRect(origin: origin, size: CGSize(width: side, height: side))

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).addClip()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: crop, size: NSSize(width: count, height: count))
            .draw(in: box, from: .zero, operation: .copy, fraction: 1, respectFlipped: true,
                  hints: [NSImageRep.HintKey.interpolation: NSNumber(value: NSImageInterpolation.none.rawValue)])
        let cell = side / CGFloat(count)
        let grid = NSBezierPath()
        for i in 1..<count {
            let offset = CGFloat(i) * cell
            grid.move(to: CGPoint(x: box.minX + offset, y: box.minY))
            grid.line(to: CGPoint(x: box.minX + offset, y: box.maxY))
            grid.move(to: CGPoint(x: box.minX, y: box.minY + offset))
            grid.line(to: CGPoint(x: box.maxX, y: box.minY + offset))
        }
        grid.lineWidth = 0.5
        NSColor.black.withAlphaComponent(0.12).setStroke()
        grid.stroke()
        let centre = CGRect(x: box.minX + CGFloat(half) * cell, y: box.minY + CGFloat(half) * cell, width: cell, height: cell)
        let marker = NSBezierPath(rect: centre)
        marker.lineWidth = 1.5
        NSColor.white.setStroke()
        marker.stroke()
        NSGraphicsContext.restoreGraphicsState()

        let ring = NSBezierPath(roundedRect: box.insetBy(dx: -1, dy: -1), xRadius: 13, yRadius: 13)
        ring.lineWidth = 2
        NSColor.white.setStroke()
        ring.stroke()

        let point = global(p)
        let colour = Self.hex(of: image, x: Int(p.x * scale), y: Int(p.y * scale))
        let text = "\(Int(point.x - shot.frame.minX)), \(Int(p.y))   \(colour)"
        let (attributed, size) = pill(text, font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium))
        drawPill(attributed, size: CGSize(width: max(size.width, side), height: size.height),
                 at: CGPoint(x: box.minX, y: box.maxY + 6))
    }

    /// "#RRGGBB" of one pixel of a picture.
    static func hex(of image: CGImage, x: Int, y: Int) -> String {
        let px = min(max(x, 0), image.width - 1), py = min(max(y, 0), image.height - 1)
        guard let pixel = image.cropping(to: CGRect(x: px, y: py, width: 1, height: 1)),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return "" }
        var bytes = [UInt8](repeating: 0, count: 4)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return ok ? String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2]) : ""
    }
}

/// The selection overlay as a SwiftUI view, for the window pictures.
struct SelectionShowcase: NSViewRepresentable {
    let shot: DisplayShot
    let selection: CGRect

    func makeNSView(context: Context) -> SelectionView {
        let view = SelectionView(frame: NSRect(origin: .zero, size: shot.frame.size), shot: shot, mode: .area,
                                 windows: [], hint: nil)
        view.showcase(selection: selection)
        return view
    }

    func updateNSView(_ view: SelectionView, context: Context) {}
}

// MARK: - Frame around an area

/// A thin frame drawn just outside an area being recorded or scrolled, which clicks pass through.
@MainActor
final class AreaFrame {
    let panel: KeyPanel

    init(around rect: CGRect, dashed: Bool = false) {
        let frame = rect.insetBy(dx: -3, dy: -3)
        panel = KeyPanel.floating(frame, level: .statusBar, clickThrough: true)
        panel.contentView = NSHostingView(rootView: AreaFrameView(dashed: dashed))
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }
}

struct AreaFrameView: View {
    let dashed: Bool

    var body: some View {
        Rectangle()
            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: dashed ? [6, 4] : []))
    }
}

// MARK: - Countdown

/// Big numbers counting down before a timed capture or a recording starts.
@MainActor
enum Countdown {
    static func run(seconds: Int, centredOn rect: CGRect?) async {
        guard seconds > 0 else { return }
        let target = rect ?? ScreenGrabber.screenUnderMouse?.frame ?? .zero
        let side: CGFloat = 132
        let frame = NSRect(x: target.midX - side / 2, y: target.midY - side / 2, width: side, height: side)
        let panel = KeyPanel.floating(frame, level: .screenSaver, clickThrough: true)
        for number in stride(from: seconds, to: 0, by: -1) {
            panel.contentView = NSHostingView(rootView: CountdownView(number: number))
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        panel.orderOut(nil)
        panel.close()
        // Give the window server a moment to take it off the screen before capturing.
        try? await Task.sleep(nanoseconds: 180_000_000)
    }
}

struct CountdownView: View {
    let number: Int

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.black.opacity(0.72))
            RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Theme.accent, lineWidth: 2)
            Text("\(number)")
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
        .padding(6)
    }
}

// MARK: - Hiding desktop icons

/// Covers the desktop icons with the desktop picture while a capture is taken; Finder is left alone.
@MainActor
enum DesktopIconHider {
    private static var windows: [NSWindow] = []

    static func show() {
        hide()
        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        for screen in NSScreen.screens {
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen), let image = NSImage(contentsOf: url) else { continue }
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = level
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.hasShadow = false
            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            view.layer?.contents = image
            view.layer?.contentsGravity = .resizeAspectFill
            view.layer?.backgroundColor = NSColor.black.cgColor
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.orderFront(nil)
            windows.append(window)
        }
    }

    static func hide() {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
    }
}
