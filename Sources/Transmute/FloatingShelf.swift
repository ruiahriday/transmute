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

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Drop files that were moved or deleted since they were added.
        let existing = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        if existing.count != files.count {
            files = existing
            save()
        }
        panel.orderFrontRegardless()
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
