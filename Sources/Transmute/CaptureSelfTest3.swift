import AppKit
import SwiftUI

// MARK: - Robustness: nothing may lock the user out

extension SelfTest {
    /// Polls `condition` on the main actor until it's true or `seconds` pass.
    static func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    /// How long a job queued on the main thread waits to run (a frozen main thread shows up here).
    static func mainThreadLag() async -> Double {
        let start = Date()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        return Date().timeIntervalSince(start)
    }

    static func robustnessChecks(dir: URL) async {
        func writePNG(_ image: CGImage?, _ name: String) throws -> URL {
            guard let image else { throw ConversionError("couldn't draw \(name)") }
            let url = dir.appendingPathComponent(name)
            try ImageConverter.data(from: image, type: .png).write(to: url)
            return url
        }
        func sample(_ url: URL, _ x: Double, _ y: Double) throws -> RGBAColor {
            try ImageEditEngine.samplePixel(url, at: NormPoint(x: x, y: y))
        }

        await check("Deadlines: a system call that never answers gives up on time") {
            let start = Date()
            do {
                _ = try await Deadline.run(0.4, "A stuck call") { () async throws -> Int in
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    return 1
                }
                throw ConversionError("didn't time out")
            } catch let failure as CaptureFailure {
                guard case .timedOut = failure else { throw failure }
            }
            let took = Date().timeIntervalSince(start)
            guard took < 2 else { throw ConversionError("took \(took) s") }
            let quick = try await Deadline.run(2, "A quick call") { 7 }
            guard quick == 7 else { throw ConversionError("wrong value") }; return []
        }

        // The crosshair: open, then Esc; open, then an error; open, then nothing at all.
        let screenFrame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        let art = SampleArt.solid(0x334155, width: Int(screenFrame.width), height: Int(screenFrame.height))
        await check("Crosshair: Esc closes it and leaves nothing on screen") {
            guard let art else { throw ConversionError("art") }
            let shot = DisplayShot(image: art, frame: screenFrame, displayID: CGMainDisplayID())
            let task = Task { await SelectionOverlay.select(mode: .area, shots: [shot], windows: [], look: SelectionLook()) }
            guard await waitUntil(3, { SelectionOverlay.visiblePanelCount == 1 }) else {
                CaptureCleanup.closeAll()
                throw ConversionError("the crosshair didn't open")
            }
            guard let panel = NSApp.windows.first(where: { $0.isVisible && $0.level == .screenSaver }),
                  let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                             context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                             isARepeat: false, keyCode: 53) else {
                CaptureCleanup.closeAll()
                throw ConversionError("no crosshair window")
            }
            panel.sendEvent(esc)
            let outcome = try await Deadline.run(3, "Closing the crosshair") { await task.value }
            guard outcome == nil else { throw ConversionError("Esc picked something") }
            guard CaptureCleanup.blockingWindows.isEmpty, !SelectionOverlay.isActive else {
                throw ConversionError("\(CaptureCleanup.blockingWindows.count) windows left on screen")
            }
            let lag = await mainThreadLag()
            guard lag < 0.5 else { throw ConversionError("main thread lagged \(lag) s") }
            return []
        }
        await check("Crosshair: an error while it's open takes it down") {
            guard let art else { throw ConversionError("art") }
            let shot = DisplayShot(image: art, frame: screenFrame, displayID: CGMainDisplayID())
            let task = Task { await SelectionOverlay.select(mode: .window, shots: [shot], windows: [], look: SelectionLook()) }
            guard await waitUntil(3, { SelectionOverlay.visiblePanelCount == 1 }) else { throw ConversionError("didn't open") }
            // What every capture path does when something fails.
            CaptureCleanup.closeAll()
            let outcome = try await Deadline.run(3, "Closing the crosshair") { await task.value }
            guard outcome == nil, CaptureCleanup.blockingWindows.isEmpty else { throw ConversionError("still on screen") }
            return []
        }
        await check("Crosshair: closes itself when left alone (watchdog)") {
            guard let art else { throw ConversionError("art") }
            let shot = DisplayShot(image: art, frame: screenFrame, displayID: CGMainDisplayID())
            SelectionOverlay.watchdogSeconds = 1
            defer { SelectionOverlay.watchdogSeconds = 60 }
            let task = Task { await SelectionOverlay.select(mode: .area, shots: [shot], windows: [], look: SelectionLook()) }
            let outcome = try await Deadline.run(6, "The watchdog") { await task.value }
            guard outcome == nil, CaptureCleanup.blockingWindows.isEmpty else { throw ConversionError("still on screen") }
            return []
        }
        await check("All-in-one chooser: closes on cleanup") {
            let task = Task { await CaptureChooser.choose() }
            try? await Task.sleep(nanoseconds: 400_000_000)
            CaptureCleanup.closeAll()
            let choice = try await Deadline.run(3, "Closing the chooser") { await task.value }
            guard choice == nil else { throw ConversionError("picked \(String(describing: choice))") }; return []
        }

        // Every action has a working name and symbol; every link resolves.
        record("Actions: every capture action has a name and an icon", [], {
            for action in CaptureAction.allCases {
                guard !action.title.isEmpty, !action.shortTitle.isEmpty,
                      NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil) != nil else { return "\(action)" }
            }
            return nil
        }())
        record("Actions: every spinform:// link in Settings resolves", [], {
            for name in AutomationCommand.names {
                let text = "spinform://" + name.replacingOccurrences(of: "…", with: "/tmp/sample.png")
                guard let url = URL(string: text), AutomationCommand.parse(url) != nil else { return name }
            }
            return nil
        }())

        // The capture card's buttons, driven the way a click drives them.
        await check("Capture card: Text copies the words, Copy, Pin, Frame, Markup and close all work") {
            guard let picture = SampleArt.textImage("Spinform card reading", width: 900, height: 170, size: 54) else {
                throw ConversionError("art")
            }
            let file = try writePNG(picture, "card-text.png")
            let result = CaptureResult(url: file, kind: .screenshot, savedToFolder: true,
                                       pixelSize: CGSize(width: picture.width, height: picture.height))
            let cards = QuickAccess.shared
            let before = cards.count
            cards.show(result)
            guard cards.count == before + 1 else { throw ConversionError("card not shown") }
            let actions = cards.actions(for: result)
            NSPasteboard.general.clearContents()
            actions.text()
            guard await waitUntil(25, { NSPasteboard.general.string(forType: .string)?.contains("Spinform") == true }) else {
                throw ConversionError("Text copied \(NSPasteboard.general.string(forType: .string).debugDescription)")
            }
            NSPasteboard.general.clearContents()
            actions.copy()
            guard NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil) else { throw ConversionError("Copy") }
            // Pin, Frame and Markup each open a window.
            for (name, run) in [("Pin", actions.pin), ("Frame", actions.frame), ("Markup", actions.annotate)] {
                let open = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
                if cards.count == 0 { cards.show(result) }
                run()
                let appeared = await waitUntil(4) {
                    NSApp.windows.contains { $0.isVisible && !open.contains(ObjectIdentifier($0)) && $0.level != .statusBar }
                }
                for window in NSApp.windows where window.isVisible && !open.contains(ObjectIdentifier(window)) && window.level != .statusBar {
                    window.close()
                }
                guard appeared else { throw ConversionError("\(name) opened nothing") }
            }
            cards.show(result)
            let shown = cards.count
            cards.actions(for: result).close()
            guard cards.count == shown - 1 else { throw ConversionError("close") }
            cards.setHidden(true)
            cards.setHidden(false)
            return []
        }

        // Recording can always be stopped, even during the countdown.
        if CapturePermissions.screenRecording, let screen = NSScreen.main {
            await check("Recording: Stop during the countdown and during recording always ends it") {
                let recorder = ScreenRecorder.shared
                var options = RecordingOptions()
                options.clicks = false
                options.high = false
                let early = Task { await recorder.start(.screen(screen), options: options) }
                guard await waitUntil(3, { recorder.phase == .countdown }) else { throw ConversionError("no countdown") }
                recorder.stop()
                _ = try await Deadline.run(15, "Starting after Stop") { await early.value }
                guard recorder.phase == .idle else { throw ConversionError("phase \(recorder.phase) after Stop") }
                let full = Task { await recorder.start(.screen(screen), options: options) }
                guard await waitUntil(20, { recorder.phase == .recording }) else {
                    recorder.stop()
                    throw ConversionError("never started (phase \(recorder.phase))")
                }
                _ = try await Deadline.run(5, "Start returning") { await full.value }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                recorder.stop()
                guard await waitUntil(30, { recorder.phase == .idle }) else { throw ConversionError("stuck \(recorder.phase)") }
                CaptureCleanup.closeAll()
                guard CaptureCleanup.blockingWindows.isEmpty else { throw ConversionError("windows left") }
                let lag = await mainThreadLag()
                guard lag < 0.5 else { throw ConversionError("main thread lagged \(lag) s") }; return []
            }
        } else {
            skipped += 1
            print("SKIP  Recording: Stop always ends it: no Screen Recording permission on this runner")
        }

        // Scrolling capture: fast, uneven scrolling under a sticky header and footer.
        await check("Scrolling capture: big uneven steps with a sticky header and footer") {
            let w = 400, frameH = 600, headerH = 40, footerH = 30
            let bandH = frameH - headerH - footerH
            guard let content = SampleArt.tallPage(width: w, height: 2000, seed: 3),
                  let header = SampleArt.tallPage(width: w, height: headerH, seed: 11),
                  let footer = SampleArt.tallPage(width: w, height: footerH, seed: 12),
                  let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw ConversionError("art") }
            func canvas(_ height: Int) -> CGContext? {
                CGContext(data: nil, width: w, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            }
            func frame(top: Int) -> CGImage? {
                guard let ctx = canvas(frameH), let part = content.cropping(to: CGRect(x: 0, y: top, width: w, height: bandH)) else { return nil }
                ctx.draw(footer, in: CGRect(x: 0, y: 0, width: w, height: footerH))
                ctx.draw(part, in: CGRect(x: 0, y: footerH, width: w, height: bandH))
                ctx.draw(header, in: CGRect(x: 0, y: footerH + bandH, width: w, height: headerH))
                return ctx.makeImage()
            }
            let stitcher = ScrollStitcher()
            var results: [ScrollStitcher.AddResult] = []
            // Steps of 120 to 370 rows; 350 and 370 are more than half the 530-row scrolling part.
            for top in [0, 120, 470, 610, 980, 1000, 1350, 1470] {
                guard let f = frame(top: top) else { throw ConversionError("frame") }
                results.append(stitcher.add(f))
            }
            guard results.dropFirst().allSatisfy({ if case .appended = $0 { return true }; return false }) else {
                throw ConversionError("results \(results)")
            }
            guard stitcher.stickyTop == headerH, stitcher.stickyBottom == footerH else {
                throw ConversionError("sticky \(stitcher.stickyTop)/\(stitcher.stickyBottom)")
            }
            let expectedH = headerH + 2000 + footerH
            guard let stitched = stitcher.makeImage(), abs(stitched.height - expectedH) <= 3, stitched.width == w else {
                throw ConversionError("stitched \(stitcher.width)×\(stitcher.height), expected \(w)×\(expectedH)")
            }
            guard let ctx = canvas(expectedH) else { throw ConversionError("canvas") }
            ctx.draw(footer, in: CGRect(x: 0, y: 0, width: w, height: footerH))
            ctx.draw(content, in: CGRect(x: 0, y: footerH, width: w, height: 2000))
            ctx.draw(header, in: CGRect(x: 0, y: footerH + 2000, width: w, height: headerH))
            let a = try writePNG(ctx.makeImage(), "sticky-page.png"), b = try writePNG(stitched, "sticky-page stitched.png")
            for y in stride(from: 0.005, to: 1.0, by: 0.033) {
                for x in [0.1, 0.5, 0.9] {
                    let p = try sample(a, x, y), q = try sample(b, x, y)
                    guard abs(p.red - q.red) < 0.03, abs(p.green - q.green) < 0.03, abs(p.blue - q.blue) < 0.03 else {
                        throw ConversionError("differs at \(x), \(y)")
                    }
                }
            }
            return [b]
        }
        await check("Scrolling capture: a jump past the overlap keeps the frame, using the scroll distance") {
            guard let page = SampleArt.tallPage(width: 300, height: 2000, seed: 5),
                  let f0 = page.cropping(to: CGRect(x: 0, y: 0, width: 300, height: 500)),
                  let f1 = page.cropping(to: CGRect(x: 0, y: 900, width: 300, height: 500)),
                  let f2 = page.cropping(to: CGRect(x: 0, y: 1100, width: 300, height: 500)) else { throw ConversionError("crops") }
            let stitcher = ScrollStitcher()
            let got = [stitcher.add(f0), stitcher.add(f1, scrolledPoints: 450, pixelsPerPoint: 2), stitcher.add(f2)]
            guard got == [.first, .guessed(500), .appended(200)], stitcher.height == 1200, stitcher.guessedFrames == 1 else {
                throw ConversionError("got \(got), height \(stitcher.height)")
            }
            // Scrolling back reports nothing new.
            guard stitcher.add(f0, scrolledPoints: -300) == .noMatch else { throw ConversionError("scrolled back") }
            return []
        }

        await retinaChecks(dir: dir)
    }

    /// Every pixel as RGBA bytes, drawn the same way for any image so two can be compared.
    static func rgbaBytes(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        bytes.withUnsafeMutableBytes { buffer in
            if let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .none
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        return bytes
    }

    static func retinaChecks(dir: URL) async {
        await check("Sharpness: a 2x screen keeps every Retina pixel, untouched, saved at 144 DPI") {
            // A 200×150-point screen at 2x, filled with a fine pattern that any resampling would smear.
            let w = 400, h = 300
            var pixels = [UInt8](repeating: 255, count: w * h * 4)
            for y in 0..<h { for x in 0..<w {
                let i = (y * w + x) * 4
                pixels[i] = UInt8((x * 7 + y * 13) & 0xFF)
                pixels[i + 1] = (x + y) % 2 == 0 ? 0 : 255
                pixels[i + 2] = UInt8((x ^ y) & 0xFF)
            } }
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let provider = CGDataProvider(data: Data(pixels) as CFData),
                  let source = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
                throw ConversionError("couldn't make the screen")
            }
            let shot = DisplayShot(image: source, frame: CGRect(x: 0, y: 0, width: 200, height: 150), displayID: CGMainDisplayID())
            // 60×30 points, 40 points up from the bottom: rows 80–110 points from the top.
            guard let crop = ScreenGrabber.crop(shot, to: CGRect(x: 50, y: 40, width: 60, height: 30)) else { throw ConversionError("crop") }
            guard crop.width == 120, crop.height == 60 else { throw ConversionError("crop is \(crop.width)×\(crop.height), wanted 120×60") }
            guard let expected = source.cropping(to: CGRect(x: 100, y: 160, width: 120, height: 60)) else { throw ConversionError("source crop") }
            let want = rgbaBytes(expected)
            guard rgbaBytes(crop) == want else { throw ConversionError("the crop's pixels differ from the screen's") }

            var outputs: [URL] = []
            for format in [CaptureImageFormat.png, .jpeg] {
                guard let encoded = CaptureFiles.encode(crop, format: format, scale: 2) else { throw ConversionError("encode \(format)") }
                let url = dir.appendingPathComponent("retina.\(encoded.ext)")
                try encoded.data.write(to: url)
                guard let src = CGImageSourceCreateWithData(encoded.data as CFData, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                      let decoded = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw ConversionError("read \(format)") }
                let dpi = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 0
                guard decoded.width == 120, decoded.height == 60, abs(dpi - 144) < 0.5 else {
                    throw ConversionError("\(format): \(decoded.width)×\(decoded.height) at \(dpi) DPI")
                }
                guard let size = NSImage(contentsOf: url)?.size, abs(size.width - 60) < 0.5, abs(size.height - 30) < 0.5 else {
                    throw ConversionError("\(format) opens at the wrong size")
                }
                if format == .png, rgbaBytes(decoded) != want { throw ConversionError("PNG changed pixels") }
                outputs.append(url)
            }
            guard ImageConverter.dpi(of: outputs[0]) == 144 else { throw ConversionError("DPI isn't read back") }
            return outputs
        }

        if CapturePermissions.screenRecording, let screen = NSScreen.main {
            await check("Sharpness: a live area capture is point size × the screen's scale") {
                let rect = CGRect(x: screen.frame.minX + 40, y: screen.frame.minY + 40, width: 101, height: 77)
                let image = try await ScreenGrabber.captureArea(rect, excludingSelf: true)
                let scale = screen.backingScaleFactor
                let w = Int((rect.width * scale).rounded()), h = Int((rect.height * scale).rounded())
                guard abs(image.width - w) <= 1, abs(image.height - h) <= 1 else {
                    throw ConversionError("got \(image.width)×\(image.height), wanted \(w)×\(h) at \(scale)x")
                }
                guard ScreenGrabber.lastScale == scale else { throw ConversionError("scale not recorded") }
                return []
            }
        } else {
            skipped += 1
        }
    }
}
