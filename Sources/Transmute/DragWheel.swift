import AppKit
import SwiftUI

/// The drag wheel: while you drag files anywhere (Finder, Desktop, another app) and hold
///   ⇧ Shift      → a ring of output formats,
///   ⌘ Command    → tools (compress, clean metadata, zip…),
///   ⌃ Control    → file actions (AirDrop, float, copy, copy path, Terminal, move).
/// The keys, and what each wheel shows and where (WheelLayout), can be changed in Settings.
/// Drop the files on a bubble to run it.
/// The converted copy lands next to the original.
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

        // Actions and tools win over convert when several keys are held.
        let flags = NSEvent.modifierFlags
        let wanted = [WheelKind.actions, .tools, .convert].first { kind in
            guard let flag = kind.key.flag else { return false }
            return flags.contains(flag)
        }
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

    /// The wheel's positions clockwise from the top, as set in Settings; nil is an empty position.
    static func items(for kind: WheelKind, urls: [URL]) -> [WheelItem?] {
        WheelLayout.resolve(kind, urls.map(FileKind.of), custom: WheelLayout.saved).map(WheelItem.init(id:))
    }

    // MARK: Panel

    private func show(_ items: [WheelItem?], kind: WheelKind, at point: NSPoint?) {
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
        case .edit:
            if let url = urls.first(where: { EditRequest.editMode(for: FileKind.of($0)) != nil }) {
                EditorWindow.open(url)
            }
        }
    }
}

/// An editor in a window of its own, for the drag wheel's Edit bubble: no need to open
/// Spinform and add the file first. The result is saved as a copy, as from the main window.
@MainActor
enum EditorWindow {
    private static var windows: [NSWindow] = []

    static func open(_ url: URL, startOnMarkup: Bool = false, initialEdit: ImageEdit? = nil, projectURL: URL? = nil,
                     saveFolder: URL? = nil) {
        let queue = JobQueue.shared
        guard let id = queue.add([url]).first, let job = queue.job(id),
              let mode = EditRequest.editMode(for: job.kind) else { return }
        var request = EditRequest(job: job, mode: mode)
        request.startOnMarkup = startOnMarkup
        request.initialEdit = initialEdit
        request.projectURL = projectURL
        request.saveFolder = saveFolder
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = projectURL.map { "Edit \($0.lastPathComponent)" } ?? "Edit \(url.lastPathComponent)"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorHost(request: request) { [weak window] in
            window?.close()
        })
        window.center()
        windows.append(window)
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                windows.removeAll { $0 === window }
                if let token { NotificationCenter.default.removeObserver(token) }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

enum WheelKind: CaseIterable, Identifiable {
    case convert, tools, actions

    var id: String {
        switch self {
        case .convert: "convert"
        case .tools: "tools"
        case .actions: "actions"
        }
    }

    var title: String {
        switch self {
        case .convert: "Convert to"
        case .tools: "Tools"
        case .actions: "Actions"
        }
    }

    /// Short phrase for menus: "Hold ⇧ Shift while dragging for formats".
    var hint: String {
        switch self {
        case .convert: "formats"
        case .tools: "tools"
        case .actions: "actions"
        }
    }

    var prefKey: String {
        switch self {
        case .convert: "wheelKeyConvert"
        case .tools: "wheelKeyTools"
        case .actions: "wheelKeyActions"
        }
    }

    var defaultKey: WheelKey {
        switch self {
        case .convert: .shift
        case .tools: .command
        case .actions: .control
        }
    }

    /// The modifier that opens this wheel, from Settings.
    var key: WheelKey {
        UserDefaults.standard.string(forKey: prefKey).flatMap(WheelKey.init(rawValue:)) ?? defaultKey
    }
}

enum WheelKey: String, CaseIterable, Identifiable {
    case shift, command, option, control, off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .shift: "⇧ Shift"
        case .command: "⌘ Command"
        case .option: "⌥ Option"
        case .control: "⌃ Control"
        case .off: "Off"
        }
    }

    var flag: NSEvent.ModifierFlags? {
        switch self {
        case .shift: .shift
        case .command: .command
        case .option: .option
        case .control: .control
        case .off: nil
        }
    }
}

struct WheelItem: Identifiable {
    enum Action {
        case job(JobOperation)
        case batch(BatchTool)
        case file(FileAction)
        /// Opens the photo, video or audio editor on the file.
        case edit
    }

    let id = UUID()
    let label: String
    let symbol: String
    let action: Action

    init(label: String, symbol: String, action: Action) {
        self.label = label
        self.symbol = symbol
        self.action = action
    }

    /// The bubble for a WheelLayout id; nil for an empty position or an unknown id.
    init?(id: String) {
        if let format = WheelLayout.format(of: id) {
            self.init(label: format.label, symbol: format.symbol, action: .job(.convert(format)))
            return
        }
        let squeeze = "arrow.down.right.and.arrow.up.left"
        switch id {
        case "tool:half": self.init(label: "Half size", symbol: squeeze, action: .job(.compress(.percent(0.5))))
        case "tool:quarter": self.init(label: "Quarter", symbol: squeeze, action: .job(.compress(.percent(0.25))))
        case "tool:clean": self.init(label: "Clean", symbol: "eye.slash", action: .job(.stripMetadata))
        case "tool:split": self.init(label: "Split", symbol: "rectangle.split.3x1", action: .job(.splitPDF))
        case "tool:merge": self.init(label: "Merge", symbol: "doc.on.doc", action: .batch(.mergePDFs))
        case "tool:topdf": self.init(label: "To PDF", symbol: "doc.richtext", action: .batch(.imagesToPDF))
        case "tool:qr": self.init(label: "QR", symbol: "qrcode.viewfinder", action: .job(.readQR))
        case "tool:zip": self.init(label: "Zip", symbol: "archivebox", action: .batch(.archive(.zip)))
        case "tool:edit": self.init(label: "Edit", symbol: "wand.and.stars", action: .edit)
        case "tool:nobg": self.init(label: "Remove BG", symbol: "scissors", action: .job(.editImage(.removingBackground)))
        default:
            guard id.hasPrefix("action:"),
                  let action = FileAction.allCases.first(where: { "action:" + $0.id == id }) else { return nil }
            self.init(label: action.label, symbol: action.symbol, action: .file(action))
        }
    }

    /// A longer name for the list in Settings: "Convert to PDF", "Compress to half size"…
    static func describe(_ id: String) -> String {
        if id == WheelLayout.gap { return "Empty space" }
        if let format = WheelLayout.format(of: id) { return format == .extract ? "Extract" : "Convert to \(format.label)" }
        switch id {
        case "tool:half": return "Compress to half size"
        case "tool:quarter": return "Compress to a quarter"
        case "tool:clean": return "Remove metadata"
        case "tool:split": return "Split into pages"
        case "tool:merge": return "Merge PDFs (2 or more)"
        case "tool:topdf": return "Images to one PDF"
        case "tool:qr": return "Read QR code"
        case "tool:zip": return "Zip"
        case "tool:edit": return "Edit (opens the photo, video or audio editor)"
        case "tool:nobg": return "Remove background (transparent PNG)"
        case "action:airdrop": return "AirDrop"
        case "action:float": return "Float (floating files)"
        case "action:copy": return "Copy"
        case "action:copypath": return "Copy path"
        case "action:terminal": return "Open Terminal here"
        case "action:move": return "Move to a folder"
        default: return id
        }
    }
}

enum FileAction: CaseIterable {
    case airDrop, float, copy, copyPath, terminal, move

    /// Its name in WheelLayout ids ("action:copypath").
    var id: String {
        switch self {
        case .airDrop: "airdrop"
        case .float: "float"
        case .copy: "copy"
        case .copyPath: "copypath"
        case .terminal: "terminal"
        case .move: "move"
        }
    }

    var label: String {
        switch self {
        case .airDrop: "AirDrop"
        case .float: "Float"
        case .copy: "Copy"
        case .copyPath: "Copy Path"
        case .terminal: "Terminal"
        case .move: "Move…"
        }
    }

    var symbol: String {
        switch self {
        case .airDrop: "airplayaudio"
        case .float: "pin"
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
        case .float:
            FloatingShelf.shared.add(urls)
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
    /// Positions clockwise from the top; nil leaves a position empty.
    let items: [WheelItem?]
    let onDrop: (WheelItem) -> Void

    @State private var targeted: UUID?
    @State private var appeared = false

    private let radius: CGFloat = 128

    // Split into small pieces: one big expression mixing CGFloat and Double maths is too
    // slow for the type checker.
    var body: some View {
        ZStack {
            ring
            caption
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if let item {
                    bubbleView(item)
                        .offset(appeared ? WheelGeometry.position(of: index, count: items.count, radius: radius) : .zero)
                        .scaleEffect(appeared ? 1 : 0.3)
                        .opacity(appeared ? 1 : 0)
                        .animation(.spring(response: 0.38, dampingFraction: 0.72).delay(Double(index) * 0.025), value: appeared)
                }
            }
        }
        .frame(width: Self.size, height: Self.size)
        .onAppear { appeared = true }
    }

    private var bubble: CGFloat { WheelGeometry.bubbleSize(count: items.count, radius: radius, largest: 66) }

    private var ring: some View {
        let diameter: CGFloat = (radius + 33 + 10) * 2
        return Circle()
            .fill(Theme.canvas.opacity(0.97))
            .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1).padding(radius * 0.62))
            .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            .frame(width: diameter, height: diameter)
            .scaleEffect(appeared ? 1 : 0.6)
            .opacity(appeared ? 1 : 0)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: appeared)
    }

    private var caption: some View {
        VStack(spacing: 2) {
            Text(kind.title).font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary)
            Text("Drop on a bubble").font(Theme.Fonts.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    private func bubbleView(_ item: WheelItem) -> some View {
        let isTargeted = targeted == item.id
        return VStack(spacing: 3) {
            Image(systemName: item.symbol).font(.system(size: 16, weight: .medium))
            Text(item.label).font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundStyle(isTargeted ? Color.white : Theme.textPrimary)
        .frame(width: bubble, height: bubble)
        .background(
            Circle().fill(isTargeted ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.surface))
        )
        .overlay(Circle().strokeBorder(isTargeted ? Color.black.opacity(0.1) : Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(isTargeted ? 0.22 : 0.08), radius: isTargeted ? 4 : 1.5, y: 1)
        .scaleEffect(isTargeted ? 1.12 : 1)
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

/// Where the bubbles go, shared by the wheel and its editor in Settings.
enum WheelGeometry {
    /// Position `index` of `count`, from the centre: the first at the top, then clockwise.
    static func position(of index: Int, count: Int, radius: CGFloat) -> CGSize {
        let total = Double(max(count, 1))
        let angle: Double = Double(index) / total * 2 * Double.pi - Double.pi / 2
        return CGSize(width: CGFloat(cos(angle)) * radius, height: CGFloat(sin(angle)) * radius)
    }

    /// Bubbles shrink a little when there are so many that they would touch.
    static func bubbleSize(count: Int, radius: CGFloat, largest: CGFloat) -> CGFloat {
        min(largest, 2 * CGFloat.pi * radius / CGFloat(max(count, 1)) - 4)
    }
}
