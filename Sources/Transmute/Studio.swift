import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import VideoToolbox

// MARK: - Model

/// A stretch of a recording shown closer up.
struct ZoomSegment: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var start: Double
    var end: Double
    /// 1 is no zoom, 2 shows a quarter of the picture.
    var scale: Double = 2
    /// What to zoom on (normalized, top-left origin); nil follows the pointer.
    var centre: NormPoint? = nil
    var manual = false
}

enum StudioAspect: String, Codable, CaseIterable, Identifiable, Sendable {
    case landscape, square, vertical, original

    var id: String { rawValue }

    var label: String {
        switch self {
        case .landscape: "16:9"
        case .square: "1:1"
        case .vertical: "9:16"
        case .original: "Original"
        }
    }

    var help: String {
        switch self {
        case .landscape: "Landscape, for YouTube, slides and the web"
        case .square: "Square, for feeds"
        case .vertical: "Vertical, for stories, Reels and Shorts"
        case .original: "The recording's own shape"
        }
    }
}

/// Everything Studio does to a recording.
struct StudioSettings: Codable, Equatable, Sendable {
    var trimStart = 0.0
    /// nil runs to the end.
    var trimEnd: Double? = nil
    var output: StudioAspect = .landscape
    var background: FrameStyle.Background = .gradient(0x48484A, 0x1C1C1E)
    /// Space around the recording, as a fraction of the output's shorter side.
    var padding = 0.06
    /// Corner radius, as a fraction of the recording's shorter side on the output.
    var corners = 0.025
    var shadow = 0.6
    var autoZoom = true
    var zoomScale = 2.0
    /// Hand-made zooms (automatic ones are worked out from the clicks).
    var zooms: [ZoomSegment] = []
    var smoothCursor = true
    /// 0 hides the pointer; 1 is its normal size.
    var cursorSize = 1.0
    var motionBlur = false
}

/// Pointer paths of Studio recordings, kept in Application Support by the recording's file name
/// (both the saved copy and the history copy).
enum StudioTracks {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Spinform/Studio", isDirectory: true)
    }

    private static func file(for url: URL, in folder: URL) -> URL {
        let safe = url.lastPathComponent.replacingOccurrences(of: "/", with: "-")
        return folder.appendingPathComponent(safe + ".json")
    }

    static func save(_ track: CursorTrack, for urls: [URL], in folder: URL = directory) {
        guard let data = try? JSONEncoder().encode(track) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for url in urls { try? data.write(to: file(for: url, in: folder), options: .atomic) }
    }

    static func load(for url: URL, in folder: URL = directory) -> CursorTrack? {
        guard let data = try? Data(contentsOf: file(for: url, in: folder)) else { return nil }
        return try? JSONDecoder().decode(CursorTrack.self, from: data)
    }
}

// MARK: - Engine

enum StudioEngine {
    /// How long a zoom takes to ease in and out.
    static let ramp = 0.45

    /// One zoom per burst of clicks: from just before the first click to a little after the last,
    /// merged when they're close together.
    static func autoZooms(clicks: [Double], duration: Double, scale: Double) -> [ZoomSegment] {
        var segments: [ZoomSegment] = []
        for t in clicks.sorted() {
            let start = max(0, t - 0.6)
            let end = min(duration, t + 2.2)
            guard end > start else { continue }
            if var last = segments.last, start <= last.end + 0.8 {
                last.end = max(last.end, end)
                segments[segments.count - 1] = last
            } else {
                segments.append(ZoomSegment(start: start, end: end, scale: scale))
            }
        }
        return segments
    }

    /// All zooms for a recording: hand-made ones win where they overlap automatic ones.
    static func zooms(for settings: StudioSettings, track: CursorTrack?, duration: Double) -> [ZoomSegment] {
        var result = settings.zooms
        if settings.autoZoom, let track {
            let auto = autoZooms(clicks: track.clicks.map(\.t), duration: duration, scale: settings.zoomScale)
            for segment in auto where !result.contains(where: { $0.start < segment.end && segment.start < $0.end }) {
                result.append(segment)
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    static func smoothstep(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The pointer at time `t`: in between samples, or averaged over a short window when smoothing.
    static func cursor(at t: Double, track: CursorTrack, smooth: Bool) -> NormPoint? {
        let samples = track.samples
        guard !samples.isEmpty else { return nil }
        if smooth {
            let window = 0.15
            var sx = 0.0, sy = 0.0, total = 0.0
            for sample in samples where abs(sample.t - t) <= window {
                // A triangle window: nearer samples count more.
                let weight = 1 - abs(sample.t - t) / (window * 1.0001)
                sx += sample.x * weight
                sy += sample.y * weight
                total += weight
            }
            if total > 0 { return NormPoint(x: sx / total, y: sy / total) }
        }
        guard let after = samples.firstIndex(where: { $0.t >= t }) else {
            return NormPoint(x: samples[samples.count - 1].x, y: samples[samples.count - 1].y)
        }
        if after == 0 { return NormPoint(x: samples[0].x, y: samples[0].y) }
        let a = samples[after - 1], b = samples[after]
        let f = b.t > a.t ? (t - a.t) / (b.t - a.t) : 0
        return NormPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }

    /// The zoom at time `t`: how close, and on what. The view never leaves the picture.
    static func zoomState(at t: Double, zooms: [ZoomSegment], track: CursorTrack?, smooth: Bool) -> (scale: Double, centre: NormPoint) {
        var scale = 1.0
        var centre = NormPoint(x: 0.5, y: 0.5)
        for segment in zooms where t >= segment.start && t <= segment.end {
            let length = segment.end - segment.start
            let ramp = min(Self.ramp, length / 2)
            let p = min(smoothstep((t - segment.start) / max(ramp, 0.001)), smoothstep((segment.end - t) / max(ramp, 0.001)))
            scale = 1 + (segment.scale - 1) * p
            let target = segment.centre ?? track.flatMap { cursor(at: t, track: $0, smooth: true) } ?? NormPoint(x: 0.5, y: 0.5)
            centre = NormPoint(x: 0.5 + (target.x - 0.5) * p, y: 0.5 + (target.y - 0.5) * p)
            break
        }
        _ = smooth
        let half = 0.5 / max(scale, 1)
        centre.x = min(max(centre.x, half), 1 - half)
        centre.y = min(max(centre.y, half), 1 - half)
        return (scale, centre)
    }

    /// The output size for a recording of `source` pixels. `base` is the shorter side of the
    /// square and vertical shapes and the height of landscape.
    static func outputSize(source: CGSize, aspect: StudioAspect, base: Int = 1080) -> CGSize {
        func even(_ v: CGFloat) -> CGFloat { CGFloat(max(2, Int(v / 2) * 2)) }
        let b = CGFloat(base)
        switch aspect {
        case .landscape: return CGSize(width: even(b * 16 / 9), height: b)
        case .square: return CGSize(width: b, height: b)
        case .vertical: return CGSize(width: b, height: even(b * 16 / 9))
        case .original:
            let scale = min(1, b * 16 / 9 / max(source.width, 1), b * 16 / 9 / max(source.height, 1))
            return CGSize(width: even(source.width * scale), height: even(source.height * scale))
        }
    }

    /// Where the recording sits on the output (top-left origin): fitted inside the padding, centred.
    static func contentRect(source: CGSize, output: CGSize, padding: Double) -> CGRect {
        let pad = CGFloat(min(max(padding, 0), 0.3)) * min(output.width, output.height)
        let room = CGSize(width: max(1, output.width - 2 * pad), height: max(1, output.height - 2 * pad))
        let scale = min(room.width / max(source.width, 1), room.height / max(source.height, 1))
        let size = CGSize(width: (source.width * scale).rounded(), height: (source.height * scale).rounded())
        return CGRect(x: ((output.width - size.width) / 2).rounded(), y: ((output.height - size.height) / 2).rounded(),
                      width: size.width, height: size.height)
    }

    /// The background, the recording's shadow and a black card where the recording goes, drawn once.
    static func backdrop(output: CGSize, content: CGRect, settings: StudioSettings) -> CGImage? {
        let w = Int(output.width), h = Int(output.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Reuse the frame renderer's backgrounds on a one-pixel picture with no padding.
        var style = FrameStyle(background: settings.background, padding: 0, corners: 0, shadow: 0, aspect: .auto)
        style.balance = false
        if let pixel = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage(),
           let background = try? FrameRenderer.render(pixel, style: style) {
            ctx.draw(background, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let rect = CGRect(x: content.minX, y: output.height - content.maxY, width: content.width, height: content.height)
        let radius = cornerRadius(content: content, settings: settings)
        let shadow = CGFloat(min(max(settings.shadow, 0), 1))
        ctx.saveGState()
        if shadow > 0 {
            let reach = max(content.width, content.height)
            ctx.setShadow(offset: CGSize(width: 0, height: -reach * 0.012 * shadow), blur: reach * 0.04 * shadow,
                          color: CGColor(gray: 0, alpha: 0.5 * shadow))
        }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
        return ctx.makeImage()
    }

    static func cornerRadius(content: CGRect, settings: StudioSettings) -> CGFloat {
        min(content.width, content.height) / 2 * CGFloat(min(max(settings.corners, 0), 0.5)) * 2
    }

    /// A rounded-rectangle mask for the recording, in CoreImage coordinates.
    static func mask(output: CGSize, content: CGRect, settings: StudioSettings) -> CIImage? {
        let w = Int(output.width), h = Int(output.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        let rect = CGRect(x: content.minX, y: output.height - content.maxY, width: content.width, height: content.height)
        let radius = cornerRadius(content: content, settings: settings)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }

    /// The system arrow pointer as a picture, for drawing the smoothed pointer. AppKit hands it
    /// over on the main thread (`preparePointer`); renders read the copy.
    private static let pointerLock = NSLock()
    private static var pointerStore: (image: CGImage, hotSpot: CGPoint, size: CGSize)?

    static var pointer: (image: CGImage, hotSpot: CGPoint, size: CGSize)? {
        pointerLock.lock()
        defer { pointerLock.unlock() }
        return pointerStore
    }

    /// Loads the pointer picture on the main thread before a render needs it.
    @MainActor static func preparePointer() {
        guard pointer == nil else { return }
        let cursor = NSCursor.arrow
        let image = cursor.image
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
        pointerLock.lock()
        pointerStore = (cg, cursor.hotSpot, image.size)
        pointerLock.unlock()
    }

    /// Everything needed to draw frames of one export.
    struct Composer {
        let settings: StudioSettings
        let track: CursorTrack?
        let zooms: [ZoomSegment]
        let source: CGSize
        let output: CGSize
        let content: CGRect
        let backdrop: CIImage
        let mask: CIImage?

        init?(settings: StudioSettings, track: CursorTrack?, duration: Double, source: CGSize, base: Int = 1080) {
            self.settings = settings
            self.track = track
            self.source = source
            zooms = StudioEngine.zooms(for: settings, track: track, duration: duration)
            output = StudioEngine.outputSize(source: source, aspect: settings.output, base: base)
            content = StudioEngine.contentRect(source: source, output: output, padding: settings.padding)
            guard let back = StudioEngine.backdrop(output: output, content: content, settings: settings) else { return nil }
            backdrop = CIImage(cgImage: back)
            mask = StudioEngine.mask(output: output, content: content, settings: settings)
        }

        /// One output frame for a source frame at time `t`.
        func frame(_ image: CIImage, at t: Double) -> CIImage {
            let state = StudioEngine.zoomState(at: t, zooms: zooms, track: track, smooth: settings.smoothCursor)
            let extent = image.extent
            // The part of the source in view (CoreImage is y-up; normalized y runs down).
            let viewW = extent.width / CGFloat(state.scale), viewH = extent.height / CGFloat(state.scale)
            let viewX = extent.minX + CGFloat(state.centre.x) * extent.width - viewW / 2
            let viewY = extent.minY + (1 - CGFloat(state.centre.y)) * extent.height - viewH / 2
            let sx = content.width / viewW, sy = content.height / viewH
            let target = CGRect(x: content.minX, y: output.height - content.maxY, width: content.width, height: content.height)
            var video = image
                .transformed(by: CGAffineTransform(translationX: -viewX, y: -viewY))
                .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
                .cropped(to: target)
            // The smoothed pointer, scaled with the zoom.
            if settings.cursorSize > 0.01, let track, let arrow = StudioEngine.pointer,
               let at = StudioEngine.cursor(at: t, track: track, smooth: settings.smoothCursor) {
                let px = (CGFloat(at.x) * extent.width + extent.minX - viewX) * sx + target.minX
                let py = ((1 - CGFloat(at.y)) * extent.height + extent.minY - viewY) * sy + target.minY
                // The pointer's size in output pixels: its point size on the recorded area, scaled like the picture.
                let pointsToPixels = content.width / CGFloat(max(track.areaWidth, 1)) * CGFloat(state.scale)
                let grow = pointsToPixels * CGFloat(settings.cursorSize)
                let size = CGSize(width: arrow.size.width * grow, height: arrow.size.height * grow)
                let hot = CGPoint(x: arrow.hotSpot.x / max(arrow.size.width, 1) * size.width,
                                  y: arrow.hotSpot.y / max(arrow.size.height, 1) * size.height)
                let pointerImage = CIImage(cgImage: arrow.image)
                let scaleX = size.width / max(pointerImage.extent.width, 1)
                let scaleY = size.height / max(pointerImage.extent.height, 1)
                let placed = pointerImage
                    .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                    .transformed(by: CGAffineTransform(translationX: px - hot.x, y: py - (size.height - hot.y)))
                if target.contains(CGPoint(x: px, y: py)) { video = placed.composited(over: video).cropped(to: target) }
            }
            if let mask {
                let blend = CIFilter.blendWithMask()
                blend.inputImage = video
                blend.backgroundImage = backdrop
                blend.maskImage = mask
                return (blend.outputImage ?? video.composited(over: backdrop)).cropped(to: backdrop.extent)
            }
            return video.composited(over: backdrop).cropped(to: backdrop.extent)
        }

        /// True while a zoom is moving, when motion blur helps.
        func isMoving(at t: Double, step: Double) -> Bool {
            let a = StudioEngine.zoomState(at: t, zooms: zooms, track: track, smooth: settings.smoothCursor)
            let b = StudioEngine.zoomState(at: max(0, t - step), zooms: zooms, track: track, smooth: settings.smoothCursor)
            return abs(a.scale - b.scale) > 0.002 || abs(a.centre.x - b.centre.x) + abs(a.centre.y - b.centre.y) > 0.002
        }
    }

    /// The source video's pixel size, duration and frame rate.
    static func info(of url: URL) async throws -> (size: CGSize, duration: Double, fps: Double) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionError("That file has no video.")
        }
        let (natural, transform, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let size = natural.applying(transform)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        return (CGSize(width: abs(size.width), height: abs(size.height)), duration, Double(rate > 0 ? rate : 30))
    }

    /// One finished frame at `seconds`, for the preview.
    static func previewFrame(url: URL, seconds: Double, settings: StudioSettings, track: CursorTrack?,
                             base: Int = 540) async throws -> CGImage {
        let info = try await StudioEngine.info(of: url)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        let frame = try await generator.image(at: CMTime(seconds: max(0, seconds), preferredTimescale: 600)).image
        guard let composer = Composer(settings: settings, track: track, duration: info.duration,
                                      source: CGSize(width: frame.width, height: frame.height), base: base) else {
            throw ConversionError("Couldn't draw the preview.")
        }
        let out = composer.frame(CIImage(cgImage: frame), at: seconds)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = context.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: space) else {
            throw ConversionError("Couldn't draw the preview.")
        }
        return image
    }

    /// Renders the finished video: trims, zooms, background, pointer and motion blur, encoded in
    /// hardware where the Mac has an encoder (VideoToolbox), with the sound carried over untouched.
    static func export(url: URL, settings: StudioSettings, track: CursorTrack?, to out: URL, base: Int = 1080,
                       progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let info = try await StudioEngine.info(of: url)
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionError("That file has no video.")
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let start = min(max(0, settings.trimStart), max(0, info.duration - 0.1))
        let end = min(info.duration, max(start + 0.1, settings.trimEnd ?? info.duration))
        guard let composer = Composer(settings: settings, track: track, duration: info.duration, source: info.size, base: base) else {
            throw ConversionError("Couldn't set up Studio's picture.")
        }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       end: CMTime(seconds: end, preferredTimescale: 600))
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw ConversionError("Couldn't read the video.") }
        reader.add(videoOutput)
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            if reader.canAdd(output) { reader.add(output); audioOutput = output }
        }

        try? FileManager.default.removeItem(at: out)
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let width = Int(composer.output.width), height = Int(composer.output.height)
        let bitrate = max(4_000_000, Int(Double(width * height) * info.fps * 0.1))
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: Int(info.fps.rounded()),
            ] as [String: Any],
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(videoInput) else { throw ConversionError("Couldn't set up the video encoder.") }
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if let audioOutput, let audioTrack {
            let hints = try await audioTrack.load(.formatDescriptions)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hints.first)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); audioInput = input }
            _ = audioOutput
        }

        guard reader.startReading() else { throw reader.error ?? ConversionError("Couldn't read the video.") }
        guard writer.startWriting() else { throw writer.error ?? ConversionError("Couldn't write the video.") }
        writer.startSession(atSourceTime: CMTime(seconds: start, preferredTimescale: 600))

        let context = CIContext(options: [.cacheIntermediates: false])
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let job = StudioJob(reader: reader, writer: writer, videoOutput: videoOutput, videoInput: videoInput, adaptor: adaptor,
                            audioOutput: audioInput == nil ? nil : audioOutput, audioInput: audioInput, composer: composer,
                            context: context, space: space, start: start, end: end, fps: info.fps, progress: progress)
        try await job.run()
        return out
    }
}

/// One export in progress: pulls frames, draws them and feeds the encoder on its own queues.
private final class StudioJob: @unchecked Sendable {
    let reader: AVAssetReader
    let writer: AVAssetWriter
    let videoOutput: AVAssetReaderTrackOutput
    let videoInput: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let audioOutput: AVAssetReaderTrackOutput?
    let audioInput: AVAssetWriterInput?
    let composer: StudioEngine.Composer
    let context: CIContext
    let space: CGColorSpace
    let start: Double
    let end: Double
    let fps: Double
    let progress: @Sendable (Double) -> Void
    private var previous: CIImage?
    private var failure: Error?

    init(reader: AVAssetReader, writer: AVAssetWriter, videoOutput: AVAssetReaderTrackOutput, videoInput: AVAssetWriterInput,
         adaptor: AVAssetWriterInputPixelBufferAdaptor, audioOutput: AVAssetReaderTrackOutput?, audioInput: AVAssetWriterInput?,
         composer: StudioEngine.Composer, context: CIContext, space: CGColorSpace, start: Double, end: Double, fps: Double,
         progress: @escaping @Sendable (Double) -> Void) {
        self.reader = reader
        self.writer = writer
        self.videoOutput = videoOutput
        self.videoInput = videoInput
        self.adaptor = adaptor
        self.audioOutput = audioOutput
        self.audioInput = audioInput
        self.composer = composer
        self.context = context
        self.space = space
        self.start = start
        self.end = end
        self.fps = fps
        self.progress = progress
    }

    func run() async throws {
        let group = DispatchGroup()
        group.enter()
        let videoQueue = DispatchQueue(label: "spinform.studio.video")
        videoInput.requestMediaDataWhenReady(on: videoQueue) { [self] in
            while videoInput.isReadyForMoreMediaData {
                guard let sample = videoOutput.copyNextSampleBuffer() else {
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
                if !append(sample) {
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
            }
        }
        if let audioOutput, let audioInput {
            group.enter()
            let audioQueue = DispatchQueue(label: "spinform.studio.audio")
            audioInput.requestMediaDataWhenReady(on: audioQueue) {
                while audioInput.isReadyForMoreMediaData {
                    guard let sample = audioOutput.copyNextSampleBuffer() else {
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                    audioInput.append(sample)
                }
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { continuation.resume() }
        }
        if let failure {
            writer.cancelWriting()
            throw failure
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? ConversionError("Couldn't read the video.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ConversionError("Couldn't finish the video.") }
    }

    private func append(_ sample: CMSampleBuffer) -> Bool {
        guard let pixels = CMSampleBufferGetImageBuffer(sample) else { return true }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        let t = CMTimeGetSeconds(time)
        var image = composer.frame(CIImage(cvPixelBuffer: pixels), at: t)
        if composer.settings.motionBlur, let previous, composer.isMoving(at: t, step: 1 / max(fps, 1)) {
            let mix = CIFilter.dissolveTransition()
            mix.inputImage = previous
            mix.targetImage = image
            mix.time = 0.6
            image = mix.outputImage ?? image
        }
        previous = image
        guard let pool = adaptor.pixelBufferPool else {
            failure = ConversionError("The video encoder isn't ready.")
            return false
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else {
            failure = ConversionError("Ran out of memory for video frames.")
            return false
        }
        context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: composer.output), colorSpace: space)
        if !adaptor.append(buffer, withPresentationTime: time) {
            failure = writer.error ?? ConversionError("Couldn't encode a frame.")
            return false
        }
        progress(min(1, max(0, (t - start) / max(end - start, 0.001))))
        return true
    }
}

// MARK: - Window

@MainActor
enum StudioWindow {
    private static var windows: [NSWindow] = []

    static func open(_ url: URL) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Studio"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: StudioView(url: url) { [weak window] in window?.close() })
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

    /// Asks for a recording, then opens it.
    static func choose() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.prompt = "Open in Studio"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
}

/// Studio: a preview with a timeline of zooms on the left, the look on the right.
struct StudioView: View {
    let url: URL
    var onClose: () -> Void = {}

    @State private var settings: StudioSettings
    @State private var track: CursorTrack?
    @State private var duration = 0.0
    @State private var time = 0.0
    @State private var preview: CGImage?
    @State private var exporting = false
    @State private var exportProgress = 0.0
    @State private var error: String?

    init(url: URL, settings: StudioSettings = StudioSettings(), track: CursorTrack? = nil, time: Double = 0,
         onClose: @escaping () -> Void = {}) {
        self.url = url
        self.onClose = onClose
        _settings = State(initialValue: settings)
        _track = State(initialValue: track)
        _time = State(initialValue: time)
    }

    private struct PreviewKey: Equatable {
        var settings: StudioSettings
        var time: Double
        var duration: Double
    }

    private var zooms: [ZoomSegment] { StudioEngine.zooms(for: settings, track: track, duration: duration) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ZStack {
                    Theme.stage
                    if let preview {
                        Image(decorative: preview, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .padding(24)
                            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                    } else if let error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).padding()
                    } else {
                        ProgressView()
                    }
                }
                Divider()
                timeline.padding(12).background(Theme.surface)
            }
            Divider()
            sidebar.frame(width: 300).background(Theme.surface)
        }
        .frame(minWidth: 900, minHeight: 600)
        .tint(Theme.accent)
        .task(id: url) { await load() }
        .task(id: PreviewKey(settings: settings, time: time, duration: duration)) { await refresh() }
    }

    // MARK: Timeline

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(HistoryCard.time(time)).font(Theme.Fonts.bodyStrong.monospacedDigit()).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button { addZoom() } label: { Label("Add Zoom Here", systemImage: "plus.magnifyingglass") }
                    .buttonStyle(ChipButtonStyle())
                    .disabled(duration <= 0)
                    .help("Zoom in for two seconds from here, on the pointer (or the middle)")
                Text(HistoryCard.time(duration)).font(Theme.Fonts.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.surfaceRaised)
                    RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.hairline)
                    // Kept part.
                    let keepStart = duration > 0 ? settings.trimStart / duration : 0
                    let keepEnd = duration > 0 ? (settings.trimEnd ?? duration) / duration : 1
                    Rectangle()
                        .fill(Theme.accent.opacity(0.08))
                        .frame(width: max(0, CGFloat(keepEnd - keepStart) * width))
                        .offset(x: CGFloat(keepStart) * width)
                    ForEach(zooms) { zoom in
                        let x = duration > 0 ? CGFloat(zoom.start / duration) * width : 0
                        let w = duration > 0 ? CGFloat((zoom.end - zoom.start) / duration) * width : 0
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(zoom.manual ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.accent.opacity(0.55)))
                            .frame(width: max(4, w), height: 16)
                            .overlay(Image(systemName: "plus.magnifyingglass").font(.system(size: 9, weight: .bold)).foregroundStyle(.white))
                            .offset(x: x)
                            .help(zoom.manual ? "Your zoom" : "Automatic zoom on a click")
                    }
                    Rectangle()
                        .fill(Theme.textPrimary)
                        .frame(width: 2, height: 30)
                        .offset(x: duration > 0 ? CGFloat(time / duration) * width - 1 : 0)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    guard duration > 0 else { return }
                    time = min(max(0, Double(value.location.x / max(width, 1)) * duration), duration)
                })
            }
            .frame(height: 30)
            HStack(spacing: 10) {
                Text("Trim").font(Theme.Fonts.bodyStrong).foregroundStyle(Theme.textPrimary)
                Slider(value: Binding(get: { settings.trimStart }, set: { value in
                    settings.trimStart = min(value, (settings.trimEnd ?? duration) - 0.2)
                    time = settings.trimStart
                }), in: 0...max(duration, 0.1))
                Slider(value: Binding(get: { settings.trimEnd ?? duration }, set: { value in
                    let end = max(value, settings.trimStart + 0.2)
                    settings.trimEnd = end >= duration - 0.01 ? nil : end
                    time = end
                }), in: 0...max(duration, 0.1))
                Text("\(HistoryCard.time(settings.trimStart))–\(HistoryCard.time(settings.trimEnd ?? duration))")
                    .font(Theme.Fonts.caption.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func addZoom() {
        let centre = track.flatMap { StudioEngine.cursor(at: time, track: $0, smooth: true) }
        settings.zooms.append(ZoomSegment(start: time, end: min(duration, time + 2), scale: settings.zoomScale,
                                          centre: centre ?? NormPoint(x: 0.5, y: 0.5), manual: true))
        settings.zooms.sort { $0.start < $1.start }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars").foregroundStyle(Theme.accentText)
                Text("Studio").font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary)
            }
            .padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    shapeSection
                    zoomSection
                    pointerSection
                    lookSection
                }
                .padding(14)
            }
            Divider()
            footer.padding(14)
        }
    }

    private var shapeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Shape")
            Picker("Shape", selection: $settings.output) {
                ForEach(StudioAspect.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(settings.output.help).font(Theme.Fonts.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    private var zoomSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Zoom")
            Toggle("Zoom in on clicks automatically", isOn: $settings.autoZoom)
                .disabled(track == nil)
            slider("Zoom level", value: $settings.zoomScale, range: 1.25...3) { String(format: "%.1f×", $0) }
            if !settings.zooms.isEmpty {
                ForEach(settings.zooms) { zoom in
                    HStack {
                        Image(systemName: "plus.magnifyingglass").foregroundStyle(Theme.accent)
                        Text("\(HistoryCard.time(zoom.start))–\(HistoryCard.time(zoom.end))").monospacedDigit()
                        Spacer()
                        Button { settings.zooms.removeAll { $0.id == zoom.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Remove this zoom")
                    }
                    .font(Theme.Fonts.body)
                }
            }
            if track == nil {
                Text("Automatic zooms and the smooth pointer need a recording made with Studio mode on (Settings → Screen recording). You can still add zooms by hand.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var pointerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Pointer")
            Toggle("Smooth the pointer's movement", isOn: $settings.smoothCursor)
            slider("Pointer size", value: $settings.cursorSize, range: 0...3) { $0 < 0.01 ? "Hidden" : String(format: "%.1f×", $0) }
            Toggle("Motion blur while zooming", isOn: $settings.motionBlur)
        }
        .disabled(track == nil)
    }

    private var lookSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Background")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 10) {
                ForEach(FramePreset.builtIn) { preset in
                    let selected = preset.style.background == settings.background
                    Button { settings.background = preset.style.background } label: {
                        Circle()
                            .fill(FrameToolView.fill(preset.style.background))
                            .frame(width: 28, height: 28)
                            .overlay(Circle().strokeBorder(Theme.controlBorder.opacity(0.5), lineWidth: 1))
                            .overlay(Circle().strokeBorder(Theme.accent, lineWidth: selected ? 2 : 0).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .help(preset.name)
                }
            }
            slider("Padding", value: $settings.padding, range: 0...0.2) { "\(Int(($0 * 100).rounded()))%" }
            slider("Corners", value: $settings.corners, range: 0...0.08) { "\(Int(($0 * 1000).rounded()))" }
            slider("Shadow", value: $settings.shadow, range: 0...1) { "\(Int(($0 * 100).rounded()))%" }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                        format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(Theme.Fonts.bodyStrong).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(format(value.wrappedValue)).font(Theme.Fonts.body).monospacedDigit().foregroundStyle(Theme.textSecondary)
            }
            Slider(value: value, in: range)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if exporting {
                ProgressView(value: exportProgress)
            }
            HStack {
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                Spacer()
                Button { export() } label: { Label("Export MP4", systemImage: "square.and.arrow.down") }
                    .buttonStyle(GlowButtonStyle())
                    .disabled(exporting || duration <= 0)
                    .keyboardShortcut("s", modifiers: .command)
            }
            Text("Encoded with the Mac's video hardware when it has it.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: Work

    private func load() async {
        StudioEngine.preparePointer()
        if track == nil { track = StudioTracks.load(for: url) }
        do {
            duration = try await StudioEngine.info(of: url).duration
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func refresh() async {
        guard duration > 0 else { return }
        try? await Task.sleep(nanoseconds: 80_000_000)
        guard !Task.isCancelled else { return }
        do {
            let image = try await StudioEngine.previewFrame(url: url, seconds: time, settings: settings, track: track)
            guard !Task.isCancelled else { return }
            preview = image
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func export() {
        exporting = true
        exportProgress = 0
        let url = self.url, settings = self.settings, track = self.track
        let out = OutputPaths.destination(for: url, ext: "mp4", suffix: "studio", folder: nil)
        Task {
            do {
                let done = try await StudioEngine.export(url: url, settings: settings, track: track, to: out) { value in
                    Task { @MainActor in exportProgress = value }
                }
                Toast.show("Exported \(done.lastPathComponent)", detail: done.deletingLastPathComponent().path, symbol: "wand.and.stars")
                NSWorkspace.shared.activateFileViewerSelecting([done])
            } catch {
                Toast.show("Couldn't export", detail: error.localizedDescription, symbol: "exclamationmark.triangle.fill")
            }
            exporting = false
        }
    }
}
