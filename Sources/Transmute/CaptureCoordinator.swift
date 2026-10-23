import AppKit
import AVFoundation
import SwiftUI

/// Runs the capture tools: picks the target, takes the picture, then saves, copies, keeps it in the
/// history and shows the quick access card, as set in Settings.
@MainActor
final class CaptureCoordinator: ObservableObject {
    static let shared = CaptureCoordinator()

    @Published private(set) var busy = false
    /// The history copy made by the last store(), so Studio can find a recording's pointer path from either copy.
    private var lastHistoryURL: URL?
    private static let previousAreaKey = "capturePreviousArea"

    func perform(_ action: CaptureAction) {
        switch action {
        case .history:
            HistoryWindow.show()
            return
        case .recordArea, .recordWindow, .recordScreen:
            if ScreenRecorder.shared.isActive {
                ScreenRecorder.shared.stop()
                return
            }
        default:
            break
        }
        guard !busy else { NSSound.beep(); return }
        guard ensurePermission() else { return }
        busy = true
        Task {
            await run(action)
            // Whatever happened, nothing the capture put up stays on the screen.
            CaptureCleanup.closeAll()
            busy = false
        }
    }

    /// True when Spinform may see the screen; otherwise explains how to allow it.
    func ensurePermission() -> Bool {
        if CapturePermissions.screenRecording { return true }
        PermissionPrompt.show(.screen)
        return false
    }

    private func run(_ action: CaptureAction) async {
        do {
            switch action {
            case .allInOne:
                try await allInOne()
            case .area:
                if let image = try await pickAndCapture(mode: .area) { deliver(image, kind: .screenshot) }
            case .window:
                if let image = try await pickAndCapture(mode: .window) { deliver(image, kind: .screenshot) }
            case .fullscreen:
                if let image = try await captureFullScreen() { deliver(image, kind: .screenshot) }
            case .previous:
                if let image = try await capturePreviousArea() { deliver(image, kind: .screenshot) }
            case .scrolling:
                try await scrollingCapture()
            case .text:
                try await recognizeText()
            case .recordArea:
                try await startRecording(mode: .area)
            case .recordWindow:
                try await startRecording(mode: .window)
            case .recordScreen:
                try await startRecording(mode: nil)
            case .history:
                break
            }
        } catch {
            CaptureCleanup.closeAll()
            if (error as? CaptureFailure) == .screenPermission {
                PermissionPrompt.show(.screen)
            } else {
                Toast.show("Couldn't capture", detail: error.localizedDescription, symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    // MARK: All-in-one

    private func allInOne() async throws {
        guard let choice = await CaptureChooser.choose() else { return }
        // Let the chooser leave the screen before anything is captured.
        try? await Task.sleep(nanoseconds: 150_000_000)
        switch choice {
        case .action(let action):
            if action == .history || action == .allInOne {
                HistoryWindow.show()
            } else {
                await run(action)
            }
        case .exactSize(let size):
            if let image = try await pickAndCapture(mode: .area, constraint: .fixedSize(size)) { deliver(image, kind: .screenshot) }
        case .lockedAspect(let ratio):
            if let image = try await pickAndCapture(mode: .area, constraint: .aspect(ratio)) { deliver(image, kind: .screenshot) }
        }
    }

    // MARK: Picking

    /// Freezes the screens, lets the user choose, then returns what to keep.
    private func choose(mode: SelectionMode, hint: String? = nil, constraint: SelectionConstraint? = nil) async throws -> SelectionOutcome? {
        let hideIcons = CaptureSettings.hideDesktopIcons
        if hideIcons {
            DesktopIconHider.show()
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let windows = ScreenGrabber.onScreenWindows()
        let shots: [DisplayShot]
        do {
            shots = try await ScreenGrabber.captureAllScreens()
        } catch {
            if hideIcons { DesktopIconHider.hide() }
            throw error
        }
        let outcome = await SelectionOverlay.select(mode: mode, shots: shots, windows: windows, hint: hint,
                                                    constraint: constraint, look: .fromSettings)
        if hideIcons && outcome == nil { DesktopIconHider.hide() }
        return outcome
    }

    private func pickAndCapture(mode: SelectionMode, constraint: SelectionConstraint? = nil) async throws -> CGImage? {
        guard let outcome = try await choose(mode: mode, constraint: constraint) else { return nil }
        defer { DesktopIconHider.hide() }
        let timer = CaptureSettings.selfTimer
        switch outcome {
        case .area(let rect, let shot):
            rememberArea(rect)
            if timer > 0 {
                await Countdown.run(seconds: timer, centredOn: rect)
                return try await ScreenGrabber.captureArea(rect, excludingSelf: false)
            }
            if !CaptureSettings.freezeScreen {
                // The screen wasn't frozen, so take what's there now that the crosshair has gone.
                try? await Task.sleep(nanoseconds: 120_000_000)
                return try await ScreenGrabber.captureArea(rect, excludingSelf: true)
            }
            return ScreenGrabber.crop(shot, to: rect)
        case .window(let window):
            // Give the overlay a moment to leave the screen.
            try? await Task.sleep(nanoseconds: 120_000_000)
            if timer > 0 { await Countdown.run(seconds: timer, centredOn: window.frame) }
            return try await captureWindowWithBackdrop(window)
        }
    }

    /// A window as Settings asks: on transparency with or without its shadow, or on a background.
    private func captureWindowWithBackdrop(_ window: WindowInfo) async throws -> CGImage? {
        let backdrop = CaptureSettings.windowBackdrop
        let image = try await ScreenGrabber.captureWindow(window, shadow: backdrop == .shadow)
        guard backdrop.usesBackground else { return image }
        DesktopPicture.refresh()
        let style = Self.backdropStyle(backdrop, color: CaptureSettings.windowBackdropColor,
                                       picture: CaptureSettings.windowBackdropImage, padding: CaptureSettings.windowPadding)
        let box = ImageEditEngine.PreviewImage(image: image, originalSize: .zero)
        return try await Task.detached(priority: .userInitiated) { try FrameRenderer.render(box.image, style: style) }.value
    }

    /// The frame look for a window backdrop: the background, padding and a soft shadow, no extra rounding.
    nonisolated static func backdropStyle(_ backdrop: WindowBackdrop, color: UInt32, picture: URL?, padding: Double) -> FrameStyle {
        let background: FrameStyle.Background
        switch backdrop {
        case .image: background = picture.map { .image($0.path) } ?? .desktop
        case .color: background = .solid(color)
        default: background = .desktop
        }
        return FrameStyle(background: background, padding: min(max(padding, 0), 0.25), corners: 0, shadow: 0.7, aspect: .auto)
    }

    private func captureFullScreen() async throws -> CGImage? {
        guard let screen = ScreenGrabber.screenUnderMouse else { return nil }
        let timer = CaptureSettings.selfTimer
        if timer > 0 { await Countdown.run(seconds: timer, centredOn: screen.frame) }
        let hideIcons = CaptureSettings.hideDesktopIcons
        if hideIcons {
            DesktopIconHider.show()
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        defer { if hideIcons { DesktopIconHider.hide() } }
        return try await ScreenGrabber.captureScreen(screen).image
    }

    private func capturePreviousArea() async throws -> CGImage? {
        guard let rect = previousArea else {
            Toast.show("No previous area yet", detail: "Capture an area first; Spinform remembers it.", symbol: "exclamationmark.triangle.fill")
            return nil
        }
        let timer = CaptureSettings.selfTimer
        if timer > 0 { await Countdown.run(seconds: timer, centredOn: rect) }
        let hideIcons = CaptureSettings.hideDesktopIcons
        if hideIcons {
            DesktopIconHider.show()
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        defer { if hideIcons { DesktopIconHider.hide() } }
        return try await ScreenGrabber.captureArea(rect, excludingSelf: true)
    }

    private func rememberArea(_ rect: CGRect) {
        UserDefaults.standard.set(NSStringFromRect(rect), forKey: Self.previousAreaKey)
    }

    var previousArea: CGRect? {
        guard let text = UserDefaults.standard.string(forKey: Self.previousAreaKey) else { return nil }
        let rect = NSRectFromString(text)
        return rect.width >= 1 && rect.height >= 1 ? rect : nil
    }

    private func scrollingCapture() async throws {
        guard let outcome = try await choose(mode: .area, hint: "Drag over the part that scrolls") else { return }
        DesktopIconHider.hide()
        guard case .area(let rect, _) = outcome else {
            Toast.show("Pick an area for a scrolling capture", symbol: "exclamationmark.triangle.fill")
            return
        }
        rememberArea(rect)
        if let image = await ScrollCaptureSession.run(area: rect) {
            deliver(image, kind: .scrolling)
        }
    }

    private func recognizeText() async throws {
        guard let outcome = try await choose(mode: .area, hint: "Drag over the text to copy") else { return }
        DesktopIconHider.hide()
        let image: CGImage?
        switch outcome {
        case .area(let rect, let shot): image = ScreenGrabber.crop(shot, to: rect)
        case .window(let window): image = try await ScreenGrabber.captureWindow(window, shadow: false)
        }
        guard let image else { return }
        let box = ImageEditEngine.PreviewImage(image: image, originalSize: .zero)
        let result = try await Task.detached(priority: .userInitiated) { try TextRecognizer.recognize(box.image) }.value
        TextRecognizer.deliver(result)
        if !result.isEmpty { keepText(result.clipboardText) }
    }

    /// Copy Text from an image or PDF file instead of the screen.
    func recognizeTextInFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.prompt = "Copy Text"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        recognizeText(inFile: url)
    }

    /// Copies the text in an image or PDF (a quick access card's Text button, the URL scheme).
    func recognizeText(inFile url: URL) {
        Toast.show("Reading text…", symbol: "text.viewfinder")
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { try TextRecognizer.recognize(fileAt: url) }.value
                TextRecognizer.deliver(result)
                if !result.isEmpty { keepText(result.clipboardText) }
            } catch {
                Toast.show("Couldn't read text", detail: error.localizedDescription, symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    /// Recognised text goes into the history too (as a .txt), so it can be found again.
    func keepText(_ text: String) {
        let days = CaptureSettings.historyDays
        guard days > 0, let data = text.data(using: .utf8) else { return }
        let temp = OutputPaths.temporaryURL(ext: "txt")
        do {
            try data.write(to: temp, options: .atomic)
            try CaptureHistory.shared.add(file: temp, kind: .text, width: 0, height: 0)
            try? FileManager.default.removeItem(at: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
        }
    }

    // MARK: Recording

    private func startRecording(mode: SelectionMode?) async throws {
        // Ask macOS for the screen first, so a missing or stale permission shows the prompt
        // before anything goes on screen.
        _ = try await ScreenGrabber.shareableContent()
        let target: RecordingTarget
        if let mode {
            guard let outcome = try await choose(mode: mode, hint: mode == .area ? "Drag over the area to record" : "Click the window to record")
            else { return }
            DesktopIconHider.hide()
            switch outcome {
            case .area(let rect, _):
                rememberArea(rect)
                guard let screen = ScreenGrabber.screen(containing: CGPoint(x: rect.midX, y: rect.midY)) else { return }
                target = .area(rect, screen)
            case .window(let window):
                target = .window(window)
            }
        } else {
            guard let screen = ScreenGrabber.screenUnderMouse else { return }
            target = .screen(screen)
        }
        await ScreenRecorder.shared.start(target, options: CaptureSettings.recording)
    }

    // MARK: Results

    /// Saves, copies, keeps and shows a new picture.
    func deliver(_ image: CGImage, kind: HistoryItem.Kind) {
        guard let encoded = CaptureFiles.encode(image, format: CaptureSettings.format) else {
            Toast.show("Couldn't save the capture", symbol: "exclamationmark.triangle.fill")
            return
        }
        let name = CaptureFiles.baseName()
        let size = CGSize(width: image.width, height: image.height)
        do {
            let file = try store(encoded.data, ext: encoded.ext, name: name, kind: kind, size: size, duration: nil)
            if CaptureSettings.copyToClipboard { CaptureFiles.copyImage(at: file.url) }
            present(CaptureResult(url: file.url, kind: kind, savedToFolder: file.saved, pixelSize: size))
        } catch {
            Toast.show("Couldn't save the capture", detail: error.localizedDescription, symbol: "exclamationmark.triangle.fill")
        }
    }

    /// A finished recording (or GIF) at a temporary location.
    func deliverRecording(_ temp: URL, kind: HistoryItem.Kind, size: CGSize, duration: Double,
                          track: CursorTrack? = nil, openStudio: Bool = false) {
        do {
            let data = try Data(contentsOf: temp, options: .mappedIfSafe)
            let file = try store(data, ext: temp.pathExtension, name: CaptureFiles.baseName("Spinform Recording"),
                                 kind: kind, size: size, duration: duration)
            try? FileManager.default.removeItem(at: temp)
            if let track { StudioTracks.save(track, for: [file.url] + (lastHistoryURL.map { [$0] } ?? [])) }
            if openStudio {
                StudioWindow.open(file.url)
                return
            }
            if CaptureSettings.copyToClipboard { CaptureFiles.copyFile(file.url) }
            present(CaptureResult(url: file.url, kind: kind, savedToFolder: file.saved, pixelSize: size, duration: duration))
        } catch {
            Toast.show("Couldn't save the recording", detail: error.localizedDescription, symbol: "exclamationmark.triangle.fill")
        }
    }

    /// Writes to the capture folder (when saving automatically) and the history. Returns the file to show.
    private func store(_ data: Data, ext: String, name: String, kind: HistoryItem.Kind, size: CGSize,
                       duration: Double?) throws -> (url: URL, saved: Bool) {
        var saved: URL?
        if CaptureSettings.autoSave {
            saved = try CaptureFiles.write(data, ext: ext, name: name, to: CaptureSettings.folder)
        }
        var kept: URL?
        lastHistoryURL = nil
        let days = CaptureSettings.historyDays
        if days > 0 {
            let source: URL
            if let saved {
                source = saved
            } else {
                source = OutputPaths.temporaryURL(ext: ext)
                try data.write(to: source, options: .atomic)
            }
            let item = try CaptureHistory.shared.add(file: source, kind: kind, width: Int(size.width), height: Int(size.height),
                                                     duration: duration)
            if saved == nil { try? FileManager.default.removeItem(at: source) }
            kept = CaptureHistory.shared.url(for: item)
            lastHistoryURL = kept
            CaptureHistory.shared.prune(keepingDays: days)
        }
        if let saved { return (saved, true) }
        if let kept { return (kept, false) }
        // Neither saving nor history: keep a temporary copy so the card still works.
        let temp = OutputPaths.temporaryURL(ext: ext).deletingLastPathComponent().appendingPathComponent("\(name).\(ext)")
        try data.write(to: temp, options: .atomic)
        return (temp, false)
    }

    private func present(_ result: CaptureResult) {
        if CaptureSettings.showOverlay || (!result.savedToFolder && !CaptureSettings.copyToClipboard) {
            QuickAccess.shared.show(result)
        } else if result.savedToFolder {
            Toast.show("Saved \(result.url.lastPathComponent)", detail: CaptureSettings.copyToClipboard ? "Also copied" : nil)
        } else {
            Toast.show("Copied to the clipboard")
        }
    }

    // MARK: Actions on results

    func copy(_ url: URL) {
        if url.pathExtension.lowercased() == "txt", let text = try? String(contentsOf: url, encoding: .utf8) {
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(text, forType: .string)
        } else if CaptureFiles.isVideo(url) {
            CaptureFiles.copyFile(url)
        } else {
            CaptureFiles.copyImage(at: url)
        }
        Toast.show("Copied")
    }

    /// The photo editor on its Markup tools, or the video editor for trimming.
    func edit(_ url: URL) {
        EditorWindow.open(url, startOnMarkup: true)
    }

    func makeGIF(from url: URL) {
        Toast.show("Making a GIF…", symbol: "photo.stack")
        Task {
            do {
                let gif = try await ScreenRecorder.convertToGIF(url)
                let size = (try? ImageConverter.loadCGImage(gif)).map { CGSize(width: $0.width, height: $0.height) } ?? .zero
                let asset = AVURLAsset(url: url)
                let seconds = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
                deliverRecording(gif, kind: .gif, size: size, duration: seconds)
            } catch {
                Toast.show("Couldn't make a GIF", detail: error.localizedDescription, symbol: "exclamationmark.triangle.fill")
            }
        }
    }
}
