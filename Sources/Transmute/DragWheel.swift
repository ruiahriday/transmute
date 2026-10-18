import AppKit
import SwiftUI

/// The drag wheel: while you drag files anywhere (Finder, Desktop, another app) and hold
///   ⇧ Shift      → a ring of output formats,
///   ⌘ or ⌥       → tools (compress, clean metadata, zip…),
///   ⌃ Control    → file actions (AirDrop, copy, copy path, Terminal, move).
/// Drop the files on a bubble to run it. The converted copy lands next to the original.
///
/// It polls the system drag pasteboard instead of using event taps, so it needs no
/// Accessibility permission.
@MainActor
final class DragWheelController {
    private var timer: Timer?
    private var panel: NSPanel?
    private var baseline = NSPasteboard(name: .drag).changeCount
    private var mouseWasDown = false
    private var shownThisDrag = false
    private var currentWheel: WheelKind?
    private var currentURLs: [URL] = []

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tick() }
        }
    }

    private func tick() {
        let pasteboard = NSPasteboard(name: .drag)
        let mouseDown = (NSEvent.pressedMouseButtons & 1) != 0
        guard mouseDown else {
            if mouseWasDown {
                mouseWasDown = false
                // Let the drop land before hiding.
                if panel?.isVisible == true { hide(after: 0.3) }
            }
            baseline = pasteboard.changeCount
            shownThisDrag = false
            return
        }
        mouseWasDown = true

        // A drag is in progress when the drag pasteboard changed since the button went down.
        guard pasteboard.changeCount != baseline,
              UserDefaults.standard.bool(forKey: Prefs.wheelEnabled) else { return }

        let flags = NSEvent.modifierFlags
        let wanted: WheelKind? =
            flags.contains(.control) ? .actions
            : (flags.contains(.command) || flags.contains(.option)) ? .tools
            : flags.contains(.shift) ? .convert
            : nil
        // Once open, the wheel stays until the drop; pressing another key switches wheels.
        guard let wanted, wanted != currentWheel || !shownThisDrag else { return }

        if !shownThisDrag {
            guard let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                                    options: [.urlReadingFileURLsOnly: true]) as? [URL],
                  !urls.isEmpty else { return }
            currentURLs = urls
        }
        let items = Self.items(for: wanted, urls: currentURLs)
        guard !items.isEmpty else { return }
        show(items, kind: wanted, at: shownThisDrag ? nil : NSEvent.mouseLocation)
        shownThisDrag = true
    }

    // MARK: Items

    static func items(for kind: WheelKind, urls: [URL]) -> [WheelItem] {
        let kinds = urls.map(FileKind.of)
        switch kind {
        case .convert:
            guard let first = kinds.first else { return [] }
            let common = first.convertTargets.filter { format in kinds.allSatisfy { $0.convertTargets.contains(format) } }
            return common.prefix(10).map { WheelItem(label: $0.label, symbol: $0.symbol, action: .job(.convert($0))) }
        case .tools:
            var items: [WheelItem] = []
            if kinds.allSatisfy(\.canCompress) {
                items.append(WheelItem(label: "Half size", symbol: "arrow.down.right.and.arrow.up.left",
                                       action: .job(.compress(.percent(0.5)))))
                items.append(WheelItem(label: "Quarter", symbol: "arrow.down.right.and.arrow.up.left",
                                       action: .job(.compress(.percent(0.25)))))
            }
            if kinds.allSatisfy(\.canStripMetadata) {
                items.append(WheelItem(label: "Clean", symbol: "eye.slash", action: .job(.stripMetadata)))
            }
            if kinds.allSatisfy({ $0 == .pdf }) {
                items.append(WheelItem(label: "Split", symbol: "rectangle.split.3x1", action: .job(.splitPDF)))
                if kinds.count > 1 { items.append(WheelItem(label: "Merge", symbol: "doc.on.doc", action: .batch(.mergePDFs))) }
            }
            if kinds.allSatisfy({ $0 == .image }) {
                items.append(WheelItem(label: "To PDF", symbol: "doc.richtext", action: .batch(.imagesToPDF)))
                items.append(WheelItem(label: "QR", symbol: "qrcode.viewfinder", action: .job(.readQR)))
            }
            items.append(WheelItem(label: "Zip", symbol: "archivebox", action: .batch(.archive(.zip))))
            return items
        case .actions:
            return FileAction.allCases.map { WheelItem(label: $0.label, symbol: $0.symbol, action: .file($0)) }
        }
    }

    // MARK: Panel

    private func show(_ items: [WheelItem], kind: WheelKind, at point: NSPoint?) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        currentWheel = kind
        if let point {
            let size = WheelView.size
            panel.setFrame(NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size), display: false)
        }
        let urls = currentURLs
        panel.contentView = NSHostingView(rootView: WheelView(kind: kind, items: items) { [weak self] item in
            self?.run(item, on: urls)
        })
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }

    private func hide(after delay: Double) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !self.mouseWasDown else { return }
            self.panel?.orderOut(nil)
            self.currentWheel = nil
        }
    }

    // MARK: Running

    private func run(_ item: WheelItem, on urls: [URL]) {
        panel?.orderOut(nil)
        currentWheel = nil
        let queue = JobQueue.shared
        let options = ConversionOptions.fromDefaults()
        let reveal = UserDefaults.standard.bool(forKey: Prefs.revealWhenDone)
        switch item.action {
        case .job(let operation):
            let ids = queue.add(urls)
            HUDController.shared.show(ids: ids)
            queue.start(ids.map { ($0, operation) }, options: options, reveal: reveal && operation != .readQR) {
                HUDController.shared.finish()
            }
        case .batch(let tool):
            let ids = queue.add(urls)
            HUDController.shared.show(ids: ids)
            queue.runBatch(tool, ids: ids, options: options, reveal: reveal)
            HUDController.shared.finishWhenDone(ids: ids)
        case .file(let action):
            action.perform(on: urls)
        }
    }
}

enum WheelKind {
    case convert, tools, actions

    var title: String {
        switch self {
        case .convert: "Convert to"
        case .tools: "Tools"
        case .actions: "Actions"
        }
    }
}

struct WheelItem: Identifiable {
    enum Action {
        case job(JobOperation)
        case batch(BatchTool)
        case file(FileAction)
    }

    let id = UUID()
    let label: String
    let symbol: String
    let action: Action
}

enum FileAction: CaseIterable {
    case airDrop, copy, copyPath, terminal, move

    var label: String {
        switch self {
        case .airDrop: "AirDrop"
        case .copy: "Copy"
        case .copyPath: "Copy Path"
        case .terminal: "Terminal"
        case .move: "Move…"
        }
    }

    var symbol: String {
        switch self {
        case .airDrop: "airplayaudio"
        case .copy: "doc.on.clipboard"
        case .copyPath: "link"
        case .terminal: "terminal"
        case .move: "folder"
        }
    }

    @MainActor
    func perform(on urls: [URL]) {
        switch self {
        case .airDrop:
            NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        case .terminal:
            let folder = urls[0].hasDirectoryPath ? urls[0] : urls[0].deletingLastPathComponent()
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        case .move:
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = "Move Here"
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            for url in urls {
                let target = OutputPaths.unique(in: destination, base: OutputPaths.baseName(of: url), ext: url.pathExtension)
                try? FileManager.default.moveItem(at: url, to: target)
            }
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }
}

struct WheelView: View {
    static let size: CGFloat = 360

    let kind: WheelKind
    let items: [WheelItem]
    let onDrop: (WheelItem) -> Void

    @State private var targeted: UUID?

    private let radius: CGFloat = 128
    private let bubble: CGFloat = 66

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
                .frame(width: (radius + bubble / 2 + 10) * 2, height: (radius + bubble / 2 + 10) * 2)
            VStack(spacing: 2) {
                Text(kind.title).font(.headline)
                Text("Drop on a bubble").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let angle = Double(index) / Double(items.count) * 2 * .pi - .pi / 2
                bubbleView(item)
                    .offset(x: cos(angle) * radius, y: sin(angle) * radius)
            }
        }
        .frame(width: Self.size, height: Self.size)
    }

    private func bubbleView(_ item: WheelItem) -> some View {
        let isTargeted = targeted == item.id
        return VStack(spacing: 3) {
            Image(systemName: item.symbol).font(.system(size: 16, weight: .semibold))
            Text(item.label).font(.system(size: 10, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundStyle(isTargeted ? Color.white : Color.primary)
        .frame(width: bubble, height: bubble)
        .background(Circle().fill(isTargeted ? Color.accentColor : Color(nsColor: .windowBackgroundColor)))
        .shadow(radius: isTargeted ? 6 : 2)
        .scaleEffect(isTargeted ? 1.15 : 1)
        .animation(.spring(response: 0.25), value: isTargeted)
        .onDrop(of: [.fileURL], isTargeted: Binding(
            get: { targeted == item.id },
            set: { inside in
                if inside { targeted = item.id } else if targeted == item.id { targeted = nil }
            }
        )) { _ in
            onDrop(item)
            return true
        }
    }
}
