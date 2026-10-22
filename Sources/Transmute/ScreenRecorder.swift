import AppKit
import AVFoundation
import Carbon.HIToolbox
import ScreenCaptureKit
import SwiftUI

enum RecordingTarget {
    case area(CGRect, NSScreen)
    case window(WindowInfo)
    case screen(NSScreen)
}

/// Writes ScreenCaptureKit frames, system audio and the microphone into an MP4. Every sample
/// arrives on one serial queue, so the writer is only touched from there.
final class StreamWriter: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate,
                          @unchecked Sendable {
    let queue = DispatchQueue(label: "spinform.recorder.samples")
    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let systemInput: AVAssetWriterInput?
    private let micInput: AVAssetWriterInput?
    private var started = false
    private var startTime = CMTime.invalid
    private var lastVideoTime = CMTime.invalid
    private var lastFrame: CVPixelBuffer?
    private(set) var frames = 0
    /// The microphone session's clock, so its timestamps can be moved onto the screen's clock.
    var micClock: CMClock?
    var onStop: (@Sendable (Error?) -> Void)?

    init(url: URL, width: Int, height: Int, fps: Int, high: Bool, systemAudio: Bool, microphone: Bool) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let bitsPerPixel = high ? 0.12 : 0.07
        let bitrate = max(2_000_000, Int(Double(width * height * fps) * bitsPerPixel))
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 2,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ]
        let video: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: video)
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(videoInput) else { throw ConversionError("Couldn't set up the video recorder.") }
        writer.add(videoInput)

        func audioInput(channels: Int) -> AVAssetWriterInput {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            return input
        }
        var system: AVAssetWriterInput?
        if systemAudio {
            let input = audioInput(channels: 2)
            if writer.canAdd(input) { writer.add(input); system = input }
        }
        var mic: AVAssetWriterInput?
        if microphone {
            let input = audioInput(channels: 1)
            if writer.canAdd(input) { writer.add(input); mic = input }
        }
        systemInput = system
        micInput = mic
        super.init()
    }

    var hasTwoAudioTracks: Bool { systemInput != nil && micInput != nil }

    // MARK: Samples

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        switch type {
        case .screen:
            appendVideo(sampleBuffer)
        case .audio:
            appendAudio(sampleBuffer, to: systemInput, retime: false)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        appendAudio(sampleBuffer, to: micInput, retime: true)
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus), status == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !started {
            guard writer.startWriting() else {
                onStop?(writer.error ?? ConversionError("Couldn't start writing the recording."))
                return
            }
            writer.startSession(atSourceTime: time)
            startTime = time
            started = true
        }
        guard videoInput.isReadyForMoreMediaData, CMTimeCompare(time, lastVideoTime) > 0 || !lastVideoTime.isValid else { return }
        if adaptor.append(pixels, withPresentationTime: time) {
            lastVideoTime = time
            lastFrame = pixels
            frames += 1
        }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?, retime: Bool) {
        guard started, let input, input.isReadyForMoreMediaData else { return }
        var buffer = sampleBuffer
        if retime, let clock = micClock {
            let original = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let converted = CMSyncConvertTime(original, from: clock, to: CMClockGetHostTimeClock())
            var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sampleBuffer),
                                            presentationTimeStamp: converted, decodeTimeStamp: .invalid)
            var copy: CMSampleBuffer?
            if CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
                                                     sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                                     sampleBufferOut: &copy) == noErr, let copy {
                buffer = copy
            }
        }
        guard CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(buffer), startTime) >= 0 else { return }
        input.append(buffer)
    }

    /// Ends the file. nil when no frame ever arrived.
    func finish() async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            queue.async {
                guard self.started else {
                    self.writer.cancelWriting()
                    continuation.resume(returning: nil)
                    return
                }
                // Hold the last frame until now, so a still screen lasts as long as the recording did.
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                if let last = self.lastFrame, CMTimeCompare(now, self.lastVideoTime) > 0, self.videoInput.isReadyForMoreMediaData {
                    if self.adaptor.append(last, withPresentationTime: now) { self.lastVideoTime = now }
                }
                self.videoInput.markAsFinished()
                self.systemInput?.markAsFinished()
                self.micInput?.markAsFinished()
                self.writer.endSession(atSourceTime: self.lastVideoTime)
                self.writer.finishWriting {
                    continuation.resume(returning: self.writer.status == .completed ? self.url : nil)
                }
            }
        }
    }

    func cancel() {
        queue.async {
            if self.started { self.writer.cancelWriting() }
            try? FileManager.default.removeItem(at: self.url)
        }
    }
}

// MARK: - Recorder

/// Screen recording: countdown, ScreenCaptureKit stream, the floating Stop button and menu bar timer,
/// click highlights, keystrokes and the webcam bubble.
@MainActor
final class ScreenRecorder: NSObject, ObservableObject {
    static let shared = ScreenRecorder()

    enum Phase: Equatable {
        case idle, countdown, recording, finishing
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var startedAt: Date?
    @Published private(set) var micOn = false
    @Published private(set) var audioOn = false

    var isActive: Bool { phase != .idle }

    private var stream: SCStream?
    private var writer: StreamWriter?
    private var micSession: AVCaptureSession?
    private var controls: KeyPanel?
    private var areaFrame: AreaFrame?
    private var statusItem: NSStatusItem?
    private var ticker: Timer?
    private var monitors: [Any] = []
    private var webcam: WebcamBubble?
    private var outputSize = CGSize.zero
    private var gif = false
    private var studio = false
    private var hidDesktop = false
    /// The pointer's path for Studio, when recording in Studio mode.
    private var tracker: CursorTracker?

    func start(_ target: RecordingTarget, options requested: RecordingOptions) async {
        guard phase == .idle else { return }
        var options = requested
        phase = .countdown

        if options.microphone, !(await CapturePermissions.requestMedia(.microphone)) {
            options.microphone = false
            PermissionPrompt.show(.microphone)
        }
        if options.camera, !(await CapturePermissions.requestMedia(.camera)) {
            options.camera = false
            PermissionPrompt.show(.camera)
        }
        if options.keystrokes, !AXIsProcessTrusted() {
            options.keystrokes = false
            CapturePermissions.requestAccessibility()
            Toast.show("Recording without keystrokes", detail: "Allow Spinform in Accessibility to show the keys you press.",
                       symbol: "exclamationmark.triangle.fill")
        }
        gif = options.gif
        studio = options.studio

        // Where, and how big.
        let rect: CGRect
        let screen: NSScreen
        switch target {
        case .area(let r, let s): rect = r; screen = s
        case .window(let w):
            rect = w.frame
            screen = ScreenGrabber.screen(containing: CGPoint(x: w.frame.midX, y: w.frame.midY)) ?? NSScreen.main ?? NSScreen.screens[0]
        case .screen(let s): rect = s.frame; screen = s
        }
        let scale = options.high ? screen.backingScaleFactor : 1
        let longest = max(rect.width, rect.height) * scale
        let fit = min(1, (options.high ? 3840 : 1920) / max(1, longest))
        var width = Self.even(rect.width * scale * fit)
        var height = Self.even(rect.height * scale * fit)
        if let cap = options.maxHeight {
            let size = Self.capped(width: width, height: height, maxHeight: cap)
            width = size.width
            height = size.height
        }
        outputSize = CGSize(width: width, height: height)
        if options.hideDesktop {
            DesktopIconHider.show()
            hidDesktop = true
        }

        if options.camera {
            let bubble = WebcamBubble()
            if bubble.show(in: rect, style: .fromSettings) { webcam = bubble }
        }
        if case .area = target { areaFrame = AreaFrame(around: rect) }
        showControls(near: rect, on: screen)

        await Countdown.run(seconds: 3, centredOn: rect)
        guard phase == .countdown else { cleanUp(); return }

        do {
            let temp = OutputPaths.temporaryURL(ext: "mp4")
            let writer = try StreamWriter(url: temp, width: width, height: height, fps: options.fps, high: options.high,
                                          systemAudio: options.systemAudio, microphone: options.microphone)
            writer.onStop = { error in
                Task { @MainActor in ScreenRecorder.shared.streamStopped(error) }
            }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            var hidden = Set<CGWindowID>()
            if let number = controls?.windowNumber { hidden.insert(CGWindowID(number)) }
            if let number = areaFrame?.panel.windowNumber { hidden.insert(CGWindowID(number)) }
            let excluded = content.windows.filter { hidden.contains($0.windowID) }
            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
            config.queueDepth = 6
            // Studio draws its own smooth pointer, so the recording leaves the real one out.
            config.showsCursor = options.cursor && !options.studio
            config.pixelFormat = kCVPixelFormatType_32BGRA
            if options.systemAudio {
                config.capturesAudio = true
                config.sampleRate = 48_000
                config.channelCount = 2
                config.excludesCurrentProcessAudio = true
            }
            let filter: SCContentFilter
            switch target {
            case .window(let w):
                guard let scWindow = content.windows.first(where: { $0.windowID == w.id }) else {
                    throw ConversionError("That window closed.")
                }
                filter = SCContentFilter(desktopIndependentWindow: scWindow)
            case .area, .screen:
                let id = ScreenGrabber.displayID(of: screen)
                guard let display = content.displays.first(where: { $0.displayID == id }) else {
                    throw ConversionError("Couldn't find that screen.")
                }
                filter = SCContentFilter(display: display, excludingWindows: excluded)
                if case .area = target { config.sourceRect = ScreenGrabber.localRect(rect, in: screen.frame) }
            }
            let stream = SCStream(filter: filter, configuration: config, delegate: writer)
            try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
            if options.systemAudio {
                try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue)
            }
            if options.microphone { startMicrophone(into: writer) }
            try await stream.startCapture()
            self.stream = stream
            self.writer = writer
            micOn = micSession != nil
            audioOn = options.systemAudio
            startedAt = Date()
            phase = .recording
            showStatusItem()
            startHelpers(options, screen: screen)
            if options.studio {
                let tracker = CursorTracker(area: rect)
                tracker.start()
                self.tracker = tracker
            }
        } catch {
            cleanUp()
            Toast.show("Couldn't start recording", detail: error.localizedDescription, symbol: "exclamationmark.triangle.fill")
        }
    }

    private static func even(_ value: CGFloat) -> Int {
        max(2, Int(value / 2) * 2)
    }

    /// Shrinks a size to at most `maxHeight` tall (the shorter side for portrait areas), keeping its shape, in even pixels.
    static func capped(width: Int, height: Int, maxHeight: Int) -> (width: Int, height: Int) {
        let shorter = min(width, height)
        guard shorter > maxHeight else { return (width, height) }
        let factor = CGFloat(maxHeight) / CGFloat(shorter)
        return (even(CGFloat(width) * factor), even(CGFloat(height) * factor))
    }

    private func startMicrophone(into writer: StreamWriter) {
        guard let device = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: device) else { return }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        guard session.canAddInput(input), session.canAddOutput(output) else { return }
        session.addInput(input)
        session.addOutput(output)
        output.setSampleBufferDelegate(writer, queue: writer.queue)
        writer.micClock = session.masterClock
        micSession = session
        let running = SessionBox(session: session)
        DispatchQueue.global(qos: .userInitiated).async { running.session.startRunning() }
    }

    /// Stops and saves.
    func stop() {
        switch phase {
        case .countdown:
            phase = .idle
            cleanUp()
        case .recording:
            phase = .finishing
            Task { await finish() }
        default:
            break
        }
    }

    /// Stops and throws the recording away.
    func cancel() {
        guard phase == .recording || phase == .countdown else { return }
        let stream = self.stream
        writer?.cancel()
        writer = nil
        Task { try? await stream?.stopCapture() }
        phase = .idle
        cleanUp()
        Toast.show("Recording discarded", symbol: "trash")
    }

    private func streamStopped(_ error: Error?) {
        guard phase == .recording else { return }
        if let error { Toast.show("Recording stopped", detail: error.localizedDescription, symbol: "exclamationmark.triangle.fill") }
        stop()
    }

    private func finish() async {
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        try? await stream?.stopCapture()
        micSession?.stopRunning()
        let writer = self.writer
        let mixedNeeded = writer?.hasTwoAudioTracks == true
        let size = outputSize
        let makeGIF = gif
        let track = tracker?.finish()
        let openStudio = studio
        cleanUp()
        guard let writer, var file = await writer.finish() else {
            phase = .idle
            Toast.show("Nothing was recorded", detail: "The recording stopped before the first frame.", symbol: "exclamationmark.triangle.fill")
            return
        }
        if mixedNeeded, let mixed = try? await Self.mixAudio(file) {
            try? FileManager.default.removeItem(at: file)
            file = mixed
        }
        phase = .idle
        if makeGIF {
            do {
                let gifFile = try await Self.convertToGIF(file)
                try? FileManager.default.removeItem(at: file)
                let gifSize = (try? ImageConverter.loadCGImage(gifFile)).map { CGSize(width: $0.width, height: $0.height) } ?? size
                CaptureCoordinator.shared.deliverRecording(gifFile, kind: .gif, size: gifSize, duration: duration)
                return
            } catch {
                Toast.show("Saved as MP4 instead of GIF", detail: error.localizedDescription, symbol: "exclamationmark.triangle.fill")
            }
        }
        CaptureCoordinator.shared.deliverRecording(file, kind: .recording, size: size, duration: duration,
                                                   track: track, openStudio: openStudio)
    }

    private func cleanUp() {
        stream = nil
        writer = nil
        micSession = nil
        micOn = false
        audioOn = false
        startedAt = nil
        controls?.orderOut(nil)
        controls?.close()
        controls = nil
        areaFrame?.close()
        areaFrame = nil
        webcam?.hide()
        webcam = nil
        ticker?.invalidate()
        ticker = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        KeystrokeOverlay.shared.hide()
        tracker?.stop()
        tracker = nil
        if hidDesktop {
            DesktopIconHider.hide()
            hidDesktop = false
        }
        if phase != .finishing { phase = .idle }
    }

    // MARK: Controls

    private func showControls(near rect: CGRect, on screen: NSScreen) {
        let size = CGSize(width: 248, height: 50)
        let visible = screen.visibleFrame
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 10)
        if origin.y < visible.minY + 6 { origin.y = rect.maxY + 10 }
        if origin.y + size.height > visible.maxY - 4 { origin = CGPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 8) }
        origin.x = min(max(origin.x, visible.minX + 6), visible.maxX - size.width - 6)
        let panel = KeyPanel.floating(NSRect(origin: origin, size: size), level: .statusBar)
        panel.contentView = FirstClickHostingView(rootView: RecordingControlsView(recorder: self))
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        controls = panel
    }

    private func showStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")
            button.imagePosition = .imageLeading
            button.title = " 0:00"
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            button.contentTintColor = .systemRed
            button.target = self
            button.action = #selector(statusItemClicked)
            button.toolTip = "Stop recording"
        }
        statusItem = item
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { ScreenRecorder.shared.tick() }
        }
    }

    @objc private func statusItemClicked() {
        stop()
    }

    private func tick() {
        guard let startedAt else { return }
        statusItem?.button?.title = " " + HistoryCard.time(Date().timeIntervalSince(startedAt))
    }

    // MARK: Clicks and keys

    private func startHelpers(_ options: RecordingOptions, screen: NSScreen) {
        if options.clicks {
            if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { _ in
                MainActor.assumeIsolated { ClickRipple.show(at: NSEvent.mouseLocation) }
            }) {
                monitors.append(global)
            }
            if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { event in
                MainActor.assumeIsolated { ClickRipple.show(at: NSEvent.mouseLocation) }
                return event
            }) {
                monitors.append(local)
            }
        }
        if options.keystrokes {
            KeystrokeOverlay.shared.prepare(on: screen)
            let shortcutsOnly = UserDefaults.standard.bool(forKey: Prefs.keysShortcutsOnly)
            if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { event in
                guard KeystrokeOverlay.shouldShow(keyCode: event.keyCode, flags: event.modifierFlags, shortcutsOnly: shortcutsOnly)
                else { return }
                let text = KeystrokeOverlay.describe(event)
                MainActor.assumeIsolated { KeystrokeOverlay.shared.show(text) }
            }) {
                monitors.append(global)
            }
        }
    }

    // MARK: Post-processing

    /// System sound and the microphone end up as two tracks; most players play only one, so mix them.
    static func mixAudio(_ file: URL) async throws -> URL {
        guard let ffmpeg = Tools.ffmpeg else { throw ConversionError("ffmpeg isn't available") }
        let out = OutputPaths.temporaryURL(ext: "mp4")
        try await Shell.check(ffmpeg, ["-hide_banner", "-nostdin", "-y", "-i", file.path,
                                       "-filter_complex", "[0:a:0][0:a:1]amix=inputs=2:duration=longest:normalize=0[a]",
                                       "-map", "0:v", "-map", "[a]", "-c:v", "copy", "-c:a", "aac", "-b:a", "160k",
                                       "-movflags", "+faststart", out.path])
        return out
    }

    /// A GIF of a recording through the converter's ffmpeg, sharper than the general video → GIF setting.
    static func convertToGIF(_ file: URL) async throws -> URL {
        let ffmpeg = try Tools.requireFFmpeg(for: "Making a GIF")
        let out = OutputPaths.temporaryURL(ext: "gif")
        let filter = "fps=15,scale='min(960,iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a"
        try await MediaConverter.runFFmpeg(ffmpeg, input: file, args: ["-an", "-vf", filter, "-loop", "0"], output: out) { _ in }
        return out
    }
}

/// Lets a capture session be started off the main thread.
private struct SessionBox: @unchecked Sendable {
    let session: AVCaptureSession
}

struct RecordingControlsView: View {
    @ObservedObject var recorder: ScreenRecorder

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            RecordingControlsBar(
                phase: recorder.phase,
                elapsed: recorder.startedAt.map { context.date.timeIntervalSince($0) } ?? 0,
                micOn: recorder.micOn,
                audioOn: recorder.audioOn,
                onStop: { recorder.stop() },
                onCancel: { recorder.cancel() })
        }
    }
}

/// The floating recording pill (also drawn for the window pictures).
struct RecordingControlsBar: View {
    let phase: ScreenRecorder.Phase
    let elapsed: Double
    var micOn = false
    var audioOn = false
    var onStop: () -> Void = {}
    var onCancel: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(phase == .recording ? Color.red : Theme.textTertiary)
                .frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 1))
            Text(phase == .countdown ? "Starting…" : HistoryCard.time(elapsed))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .frame(minWidth: 56, alignment: .leading)
            if micOn {
                Image(systemName: "mic.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    .help("Recording the microphone")
            }
            if audioOn {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    .help("Recording the Mac's sound")
            }
            Spacer(minLength: 2)
            Button(action: onCancel) {
                Image(systemName: "trash").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(ChipButtonStyle())
            .help("Stop and discard")
            Button(action: onStop) {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(GlowButtonStyle())
            .help("Stop and save")
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.16), radius: 4, y: 2)
        .padding(3)
    }
}

// MARK: - Click highlights

/// How clicks are shown, from Settings.
struct ClickLook: Equatable {
    var color: UInt32 = 0x8B5CF6
    var size: CGFloat = 64
    var filled = true
    var animated = true

    static var fromSettings: ClickLook {
        let d = UserDefaults.standard
        return ClickLook(color: UInt32(truncatingIfNeeded: d.integer(forKey: Prefs.clickColor)),
                         size: CGFloat(min(max(d.double(forKey: Prefs.clickSize), 24), 160)),
                         filled: d.bool(forKey: Prefs.clickFilled),
                         animated: d.bool(forKey: Prefs.clickAnimate))
    }
}

@MainActor
enum ClickRipple {
    static func show(at point: CGPoint, look: ClickLook = .fromSettings) {
        let side = look.size
        let frame = NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
        let panel = KeyPanel.floating(frame, level: .screenSaver, clickThrough: true)
        panel.contentView = NSHostingView(rootView: RippleView(look: look))
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: look.animated ? 550_000_000 : 380_000_000)
            panel.orderOut(nil)
            panel.close()
        }
    }
}

struct RippleView: View {
    var look = ClickLook()
    var frozen = false
    @State private var grown = false

    var body: some View {
        let color = RGBAColor(hex: look.color).color
        let done = grown && look.animated && !frozen
        ZStack {
            if look.filled { Circle().fill(color.opacity(done ? 0 : 0.35)) }
            Circle().strokeBorder(color.opacity(done ? 0 : 0.95), lineWidth: 3)
        }
        .scaleEffect(look.animated && !frozen ? (grown ? 1 : 0.35) : 0.8)
        .onAppear { if look.animated && !frozen { withAnimation(.easeOut(duration: 0.5)) { grown = true } } }
    }
}

// MARK: - Keystrokes

/// How keystrokes are shown, from Settings.
struct KeystrokeLook: Equatable {
    enum Position: String, CaseIterable {
        case bottom, bottomLeft, bottomRight, top
    }
    var position: Position = .bottom
    var scale: CGFloat = 1
    var light = false

    static var fromSettings: KeystrokeLook {
        let d = UserDefaults.standard
        let scale: CGFloat
        switch d.string(forKey: Prefs.keysSize) {
        case "small": scale = 0.75
        case "large": scale = 1.4
        default: scale = 1
        }
        return KeystrokeLook(position: Position(rawValue: d.string(forKey: Prefs.keysPosition) ?? "") ?? .bottom,
                             scale: scale, light: d.bool(forKey: Prefs.keysLight))
    }

    /// Where the keystroke pill goes on a screen.
    func frame(on screen: CGRect, visible: CGRect) -> CGRect {
        let size = CGSize(width: 420 * scale, height: 64 * scale)
        let x: CGFloat
        switch position {
        case .bottomLeft: x = visible.minX + 40
        case .bottomRight: x = visible.maxX - size.width - 40
        case .bottom, .top: x = screen.midX - size.width / 2
        }
        let y = position == .top ? visible.maxY - size.height - 40 : visible.minY + 60
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

@MainActor
final class KeystrokeOverlay {
    static let shared = KeystrokeOverlay()
    private var panel: KeyPanel?
    private var frame = NSRect.zero
    private var look = KeystrokeLook()
    private var generation = 0

    func prepare(on screen: NSScreen) {
        look = .fromSettings
        frame = look.frame(on: screen.frame, visible: screen.visibleFrame)
    }

    func show(_ text: String) {
        guard !text.isEmpty else { return }
        generation += 1
        let current = generation
        let panel = self.panel ?? KeyPanel.floating(frame, level: .screenSaver, clickThrough: true)
        self.panel = panel
        panel.contentView = NSHostingView(rootView: KeystrokeView(text: text, look: look))
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            if self.generation == current { panel.orderOut(nil) }
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// With "only shortcuts" on, plain typing stays private: only keys with ⌘, ⌃ or ⌥, and
    /// special keys (Esc, Return, Tab, arrows, Delete, function keys) are shown.
    nonisolated static func shouldShow(keyCode: UInt16, flags: NSEvent.ModifierFlags, shortcutsOnly: Bool) -> Bool {
        guard shortcutsOnly else { return true }
        if !flags.intersection([.command, .control, .option]).isEmpty { return true }
        let special: Set<UInt16> = [36, 48, 51, 53, 117, 123, 124, 125, 126, 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        return special.contains(keyCode)
    }

    /// "⌘ ⇧ K", with symbols for special keys.
    nonisolated static func describe(_ event: NSEvent) -> String {
        let flags = event.modifierFlags
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "esc", 117: "⌦",
                                         123: "←", 124: "→", 125: "↓", 126: "↑"]
        if let symbol = special[event.keyCode] {
            parts.append(symbol)
        } else if let key = Hotkey.keyNames[UInt32(event.keyCode)] {
            parts.append(key)
        } else if let characters = event.charactersIgnoringModifiers?.uppercased(), !characters.isEmpty {
            parts.append(characters)
        }
        return parts.joined(separator: " ")
    }
}

struct KeystrokeView: View {
    let text: String
    var look = KeystrokeLook()

    var body: some View {
        Text(text)
            .font(.system(size: 24 * look.scale, weight: .semibold, design: .rounded))
            .foregroundStyle(look.light ? Color.black : Color.white)
            .padding(.horizontal, 18 * look.scale)
            .padding(.vertical, 9 * look.scale)
            .background(look.light ? Color.white.opacity(0.92) : Color.black.opacity(0.72),
                        in: RoundedRectangle(cornerRadius: 14 * look.scale, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14 * look.scale, style: .continuous)
                .strokeBorder(look.light ? Color.black.opacity(0.12) : Color.white.opacity(0.15)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Webcam bubble

/// How the camera appears in a recording, from Settings.
struct WebcamStyle: Equatable {
    enum Corner: String, CaseIterable {
        case bottomRight, bottomLeft, topRight, topLeft
    }
    var corner: Corner = .bottomRight
    var side: CGFloat = 168
    var rounded = false
    /// The camera fills the whole recorded area (picture-in-picture off).
    var full = false

    static var fromSettings: WebcamStyle {
        let d = UserDefaults.standard
        let side: CGFloat
        switch d.string(forKey: Prefs.cameraSize) {
        case "small": side = 120
        case "large": side = 240
        default: side = 168
        }
        return WebcamStyle(corner: Corner(rawValue: d.string(forKey: Prefs.cameraPosition) ?? "") ?? .bottomRight,
                           side: side, rounded: d.string(forKey: Prefs.cameraShape) == "rounded",
                           full: d.bool(forKey: Prefs.cameraFull))
    }

    /// The camera's frame for a recorded area (AppKit coordinates).
    func frame(in rect: CGRect) -> CGRect {
        if full { return rect }
        let inset: CGFloat = 24
        let x = (corner == .bottomRight || corner == .topRight) ? rect.maxX - side - inset : rect.minX + inset
        let y = (corner == .topLeft || corner == .topRight) ? rect.maxY - side - inset : rect.minY + inset
        return CGRect(x: x, y: y, width: side, height: side)
    }

    var cornerRadius: CGFloat { full ? 0 : (rounded ? side * 0.18 : side / 2) }
}

/// A draggable camera picture that's recorded along with the screen.
@MainActor
final class WebcamBubble {
    private var panel: NSPanel?
    private let session = AVCaptureSession()

    func show(in rect: CGRect, style: WebcamStyle = WebcamStyle()) -> Bool {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return false }
        session.addInput(input)
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        let frame = style.frame(in: rect)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = !style.full
        panel.level = .floating
        panel.isMovableByWindowBackground = !style.full
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = CameraView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let root = CALayer()
        root.cornerRadius = style.cornerRadius
        root.masksToBounds = true
        root.borderWidth = style.full ? 0 : 3
        root.borderColor = NSColor.white.cgColor
        root.backgroundColor = NSColor.black.cgColor
        view.layer = root
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        root.addSublayer(preview)
        panel.contentView = view
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        let box = SessionBox(session: session)
        DispatchQueue.global(qos: .userInitiated).async { box.session.startRunning() }
        return true
    }

    func hide() {
        let box = SessionBox(session: session)
        DispatchQueue.global(qos: .userInitiated).async { box.session.stopRunning() }
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    private final class CameraView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}

// MARK: - Pointer track for Studio

/// Where the pointer was and when it clicked during a recording, relative to the recorded area
/// (normalized, top-left origin) and the recording's start.
struct CursorTrack: Codable, Equatable, Sendable {
    struct Sample: Codable, Equatable, Sendable {
        var t: Double
        var x: Double
        var y: Double
    }
    var samples: [Sample] = []
    var clicks: [Sample] = []
    /// The recorded area in points, for sizing the pointer.
    var areaWidth: Double = 0
    var areaHeight: Double = 0
}

/// Samples the pointer 60 times a second while recording for Studio. Clicks come from a global
/// mouse monitor, which needs no extra permission.
@MainActor
final class CursorTracker {
    private let area: CGRect
    private var track = CursorTrack()
    private var timer: Timer?
    private var monitors: [Any] = []
    private var startDate = Date()

    init(area: CGRect) {
        self.area = area
        track.areaWidth = Double(area.width)
        track.areaHeight = Double(area.height)
    }

    func start() {
        startDate = Date()
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.click() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    private func point() -> CursorTrack.Sample {
        let p = NSEvent.mouseLocation
        return CursorTrack.Sample(t: Date().timeIntervalSince(startDate),
                                  x: Double((p.x - area.minX) / max(area.width, 1)),
                                  y: Double((area.maxY - p.y) / max(area.height, 1)))
    }

    private func sample() { track.samples.append(point()) }

    private func click() { track.clicks.append(point()) }

    func stop() {
        timer?.invalidate()
        timer = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    func finish() -> CursorTrack {
        stop()
        return track
    }
}
