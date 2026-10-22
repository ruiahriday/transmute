import AppKit
import SwiftUI

/// Saves pictures of Spinform's windows, for the build server and the website:
///   Spinform.app/Contents/MacOS/Spinform --snapshots <fixtures folder> <output folder>
@MainActor
enum Snapshots {
    static func start(fixtures: URL, output: URL) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Prefs.registerDefaults()
        Task { @MainActor in
            await run(fixtures: fixtures, output: output)
            exit(0)
        }
        app.run()
        exit(1)
    }

    private static func run(fixtures: URL, output: URL) async {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let queue = JobQueue.shared
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            let suffix = appearance == .aqua ? "light" : "dark"
            // Showcased "running" jobs from the previous pass would survive clear().
            for job in queue.jobs { queue.showcase(job.id, .queued) }
            queue.clear()

            await shoot("main-empty-\(suffix)", output, size: CGSize(width: 760, height: 600)) {
                ContentView().environmentObject(queue)
            }

            let names = ["photo.jpg", "clip.mp4", "song.mp3", "report.docx", "sample.png"]
            let urls = names.map { fixtures.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            let ids = queue.add(urls)
            let states: [JobState] = [
                .done(JobResult(outputs: [], message: "2.4 MB → 610 KB")),
                .running(0.62),
                .running(0.28),
                .queued,
                .queued,
            ]
            for (id, state) in zip(ids, states) { queue.showcase(id, state) }
            await shoot("main-files-\(suffix)", output, size: CGSize(width: 760, height: 600)) {
                ContentView().environmentObject(queue)
            }

            await shoot("settings-\(suffix)", output, size: CGSize(width: 480, height: 628)) {
                SettingsView()
            }

            await shoot("drag-wheel-\(suffix)", output, size: CGSize(width: WheelView.size, height: WheelView.size), clear: true) {
                WheelView(kind: .tools, items: DragWheelController.items(for: .tools, urls: [fixtures.appendingPathComponent("photo.jpg")])) { _ in }
            }
            await shoot("drag-wheel-formats-\(suffix)", output, size: CGSize(width: WheelView.size, height: WheelView.size), clear: true) {
                WheelView(kind: .convert, items: DragWheelController.items(for: .convert, urls: [fixtures.appendingPathComponent("clip.mp4")])) { _ in }
            }

            if let id = ids.first, let job = queue.job(id) {
                await shoot("photo-editor-\(suffix)", output, size: CGSize(width: 920, height: 660), wait: 2.5) {
                    EditorHost(request: EditRequest(job: job, mode: .image)) {}
                }
            }
            if ids.count > 1, let job = queue.job(ids[1]) {
                await shoot("video-editor-\(suffix)", output, size: CGSize(width: 920, height: 660), wait: 3.5) {
                    EditorHost(request: EditRequest(job: job, mode: .video)) {}
                }
            }
        }
        print("snapshots saved to \(output.path)")
    }

    /// Shows the view in a window, waits for it to settle, and saves the window as a PNG.
    private static func shoot<V: View>(_ name: String, _ output: URL, size: CGSize, wait: Double = 1.6, clear: Bool = false,
                                       @ViewBuilder _ view: () -> V) async {
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: 120, y: 120), size: size),
                              styleMask: clear ? [.borderless] : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Spinform"
        if clear {
            window.isOpaque = false
            window.backgroundColor = .clear
        }
        window.contentView = NSHostingView(rootView: view())
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))

        let file = output.appendingPathComponent("\(name).png")
        var data: Data?
        if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                            [.boundsIgnoreFraming, .bestResolution]), cg.width > 10 {
            data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        }
        if data == nil, let content = window.contentView,
           let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            // Without screen recording permission: AppKit's own drawing (materials come out plain).
            content.cacheDisplay(in: content.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }
        if let data { try? data.write(to: file) }
        print(data == nil ? "FAIL  \(name)" : "saved \(name).png")
        window.orderOut(nil)
        window.close()
    }
}
