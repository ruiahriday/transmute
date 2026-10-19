import AppKit
import Darwin
import ServiceManagement
import SwiftUI

@main
enum Launcher {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--selftest"), flag + 1 < args.count {
            SelfTest.start(inputDir: URL(fileURLWithPath: args[flag + 1], isDirectory: true))
        }
        TransmuteApp.main()
    }
}

struct TransmuteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Transmute", id: "main") {
            ContentView().environmentObject(JobQueue.shared)
        }
        .defaultSize(width: 700, height: 560)

        MenuBarExtra("Transmute", systemImage: "arrow.triangle.2.circlepath.circle") {
            MenuContent()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var wheel: DragWheelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        // The Dock icon is on by default: on a crowded menu bar the menu bar icon can end up
        // hidden behind the camera notch.
        if !UserDefaults.standard.bool(forKey: Prefs.showInDock) {
            NSApp.setActivationPolicy(.accessory)
        }
        // A downloaded app's bundled ffmpeg carries the quarantine flag; clear it so it can run.
        if let ffmpeg = Bundle.main.path(forAuxiliaryExecutable: "ffmpeg") {
            removexattr(ffmpeg, "com.apple.quarantine", 0)
        }
        let controller = DragWheelController()
        controller.start()
        wheel = controller
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MenuContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Transmute") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Text("Hold ⇧ while dragging files to convert")
        Text("Hold ⌘ for tools, ⌃ for actions")
        Divider()
        Button("Quit Transmute") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Small progress card shown in the top-right corner for wheel drops.
@MainActor
final class HUDController {
    static let shared = HUDController()
    private var panel: NSPanel?
    private var generation = 0

    func show(ids: [UUID]) {
        generation += 1
        let panel = self.panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .floating
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            return p
        }()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: HUDView(ids: ids).environmentObject(JobQueue.shared))
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrame(NSRect(x: frame.maxX - 330, y: frame.maxY - 96, width: 320, height: 84), display: true)
        }
        panel.orderFrontRegardless()
    }

    func finish() {
        let current = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.generation == current else { return }
            self.panel?.orderOut(nil)
        }
    }

    func finishWhenDone(ids: [UUID]) {
        Task { @MainActor [weak self] in
            while ids.contains(where: { JobQueue.shared.job($0)?.state.isFinished == false }) {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            self?.finish()
        }
    }
}

struct HUDView: View {
    let ids: [UUID]
    @EnvironmentObject private var queue: JobQueue

    var body: some View {
        let jobs = ids.compactMap { queue.job($0) }
        let finished = jobs.filter { $0.state.isFinished }.count
        let failed = jobs.filter { $0.state.isFailed }
        let progress = jobs.isEmpty ? 1 : jobs.map(\.state.fraction).reduce(0, +) / Double(jobs.count)
        let allDone = finished == jobs.count

        HStack(spacing: 12) {
            Image(systemName: !allDone ? "arrow.triangle.2.circlepath"
                  : failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(!allDone ? Color.accentColor : failed.isEmpty ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(title(jobs: jobs, allDone: allDone, failed: failed.count))
                    .font(.headline)
                    .lineLimit(1)
                if allDone, let first = failed.first, case .failed(let message) = first.state {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else if allDone, let message = qrMessage(jobs) {
                    Text(message).font(.caption).textSelection(.enabled).lineLimit(2)
                } else {
                    ProgressView(value: progress)
                }
            }
        }
        .padding(14)
        .frame(width: 320, height: 84, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func title(jobs: [Job], allDone: Bool, failed: Int) -> String {
        let noun = jobs.count == 1 ? jobs[0].url.lastPathComponent : "\(jobs.count) files"
        if !allDone { return "Working on \(noun)…" }
        if failed > 0 { return failed == jobs.count ? "Couldn't process \(noun)" : "Done, \(failed) failed" }
        return "Done: \(noun)"
    }

    private func qrMessage(_ jobs: [Job]) -> String? {
        for job in jobs {
            if case .done(let result) = job.state, result.outputs.isEmpty, let message = result.message { return message }
        }
        return nil
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.outputMode) private var outputMode = OutputMode.besideOriginal.rawValue
    @AppStorage(Prefs.outputFolderPath) private var outputFolderPath = ""
    @AppStorage(Prefs.revealWhenDone) private var revealWhenDone = true
    @AppStorage(Prefs.wheelEnabled) private var wheelEnabled = true
    @AppStorage(Prefs.showInDock) private var showInDock = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Output") {
                    Picker("Save results", selection: $outputMode) {
                        Text("Next to the original").tag(OutputMode.besideOriginal.rawValue)
                        Text("In a folder").tag(OutputMode.folder.rawValue)
                    }
                    if outputMode == OutputMode.folder.rawValue {
                        HStack {
                            Text(outputFolderPath.isEmpty ? "No folder chosen" : outputFolderPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Choose…", action: chooseFolder)
                        }
                    }
                    Toggle("Show results in Finder when done", isOn: $revealWhenDone)
                }
                Section("Drag wheel") {
                    Toggle("Show the wheel when I hold a key while dragging files", isOn: $wheelEnabled)
                    Text("⇧ Shift for formats, ⌘ Command or ⌥ Option for tools, ⌃ Control for actions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("General") {
                    Toggle("Show Transmute in the Dock", isOn: Binding(
                        get: { showInDock },
                        set: { show in
                            showInDock = show
                            NSApp.setActivationPolicy(show ? .regular : .accessory)
                            // Leaving the Dock deactivates the app; keep Settings in front.
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    ))
                    Toggle("Open at login", isOn: Binding(
                        get: { launchAtLogin },
                        set: { enable in
                            do {
                                if enable { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                                launchAtLogin = enable
                            } catch {
                                NSSound.beep()
                            }
                        }
                    ))
                }
                Section("ffmpeg") {
                    if let path = Tools.ffmpeg {
                        Label("Installed at \(path)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("Not installed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Needed for MP3, MKV, WebM, AVI, WMV, OGG, Opus, GIF from video and WebP. Install it with Homebrew: brew install ffmpeg")
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 480, height: 520)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { outputFolderPath = url.path }
    }
}
