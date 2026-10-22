import AppKit

/// spinform:// links for scripts, Shortcuts and other apps, for example
/// `open "spinform://capture-area"` or `open "spinform://ocr?file=/Users/me/scan.png"`.
enum AutomationCommand: Equatable {
    case action(CaptureAction)
    case stopRecording
    case restoreOverlay
    case hideOverlays
    case showOverlays
    case textFromFile(URL)
    case pin(URL)
    case annotate(URL)
    case frame(URL)
    case studio(URL)
    case openProject(URL)

    /// Every name the scheme understands, for Settings and the docs.
    static let names: [String] = [
        "capture", "capture-area", "capture-window", "capture-screen", "capture-previous", "capture-scrolling",
        "ocr", "record", "record-area", "record-window", "record-screen", "stop-recording", "history",
        "restore-overlay", "hide-overlays", "show-overlays", "pin?file=…", "annotate?file=…", "frame?file=…",
        "studio?file=…", "ocr?file=…",
    ]

    static func parse(_ url: URL) -> AutomationCommand? {
        guard url.scheme?.lowercased() == "spinform" else { return nil }
        // spinform://capture-area and spinform:capture-area both work.
        var name = (url.host ?? "").lowercased()
        if name.isEmpty {
            name = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        }
        let file = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "file" || $0.name == "path" }?.value
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        switch name {
        case "capture", "all-in-one": return .action(.allInOne)
        case "capture-area", "area": return .action(.area)
        case "capture-window", "window": return .action(.window)
        case "capture-screen", "capture-fullscreen", "fullscreen": return .action(.fullscreen)
        case "capture-previous", "previous": return .action(.previous)
        case "capture-scrolling", "scrolling": return .action(.scrolling)
        case "ocr", "copy-text", "text":
            if let file { return .textFromFile(file) }
            return .action(.text)
        case "record", "record-area": return .action(.recordArea)
        case "record-window": return .action(.recordWindow)
        case "record-screen": return .action(.recordScreen)
        case "stop-recording", "stop": return .stopRecording
        case "history": return .action(.history)
        case "restore-overlay", "restore": return .restoreOverlay
        case "hide-overlays": return .hideOverlays
        case "show-overlays": return .showOverlays
        case "pin": return file.map { .pin($0) }
        case "annotate", "edit": return file.map { .annotate($0) }
        case "frame", "background": return file.map { .frame($0) }
        case "studio": return file.map { .studio($0) }
        case "open": return file.map { .openProject($0) }
        default: return nil
        }
    }

    @MainActor
    func run() {
        switch self {
        case .action(let action): CaptureCoordinator.shared.perform(action)
        case .stopRecording: ScreenRecorder.shared.stop()
        case .restoreOverlay: QuickAccess.shared.restoreLast()
        case .hideOverlays: QuickAccess.shared.setHidden(true)
        case .showOverlays: QuickAccess.shared.setHidden(false)
        case .textFromFile(let url): CaptureCoordinator.shared.recognizeText(inFile: url)
        case .pin(let url): PinController.open(url: url)
        case .annotate(let url): EditorWindow.open(url, startOnMarkup: true)
        case .frame(let url): FrameToolWindow.open(url)
        case .studio(let url): StudioWindow.open(url)
        case .openProject(let url): ProjectOpener.open(url)
        }
    }
}

/// Opens .spinform projects in the photo editor with every edit still editable.
@MainActor
enum ProjectOpener {
    static func open(_ url: URL) {
        do {
            let unpacked = try SpinformProject.open(url)
            EditorWindow.open(unpacked.image, startOnMarkup: true, initialEdit: unpacked.edit, projectURL: url,
                              saveFolder: url.deletingLastPathComponent())
        } catch {
            Toast.show("Couldn't open the project", detail: error.localizedDescription, symbol: "exclamationmark.triangle.fill")
        }
    }

    static func choose() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [SpinformProject.contentType]
        panel.prompt = "Open Project"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
}
