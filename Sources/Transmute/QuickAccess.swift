import AppKit
import SwiftUI

/// What a capture or recording produced.
struct CaptureResult: Identifiable {
    let id = UUID()
    let url: URL
    let kind: HistoryItem.Kind
    /// Saved to the capture folder (not only kept in the history).
    var savedToFolder: Bool
    let pixelSize: CGSize
    var duration: Double? = nil

    var isVideo: Bool { kind == .recording }

    var detail: String {
        if let duration { return HistoryCard.time(duration) }
        return "\(Int(pixelSize.width))×\(Int(pixelSize.height))"
    }
}

/// The buttons on a quick access card.
struct QuickActions {
    var copy: () -> Void = {}
    var save: () -> Void = {}
    var annotate: () -> Void = {}
    var pin: () -> Void = {}
    var frame: () -> Void = {}
    var gif: () -> Void = {}
    var text: () -> Void = {}
    var studio: () -> Void = {}
    var share: (NSView?) -> Void = { _ in }
    var close: () -> Void = {}
    var hover: (Bool) -> Void = { _ in }
}

/// Small floating cards in a corner of the screen after each capture: drag one into another app,
/// or copy, save, annotate, pin, frame, read or share it. They tidy themselves away after a while,
/// stay on the display the capture came from, can be swiped away, hidden for a while, and the last
/// one closed can be brought back.
@MainActor
final class QuickAccess: ObservableObject {
    static let shared = QuickAccess()
    static let cardSize = CGSize(width: 300, height: 214)

    private final class Card {
        let result: CaptureResult
        let panel: KeyPanel
        let screenID: CGDirectDisplayID?
        var hideTask: Task<Void, Never>?

        init(result: CaptureResult, panel: KeyPanel, screenID: CGDirectDisplayID?) {
            self.result = result
            self.panel = panel
            self.screenID = screenID
        }
    }

    private var cards: [Card] = []
    /// The most recently closed card, for Restore.
    @Published private(set) var lastClosed: CaptureResult?
    /// All cards are tucked away until shown again.
    @Published private(set) var hidden = false

    var count: Int { cards.count }

    func show(_ result: CaptureResult) {
        if hidden { setHidden(false) }
        let size = Self.scaledSize
        let panel = KeyPanel.floating(NSRect(origin: .zero, size: size), level: .statusBar)
        let screen = ScreenGrabber.screenUnderMouse ?? NSScreen.main
        let card = Card(result: result, panel: panel, screenID: screen.map { ScreenGrabber.displayID(of: $0) })
        // Laid out at the normal size, then scaled, so every button stays inside the panel at any card size.
        let host = SwipeHostingView(rootView: QuickAccessCard(result: result, actions: actions(for: result))
            .frame(width: Self.cardSize.width, height: Self.cardSize.height)
            .scaleEffect(CaptureSettings.overlayScale, anchor: .topLeading)
            .frame(width: size.width, height: size.height, alignment: .topLeading))
        let id = result.id
        host.onSwipe = { [weak self] direction in self?.swipeAway(id, direction: direction) }
        panel.contentView = host
        panel.onEscape = { [weak self] in self?.dismiss(result.id) }
        cards.insert(card, at: 0)
        while cards.count > 5 {
            let old = cards.removeLast()
            old.hideTask?.cancel()
            old.panel.orderOut(nil)
            old.panel.close()
        }
        layout()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
        scheduleHide(card)
    }

    static var scaledSize: CGSize {
        let scale = CaptureSettings.overlayScale
        return CGSize(width: (cardSize.width * scale).rounded(), height: (cardSize.height * scale).rounded())
    }

    func dismiss(_ id: UUID) {
        guard let index = cards.firstIndex(where: { $0.result.id == id }) else { return }
        let card = cards.remove(at: index)
        lastClosed = card.result
        card.hideTask?.cancel()
        let panel = card.panel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
                panel.close()
            }
        })
        layout()
    }

    /// A swipe slides the card off the way it went.
    private func swipeAway(_ id: UUID, direction: CGFloat) {
        guard let card = cards.first(where: { $0.result.id == id }) else { return }
        var frame = card.panel.frame
        frame.origin.x += direction > 0 ? frame.width : -frame.width
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            card.panel.animator().setFrame(frame, display: true)
        }
        dismiss(id)
    }

    /// Brings back the card closed last, if its file is still there.
    func restoreLast() {
        guard let result = lastClosed, FileManager.default.fileExists(atPath: result.url.path) else {
            Toast.show("Nothing to restore", detail: "Closed capture cards can be brought back here.", symbol: "exclamationmark.triangle.fill")
            return
        }
        lastClosed = nil
        show(CaptureResult(url: result.url, kind: result.kind, savedToFolder: result.savedToFolder,
                           pixelSize: result.pixelSize, duration: result.duration))
    }

    /// Tucks every card away (or brings them back) without closing them.
    func setHidden(_ hide: Bool) {
        hidden = hide
        for card in cards {
            if hide {
                card.hideTask?.cancel()
                card.panel.orderOut(nil)
            } else {
                card.panel.orderFrontRegardless()
                scheduleHide(card)
            }
        }
    }

    /// Cards stack in the chosen corner of the display each capture came from.
    private func layout() {
        let size = Self.scaledSize
        var stacks: [CGDirectDisplayID: Int] = [:]
        for card in cards {
            let screen = NSScreen.screens.first { ScreenGrabber.displayID(of: $0) == card.screenID }
                ?? ScreenGrabber.screenUnderMouse ?? NSScreen.main
            guard let screen else { continue }
            let id = ScreenGrabber.displayID(of: screen)
            let index = stacks[id, default: 0]
            stacks[id] = index + 1
            card.panel.setFrame(Self.frame(index: index, size: size, in: screen.visibleFrame,
                                           right: CaptureSettings.overlayOnRight, top: CaptureSettings.overlayOnTop),
                                display: true)
        }
    }

    /// Where the card at `index` in a stack goes.
    static func frame(index: Int, size: CGSize, in visible: CGRect, right: Bool, top: Bool) -> CGRect {
        let x = right ? visible.maxX - size.width - 10 : visible.minX + 10
        let step = CGFloat(index) * (size.height - 4)
        let y = top ? visible.maxY - size.height - 10 - step : visible.minY + 10 + step
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func scheduleHide(_ card: Card) {
        card.hideTask?.cancel()
        let seconds = CaptureSettings.overlaySeconds
        guard seconds > 0 else { return }
        let id = card.result.id
        card.hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dismiss(id)
        }
    }

    private func hover(_ id: UUID, _ inside: Bool) {
        guard let card = cards.first(where: { $0.result.id == id }) else { return }
        if inside { card.hideTask?.cancel() } else { scheduleHide(card) }
    }

    func actions(for result: CaptureResult) -> QuickActions {
        let id = result.id
        let url = result.url
        let coordinator = CaptureCoordinator.shared
        return QuickActions(
            copy: { [weak self] in
                coordinator.copy(url)
                self?.dismiss(id)
            },
            save: { [weak self] in
                if let saved = CaptureFiles.saveAs(url) {
                    Toast.show("Saved \(saved.lastPathComponent)", detail: saved.deletingLastPathComponent().path)
                    self?.dismiss(id)
                }
            },
            annotate: { [weak self] in
                self?.dismiss(id)
                coordinator.edit(url)
            },
            pin: { [weak self] in
                self?.dismiss(id)
                PinController.open(url: url)
            },
            frame: { [weak self] in
                self?.dismiss(id)
                FrameToolWindow.open(url)
            },
            gif: { [weak self] in
                self?.dismiss(id)
                coordinator.makeGIF(from: url)
            },
            text: {
                coordinator.recognizeText(inFile: url)
            },
            studio: { [weak self] in
                self?.dismiss(id)
                StudioWindow.open(url)
            },
            share: { view in
                let picker = NSSharingServicePicker(items: [url])
                if let view { picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY) }
            },
            close: { [weak self] in self?.dismiss(id) },
            hover: { [weak self] inside in self?.hover(id, inside) })
    }
}

/// Size on disk, for the card's info line.
enum FileInfo {
    static func size(of url: URL) -> String? {
        guard let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// An invisible view that hands its NSView to a closure, so the share menu knows where to appear.
struct ShareAnchor: NSViewRepresentable {
    let onMake: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onMake(view) }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

struct QuickAccessCard: View {
    let result: CaptureResult
    let actions: QuickActions
    var forceHover = false
    @State private var hovering = false
    @State private var shareView: NSView?

    var body: some View {
        VStack(spacing: 0) {
            ThumbnailView(url: result.url)
                .frame(height: 138)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 4) {
                        Image(systemName: result.kind.symbol)
                        Text(infoText).monospacedDigit()
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .padding(7)
                }
                .overlay(alignment: .topTrailing) {
                    if hovering || forceHover {
                        Button(action: actions.close) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(Theme.textPrimary)
                                .frame(width: 22, height: 22)
                                .background(Theme.surface, in: Circle())
                                .overlay(Circle().strokeBorder(Theme.hairline))
                        }
                        .buttonStyle(.plain)
                        .padding(7)
                        .help("Close")
                    }
                }
                .onDrag { NSItemProvider(contentsOf: result.url) ?? NSItemProvider() }
                .help("Drag into any app")
            Divider()
            HStack(spacing: 2) {
                tool("doc.on.doc", "Copy", action: actions.copy)
                tool("square.and.arrow.down", "Save", action: actions.save)
                if result.isVideo {
                    tool("scissors", "Trim", action: actions.annotate)
                    tool("wand.and.stars", "Studio", action: actions.studio)
                    tool("photo.stack", "GIF", action: actions.gif)
                } else {
                    tool("pencil.tip.crop.circle", "Markup", action: actions.annotate)
                    tool("pin", "Pin", action: actions.pin)
                    tool("photo.artframe", "Frame", action: actions.frame)
                    tool("text.viewfinder", "Text", action: actions.text)
                }
                tool("square.and.arrow.up", "Share") { actions.share(shareView) }
                    .background(ShareAnchor { shareView = $0 })
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card + 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card + 2, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(hovering ? 0.22 : 0.16), radius: hovering ? 10 : 7, y: 3)
        .padding(6)
        .appearIn()
        .onHover { inside in
            hovering = inside
            actions.hover(inside)
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    /// "1280×720 · 245 KB"
    private var infoText: String {
        guard let size = FileInfo.size(of: result.url) else { return result.detail }
        return "\(result.detail) · \(size)"
    }

    private func tool(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                Text(title).font(.system(size: 9.5, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuickToolStyle())
        .help(title)
    }
}

private struct QuickToolStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ToolBody(configuration: configuration)
    }

    private struct ToolBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed ? Theme.hairline : (hovering ? Theme.surfaceHover : Color.clear)))
                .onHover { hovering = $0 }
        }
    }
}
