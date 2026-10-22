import AppKit
import AVFoundation
import ImageIO
import SwiftUI

struct HistoryItem: Codable, Identifiable, Equatable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case screenshot, scrolling, recording, gif, text

        var label: String {
            switch self {
            case .screenshot: "Screenshot"
            case .scrolling: "Scrolling capture"
            case .recording: "Recording"
            case .gif: "GIF"
            case .text: "Text"
            }
        }

        var symbol: String {
            switch self {
            case .screenshot: "camera.viewfinder"
            case .scrolling: "arrow.up.and.down.text.horizontal"
            case .recording: "video.fill"
            case .gif: "photo.stack"
            case .text: "text.viewfinder"
            }
        }

        var isVideo: Bool { self == .recording }
    }

    var id: UUID
    var date: Date
    var kind: Kind
    /// The copy's name inside the history folder.
    var fileName: String
    var width: Int
    var height: Int
    var duration: Double?
}

/// Recent captures and recordings, kept in Application Support/Spinform/History with an index file.
@MainActor
final class CaptureHistory: ObservableObject {
    static let shared = CaptureHistory(directory: CaptureHistory.defaultDirectory)

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Spinform", isDirectory: true).appendingPathComponent("History", isDirectory: true)
    }

    /// Newest first.
    @Published private(set) var items: [HistoryItem] = []
    let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("history.json") }

    init(directory: URL) {
        self.directory = directory
        load()
    }

    func url(for item: HistoryItem) -> URL { directory.appendingPathComponent(item.fileName) }

    /// Keeps a copy of a capture (a hard link when it's on the same disk, so it takes no extra space).
    @discardableResult
    func add(file: URL, kind: HistoryItem.Kind, width: Int, height: Int, duration: Double? = nil,
             date: Date = Date()) throws -> HistoryItem {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let ext = file.pathExtension.isEmpty ? "png" : file.pathExtension.lowercased()
        let name = "\(id.uuidString).\(ext)"
        let target = directory.appendingPathComponent(name)
        do {
            try FileManager.default.linkItem(at: file, to: target)
        } catch {
            try FileManager.default.copyItem(at: file, to: target)
        }
        let item = HistoryItem(id: id, date: date, kind: kind, fileName: name, width: width, height: height, duration: duration)
        items.insert(item, at: 0)
        items.sort { $0.date > $1.date }
        save()
        return item
    }

    func delete(_ item: HistoryItem) {
        try? FileManager.default.removeItem(at: url(for: item))
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        for item in items { try? FileManager.default.removeItem(at: url(for: item)) }
        items.removeAll()
        save()
    }

    /// Drops captures older than `days` days (0 keeps none).
    func prune(keepingDays days: Int, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(max(0, days)) * 86_400)
        let old = items.filter { $0.date < cutoff }
        guard !old.isEmpty else { return }
        for item in old { try? FileManager.default.removeItem(at: url(for: item)) }
        items.removeAll { $0.date < cutoff }
        save()
    }

    /// Puts a copy back in the capture folder and returns it.
    func restore(_ item: HistoryItem, to folder: URL = CaptureSettings.folder) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let prefix = item.kind.isVideo ? "Spinform Recording" : "Spinform"
        let target = OutputPaths.unique(in: folder, base: CaptureFiles.baseName(prefix, date: item.date),
                                        ext: url(for: item).pathExtension)
        try FileManager.default.copyItem(at: url(for: item), to: target)
        return target
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let saved = try? JSONDecoder().decode([HistoryItem].self, from: data) else { items = []; return }
        // Files someone removed by hand drop out of the list.
        items = saved.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }.sorted { $0.date > $1.date }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: indexURL, options: .atomic) }
    }
}

// MARK: - Thumbnails

enum Thumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    static func cached(_ url: URL) -> NSImage? { cache.object(forKey: url.path as NSString) }

    /// A small picture of an image or the first moments of a video.
    static func make(_ url: URL, maxPixel: Int = 480) async -> NSImage? {
        if let hit = cached(url) { return hit }
        let image: CGImage?
        if FileKind.of(url) == .video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            image = try? await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
        } else {
            image = await Task.detached(priority: .utility) { () -> ImageEditEngine.PreviewImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                ]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                    .map { ImageEditEngine.PreviewImage(image: $0, originalSize: .zero) }
            }.value?.image
        }
        guard let image else { return nil }
        let result = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        cache.setObject(result, forKey: url.path as NSString)
        return result
    }
}

struct ThumbnailView: View {
    let url: URL
    var contentMode: ContentMode = .fill
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Theme.surfaceRaised
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
            } else {
                Image(systemName: "photo").foregroundStyle(Theme.textTertiary)
            }
        }
        .task(id: url) { image = await Thumbnails.make(url) }
    }
}

/// The start of a text capture, in place of a thumbnail.
struct TextSnippetView: View {
    let url: URL
    @State private var text = ""

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.surfaceRaised
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(7)
                .padding(EdgeInsets(top: 26, leading: 9, bottom: 6, trailing: 9))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task(id: url) {
            text = (try? String(contentsOf: url, encoding: .utf8)).map { String($0.prefix(400)) } ?? ""
        }
    }
}

// MARK: - Window

@MainActor
enum HistoryWindow {
    private static var window: NSWindow?

    static func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Capture History"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HistoryView(history: CaptureHistory.shared))
        window.center()
        window.setFrameAutosaveName("SpinformHistory")
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// A grid of recent captures by day: open, annotate or trim, copy, pin, put back, delete.
struct HistoryView: View {
    @ObservedObject var history: CaptureHistory
    @State private var filter: Filter = .all
    @State private var confirmClear = false

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", screenshots = "Screenshots", recordings = "Recordings", text = "Text"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .all: "square.grid.2x2"
            case .screenshots: "camera.viewfinder"
            case .recordings: "video"
            case .text: "text.viewfinder"
            }
        }

        func includes(_ kind: HistoryItem.Kind) -> Bool {
            switch self {
            case .all: true
            case .screenshots: kind == .screenshot || kind == .scrolling
            case .recordings: kind == .recording || kind == .gif
            case .text: kind == .text
            }
        }
    }

    private var shown: [HistoryItem] { history.items.filter { filter.includes($0.kind) } }

    private var days: [(title: String, items: [HistoryItem])] {
        let calendar = Calendar.current
        var groups: [(Date, [HistoryItem])] = []
        for item in shown {
            let day = calendar.startOfDay(for: item.date)
            if let last = groups.last, last.0 == day {
                groups[groups.count - 1].1.append(item)
            } else {
                groups.append((day, [item]))
            }
        }
        return groups.map { (title: Self.dayTitle($0.0), items: $0.1) }
    }

    static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .complete, time: .omitted)
    }

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 12) {
                header
                if shown.isEmpty {
                    empty.crispCard(padding: 0)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14, pinnedViews: []) {
                            ForEach(days, id: \.title) { group in
                                SectionLabel(group.title)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 12)], spacing: 12) {
                                    ForEach(group.items) { item in
                                        HistoryCard(item: item, url: history.url(for: item), history: history)
                                    }
                                }
                            }
                        }
                        .padding(14)
                    }
                    .crispCard(padding: 0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .padding(.top, 8)
        }
        .frame(minWidth: 640, minHeight: 440)
        .tint(Theme.accent)
        .confirmationDialog("Delete every capture in the history?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { history.clear() }
        } message: {
            Text("Copies you saved elsewhere stay where they are.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.brand)
            VStack(alignment: .leading, spacing: 0) {
                Text("Capture History").font(Theme.Fonts.wordmark).foregroundStyle(Theme.textPrimary)
                Text(retentionText).font(Theme.Fonts.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            SlidingPicker(options: Filter.allCases, selection: $filter, title: \.rawValue, symbol: \.symbol)
            Button { NSWorkspace.shared.open(history.directory) } label: { Image(systemName: "folder") }
                .buttonStyle(ChipButtonStyle())
                .help("Open the history folder")
            Button { confirmClear = true } label: { Image(systemName: "trash") }
                .buttonStyle(ChipButtonStyle())
                .disabled(history.items.isEmpty)
                .help("Delete every capture in the history")
        }
    }

    private var retentionText: String {
        let days = CaptureSettings.historyDays
        let count = "\(history.items.count) item\(history.items.count == 1 ? "" : "s")"
        if days <= 0 { return "\(count) · history is off in Settings" }
        if days >= 3650 { return "\(count) · kept until you delete them" }
        return "\(count) · kept for \(days) day\(days == 1 ? "" : "s")"
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Theme.brand)
            Text("No captures yet").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(Theme.textPrimary)
            Text("Screenshots and recordings show up here, so you can find, edit or share them later.")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HistoryCard: View {
    let item: HistoryItem
    let url: URL
    @ObservedObject var history: CaptureHistory
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if item.kind == .text {
                    TextSnippetView(url: url)
                } else {
                    ThumbnailView(url: url)
                }
            }
                .frame(height: 112)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(alignment: .topLeading) {
                    Label(item.kind.label, systemImage: item.kind.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .padding(6)
                }
                .overlay {
                    if hovering { actions.transition(.opacity) }
                }
                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            HStack(spacing: 6) {
                Text(item.date.formatted(date: .omitted, time: .shortened))
                    .font(Theme.Fonts.bodyStrong)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(detail)
                    .font(Theme.Fonts.caption.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            .strokeBorder(hovering ? Theme.accent.opacity(0.7) : Theme.hairline, lineWidth: 1))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button(item.kind.isVideo ? "Trim in Video Editor" : "Annotate") { CaptureCoordinator.shared.edit(url) }
            Button("Copy") { CaptureCoordinator.shared.copy(url) }
            if !item.kind.isVideo && item.kind != .text {
                Button("Pin to Screen") { PinController.open(url: url) }
                Button("Add Background Frame") { FrameToolWindow.open(url) }
            }
            Button("Save to Capture Folder") { restore() }
            Divider()
            Button("Delete", role: .destructive) { history.delete(item) }
        }
    }

    private var detail: String {
        if let duration = item.duration { return Self.time(duration) }
        if item.kind == .text { return FileInfo.size(of: url) ?? "" }
        return "\(item.width)×\(item.height)"
    }

    static func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var actions: some View {
        ZStack {
            Color.black.opacity(0.45)
            HStack(spacing: 6) {
                if item.kind != .text {
                    iconButton(item.kind.isVideo ? "scissors" : "pencil.tip.crop.circle", item.kind.isVideo ? "Trim" : "Annotate") {
                        CaptureCoordinator.shared.edit(url)
                    }
                }
                iconButton("doc.on.doc", "Copy") { CaptureCoordinator.shared.copy(url) }
                if !item.kind.isVideo && item.kind != .text {
                    iconButton("pin", "Pin to screen") { PinController.open(url: url) }
                }
                iconButton("square.and.arrow.down", "Save to the capture folder") { restore() }
                iconButton("trash", "Delete") { history.delete(item) }
            }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 28, height: 28)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func restore() {
        do {
            let saved = try history.restore(item)
            NSWorkspace.shared.activateFileViewerSelecting([saved])
        } catch {
            Toast.show("Couldn't save", detail: error.localizedDescription, symbol: "exclamationmark.triangle.fill")
        }
    }
}
