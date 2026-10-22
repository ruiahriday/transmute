import AppKit
import SwiftUI

/// The Capture tab in the main window: every screenshot, recording and text tool with its shortcut.
struct CaptureHomeView: View {
    @ObservedObject var history: CaptureHistory = .shared
    @ObservedObject var recorder: ScreenRecorder = .shared
    @AppStorage(Prefs.captureTimer) private var timer = 0
    @AppStorage(Prefs.hideDesktopIcons) private var hideIcons = false
    @AppStorage(Prefs.windowBackground) private var backdrop = WindowBackdrop.shadow.rawValue
    @AppStorage(Prefs.recordStudio) private var studio = false
    @AppStorage(Prefs.recordMic) private var mic = false
    @AppStorage(Prefs.recordSystemAudio) private var systemAudio = false
    @AppStorage(Prefs.recordClicks) private var clicks = true
    @AppStorage(Prefs.recordKeys) private var keys = false
    @AppStorage(Prefs.recordCamera) private var camera = false
    @AppStorage(Prefs.recordFormat) private var recordFormat = "mp4"
    @State private var permitted = CapturePermissions.screenRecording
    @State private var lockedPins = PinController.lockedCount
    @State private var pinCount = PinController.all.count
    /// Lets the window pictures show the banner whatever this Mac allows.
    var showBanner: Bool? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if showBanner ?? !permitted { PermissionBanner(kind: .screen) }
                screenshotCard
                recordCard
                toolsCard
                if !history.items.isEmpty { recentCard }
            }
            .padding(.bottom, 4)
        }
        .scrollContentBackground(.hidden)
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: PinController.didChange)) { _ in refresh() }
    }

    private func refresh() {
        permitted = CapturePermissions.screenRecording
        lockedPins = PinController.lockedCount
        pinCount = PinController.all.count
    }

    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 8), count: 6) }

    private var screenshotCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Screenshot")
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach([CaptureAction.allInOne, .area, .window, .fullscreen, .previous, .scrolling]) { action in
                    CaptureTile(action: action)
                }
            }
            HStack(spacing: 14) {
                Picker("Self-timer", selection: $timer) {
                    Text("No timer").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
                .frame(width: 210)
                Toggle("Hide desktop icons", isOn: $hideIcons).toggleStyle(CrispCheckboxStyle())
                Picker("Window", selection: $backdrop) {
                    ForEach(WindowBackdrop.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .frame(width: 250)
                Spacer()
            }
            .font(Theme.Fonts.body)
        }
        .crispCard()
    }

    private var recordCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("Screen recording")
                Spacer()
                if recorder.isActive {
                    Button { recorder.stop() } label: { Label("Stop Recording", systemImage: "stop.fill") }
                        .buttonStyle(GlowButtonStyle())
                }
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach([CaptureAction.recordArea, .recordWindow, .recordScreen]) { action in
                    CaptureTile(action: action, recording: true)
                }
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 14) {
                        Toggle("Microphone", isOn: $mic).toggleStyle(CrispCheckboxStyle())
                        Toggle("Mac sound", isOn: $systemAudio).toggleStyle(CrispCheckboxStyle())
                        Toggle("Camera", isOn: $camera).toggleStyle(CrispCheckboxStyle())
                    }
                    HStack(spacing: 14) {
                        Toggle("Show clicks", isOn: $clicks).toggleStyle(CrispCheckboxStyle())
                        Toggle("Show keys", isOn: $keys).toggleStyle(CrispCheckboxStyle())
                            .help("Shows the keys you press; needs Accessibility permission")
                        Toggle("Studio", isOn: $studio).toggleStyle(CrispCheckboxStyle())
                            .help("Smooth pointer and automatic zooms, finished in Studio")
                    }
                    Picker("Save as", selection: $recordFormat) {
                        Text("MP4 video").tag("mp4")
                        Text("GIF").tag("gif")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
                .padding(.leading, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .crispCard()
    }

    private var toolsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Tools")
            LazyVGrid(columns: columns, spacing: 8) {
                CaptureTile(action: .text)
                ToolTile(title: "Text from File", symbol: "doc.text.magnifyingglass", detail: "Image or PDF") {
                    CaptureCoordinator.shared.recognizeTextInFile()
                }
                ToolTile(title: "Background Frame", symbol: "photo.artframe", detail: "For sharing") {
                    FrameToolWindow.choose()
                }
                ToolTile(title: "Pin Image", symbol: "pin", detail: pinCount > 0 ? "\(pinCount) pinned" : "Always on top") {
                    PinController.choose()
                }
                CaptureTile(action: .history)
                ToolTile(title: "Studio", symbol: "wand.and.stars", detail: "Zooms & pointer") {
                    StudioWindow.choose()
                }
                ToolTile(title: "Open Project", symbol: "square.stack.3d.up", detail: ".spinform") {
                    ProjectOpener.choose()
                }
            }
            if lockedPins > 0 {
                HStack(spacing: 8) {
                    Label("\(lockedPins) pinned picture\(lockedPins == 1 ? " is" : "s are") locked; clicks pass through.",
                          systemImage: "lock.fill")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Button("Unlock") { PinController.unlockAll() }.buttonStyle(ChipButtonStyle())
                    Button("Close All") { PinController.closeAll() }.buttonStyle(ChipButtonStyle())
                }
            }
        }
        .crispCard()
    }

    private var recentCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("Recent")
                Spacer()
                Button("Show All") { HistoryWindow.show() }.buttonStyle(ChipButtonStyle())
            }
            HStack(spacing: 8) {
                ForEach(Array(history.items.prefix(5))) { item in
                    let url = history.url(for: item)
                    ThumbnailView(url: url)
                        .frame(maxWidth: .infinity)
                        .frame(height: 70)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).strokeBorder(Theme.hairline))
                        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                        .help("\(item.kind.label), \(item.date.formatted(date: .abbreviated, time: .shortened)). Drag it anywhere; double-click to open.")
                }
            }
        }
        .crispCard()
    }
}

/// A big button for one capture action, with its shortcut underneath.
struct CaptureTile: View {
    let action: CaptureAction
    var recording = false

    var body: some View {
        ToolTile(title: action.shortTitle, symbol: action.symbol, detail: HotkeyStore.hotkey(for: action)?.display,
                 tint: recording ? AnyShapeStyle(LinearGradient(colors: [Theme.pink, Theme.rose], startPoint: .topLeading,
                                                                endPoint: .bottomTrailing)) : nil) {
            CaptureCoordinator.shared.perform(action)
        }
        .help(action.title)
    }
}

struct ToolTile: View {
    let title: String
    let symbol: String
    var detail: String?
    var tint: AnyShapeStyle? = nil
    let action: () -> Void
    @State private var hovering = false

    init(title: String, symbol: String, detail: String? = nil, tint: AnyShapeStyle? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.detail = detail
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint ?? AnyShapeStyle(Theme.brand))
                    .frame(width: 34, height: 34)
                    .overlay(Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.black.opacity(0.08)))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(detail ?? " ")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(hovering ? Theme.surfaceHover : Theme.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .strokeBorder(hovering ? Theme.accent.opacity(0.6) : Theme.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Explains a missing permission and opens the right pane in System Settings.
struct PermissionBanner: View {
    let kind: PermissionKind

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Allow \(kind.title) to capture your screen")
                    .font(Theme.Fonts.bodyStrong)
                    .foregroundStyle(Theme.textPrimary)
                Text("Turn on Spinform in Privacy & Security, then reopen it. After an update macOS may ask again.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button("Open Settings") {
                _ = CGRequestScreenCaptureAccess()
                CapturePermissions.openSettings(kind)
            }
            .buttonStyle(GlowButtonStyle())
            Button("Reopen") { PermissionPrompt.relaunch() }
                .buttonStyle(ChipButtonStyle())
                .help("Quit and open Spinform again, so macOS applies the permission")
        }
        .padding(12)
        .background(Theme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.warning.opacity(0.45)))
    }
}

// MARK: - Settings

/// The Capture and Screen recording sections of Settings.
struct CaptureSettingsSections: View {
    @AppStorage(Prefs.captureFolder) private var folder = ""
    @AppStorage(Prefs.captureFormat) private var format = CaptureImageFormat.png.rawValue
    @AppStorage(Prefs.captureAutoSave) private var autoSave = true
    @AppStorage(Prefs.captureCopy) private var copy = false
    @AppStorage(Prefs.captureOverlay) private var overlay = true
    @AppStorage(Prefs.overlayCorner) private var corner = "left"
    @AppStorage(Prefs.overlaySeconds) private var overlaySeconds = 10
    @AppStorage(Prefs.windowShadow) private var windowShadow = true
    @AppStorage(Prefs.hideDesktopIcons) private var hideIcons = false
    @AppStorage(Prefs.historyDays) private var historyDays = 30
    @AppStorage(Prefs.recordQuality) private var quality = "high"
    @AppStorage(Prefs.recordFPS) private var fps = 30
    @AppStorage(Prefs.recordFormat) private var recordFormat = "mp4"
    @AppStorage(Prefs.recordMic) private var mic = false
    @AppStorage(Prefs.recordSystemAudio) private var systemAudio = false
    @AppStorage(Prefs.recordClicks) private var clicks = true
    @AppStorage(Prefs.recordKeys) private var keys = false
    @AppStorage(Prefs.recordCamera) private var camera = false
    @AppStorage(Prefs.captureFreeze) private var freeze = true
    @AppStorage(Prefs.captureCrosshair) private var crosshair = true
    @AppStorage(Prefs.captureMagnifier) private var magnifier = true
    @AppStorage(Prefs.windowBackground) private var backdrop = WindowBackdrop.shadow.rawValue
    @AppStorage(Prefs.windowBackgroundColor) private var backdropColor = 0x4338CA
    @AppStorage(Prefs.windowBackgroundImage) private var backdropImage = ""
    @AppStorage(Prefs.windowPadding) private var windowPadding = 0.06
    @AppStorage(Prefs.overlaySize) private var overlaySize = "medium"
    @AppStorage(Prefs.recordScale) private var resolution = "full"
    @AppStorage(Prefs.recordCursor) private var showCursor = true
    @AppStorage(Prefs.recordHideDesktop) private var recordHideDesktop = false
    @AppStorage(Prefs.recordStudio) private var studio = false
    @AppStorage(Prefs.clickColor) private var clickColor = 0x8B5CF6
    @AppStorage(Prefs.clickSize) private var clickSize = 64.0
    @AppStorage(Prefs.clickFilled) private var clickFilled = true
    @AppStorage(Prefs.clickAnimate) private var clickAnimate = true
    @AppStorage(Prefs.keysPosition) private var keysPosition = "bottom"
    @AppStorage(Prefs.keysSize) private var keysSize = "medium"
    @AppStorage(Prefs.keysLight) private var keysLight = false
    @AppStorage(Prefs.keysShortcutsOnly) private var keysShortcutsOnly = false
    @AppStorage(Prefs.cameraPosition) private var cameraPosition = "bottomRight"
    @AppStorage(Prefs.cameraSize) private var cameraSize = "medium"
    @AppStorage(Prefs.cameraShape) private var cameraShape = "circle"
    @AppStorage(Prefs.cameraFull) private var cameraFull = false
    @AppStorage(Prefs.ocrLanguage) private var ocrLanguage = ""
    @AppStorage(Prefs.ocrKeepLineBreaks) private var keepLineBreaks = true
    @State private var clashes = HotkeyStore.clashes()
    @State private var languages: [String] = []

    /// An Int-stored hex colour as a ColorPicker binding.
    private func hexBinding(_ value: Binding<Int>) -> Binding<CGColor> {
        Binding(get: { RGBAColor(hex: UInt32(truncatingIfNeeded: value.wrappedValue)).cgColor },
                set: { if let c = RGBAColor(cgColor: $0) { value.wrappedValue = Int(c.hexValue) } })
    }

    var body: some View {
        Section("Capture") {
            Group {
            HStack {
                Text("Save to")
                Spacer()
                Text(folder.isEmpty ? "Desktop" : (folder as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Theme.textSecondary)
                Button("Choose…", action: chooseFolder)
            }
            Picker("File format", selection: $format) {
                ForEach(CaptureImageFormat.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Toggle("Save each capture automatically", isOn: $autoSave)
            Toggle("Copy each capture to the clipboard", isOn: $copy)
            Toggle("Freeze the screen while choosing an area", isOn: $freeze)
            Toggle("Show crosshair guides", isOn: $crosshair)
            Toggle("Show the magnifier", isOn: $magnifier)
            }
            Group {
            Toggle("Show the quick access card after a capture", isOn: $overlay)
            Picker("Card corner", selection: $corner) {
                Text("Bottom left").tag("left")
                Text("Bottom right").tag("right")
                Text("Top left").tag("top-left")
                Text("Top right").tag("top-right")
            }
            .disabled(!overlay)
            Picker("Card size", selection: $overlaySize) {
                Text("Small").tag("small")
                Text("Medium").tag("medium")
                Text("Large").tag("large")
            }
            .disabled(!overlay)
            Picker("Hide the card after", selection: $overlaySeconds) {
                Text("5 seconds").tag(5)
                Text("10 seconds").tag(10)
                Text("30 seconds").tag(30)
                Text("Never").tag(0)
            }
            .disabled(!overlay)
            }
            Group {
            Picker("Window captures", selection: $backdrop) {
                ForEach(WindowBackdrop.allCases) { Text($0.label).tag($0.rawValue) }
            }
            if backdrop == WindowBackdrop.color.rawValue {
                ColorPicker("Background colour", selection: hexBinding($backdropColor), supportsOpacity: false)
            }
            if backdrop == WindowBackdrop.image.rawValue {
                HStack {
                    Text("Background picture")
                    Spacer()
                    Text(backdropImage.isEmpty ? "None (uses the desktop picture)" : (backdropImage as NSString).lastPathComponent)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.image]
                        if panel.runModal() == .OK, let url = panel.url { backdropImage = url.path }
                    }
                }
            }
            if WindowBackdrop(rawValue: backdrop)?.usesBackground == true {
                LabeledContent("Padding") {
                    Slider(value: $windowPadding, in: 0...0.2).frame(width: 180)
                }
            }
            Toggle("Hide desktop icons while capturing", isOn: $hideIcons)
            }
            Picker("Keep history for", selection: $historyDays) {
                Text("Off").tag(0)
                Text("1 day").tag(1)
                Text("3 days").tag(3)
                Text("1 week").tag(7)
                Text("2 weeks").tag(14)
                Text("1 month").tag(30)
                Text("Forever").tag(36500)
            }
            Text("History, text recognition and everything else stay on this Mac; nothing is uploaded.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        Section("Capture shortcuts") {
            ForEach(CaptureAction.allCases) { action in
                LabeledContent {
                    HotkeyField(action: action) { clashes = HotkeyStore.clashes() }
                } label: {
                    HStack(spacing: 6) {
                        Text(action.title)
                        if clashes.contains(action) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.warning)
                                .help("Another action has the same shortcut")
                        } else if HotkeyCenter.shared.unavailable.contains(action) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.warning)
                                .help("Another app already uses this shortcut")
                        }
                    }
                }
            }
            Text("Shortcuts work in any app. The defaults use ⌃⇧ with macOS's own numbers (⌃⇧3 full screen, ⌃⇧4 area, ⌃⇧5 record), so ⌘⇧3, 4 and 5 stay with macOS.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        Section("Text recognition") {
            Picker("Language", selection: $ocrLanguage) {
                Text("Detect automatically").tag("")
                ForEach(languages, id: \.self) { code in
                    Text(TextRecognizer.languageName(code)).tag(code)
                }
            }
            Toggle("Keep line breaks", isOn: $keepLineBreaks)
            Text("Text is read on this Mac by macOS's own text recognition.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .task { if languages.isEmpty { languages = TextRecognizer.supportedLanguages } }
        Section("Screen recording") {
            Group {
            Picker("Quality", selection: $quality) {
                Text("High (Retina)").tag("high")
                Text("Standard (smaller files)").tag("standard")
            }
            Picker("Frame rate", selection: $fps) {
                Text("24 fps").tag(24)
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            Picker("Resolution", selection: $resolution) {
                Text("Full").tag("full")
                Text("1080p").tag("1080")
                Text("720p").tag("720")
            }
            Picker("Save as", selection: $recordFormat) {
                Text("MP4 video").tag("mp4")
                Text("GIF").tag("gif")
            }
            Toggle("Show the pointer", isOn: $showCursor)
            Toggle("Hide desktop icons while recording", isOn: $recordHideDesktop)
            Toggle("Studio mode: smooth pointer and automatic zooms", isOn: $studio)
            if studio {
                Text("Records without the pointer, keeps its path, and opens the recording in Studio, which draws a smooth pointer, zooms in on clicks and adds a background.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            }
            Group {
            Toggle("Record the microphone", isOn: $mic)
            Toggle("Record the Mac's sound", isOn: $systemAudio)
            Toggle("Show clicks", isOn: $clicks)
            if clicks {
                ColorPicker("Click colour", selection: hexBinding($clickColor), supportsOpacity: false)
                LabeledContent("Click size") { Slider(value: $clickSize, in: 32...140).frame(width: 180) }
                Picker("Click style", selection: $clickFilled) {
                    Text("Filled").tag(true)
                    Text("Outline").tag(false)
                }
                Toggle("Animate clicks", isOn: $clickAnimate)
            }
            }
            Group {
            Toggle("Show keys pressed (needs Accessibility)", isOn: $keys)
            if keys {
                Picker("Keys position", selection: $keysPosition) {
                    Text("Bottom centre").tag("bottom")
                    Text("Bottom left").tag("bottomLeft")
                    Text("Bottom right").tag("bottomRight")
                    Text("Top centre").tag("top")
                }
                Picker("Keys size", selection: $keysSize) {
                    Text("Small").tag("small")
                    Text("Medium").tag("medium")
                    Text("Large").tag("large")
                }
                Picker("Keys look", selection: $keysLight) {
                    Text("Dark").tag(false)
                    Text("Light").tag(true)
                }
                Toggle("Only shortcuts (keeps typing private)", isOn: $keysShortcutsOnly)
            }
            Toggle("Show the camera", isOn: $camera)
            if camera {
                Picker("Camera corner", selection: $cameraPosition) {
                    Text("Bottom right").tag("bottomRight")
                    Text("Bottom left").tag("bottomLeft")
                    Text("Top right").tag("topRight")
                    Text("Top left").tag("topLeft")
                }
                .disabled(cameraFull)
                Picker("Camera size", selection: $cameraSize) {
                    Text("Small").tag("small")
                    Text("Medium").tag("medium")
                    Text("Large").tag("large")
                }
                .disabled(cameraFull)
                Picker("Camera shape", selection: $cameraShape) {
                    Text("Circle").tag("circle")
                    Text("Rounded square").tag("rounded")
                }
                .disabled(cameraFull)
                Toggle("Camera fills the whole recording", isOn: $cameraFull)
            }
            Text("Do Not Disturb isn't switched on for you: macOS has no public way for apps to change Focus. Turn it on in Control Centre before recording.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textSecondary)
            }
        }
        Section("Automation") {
            Text("Scripts and Shortcuts can run Spinform with links such as spinform://capture-area. Every link:")
                .font(Theme.Fonts.body)
            Text(AutomationCommand.names.map { "spinform://" + $0 }.joined(separator: "\n"))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Captures Here"
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}
