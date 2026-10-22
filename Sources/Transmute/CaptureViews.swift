import AppKit
import SwiftUI

/// The Capture tab in the main window: every screenshot, recording and text tool with its shortcut.
struct CaptureHomeView: View {
    @ObservedObject var history: CaptureHistory = .shared
    @ObservedObject var recorder: ScreenRecorder = .shared
    @AppStorage(Prefs.captureTimer) private var timer = 0
    @AppStorage(Prefs.hideDesktopIcons) private var hideIcons = false
    @AppStorage(Prefs.windowShadow) private var windowShadow = true
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

    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 8), count: 5) }

    private var screenshotCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Screenshot")
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach([CaptureAction.area, .window, .fullscreen, .previous, .scrolling]) { action in
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
                Toggle("Window shadow", isOn: $windowShadow).toggleStyle(CrispCheckboxStyle())
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
    @State private var clashes = HotkeyStore.clashes()

    var body: some View {
        Section("Capture") {
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
            Toggle("Show the quick access card after a capture", isOn: $overlay)
            Picker("Card corner", selection: $corner) {
                Text("Bottom left").tag("left")
                Text("Bottom right").tag("right")
            }
            .disabled(!overlay)
            Picker("Hide the card after", selection: $overlaySeconds) {
                Text("5 seconds").tag(5)
                Text("10 seconds").tag(10)
                Text("30 seconds").tag(30)
                Text("Never").tag(0)
            }
            .disabled(!overlay)
            Toggle("Window captures include the shadow", isOn: $windowShadow)
            Toggle("Hide desktop icons while capturing", isOn: $hideIcons)
            Picker("Keep history for", selection: $historyDays) {
                Text("Off").tag(0)
                Text("1 day").tag(1)
                Text("1 week").tag(7)
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
        Section("Screen recording") {
            Picker("Quality", selection: $quality) {
                Text("High (Retina)").tag("high")
                Text("Standard (smaller files)").tag("standard")
            }
            Picker("Frame rate", selection: $fps) {
                Text("24 fps").tag(24)
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            Picker("Save as", selection: $recordFormat) {
                Text("MP4 video").tag("mp4")
                Text("GIF").tag("gif")
            }
            Toggle("Record the microphone", isOn: $mic)
            Toggle("Record the Mac's sound", isOn: $systemAudio)
            Toggle("Show clicks", isOn: $clicks)
            Toggle("Show keys pressed (needs Accessibility)", isOn: $keys)
            Toggle("Show the camera in a bubble", isOn: $camera)
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
