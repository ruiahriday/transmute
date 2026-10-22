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
    var close: () -> Void = {}
    var hover: (Bool) -> Void = { _ in }
}

/// Small floating cards in a corner of the screen after each capture: drag one into another app,
/// or copy, save, annotate or pin it. They tidy themselves away after a while.
@MainActor
final class QuickAccess {
    static let shared = QuickAccess()
    static let cardSize = CGSize(width: 264, height: 206)

    private final class Card {
        let result: CaptureResult
        let panel: KeyPanel
        var hideTask: Task<Void, Never>?

        init(result: CaptureResult, panel: KeyPanel) {
            self.result = result
            self.panel = panel
        }
    }

    private var cards: [Card] = []

    func show(_ result: CaptureResult) {
        let panel = KeyPanel.floating(NSRect(origin: .zero, size: Self.cardSize), level: .statusBar)
        let card = Card(result: result, panel: panel)
        panel.contentView = FirstClickHostingView(rootView: QuickAccessCard(result: result, actions: actions(for: result)))
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

    func dismiss(_ id: UUID) {
        guard let index = cards.firstIndex(where: { $0.result.id == id }) else { return }
        let card = cards.remove(at: index)
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

    private func layout() {
        guard let screen = ScreenGrabber.screenUnderMouse ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = Self.cardSize
        let x = CaptureSettings.overlayOnRight ? visible.maxX - size.width - 10 : visible.minX + 10
        for (index, card) in cards.enumerated() {
            let y = visible.minY + 10 + CGFloat(index) * (size.height - 4)
            card.panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        }
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

    private func actions(for result: CaptureResult) -> QuickActions {
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
            close: { [weak self] in self?.dismiss(id) },
            hover: { [weak self] inside in self?.hover(id, inside) })
    }
}

struct QuickAccessCard: View {
    let result: CaptureResult
    let actions: QuickActions
    var forceHover = false
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            ThumbnailView(url: result.url)
                .frame(height: 138)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 4) {
                        Image(systemName: result.kind.symbol)
                        Text(result.detail).monospacedDigit()
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
                    tool("photo.stack", "GIF", action: actions.gif)
                } else {
                    tool("pencil.tip.crop.circle", "Annotate", action: actions.annotate)
                    tool("pin", "Pin", action: actions.pin)
                    tool("photo.artframe", "Frame", action: actions.frame)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(hovering ? Theme.accent.opacity(0.7) : Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        .padding(6)
        .onHover { inside in
            hovering = inside
            actions.hover(inside)
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
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
