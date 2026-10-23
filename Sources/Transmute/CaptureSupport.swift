import AppKit
import ApplicationServices
import AVFoundation
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings

extension Prefs {
    static let captureFolder = "captureFolderPath"
    static let captureFormat = "captureImageFormat"
    static let captureAutoSave = "captureSaveAutomatically"
    static let captureCopy = "captureCopyToClipboard"
    static let captureOverlay = "captureShowOverlay"
    static let overlayCorner = "captureOverlayCorner"
    static let overlaySeconds = "captureOverlaySeconds"
    static let windowShadow = "captureWindowShadow"
    static let hideDesktopIcons = "captureHideDesktopIcons"
    static let captureTimer = "captureSelfTimer"
    static let historyDays = "captureHistoryDays"
    static let recordFPS = "recordFrameRate"
    static let recordQuality = "recordQuality"
    static let recordFormat = "recordFormat"
    static let recordMic = "recordMicrophone"
    static let recordSystemAudio = "recordSystemAudio"
    static let recordClicks = "recordShowClicks"
    static let recordKeys = "recordShowKeystrokes"
    static let recordCamera = "recordCamera"
    static let captureFreeze = "captureFreezeScreen"
    static let captureCrosshair = "captureShowCrosshair"
    static let captureMagnifier = "captureShowMagnifier"
    static let windowBackground = "captureWindowBackground"
    static let windowBackgroundColor = "captureWindowBackgroundColor"
    static let windowBackgroundImage = "captureWindowBackgroundImage"
    static let windowPadding = "captureWindowPadding"
    static let overlaySize = "captureOverlaySize"
    static let recordScale = "recordResolution"
    static let recordCursor = "recordShowCursor"
    static let recordHideDesktop = "recordHideDesktop"
    static let recordStudio = "recordStudioMode"
    static let clickColor = "recordClickColor"
    static let clickSize = "recordClickSize"
    static let clickFilled = "recordClickFilled"
    static let clickAnimate = "recordClickAnimate"
    static let keysPosition = "recordKeysPosition"
    static let keysSize = "recordKeysSize"
    static let keysLight = "recordKeysLight"
    static let keysShortcutsOnly = "recordKeysShortcutsOnly"
    static let cameraPosition = "recordCameraPosition"
    static let cameraSize = "recordCameraSize"
    static let cameraShape = "recordCameraShape"
    static let cameraFull = "recordCameraFull"
    static let ocrLanguage = "ocrLanguage"
    static let ocrKeepLineBreaks = "ocrKeepLineBreaks"

    static func registerCaptureDefaults() {
        UserDefaults.standard.register(defaults: [
            captureFormat: CaptureImageFormat.png.rawValue,
            captureAutoSave: true,
            captureCopy: false,
            captureOverlay: true,
            overlayCorner: "left",
            overlaySeconds: 10,
            windowShadow: true,
            hideDesktopIcons: false,
            captureTimer: 0,
            historyDays: 30,
            recordFPS: 30,
            recordQuality: "high",
            recordFormat: "mp4",
            recordMic: false,
            recordSystemAudio: false,
            recordClicks: true,
            recordKeys: false,
            recordCamera: false,
            captureFreeze: true,
            captureCrosshair: true,
            captureMagnifier: true,
            windowBackground: WindowBackdrop.shadow.rawValue,
            windowBackgroundColor: 0x4338CA,
            windowPadding: 0.06,
            overlaySize: "medium",
            recordScale: "full",
            recordCursor: true,
            recordHideDesktop: false,
            recordStudio: false,
            clickColor: 0x8B5CF6,
            clickSize: 64.0,
            clickFilled: true,
            clickAnimate: true,
            keysPosition: "bottom",
            keysSize: "medium",
            keysLight: false,
            keysShortcutsOnly: false,
            cameraPosition: "bottomRight",
            cameraSize: "medium",
            cameraShape: "circle",
            cameraFull: false,
            ocrLanguage: "",
            ocrKeepLineBreaks: true,
        ])
    }
}

enum CaptureImageFormat: String, CaseIterable, Identifiable {
    case png, jpeg, heic
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    var utType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        }
    }
}

/// Capture settings as plain values, read when they're needed.
enum CaptureSettings {
    private static var defaults: UserDefaults { .standard }

    /// Where captures are saved: the chosen folder, or the Desktop like macOS's own screenshots.
    static var folder: URL {
        if let path = defaults.string(forKey: Prefs.captureFolder), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    static var format: CaptureImageFormat {
        CaptureImageFormat(rawValue: defaults.string(forKey: Prefs.captureFormat) ?? "") ?? .png
    }

    static var autoSave: Bool { defaults.bool(forKey: Prefs.captureAutoSave) }
    static var copyToClipboard: Bool { defaults.bool(forKey: Prefs.captureCopy) }
    static var showOverlay: Bool { defaults.bool(forKey: Prefs.captureOverlay) }
    static var overlayOnRight: Bool { (defaults.string(forKey: Prefs.overlayCorner) ?? "").hasSuffix("right") }
    static var overlayOnTop: Bool { (defaults.string(forKey: Prefs.overlayCorner) ?? "").hasPrefix("top") }
    /// The quick access card's size as a multiple of the standard size.
    static var overlayScale: CGFloat {
        switch defaults.string(forKey: Prefs.overlaySize) {
        case "small": 0.8
        case "large": 1.25
        default: 1
        }
    }
    static var freezeScreen: Bool { defaults.bool(forKey: Prefs.captureFreeze) }
    static var showCrosshair: Bool { defaults.bool(forKey: Prefs.captureCrosshair) }
    static var showMagnifier: Bool { defaults.bool(forKey: Prefs.captureMagnifier) }
    static var windowBackdrop: WindowBackdrop {
        WindowBackdrop(rawValue: defaults.string(forKey: Prefs.windowBackground) ?? "") ?? .shadow
    }
    static var windowBackdropColor: UInt32 { UInt32(truncatingIfNeeded: defaults.integer(forKey: Prefs.windowBackgroundColor)) }
    static var windowBackdropImage: URL? {
        guard let path = defaults.string(forKey: Prefs.windowBackgroundImage), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
    static var windowPadding: Double { defaults.double(forKey: Prefs.windowPadding) }
    static var overlaySeconds: Int { defaults.integer(forKey: Prefs.overlaySeconds) }
    static var windowShadow: Bool { windowBackdrop != .transparent }
    static var hideDesktopIcons: Bool { defaults.bool(forKey: Prefs.hideDesktopIcons) }
    static var selfTimer: Int { defaults.integer(forKey: Prefs.captureTimer) }
    /// 0 keeps no history.
    static var historyDays: Int { defaults.integer(forKey: Prefs.historyDays) }

    static var recording: RecordingOptions {
        RecordingOptions(
            fps: max(10, min(60, defaults.integer(forKey: Prefs.recordFPS) == 0 ? 30 : defaults.integer(forKey: Prefs.recordFPS))),
            high: defaults.string(forKey: Prefs.recordQuality) != "standard",
            gif: defaults.string(forKey: Prefs.recordFormat) == "gif",
            microphone: defaults.bool(forKey: Prefs.recordMic),
            systemAudio: defaults.bool(forKey: Prefs.recordSystemAudio),
            clicks: defaults.bool(forKey: Prefs.recordClicks),
            keystrokes: defaults.bool(forKey: Prefs.recordKeys),
            camera: defaults.bool(forKey: Prefs.recordCamera),
            maxHeight: { () -> Int? in
                switch defaults.string(forKey: Prefs.recordScale) {
                case "1080": return 1080
                case "720": return 720
                default: return nil
                }
            }(),
            cursor: defaults.bool(forKey: Prefs.recordCursor),
            hideDesktop: defaults.bool(forKey: Prefs.recordHideDesktop),
            studio: defaults.bool(forKey: Prefs.recordStudio))
    }
}

/// What goes behind a window capture.
enum WindowBackdrop: String, CaseIterable, Identifiable {
    /// Just the window, transparent around its rounded corners.
    case transparent
    /// The window with its shadow, on transparency.
    case shadow
    /// The window on the desktop picture, with padding.
    case desktop
    /// The window on a solid colour, with padding.
    case color
    /// The window on a picture of your choice, with padding.
    case image

    var id: String { rawValue }

    var label: String {
        switch self {
        case .transparent: "Transparent, no shadow"
        case .shadow: "Transparent with shadow"
        case .desktop: "On the desktop picture"
        case .color: "On a colour"
        case .image: "On a picture…"
        }
    }

    var usesBackground: Bool { self == .desktop || self == .color || self == .image }
}

struct RecordingOptions: Equatable, Sendable {
    var fps = 30
    var high = true
    var gif = false
    var microphone = false
    var systemAudio = false
    var clicks = true
    var keystrokes = false
    var camera = false
    /// Caps the recording's height (1080 or 720), nil for full resolution.
    var maxHeight: Int? = nil
    var cursor = true
    var hideDesktop = false
    /// Records without the pointer, keeps its path, and opens Studio afterwards.
    var studio = false
}

// MARK: - Permissions

enum PermissionKind: String, CaseIterable {
    case screen, microphone, camera, accessibility

    var title: String {
        switch self {
        case .screen: "Screen Recording"
        case .microphone: "Microphone"
        case .camera: "Camera"
        case .accessibility: "Accessibility"
        }
    }

    /// The pane in System Settings → Privacy & Security.
    var settingsURL: URL {
        let anchor: String
        switch self {
        case .screen: anchor = "Privacy_ScreenCapture"
        case .microphone: anchor = "Privacy_Microphone"
        case .camera: anchor = "Privacy_Camera"
        case .accessibility: anchor = "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    var explanation: String {
        switch self {
        case .screen:
            "Spinform needs Screen Recording permission to take screenshots and record your screen. Everything stays on this Mac."
        case .microphone:
            "Spinform needs the microphone to record your voice with a screen recording."
        case .camera:
            "Spinform needs the camera to show the webcam bubble in a screen recording."
        case .accessibility:
            "Spinform needs Accessibility permission to show the keys you press in a screen recording."
        }
    }
}

enum PermissionState: String {
    case granted, denied, notDetermined
}

enum CapturePermissions {
    static func state(_ kind: PermissionKind) -> PermissionState {
        switch kind {
        case .screen:
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .microphone:
            return state(AVCaptureDevice.authorizationStatus(for: .audio))
        case .camera:
            return state(AVCaptureDevice.authorizationStatus(for: .video))
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        }
    }

    private static func state(_ status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    static var screenRecording: Bool { state(.screen) == .granted }

    static func openSettings(_ kind: PermissionKind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }

    /// Asks for camera or microphone access when macOS hasn't asked yet. True when allowed.
    static func requestMedia(_ kind: PermissionKind) async -> Bool {
        let type: AVMediaType = kind == .camera ? .video : .audio
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }

    /// Shows macOS's own Accessibility prompt (only when the keystroke option is turned on).
    @discardableResult
    static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}

/// A friendly explanation with a button that opens the right System Settings pane.
@MainActor
enum PermissionPrompt {
    static func show(_ kind: PermissionKind) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow \(kind.title) for Spinform"
        var info = kind.explanation
        info += "\n\nIn System Settings → Privacy & Security → \(kind == .screen ? "Screen & System Audio Recording" : kind.title), turn on Spinform."
        if kind == .screen || kind == .accessibility {
            info += " Then quit and reopen Spinform."
            info += "\n\nIf Spinform is already switched on, macOS may be remembering an older copy of the app: select Spinform, remove it with the – button, then add it again (or switch it off and on)."
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        // Nothing else is on screen while this asks: capture overlays are never up at the same time.
        CaptureCleanup.closeAll()
        if alert.runModal() == .alertFirstButtonReturn {
            // Puts Spinform in the list (needed after the entry was reset), then opens the pane.
            if kind == .screen { _ = CGRequestScreenCaptureAccess() }
            CapturePermissions.openSettings(kind)
        }
    }

    /// Opens a fresh copy of Spinform and quits this one (macOS applies a new permission on relaunch).
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}

// MARK: - Deadlines

/// Why a capture couldn't go ahead.
enum CaptureFailure: LocalizedError, Equatable {
    /// macOS refused the screen (Screen Recording is off, or its entry is stale after an update).
    case screenPermission
    /// macOS didn't answer in time.
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .screenPermission: "macOS didn't allow Spinform to see the screen."
        case .timedOut(let what): "\(what) took too long. Try again; if it keeps happening, check Screen Recording permission."
        }
    }
}

/// Runs async work with a deadline. When it's late the caller gets `CaptureFailure.timedOut` straight
/// away, so a stuck system call can never hold up the capture tools (the work is cancelled and left to end).
enum Deadline {
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    static func run<T>(_ seconds: Double, _ what: String, _ work: @escaping () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = Once()
            let task = Task {
                do {
                    let value = try await work()
                    if once.claim() { continuation.resume(returning: value) }
                } catch {
                    if once.claim() { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if once.claim() {
                    task.cancel()
                    continuation.resume(throwing: CaptureFailure.timedOut(what))
                }
            }
        }
    }
}

// MARK: - Grabbing pixels

/// A picture of one whole screen, frozen while the user picks what to keep.
struct DisplayShot: @unchecked Sendable {
    let image: CGImage
    /// The screen's frame in global AppKit points (bottom-left origin).
    let frame: CGRect
    let displayID: CGDirectDisplayID

    /// Pixels per point in `image`.
    var scale: CGFloat { CGFloat(image.width) / max(1, frame.width) }
}

/// An on-screen window under the pointer, for window capture.
struct WindowInfo: Equatable, Sendable {
    let id: CGWindowID
    /// Global AppKit points (bottom-left origin).
    let frame: CGRect
    let owner: String
}

enum ScreenGrabber {
    /// How long macOS gets to answer a screen question before the capture gives up.
    static let systemTimeout = 8.0

    /// What's on screen, with a deadline. A refusal from macOS becomes `CaptureFailure.screenPermission`.
    static func shareableContent(excludingDesktopWindows: Bool = false) async throws -> SCShareableContent {
        do {
            return try await Deadline.run(systemTimeout, "Asking macOS for the screen") {
                try await SCShareableContent.excludingDesktopWindows(excludingDesktopWindows, onScreenWindowsOnly: true)
            }
        } catch let failure as CaptureFailure {
            throw failure
        } catch {
            throw permissionAware(error)
        }
    }

    @available(macOS 14.0, *)
    static func screenshot(_ filter: SCContentFilter, _ config: SCStreamConfiguration) async throws -> CGImage {
        do {
            return try await Deadline.run(systemTimeout, "Taking the screenshot") {
                try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            }
        } catch let failure as CaptureFailure {
            throw failure
        } catch {
            throw permissionAware(error)
        }
    }

    /// ScreenCaptureKit's "user declined" (and a missing permission) as a permission failure.
    static func permissionAware(_ error: Error) -> Error {
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain && ns.code == -3801 { return CaptureFailure.screenPermission }
        if !CGPreflightScreenCaptureAccess() { return CaptureFailure.screenPermission }
        return error
    }

    /// Takes the same area again and again (scrolling capture) without asking macOS for the
    /// screen list each time.
    @MainActor
    final class AreaCapturer {
        let rect: CGRect
        private var prepared: Any?

        init(rect: CGRect) { self.rect = rect }

        func capture() async throws -> CGImage {
            guard #available(macOS 14.0, *) else {
                return try await ScreenGrabber.captureArea(rect, excludingSelf: true)
            }
            if prepared == nil {
                guard let screen = ScreenGrabber.screen(containing: CGPoint(x: rect.midX, y: rect.midY)) else {
                    throw ConversionError("That area isn't on a screen.")
                }
                let area = rect.intersection(screen.frame)
                guard area.width >= 1, area.height >= 1 else { throw ConversionError("That area isn't on a screen.") }
                let id = ScreenGrabber.displayID(of: screen)
                let content = try await ScreenGrabber.shareableContent()
                guard let display = content.displays.first(where: { $0.displayID == id }) else {
                    throw ConversionError("Couldn't find that screen.")
                }
                let me = ProcessInfo.processInfo.processIdentifier
                let filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.processID == me },
                                             exceptingWindows: [])
                let config = ScreenGrabber.stillConfig()
                config.sourceRect = ScreenGrabber.localRect(area, in: screen.frame)
                config.width = max(1, Int((area.width * screen.backingScaleFactor).rounded()))
                config.height = max(1, Int((area.height * screen.backingScaleFactor).rounded()))
                config.showsCursor = false
                prepared = (filter, config)
            }
            guard let pair = prepared as? (SCContentFilter, SCStreamConfiguration) else {
                throw ConversionError("Couldn't set up the capture.")
            }
            return try await ScreenGrabber.screenshot(pair.0, pair.1)
        }
    }

    /// A still-picture setup that asks for every Retina pixel (`.automatic` may hand back a
    /// point-sized frame scaled up, which looks soft).
    @available(macOS 14.0, *)
    static func stillConfig() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.captureResolution = .best
        config.scalesToFit = false
        return config
    }

    /// Pixels per point of the last picture taken, saved as its DPI.
    @MainActor static var lastScale: CGFloat = 2

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number?.uint32Value ?? CGMainDisplayID()
    }

    @MainActor
    static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }

    @MainActor
    static var screenUnderMouse: NSScreen? { screen(containing: NSEvent.mouseLocation) }

    /// Height of the screen that holds the menu bar; CoreGraphics' global y runs down from its top.
    @MainActor
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// A global AppKit rectangle as CoreGraphics global coordinates (top-left origin).
    static func cgRect(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// A global AppKit rectangle relative to its screen, top-left origin (what ScreenCaptureKit expects).
    static func localRect(_ rect: CGRect, in screenFrame: CGRect) -> CGRect {
        CGRect(x: rect.minX - screenFrame.minX, y: screenFrame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The pixels of `rect` (global AppKit points) cut from a frozen screen picture.
    static func pixelRect(of rect: CGRect, in shot: (frame: CGRect, width: Int, height: Int)) -> CGRect {
        let scale = CGFloat(shot.width) / max(1, shot.frame.width)
        let local = localRect(rect.intersection(shot.frame), in: shot.frame)
        let x = (local.minX * scale).rounded()
        let y = (local.minY * scale).rounded()
        let w = min((local.width * scale).rounded(), CGFloat(shot.width) - x)
        let h = min((local.height * scale).rounded(), CGFloat(shot.height) - y)
        return CGRect(x: max(0, x), y: max(0, y), width: max(1, w), height: max(1, h))
    }

    static func crop(_ shot: DisplayShot, to rect: CGRect) -> CGImage? {
        let pixels = pixelRect(of: rect, in: (frame: shot.frame, width: shot.image.width, height: shot.image.height))
        return shot.image.cropping(to: pixels)
    }

    /// Every screen, as it is now, without the pointer.
    @MainActor
    static func captureAllScreens() async throws -> [DisplayShot] {
        var shots: [DisplayShot] = []
        for screen in NSScreen.screens {
            shots.append(try await captureScreen(screen))
        }
        return shots
    }

    @MainActor
    static func captureScreen(_ screen: NSScreen) async throws -> DisplayShot {
        let id = displayID(of: screen)
        let frame = screen.frame
        let scale = screen.backingScaleFactor
        lastScale = scale
        let image: CGImage
        if #available(macOS 14.0, *) {
            let content = try await shareableContent()
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw ConversionError("Couldn't find that screen.")
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = stillConfig()
            config.width = max(1, Int((frame.width * scale).rounded()))
            config.height = max(1, Int((frame.height * scale).rounded()))
            config.showsCursor = false
            image = try await screenshot(filter, config)
        } else {
            guard let legacy = CGWindowListCreateImage(CGDisplayBounds(id), .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) else {
                throw ConversionError("macOS didn't hand over the screen. Check Screen Recording permission.")
            }
            image = legacy
        }
        return DisplayShot(image: image, frame: frame, displayID: id)
    }

    /// One area of the screen as it is now. With `excludingSelf`, Spinform's own windows are left out
    /// (the scrolling-capture frame and buttons).
    @MainActor
    static func captureArea(_ rect: CGRect, excludingSelf: Bool) async throws -> CGImage {
        guard let screen = screen(containing: CGPoint(x: rect.midX, y: rect.midY)) else {
            throw ConversionError("That area isn't on a screen.")
        }
        let area = rect.intersection(screen.frame)
        guard area.width >= 1, area.height >= 1 else { throw ConversionError("That area isn't on a screen.") }
        let scale = screen.backingScaleFactor
        lastScale = scale
        if #available(macOS 14.0, *) {
            let id = displayID(of: screen)
            let content = try await shareableContent()
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw ConversionError("Couldn't find that screen.")
            }
            let me = ProcessInfo.processInfo.processIdentifier
            let mine = excludingSelf ? content.applications.filter { $0.processID == me } : []
            let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            let config = stillConfig()
            config.sourceRect = localRect(area, in: screen.frame)
            config.width = max(1, Int((area.width * scale).rounded()))
            config.height = max(1, Int((area.height * scale).rounded()))
            config.showsCursor = false
            return try await screenshot(filter, config)
        }
        let global = cgRect(area, primaryHeight: primaryHeight)
        guard let image = CGWindowListCreateImage(global, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) else {
            throw ConversionError("macOS didn't hand over the screen. Check Screen Recording permission.")
        }
        return image
    }

    /// One window on its own, with the shadow drawn around it when asked.
    @MainActor
    static func captureWindow(_ window: WindowInfo, shadow: Bool) async throws -> CGImage {
        let scale = screen(containing: CGPoint(x: window.frame.midX, y: window.frame.midY))?.backingScaleFactor ?? 2
        lastScale = scale
        var image: CGImage
        if #available(macOS 14.0, *) {
            let content = try await shareableContent(excludingDesktopWindows: true)
            guard let scWindow = content.windows.first(where: { $0.windowID == window.id }) else {
                throw ConversionError("That window closed.")
            }
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = stillConfig()
            config.width = max(1, Int((scWindow.frame.width * scale).rounded()))
            config.height = max(1, Int((scWindow.frame.height * scale).rounded()))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            image = try await screenshot(filter, config)
        } else {
            guard let legacy = CGWindowListCreateImage(.null, .optionIncludingWindow, window.id,
                                                       [.boundsIgnoreFraming, .bestResolution]) else {
                throw ConversionError("macOS didn't hand over the window. Check Screen Recording permission.")
            }
            image = legacy
        }
        if shadow, let shaded = WindowShadow.add(to: image, scale: scale) { image = shaded }
        return image
    }

    /// Normal app windows on screen, front to back, without Spinform's own.
    @MainActor
    static func onScreenWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        let top = primaryHeight
        return list.compactMap { info -> WindowInfo? in
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != me,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary),
                  bounds.width >= 40, bounds.height >= 40 else { return nil }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.05 else { return nil }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let frame = CGRect(x: bounds.minX, y: top - bounds.maxY, width: bounds.width, height: bounds.height)
            return WindowInfo(id: number, frame: frame, owner: owner)
        }
    }
}

/// A soft drop shadow around a window picture, like the one macOS draws.
enum WindowShadow {
    static func padding(scale: CGFloat) -> CGFloat { 40 * scale }

    static func add(to image: CGImage, scale: CGFloat) -> CGImage? {
        let pad = padding(scale: scale)
        let width = image.width + Int(pad * 2)
        let height = image.height + Int(pad * 2)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: pad, y: pad + 6 * scale, width: CGFloat(image.width), height: CGFloat(image.height))
        ctx.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 34 * scale, color: CGColor(gray: 0, alpha: 0.42))
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }
}

// MARK: - Files

enum CaptureFiles {
    /// "Spinform 2026-10-22 at 10.15.32", like macOS's own screenshot names.
    static func baseName(_ prefix: String = "Spinform", date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(prefix) \(formatter.string(from: date))"
    }

    /// Encodes in the chosen format; HEIC falls back to PNG on Macs that can't write it.
    /// Pixels are kept exactly as captured; `scale` (pixels per point) is saved as DPI (72 × scale).
    static func encode(_ image: CGImage, format: CaptureImageFormat, scale: CGFloat = 1) -> (data: Data, ext: String)? {
        let dpi = 72 * Double(max(1, scale))
        if let data = try? ImageConverter.data(from: image, type: format.utType, quality: 0.95, dpi: dpi) {
            return (data, format.fileExtension)
        }
        guard format != .png, let png = try? ImageConverter.data(from: image, type: .png, dpi: dpi) else { return nil }
        return (png, "png")
    }

    static func write(_ data: Data, ext: String, name: String, to folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = OutputPaths.unique(in: folder, base: name, ext: ext)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func copyImage(at url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([image])
    }

    static func copyFile(_ url: URL) {
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([url as NSURL])
    }

    static func isVideo(_ url: URL) -> Bool { FileKind.of(url) == .video }

    /// Lets the user pick a name and place, starting from the capture folder.
    @MainActor
    static func saveAs(_ url: URL) -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.directoryURL = CaptureSettings.folder
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let target = panel.url else { return nil }
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.copyItem(at: url, to: target)
            return target
        } catch {
            Toast.show("Couldn't save", detail: error.localizedDescription, symbol: "exclamationmark.triangle.fill")
            return nil
        }
    }
}

// MARK: - Panels

/// A borderless panel that can take key presses without bringing Spinform to the front.
final class KeyPanel: NSPanel {
    var onEscape: (() -> Void)?
    /// Arrow keys: the distance to move, in points (Shift moves ten times as far).
    var onArrow: ((CGFloat, CGFloat) -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, let onEscape {
            onEscape()
        } else if let onArrow, let step = Self.arrowStep(keyCode: event.keyCode, shift: event.modifierFlags.contains(.shift)) {
            onArrow(step.dx, step.dy)
        } else {
            super.keyDown(with: event)
        }
    }

    /// How far an arrow key nudges (AppKit's y runs up), or nil for other keys.
    static func arrowStep(keyCode: UInt16, shift: Bool) -> (dx: CGFloat, dy: CGFloat)? {
        let step: CGFloat = shift ? 10 : 1
        switch keyCode {
        case 123: return (-step, 0)
        case 124: return (step, 0)
        case 125: return (0, -step)
        case 126: return (0, step)
        default: return nil
        }
    }

    static func floating(_ rect: NSRect, level: NSWindow.Level = .floating, clickThrough: Bool = false) -> KeyPanel {
        let panel = KeyPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = level
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = clickThrough
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }
}

/// A hosting view whose buttons work on the first click, even when Spinform isn't the active app.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A hosting view that reports a sideways two-finger swipe (for dismissing cards).
final class SwipeHostingView<Content: View>: NSHostingView<Content> {
    var onSwipe: ((CGFloat) -> Void)?
    private var travelled: CGFloat = 0

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else {
            super.scrollWheel(with: event)
            return
        }
        if event.phase == .began { travelled = 0 }
        travelled += event.scrollingDeltaX
        if abs(travelled) > 70 {
            let direction = travelled
            travelled = 0
            onSwipe?(direction)
        }
        if event.phase == .ended || event.phase == .cancelled { travelled = 0 }
    }
}

/// An area that moves its window when dragged (for borderless floating windows).
struct WindowDragArea: NSViewRepresentable {
    var onScroll: ((CGFloat) -> Void)? = nil

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.onScroll = onScroll
    }

    final class DragView: NSView {
        var onScroll: ((CGFloat) -> Void)?

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func scrollWheel(with event: NSEvent) {
            if let onScroll { onScroll(event.scrollingDeltaY) } else { super.scrollWheel(with: event) }
        }

        override func magnify(with event: NSEvent) {
            onScroll?(event.magnification * 40)
        }
    }
}

// MARK: - Toast

/// A short confirmation at the top of the screen ("Text copied").
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var generation = 0

    static func show(_ title: String, detail: String? = nil, symbol: String = "checkmark.circle.fill") {
        generation += 1
        let current = generation
        let panel = self.panel ?? KeyPanel.floating(.zero, level: .statusBar, clickThrough: true)
        self.panel = panel
        let size = CGSize(width: 360, height: detail == nil ? 52 : 70)
        panel.contentView = NSHostingView(rootView: ToastView(title: title, detail: detail, symbol: symbol))
        if let screen = ScreenGrabber.screenUnderMouse {
            let visible = screen.visibleFrame
            panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 12,
                                  width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if generation == current { panel.orderOut(nil) }
        }
    }
}

struct ToastView: View {
    let title: String
    let detail: String?
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(symbol.contains("exclamation") ? Theme.warning : Theme.success)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Fonts.bodyStrong).foregroundStyle(Theme.textPrimary).lineLimit(1)
                if let detail {
                    Text(detail).font(Theme.Fonts.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .floatingPanel()
        .padding(4)
        .appearIn()
    }
}
