import AppKit
import SwiftUI

/// Joins frames of a scrolling area into one tall picture. Each new frame is matched against the
/// previous one to find how far the content moved, and only the new rows are kept. Rows that stay
/// put at the top and bottom (sticky headers and footers) are left out of the matching and appear
/// once. When frames can't be matched, the scroll distance reported by the mouse or trackpad is used.
final class ScrollStitcher {
    enum AddResult: Equatable {
        case first, appended(Int), unchanged, noMatch, full
        /// Added using the scroll distance instead of a match (some rows may be missing or repeated).
        case guessed(Int)
    }

    /// Which way the content scrolls. Sideways frames are turned a quarter turn, stitched like
    /// vertical ones, and the result is turned back.
    enum Axis: String, CaseIterable {
        case vertical, horizontal
    }

    static let columns = 32
    static let thumbnailWidth = 72

    let axis: Axis
    let maxHeight: Int
    private(set) var width = 0
    private(set) var framesUsed = 0
    private(set) var guessedFrames = 0
    private(set) var stickyTop = 0
    private(set) var stickyBottom = 0
    private var edgesDecided = false
    private var frameHeight = 0
    private var contentHeight = 0
    private var slices: [CGImage] = []
    private var thumbnails: [CGImage] = []
    private var lastSignature: [Float] = []
    private var lastFrame: CGImage?
    private var misses = 0

    init(maxHeight: Int = 30_000, axis: Axis = .vertical) {
        self.maxHeight = maxHeight
        self.axis = axis
    }

    /// Height of the stitched picture so far, sticky footer included.
    var height: Int { contentHeight + stickyBottom }

    /// The stitched size the way it will be saved (wide for sideways captures).
    var outputSize: CGSize {
        axis == .vertical ? CGSize(width: width, height: height) : CGSize(width: height, height: width)
    }

    /// Adds a frame. `scrolledPoints` is how far the user scrolled forward since the last frame (from
    /// scroll-wheel events), used when the frames can't be matched; `pixelsPerPoint` converts it.
    @discardableResult
    func add(_ input: CGImage, scrolledPoints: CGFloat? = nil, pixelsPerPoint: CGFloat = 1) -> AddResult {
        guard let frame = axis == .vertical ? input : Self.turn(input, clockwise: true) else { return .noMatch }
        guard let signature = Self.signature(frame) else { return .noMatch }
        if slices.isEmpty {
            width = frame.width
            frameHeight = frame.height
            contentHeight = frame.height
            slices = [frame]
            lastSignature = signature
            lastFrame = frame
            framesUsed = 1
            addThumbnail(frame)
            return .first
        }
        guard frame.width == width, frame.height == frameHeight else { return .noMatch }
        guard height < maxHeight else { return .full }
        let h = frameHeight
        if Self.error(previous: lastSignature, next: signature, bandTop: 0, bandRows: h, shift: 0) < 0.75 { return .unchanged }

        // The first time the content moves, rows that didn't move at the edges are sticky.
        if !edgesDecided {
            let edges = Self.staticEdges(previous: lastSignature, next: signature, rows: h)
            edgesDecided = true
            stickyTop = edges.top
            stickyBottom = edges.bottom
            if stickyBottom > 0, slices.count == 1,
               let trimmed = slices[0].cropping(to: CGRect(x: 0, y: 0, width: width, height: h - stickyBottom)) {
                slices[0] = trimmed
                contentHeight -= stickyBottom
            }
        }
        let bandTop = stickyTop
        let bandRows = h - stickyTop - stickyBottom

        var shift = Self.findShift(previous: lastSignature, next: signature, rows: h, bandTop: bandTop, bandRows: bandRows)
        var guessed = false
        if shift == nil, let points = scrolledPoints {
            let pixels = Int((points * pixelsPerPoint).rounded())
            // Scrolled back (or not at all): keep the furthest frame to match against.
            guard pixels > 0 else { return .noMatch }
            shift = min(pixels, bandRows)
            guessed = true
        }
        if shift == nil {
            misses += 1
            guard misses >= 3 else { return .noMatch }
            // Lost for several frames with nothing to go on: keep this frame whole rather than lose it.
            shift = bandRows
            guessed = true
        }
        misses = 0
        guard let moved = shift, moved > 0 else {
            lastSignature = signature
            lastFrame = frame
            return .unchanged
        }
        let rows = min(moved, maxHeight - height)
        guard rows > 0,
              let slice = frame.cropping(to: CGRect(x: 0, y: bandTop + bandRows - rows, width: width, height: rows)) else {
            return .noMatch
        }
        slices.append(slice)
        contentHeight += rows
        framesUsed += 1
        lastSignature = signature
        lastFrame = frame
        addThumbnail(slice)
        if guessed {
            guessedFrames += 1
            return .guessed(rows)
        }
        return .appended(rows)
    }

    func makeImage() -> CGImage? {
        guard let tall = makeTallImage() else { return nil }
        return axis == .vertical ? tall : Self.turn(tall, clockwise: false)
    }

    /// A narrow picture of the last part stitched, for the live preview.
    func preview(maxHeight: Int = 520) -> CGImage? {
        guard !thumbnails.isEmpty else { return nil }
        var picked: [CGImage] = []
        var total = 0
        for thumb in thumbnails.reversed() {
            picked.insert(thumb, at: 0)
            total += thumb.height
            if total >= maxHeight { break }
        }
        let w = Self.thumbnailWidth
        let h = max(1, min(total, maxHeight))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Bottom-aligned: the newest rows at the bottom edge.
        var bottom = 0
        for thumb in picked.reversed() {
            ctx.draw(thumb, in: CGRect(x: 0, y: bottom, width: w, height: thumb.height))
            bottom += thumb.height
            if bottom >= h { break }
        }
        return ctx.makeImage()
    }

    private func addThumbnail(_ slice: CGImage) {
        let w = Self.thumbnailWidth
        let h = max(1, Int((CGFloat(slice.height) * CGFloat(w) / CGFloat(max(1, slice.width))).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.interpolationQuality = .medium
        ctx.draw(slice, in: CGRect(x: 0, y: 0, width: w, height: h))
        if let thumb = ctx.makeImage() { thumbnails.append(thumb) }
        if thumbnails.count > 400 { thumbnails.removeFirst(thumbnails.count - 400) }
    }

    /// A quarter turn: clockwise brings the right edge to the bottom, so content scrolling left moves up.
    static func turn(_ image: CGImage, clockwise: Bool) -> CGImage? {
        let w = image.width, h = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: h, height: w, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // CoreGraphics is y-up: a clockwise turn on screen maps (x, y) to (y, w - x).
        if clockwise {
            ctx.concatenate(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: CGFloat(w)))
        } else {
            ctx.concatenate(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(h), ty: 0))
        }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private func makeTallImage() -> CGImage? {
        guard !slices.isEmpty, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var top = 0
        for slice in slices {
            // CoreGraphics counts y up from the bottom.
            let y = height - top - slice.height
            ctx.draw(slice, in: CGRect(x: 0, y: y, width: slice.width, height: slice.height))
            top += slice.height
        }
        // The sticky footer, once, from the last frame.
        if stickyBottom > 0, let lastFrame,
           let footer = lastFrame.cropping(to: CGRect(x: 0, y: frameHeight - stickyBottom, width: width, height: stickyBottom)) {
            ctx.draw(footer, in: CGRect(x: 0, y: 0, width: width, height: stickyBottom))
        }
        return ctx.makeImage()
    }

    /// For each row, the average brightness (0…255) of `columns` vertical strips.
    static func signature(_ image: CGImage, columns: Int = ScrollStitcher.columns) -> [Float]? {
        let w = image.width, h = image.height
        guard w >= columns, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var result = [Float](repeating: 0, count: h * columns)
        // The first row in memory is the top of the picture.
        for row in 0..<h {
            let rowBase = row * w * 4
            for column in 0..<columns {
                let x0 = column * w / columns
                let x1 = max(x0 + 1, (column + 1) * w / columns)
                var sum = 0
                var count = 0
                var x = x0
                while x < x1 {
                    let i = rowBase + x * 4
                    sum += Int(bytes[i]) * 2 + Int(bytes[i + 1]) * 5 + Int(bytes[i + 2])
                    count += 8
                    x += 2
                }
                result[row * columns + column] = Float(sum) / Float(max(1, count))
            }
        }
        return result
    }

    /// Mean difference between the band of `previous` moved up by `shift` rows and the band of `next`.
    static func error(previous: [Float], next: [Float], bandTop: Int, bandRows: Int, shift: Int,
                      columns: Int = ScrollStitcher.columns) -> Float {
        let overlap = bandRows - shift
        guard overlap > 4 else { return .infinity }
        let step = max(1, overlap / 200)
        var total: Float = 0
        var count = 0
        var row = 0
        while row < overlap {
            let p = (bandTop + row + shift) * columns
            let n = (bandTop + row) * columns
            for c in 0..<columns {
                total += abs(previous[p + c] - next[n + c])
            }
            count += columns
            row += step
        }
        return total / Float(max(1, count))
    }

    /// Rows at the top and bottom that are the same in both frames (at most a quarter of the frame each).
    static func staticEdges(previous: [Float], next: [Float], rows h: Int, columns: Int = ScrollStitcher.columns) -> (top: Int, bottom: Int) {
        guard previous.count == h * columns, next.count == h * columns else { return (0, 0) }
        func same(_ row: Int) -> Bool {
            var total: Float = 0
            for c in 0..<columns { total += abs(previous[row * columns + c] - next[row * columns + c]) }
            return total / Float(columns) < 1.0
        }
        let limit = h / 4
        var top = 0
        while top < limit, same(top) { top += 1 }
        var bottom = 0
        while bottom < limit, same(h - 1 - bottom) { bottom += 1 }
        // A few matching rows are just chance (plain margins); only call it sticky from 6 rows up.
        return (top >= 6 ? top : 0, bottom >= 6 ? bottom : 0)
    }

    /// How many rows the content moved up between two frames: 0 when it didn't move, nil when the
    /// frames don't overlap (scrolled too far at once, scrolled back, or the content changed). Every
    /// shift that leaves a small overlap is tried, so fast scrolling still matches.
    static func findShift(previous: [Float], next: [Float], rows h: Int, bandTop: Int = 0, bandRows: Int? = nil,
                          columns: Int = ScrollStitcher.columns) -> Int? {
        let band = bandRows ?? h
        guard band > 8, bandTop >= 0, bandTop + band <= h, previous.count == h * columns, next.count == h * columns else { return nil }
        if error(previous: previous, next: next, bandTop: bandTop, bandRows: band, shift: 0, columns: columns) < 0.75 { return 0 }
        let minOverlap = max(6, band / 12)
        guard band - minOverlap >= 1 else { return nil }
        var best = Float.infinity
        var bestShift = -1
        for shift in 1...(band - minOverlap) {
            let e = error(previous: previous, next: next, bandTop: bandTop, bandRows: band, shift: shift, columns: columns)
            if e < best - 0.0001 {
                best = e
                bestShift = shift
            }
        }
        guard bestShift > 0, best < 4 else { return nil }
        return bestShift
    }
}

// MARK: - Session

/// Does the stitching off the main thread, one frame at a time.
private final class StitchWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "spinform.scroll.stitch", qos: .userInitiated)
    private let stitcher: ScrollStitcher

    init(axis: ScrollStitcher.Axis) {
        stitcher = ScrollStitcher(axis: axis)
    }

    struct Update: @unchecked Sendable {
        let result: ScrollStitcher.AddResult
        let frames: Int
        let height: Int
        let preview: CGImage?
    }

    func add(_ image: CGImage, points: CGFloat?, pixelsPerPoint: CGFloat) async -> Update {
        let box = ImageEditEngine.PreviewImage(image: image, originalSize: .zero)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Update, Never>) in
            queue.async {
                let result = self.stitcher.add(box.image, scrolledPoints: points, pixelsPerPoint: pixelsPerPoint)
                let changed: Bool
                switch result {
                case .first, .appended, .guessed: changed = true
                default: changed = false
                }
                continuation.resume(returning: Update(result: result, frames: self.stitcher.framesUsed,
                                                      height: self.stitcher.height,
                                                      preview: changed ? self.stitcher.preview() : nil))
            }
        }
    }

    func makeImage() async -> CGImage? {
        let box: ImageEditEngine.PreviewImage? = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.stitcher.makeImage().map { ImageEditEngine.PreviewImage(image: $0, originalSize: .zero) })
            }
        }
        return box?.image
    }
}

/// The scrolling capture on screen: a frame around the area, a live preview strip beside it, and
/// Start / Done buttons. Frames are taken continuously (about 15 a second); scroll-wheel events
/// say how far the page moved when two frames can't be matched.
@MainActor
final class ScrollCaptureSession: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var frames = 0
    @Published private(set) var pixelHeight = 0
    @Published private(set) var note = "Press Start, then scroll down slowly."
    @Published private(set) var preview: CGImage?
    /// Briefly true when a frame couldn't be matched, so the controls can flash.
    @Published private(set) var slipped = false

    @Published var axis: ScrollStitcher.Axis = .vertical {
        didSet { if !running { worker = StitchWorker(axis: axis); note = startNote } }
    }

    private static var current: ScrollCaptureSession?
    private let rect: CGRect
    private var worker = StitchWorker(axis: .vertical)

    private var startNote: String { axis == .vertical ? "Press Start, then scroll down slowly." : "Press Start, then scroll right slowly." }
    private var runningNote: String { axis == .vertical ? "Scroll down at an easy pace. Press Done at the end." : "Scroll right at an easy pace. Press Done at the end." }
    private var areaFrame: AreaFrame?
    private var controls: KeyPanel?
    private var previewPanel: KeyPanel?
    private var loop: Task<Void, Never>?
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var monitors: [Any] = []
    /// Forward scrolling since the last frame was used, in points; nil until a scroll event arrives.
    private var pendingPoints: CGFloat?
    private var slipTask: Task<Void, Never>?

    init(rect: CGRect) {
        self.rect = rect
    }

    /// The stitched picture, or nil when cancelled.
    static func run(area rect: CGRect) async -> CGImage? {
        current?.cancel()
        let session = ScrollCaptureSession(rect: rect)
        current = session
        return await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            session.continuation = continuation
            session.showUI()
        }
    }

    private func showUI() {
        areaFrame = AreaFrame(around: rect, dashed: true)
        let size = CGSize(width: 520, height: 58)
        let screen = ScreenGrabber.screen(containing: CGPoint(x: rect.midX, y: rect.midY))?.visibleFrame ?? rect
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 12)
        if origin.y < screen.minY + 8 { origin.y = rect.maxY + 12 }
        if origin.y + size.height > screen.maxY - 8 { origin.y = rect.minY + 12 }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        let panel = KeyPanel.floating(NSRect(origin: origin, size: size), level: .statusBar)
        panel.contentView = FirstClickHostingView(rootView: ScrollControlsView(session: self))
        panel.onEscape = { [weak self] in self?.cancel() }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        controls = panel

        // The preview strip, beside the area where there's room.
        let stripSize = CGSize(width: CGFloat(ScrollStitcher.thumbnailWidth) + 16, height: min(max(rect.height, 160), 420))
        var stripX = rect.maxX + 14
        if stripX + stripSize.width > screen.maxX - 4 { stripX = rect.minX - stripSize.width - 14 }
        if stripX >= screen.minX + 4 {
            let frame = NSRect(x: stripX, y: rect.maxY - stripSize.height, width: stripSize.width, height: stripSize.height)
            let strip = KeyPanel.floating(frame, level: .statusBar, clickThrough: true)
            strip.contentView = NSHostingView(rootView: ScrollPreviewView(session: self))
            strip.setFrame(frame, display: true)
            strip.orderFrontRegardless()
            previewPanel = strip
        }
    }

    func start() {
        guard !running else { return }
        running = true
        note = runningNote
        watchScrolling()
        loop = Task { [weak self] in await self?.captureLoop() }
    }

    func done() {
        loop?.cancel()
        let worker = self.worker
        Task {
            let image = await worker.makeImage()
            finish(image)
        }
    }

    func cancel() {
        loop?.cancel()
        finish(nil)
    }

    /// Scroll-wheel events (no extra permission needed) give the distance the page moved.
    private func watchScrolling() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.scrolled(event) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: handler) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { event in handler(event); return event }) {
            monitors.append(local)
        }
    }

    private func scrolled(_ event: NSEvent) {
        let raw = axis == .vertical ? event.scrollingDeltaY : event.scrollingDeltaX
        // Content moving up (or left) is forward. Line-based wheels report lines, not points.
        let points = -raw * (event.hasPreciseScrollingDeltas ? 1 : 12)
        pendingPoints = (pendingPoints ?? 0) + points
    }

    private func captureLoop() async {
        let capturer = ScreenGrabber.AreaCapturer(rect: rect)
        let pixelsPerPoint = ScreenGrabber.screen(containing: CGPoint(x: rect.midX, y: rect.midY))?.backingScaleFactor ?? 2
        var failures = 0
        while !Task.isCancelled {
            do {
                let image = try await capturer.capture()
                guard !Task.isCancelled else { return }
                let points = pendingPoints
                let update = await worker.add(image, points: points, pixelsPerPoint: pixelsPerPoint)
                guard !Task.isCancelled else { return }
                failures = 0
                switch update.result {
                case .first, .appended:
                    pendingPoints = points == nil ? nil : 0
                    note = runningNote
                case .guessed:
                    pendingPoints = points == nil ? nil : 0
                    flashSlip("Going a bit fast: some rows may be missing. Slow down a little.")
                case .noMatch:
                    flashSlip("Lost the place: scroll a little slower.")
                case .full:
                    note = "That's as tall as it gets. Press Done."
                case .unchanged:
                    break
                }
                frames = update.frames
                pixelHeight = update.height
                if let picture = update.preview { preview = picture }
            } catch {
                failures += 1
                note = error.localizedDescription
                if failures >= 5 {
                    // Something is wrong with screen capture; don't leave the frame up for ever.
                    Toast.show("Scrolling capture stopped", detail: error.localizedDescription, symbol: "exclamationmark.triangle.fill")
                    cancel()
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
    }

    private func flashSlip(_ message: String) {
        note = message
        slipped = true
        slipTask?.cancel()
        slipTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            self?.slipped = false
        }
    }

    private func finish(_ image: CGImage?) {
        running = false
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        areaFrame?.close()
        areaFrame = nil
        controls?.orderOut(nil)
        controls?.close()
        controls = nil
        previewPanel?.orderOut(nil)
        previewPanel?.close()
        previewPanel = nil
        if ScrollCaptureSession.current === self { ScrollCaptureSession.current = nil }
        continuation?.resume(returning: image)
        continuation = nil
    }

    /// Closes a session left open (used when capture tools are reset).
    static func cancelActive() {
        current?.cancel()
    }
}

/// The growing picture, newest rows at the bottom.
struct ScrollPreviewView: View {
    @ObservedObject var session: ScrollCaptureSession

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if let preview = session.preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(systemName: "arrow.down")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .floatingPanel(radius: 10)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Theme.warning, lineWidth: session.slipped ? 2 : 0))
        .animation(.easeOut(duration: 0.15), value: session.slipped)
        .padding(2)
    }
}

struct ScrollControlsView: View {
    @ObservedObject var session: ScrollCaptureSession

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.and.down.text.horizontal")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accentText)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.running ? "Capturing · \(session.pixelHeight) px \(session.axis == .vertical ? "tall" : "wide")" : "Scrolling capture")
                    .font(Theme.Fonts.bodyStrong)
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
                Text(session.note)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if !session.running {
                Picker("Direction", selection: $session.axis) {
                    Image(systemName: "arrow.up.and.down").tag(ScrollStitcher.Axis.vertical)
                    Image(systemName: "arrow.left.and.right").tag(ScrollStitcher.Axis.horizontal)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 80)
                .help("Which way the content scrolls")
            }
            Button("Cancel") { session.cancel() }
                .buttonStyle(ChipButtonStyle())
            if session.running {
                Button("Done") { session.done() }
                    .buttonStyle(GlowButtonStyle())
            } else {
                Button("Start") { session.start() }
                    .buttonStyle(GlowButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .floatingPanel()
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card + 2, style: .continuous)
            .strokeBorder(Theme.warning, lineWidth: session.slipped ? 2 : 0))
        .animation(.easeOut(duration: 0.15), value: session.slipped)
        .padding(3)
        .tint(Theme.accent)
    }
}
