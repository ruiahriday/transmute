import AppKit
import SwiftUI

/// Joins frames of a scrolling area into one tall picture. Each new frame is matched against the
/// previous one row by row to find how far the content moved, and only the new rows are kept.
final class ScrollStitcher {
    enum AddResult: Equatable {
        case first, appended(Int), unchanged, noMatch, full
    }

    /// Which way the content scrolls. Sideways frames are turned a quarter turn, stitched like
    /// vertical ones, and the result is turned back.
    enum Axis: String, CaseIterable {
        case vertical, horizontal
    }

    static let columns = 32

    let axis: Axis
    let maxHeight: Int
    private(set) var width = 0
    private(set) var height = 0
    private(set) var framesUsed = 0
    private var frameHeight = 0
    private var slices: [CGImage] = []
    private var lastSignature: [Float] = []

    init(maxHeight: Int = 30_000, axis: Axis = .vertical) {
        self.maxHeight = maxHeight
        self.axis = axis
    }

    /// The stitched size the way it will be saved (wide for sideways captures).
    var outputSize: CGSize {
        axis == .vertical ? CGSize(width: width, height: height) : CGSize(width: height, height: width)
    }

    @discardableResult
    func add(_ input: CGImage) -> AddResult {
        guard let frame = axis == .vertical ? input : Self.turn(input, clockwise: true) else { return .noMatch }
        guard let signature = Self.signature(frame) else { return .noMatch }
        if slices.isEmpty {
            width = frame.width
            frameHeight = frame.height
            height = frame.height
            slices = [frame]
            lastSignature = signature
            framesUsed = 1
            return .first
        }
        guard frame.width == width, frame.height == frameHeight else { return .noMatch }
        guard height < maxHeight else { return .full }
        guard let shift = Self.findShift(previous: lastSignature, next: signature, rows: frameHeight) else { return .noMatch }
        lastSignature = signature
        if shift == 0 { return .unchanged }
        let rows = min(shift, maxHeight - height)
        guard rows > 0, let slice = frame.cropping(to: CGRect(x: 0, y: frame.height - rows, width: frame.width, height: rows)) else {
            return .noMatch
        }
        slices.append(slice)
        height += rows
        framesUsed += 1
        return .appended(rows)
    }

    func makeImage() -> CGImage? {
        guard let tall = makeTallImage() else { return nil }
        return axis == .vertical ? tall : Self.turn(tall, clockwise: false)
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

    /// How many rows the content moved up between two frames: 0 when it didn't move, nil when the
    /// frames don't overlap (scrolled too far at once, scrolled back, or the content changed).
    static func findShift(previous: [Float], next: [Float], rows h: Int, columns: Int = ScrollStitcher.columns) -> Int? {
        guard h > 8, previous.count == h * columns, next.count == h * columns else { return nil }
        // A header that stays put at the top of the area shouldn't spoil the match.
        let ignoreTop = h / 8

        func error(_ shift: Int) -> Float {
            let overlap = h - shift
            let start = min(ignoreTop, overlap / 3)
            let compared = overlap - start
            guard compared > 4 else { return .infinity }
            let step = max(1, compared / 160)
            var total: Float = 0
            var count = 0
            var row = start
            while row < overlap {
                let p = (row + shift) * columns
                let n = row * columns
                for c in 0..<columns {
                    total += abs(previous[p + c] - next[n + c])
                }
                count += columns
                row += step
            }
            return total / Float(max(1, count))
        }

        if error(0) < 0.75 { return 0 }
        let minOverlap = max(8, h / 5)
        guard h - minOverlap >= 1 else { return nil }
        var best = Float.infinity
        var bestShift = -1
        for shift in 1...(h - minOverlap) {
            let e = error(shift)
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

/// The scrolling capture on screen: a frame around the area and Start / Done buttons beside it.
@MainActor
final class ScrollCaptureSession: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var frames = 0
    @Published private(set) var pixelHeight = 0
    @Published private(set) var note = "Press Start, then scroll down slowly."

    @Published var axis: ScrollStitcher.Axis = .vertical {
        didSet { if !running { stitcher = ScrollStitcher(axis: axis); note = startNote } }
    }

    private static var current: ScrollCaptureSession?
    private let rect: CGRect
    private var stitcher = ScrollStitcher()

    private var startNote: String { axis == .vertical ? "Press Start, then scroll down slowly." : "Press Start, then scroll right slowly." }
    private var runningNote: String { axis == .vertical ? "Scroll down slowly. Press Done at the end." : "Scroll right slowly. Press Done at the end." }
    private var areaFrame: AreaFrame?
    private var controls: KeyPanel?
    private var loop: Task<Void, Never>?
    private var continuation: CheckedContinuation<CGImage?, Never>?

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
        let size = CGSize(width: 500, height: 58)
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
    }

    func start() {
        guard !running else { return }
        running = true
        note = runningNote
        loop = Task { [weak self] in await self?.captureLoop() }
    }

    func done() {
        loop?.cancel()
        finish(stitcher.makeImage())
    }

    func cancel() {
        loop?.cancel()
        finish(nil)
    }

    private func captureLoop() async {
        while !Task.isCancelled {
            do {
                let image = try await ScreenGrabber.captureArea(rect, excludingSelf: true)
                guard !Task.isCancelled else { return }
                switch stitcher.add(image) {
                case .noMatch: note = "Lost the place: scroll a little slower."
                case .full: note = "That's as tall as it gets. Press Done."
                case .first, .appended: note = runningNote
                case .unchanged: break
                }
                frames = stitcher.framesUsed
                pixelHeight = stitcher.height
            } catch {
                note = error.localizedDescription
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func finish(_ image: CGImage?) {
        running = false
        areaFrame?.close()
        areaFrame = nil
        controls?.orderOut(nil)
        controls?.close()
        controls = nil
        if ScrollCaptureSession.current === self { ScrollCaptureSession.current = nil }
        continuation?.resume(returning: image)
        continuation = nil
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
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline))
        .padding(3)
        .tint(Theme.accent)
    }
}
