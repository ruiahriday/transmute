import AppKit
import SwiftUI

/// Floating files: a small always-on-top shelf to park files on while you switch
/// windows, then drag them out again. The list survives relaunches.
@MainActor
final class FloatingShelf: ObservableObject {
    static let shared = FloatingShelf()

    @Published private(set) var files: [URL] = []
    private var panel: NSPanel?
    private let storeKey = "floatingShelfFiles"

    private init() {
        let paths = UserDefaults.standard.stringArray(forKey: storeKey) ?? []
        files = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ urls: [URL]) {
        for url in urls where !files.contains(url) {
            files.append(url)
        }
        save()
        show()
    }

    func remove(_ url: URL) {
        files.removeAll { $0 == url }
        save()
    }

    func clear() {
        files.removeAll()
        save()
    }

    func toggle() {
        if panel?.isVisible == true {
            panel?.orderOut(nil)
        } else {
            show()
        }
    }

    /// Shows the shelf. With `point`, the shelf is moved so its top centre sits there
    /// (kept on screen), which puts it under the files being dragged.
    func show(at point: NSPoint? = nil) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let point { place(panel, topCentre: point) }
        // Drop files that were moved or deleted since they were added.
        let existing = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        if existing.count != files.count {
            files = existing
            save()
        }
        panel.orderFrontRegardless()
    }

    private func place(_ panel: NSPanel, topCentre point: NSPoint) {
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height)
        panel.setFrameOrigin(origin)
    }

    private func save() {
        UserDefaults.standard.set(files.map(\.path), forKey: storeKey)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 340),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Floating Files"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ShelfView(shelf: self))
        if !panel.setFrameUsingName("FloatingShelf"), let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 280, y: frame.midY - 170))
        }
        panel.setFrameAutosaveName("FloatingShelf")
        return panel
    }
}

/// Opens the shelf when files are shaken while being dragged, or dragged up into the
/// notch (on a Mac without one, the middle of the top edge of the screen).
/// Like the drag wheel, it watches the drag pasteboard and the mouse, so it needs no
/// Accessibility permission.
@MainActor
final class ShelfSummoner {
    private var timer: Timer?
    private var baseline = NSPasteboard(name: .drag).changeCount
    private var isFileDrag: Bool?
    private var openedThisDrag = false
    private var shake = ShakeDetector()

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tick() }
        }
    }

    private func tick() {
        let pasteboard = NSPasteboard(name: .drag)
        guard (NSEvent.pressedMouseButtons & 1) != 0 else {
            reset(baseline: pasteboard.changeCount)
            return
        }
        guard pasteboard.changeCount != baseline, !openedThisDrag else { return }
        if isFileDrag == nil {
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
            isFileDrag = !(urls ?? []).isEmpty
        }
        guard isFileDrag == true else { return }

        let defaults = UserDefaults.standard
        let point = NSEvent.mouseLocation
        if defaults.bool(forKey: Prefs.notchToShelf), let below = Self.notchBottom(containing: point) {
            open(at: below)
        } else if defaults.bool(forKey: Prefs.shakeToShelf),
                  shake.add(x: point.x, at: ProcessInfo.processInfo.systemUptime) {
            open(at: NSPoint(x: point.x, y: point.y + 60))
        }
    }

    private func open(at point: NSPoint) {
        openedThisDrag = true
        FloatingShelf.shared.show(at: point)
    }

    private func reset(baseline: Int) {
        self.baseline = baseline
        isFileDrag = nil
        openedThisDrag = false
        shake = ShakeDetector()
    }

    /// When `point` is in the notch, the point just below the notch's middle.
    static func notchBottom(containing point: NSPoint) -> NSPoint? {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return nil }
        let frame = screen.frame
        var zone = NSRect(x: frame.midX - 120, y: frame.maxY - 4, width: 240, height: 4)
        if #available(macOS 12.0, *), screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let top = screen.safeAreaInsets.top
            zone = NSRect(x: left.maxX, y: frame.maxY - top, width: right.minX - left.maxX, height: top)
        }
        guard NSMouseInRect(point, zone, false) else { return nil }
        return NSPoint(x: zone.midX, y: zone.minY - 6)
    }
}

/// Spots a quick left-right shake in a stream of pointer positions.
struct ShakeDetector {
    /// How far the pointer must travel back the other way to count as a turn, in points.
    var distance: CGFloat = 40
    /// Turns needed within `window` seconds.
    var turnsNeeded = 4
    var window: TimeInterval = 0.9

    // Where the pointer last turned round (or its furthest point so far), which way it is
    // heading, and when each recent turn happened.
    private var turnX: CGFloat?
    private var heading: CGFloat = 0
    private var turns: [TimeInterval] = []

    /// Records the pointer's x position at `time` and says whether it has just been shaken.
    mutating func add(x: CGFloat, at time: TimeInterval) -> Bool {
        guard let start = turnX else {
            turnX = x
            return false
        }
        let moved = x - start
        if heading == 0 {
            if abs(moved) >= distance {
                heading = moved > 0 ? 1 : -1
                turnX = x
            }
        } else if moved * heading > 0 {
            turnX = x  // still going the same way: follow the furthest point
        } else if abs(moved) >= distance {
            heading = -heading
            turnX = x
            turns.append(time)
        }
        turns.removeAll { time - $0 > window }
        return turns.count >= turnsNeeded
    }
}

struct ShelfView: View {
    @ObservedObject var shelf: FloatingShelf
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if shelf.files.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("Drop files here to keep them handy, then drag them out wherever you need them.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(shelf.files, id: \.self) { url in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                                .frame(width: 26, height: 26)
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button { shelf.remove(url) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("Remove from shelf")
                        }
                        .onDrag { NSItemProvider(object: url as NSURL) }
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            Button("Open") { NSWorkspace.shared.open(url) }
                            Button("Remove") { shelf.remove(url) }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text(shelf.files.count == 1 ? "1 file" : "\(shelf.files.count) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { shelf.clear() }
                    .disabled(shelf.files.isEmpty)
            }
            .padding(8)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).padding(3)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            let shelf = self.shelf
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { shelf.add([url]) }
                }
            }
            return true
        }
        .frame(minWidth: 220, minHeight: 240)
    }
}
