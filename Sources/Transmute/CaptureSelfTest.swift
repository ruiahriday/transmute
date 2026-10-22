import AppKit
import AVFoundation
import CoreImage
import CoreText
import ScreenCaptureKit
import SwiftUI

// MARK: - Pictures for the tests and the window pictures

extension SampleArt {
    private static func rgbCanvas(_ width: Int, _ height: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// One line of text with its top-left corner at (x, top), measured from the top of the canvas.
    static func drawText(_ string: String, in ctx: CGContext, x: CGFloat, top: CGFloat, size: CGFloat,
                         color: UInt32, bold: Bool = false) {
        let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: RGBAColor(hex: color).cgColor]
        guard let attributed = CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary) else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: x, y: CGFloat(ctx.height) - top - ascent)
        CTLineDraw(line, ctx)
    }

    /// A rectangle given from the top-left, as CoreGraphics (bottom-left) coordinates.
    private static func box(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: CGFloat(ctx.height) - y - h, width: w, height: h)
    }

    private static func fill(_ ctx: CGContext, _ hex: UInt32, _ rect: CGRect, radius: CGFloat = 0) {
        ctx.setFillColor(RGBAColor(hex: hex).cgColor)
        if radius > 0 {
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        } else {
            ctx.fill(rect)
        }
    }

    /// A made-up app window (sidebar, heading, text and a chart) to stand in for a screenshot.
    static func fakeScreenshot(width: Int = 1200, height: Int = 760) -> CGImage? {
        guard let ctx = rgbCanvas(width, height) else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        fill(ctx, 0xF4F4F7, CGRect(x: 0, y: 0, width: w, height: h))
        // Title bar.
        fill(ctx, 0xE7E7EC, box(ctx, 0, 0, w, 52))
        for (i, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
            ctx.setFillColor(RGBAColor(hex: hex).cgColor)
            ctx.fillEllipse(in: box(ctx, 22 + CGFloat(i) * 24, 18, 15, 15))
        }
        drawText("Planner", in: ctx, x: w / 2 - 36, top: 15, size: 18, color: 0x3F3F46, bold: true)
        // Sidebar.
        fill(ctx, 0xEDEDF2, box(ctx, 0, 52, 250, h - 52))
        let items = ["Inbox", "Today", "Projects", "Reports", "Team"]
        for (i, item) in items.enumerated() {
            let top = 82 + CGFloat(i) * 46
            if i == 2 { fill(ctx, 0xDDD6FE, box(ctx, 14, top - 8, 222, 38), radius: 9) }
            fill(ctx, i == 2 ? 0x7C3AED : 0xA1A1AA, box(ctx, 30, top + 3, 16, 16), radius: 4)
            drawText(item, in: ctx, x: 58, top: top, size: 18, color: i == 2 ? 0x4C1D95 : 0x3F3F46, bold: i == 2)
        }
        // Content.
        drawText("Quarterly plan", in: ctx, x: 290, top: 84, size: 38, color: 0x111118, bold: true)
        drawText("Launch Spinform to friends and family", in: ctx, x: 290, top: 140, size: 20, color: 0x52525B)
        let lines: [CGFloat] = [560, 610, 520, 590]
        for (i, length) in lines.enumerated() {
            fill(ctx, 0xD4D4DC, box(ctx, 290, 192 + CGFloat(i) * 30, length, 12), radius: 6)
        }
        // A card with a bar chart.
        fill(ctx, 0xFFFFFF, box(ctx, 290, 330, 560, 330), radius: 16)
        drawText("Downloads", in: ctx, x: 316, top: 352, size: 20, color: 0x18181B, bold: true)
        let bars: [CGFloat] = [90, 140, 120, 190, 170, 230, 260]
        for (i, bar) in bars.enumerated() {
            let left = 322 + CGFloat(i) * 74
            fill(ctx, i == bars.count - 1 ? 0xEC4899 : 0x8B5CF6, box(ctx, left, 630 - bar, 44, bar), radius: 7)
        }
        // A side card with checkboxes.
        fill(ctx, 0xFFFFFF, box(ctx, 876, 330, 290, 330), radius: 16)
        drawText("To do", in: ctx, x: 900, top: 352, size: 20, color: 0x18181B, bold: true)
        for (i, task) in ["Record the demo", "Write release notes", "Share the link"].enumerated() {
            let top = 404 + CGFloat(i) * 52
            fill(ctx, i == 0 ? 0x22C55E : 0xE4E4E7, box(ctx, 900, top, 22, 22), radius: 6)
            drawText(task, in: ctx, x: 934, top: top, size: 17, color: 0x3F3F46)
        }
        return ctx.makeImage()
    }

    /// A tall page of coloured bands and blocks that never repeats, for the scrolling stitcher.
    static func tallPage(width: Int, height: Int, seed: UInt64 = 42) -> CGImage? {
        guard let ctx = rgbCanvas(width, height) else { return nil }
        var state = seed
        func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        var top = 0
        while top < height {
            let band = 6 + Int(next() % 30)
            let rect = CGRect(x: 0, y: height - top - band, width: width, height: band)
            ctx.setFillColor(CGColor(srgbRed: CGFloat(next() % 256) / 255, green: CGFloat(next() % 256) / 255,
                                     blue: CGFloat(next() % 256) / 255, alpha: 1))
            ctx.fill(rect)
            let blocks = Int(next() % 4)
            for _ in 0..<blocks {
                let bw = 10 + Int(next() % UInt64(max(11, width / 3)))
                let bx = Int(next() % UInt64(max(1, width - bw)))
                ctx.setFillColor(CGColor(srgbRed: CGFloat(next() % 256) / 255, green: CGFloat(next() % 256) / 255,
                                         blue: CGFloat(next() % 256) / 255, alpha: 1))
                ctx.fill(CGRect(x: bx, y: Int(rect.minY), width: bw, height: band))
            }
            top += band
        }
        return ctx.makeImage()
    }

    static func solid(_ hex: UInt32, width: Int, height: Int) -> CGImage? {
        guard let ctx = rgbCanvas(width, height) else { return nil }
        ctx.setFillColor(RGBAColor(hex: hex).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// Black and white squares of `square` pixels.
    static func checker(width: Int, height: Int, square: Int) -> CGImage? {
        guard let ctx = rgbCanvas(width, height) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for y in stride(from: 0, to: height, by: square) {
            for x in stride(from: 0, to: width, by: square) where (x / square + y / square) % 2 == 0 {
                ctx.fill(CGRect(x: x, y: y, width: square, height: square))
            }
        }
        return ctx.makeImage()
    }

    static func textImage(_ text: String, width: Int = 1100, height: Int = 200, size: CGFloat = 64) -> CGImage? {
        guard let ctx = rgbCanvas(width, height) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        drawText(text, in: ctx, x: 40, top: (CGFloat(height) - size * 1.2) / 2, size: size, color: 0x111111, bold: true)
        return ctx.makeImage()
    }

    static func qrImage(_ text: String) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let small = filter.outputImage else { return nil }
        let code = small.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = CIContext().createCGImage(code, from: code.extent), let ctx = rgbCanvas(cg.width + 80, cg.height + 80) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.draw(cg, in: CGRect(x: 40, y: 40, width: cg.width, height: cg.height))
        return ctx.makeImage()
    }
}

// MARK: - Self-test

extension SelfTest {
    static func captureChecks(outDir: URL, inputs: [URL]) async {
        Prefs.registerDefaults()
        let dir = outDir.appendingPathComponent("capture")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var options = ConversionOptions(quality: 0.9, outputFolder: dir, stripMetadata: false)
        options.outputFolder = dir

        func writePNG(_ image: CGImage?, _ name: String) throws -> URL {
            guard let image else { throw ConversionError("couldn't draw \(name)") }
            let url = dir.appendingPathComponent(name)
            try ImageConverter.data(from: image, type: .png).write(to: url)
            return url
        }
        func sample(_ url: URL, _ x: Double, _ y: Double) throws -> RGBAColor {
            try ImageEditEngine.samplePixel(url, at: NormPoint(x: x, y: y))
        }
        func describe(_ c: RGBAColor) -> String { String(format: "r%.2f g%.2f b%.2f a%.2f", c.red, c.green, c.blue, c.alpha) }
        func near(_ c: RGBAColor, _ hex: UInt32, _ slack: Double = 0.1) -> Bool {
            let t = RGBAColor(hex: hex)
            return abs(c.red - t.red) < slack && abs(c.green - t.green) < slack && abs(c.blue - t.blue) < slack
        }
        func edited(_ edit: ImageEdit, on input: URL) async throws -> URL {
            let result = try await Engine.perform(.editImage(edit), on: input, options: options) { _ in }
            guard let out = result.outputs.first else { throw ConversionError("no output") }
            return out
        }

        // Stitching.
        await check("Scrolling capture: frames stitch back into the page") {
            guard let page = SampleArt.tallPage(width: 400, height: 2400) else { throw ConversionError("no page") }
            let stitcher = ScrollStitcher()
            var results: [ScrollStitcher.AddResult] = []
            for top in [0, 250, 520, 800, 1100, 1400, 1700, 1800] {
                guard let frame = page.cropping(to: CGRect(x: 0, y: top, width: 400, height: 600)) else { throw ConversionError("crop") }
                results.append(stitcher.add(frame))
            }
            guard results.first == .first, results.dropFirst().allSatisfy({ if case .appended = $0 { return true }; return false }) else {
                throw ConversionError("results \(results)")
            }
            guard let stitched = stitcher.makeImage(), stitched.width == 400, stitched.height == 2400 else {
                throw ConversionError("stitched size \(stitcher.width)×\(stitcher.height), expected 400×2400")
            }
            let a = try writePNG(page, "page.png"), b = try writePNG(stitched, "page stitched.png")
            for y in stride(from: 0.01, to: 1.0, by: 0.07) {
                for x in [0.1, 0.5, 0.9] {
                    let p = try sample(a, x, y), q = try sample(b, x, y)
                    guard abs(p.red - q.red) < 0.02, abs(p.green - q.green) < 0.02, abs(p.blue - q.blue) < 0.02 else {
                        throw ConversionError("pixel at \(x), \(y) differs: \(describe(p)) vs \(describe(q))")
                    }
                }
            }
            return [b]
        }
        await check("Scrolling capture: still, backwards and unrelated frames are ignored") {
            guard let page = SampleArt.tallPage(width: 300, height: 1600), let other = SampleArt.tallPage(width: 300, height: 500, seed: 7),
                  let f0 = page.cropping(to: CGRect(x: 0, y: 0, width: 300, height: 500)),
                  let f1 = page.cropping(to: CGRect(x: 0, y: 300, width: 300, height: 500)),
                  let back = page.cropping(to: CGRect(x: 0, y: 100, width: 300, height: 500)) else { throw ConversionError("crops") }
            let stitcher = ScrollStitcher()
            let got = [stitcher.add(f0), stitcher.add(f0), stitcher.add(f1), stitcher.add(back), stitcher.add(other)]
            let want: [ScrollStitcher.AddResult] = [.first, .unchanged, .appended(300), .noMatch, .noMatch]
            guard got == want, stitcher.height == 800 else { throw ConversionError("got \(got), height \(stitcher.height)") }
            return []
        }

        // Background frames.
        await check("Background frame: layout with padding and aspect presets") {
            let size = CGSize(width: 400, height: 300)
            var style = FrameStyle(background: .solid(0xFFFFFF), padding: 0.1, corners: 0, shadow: 0, aspect: .auto)
            let fit = FrameLayout.layout(imageSize: size, style: style)
            style.aspect = .square
            let square = FrameLayout.layout(imageSize: size, style: style)
            style.aspect = .story
            let story = FrameLayout.layout(imageSize: size, style: style)
            style.aspect = .wide
            let wide = FrameLayout.layout(imageSize: size, style: style)
            guard fit.canvas == CGSize(width: 480, height: 380), fit.imageRect == CGRect(x: 40, y: 40, width: 400, height: 300),
                  square.canvas == CGSize(width: 480, height: 480), square.imageRect.origin == CGPoint(x: 40, y: 90),
                  story.canvas == CGSize(width: 480, height: 853), abs(wide.canvas.width / wide.canvas.height - 16.0 / 9.0) < 0.01 else {
                throw ConversionError("fit \(fit), square \(square), story \(story.canvas), wide \(wide.canvas)")
            }
            return []
        }
        await check("Background frame: renders background, rounded picture and shadow") {
            guard let red = SampleArt.solid(0xDC2626, width: 400, height: 300) else { throw ConversionError("art") }
            let style = FrameStyle(background: .solid(0x2563EB), padding: 0.1, corners: 0.05, shadow: 0.8, aspect: .auto)
            let framed = try writePNG(try FrameRenderer.render(red, style: style), "framed.png")
            let image = try ImageConverter.loadCGImage(framed)
            guard image.width == 480, image.height == 380 else { throw ConversionError("size \(image.width)×\(image.height)") }
            let corner = try sample(framed, 0.01, 0.01)
            let centre = try sample(framed, 0.5, 0.5)
            let roundedCorner = try sample(framed, 41.0 / 480, 41.0 / 380)
            let underShadow = try sample(framed, 0.5, 352.0 / 380)
            guard near(corner, 0x2563EB), near(centre, 0xDC2626), !near(roundedCorner, 0xDC2626, 0.15),
                  underShadow.blue < RGBAColor(hex: 0x2563EB).blue - 0.03 else {
                throw ConversionError("corner \(describe(corner)), centre \(describe(centre)), rounded corner \(describe(roundedCorner)), shadow \(describe(underShadow))")
            }
            let gradient = try FrameRenderer.render(red, style: FrameStyle(background: .gradient(0xFFFFFF, 0x000000), padding: 0.1))
            let g = try writePNG(gradient, "framed gradient.png")
            let topLeft = try sample(g, 0.01, 0.01), bottomRight = try sample(g, 0.99, 0.99)
            guard topLeft.red > 0.85, bottomRight.red < 0.15 else {
                throw ConversionError("gradient \(describe(topLeft)) → \(describe(bottomRight))")
            }
            return [framed, g]
        }
        await check("Background frame: 20 presets, custom presets saved and removed") {
            let ids = Set(FramePreset.builtIn.map(\.id))
            guard FramePreset.builtIn.count == 20, ids.count == 20 else { throw ConversionError("\(FramePreset.builtIn.count) presets") }
            guard let defaults = UserDefaults(suiteName: "spinform.selftest.frames.\(UUID().uuidString)") else { throw ConversionError("defaults") }
            let style = FrameStyle(background: .gradient(0x123456, 0x654321), padding: 0.2, corners: 0.01, shadow: 0.3, aspect: .wide)
            let preset = FramePresetStore.add(name: "Launch", style: style, defaults: defaults)
            let saved = FramePresetStore.custom(defaults: defaults)
            guard saved.count == 1, saved[0].style == style, saved[0].name == "Launch", saved[0].custom else { throw ConversionError("saved \(saved)") }
            FramePresetStore.remove(preset.id, defaults: defaults)
            guard FramePresetStore.custom(defaults: defaults).isEmpty else { throw ConversionError("not removed") }
            return []
        }

        // Annotations.
        let white = try? writePNG(SampleArt.solid(0xFFFFFF, width: 400, height: 300), "white.png")
        if let white {
            await check("Annotate: arrow, line and oval are drawn where placed") {
                var edit = ImageEdit()
                edit.annotations = [
                    .arrow(from: NormPoint(x: 0.1, y: 0.2), to: NormPoint(x: 0.9, y: 0.2), lineWidth: 0.03, color: .brightRed),
                    .line(from: NormPoint(x: 0.1, y: 0.5), to: NormPoint(x: 0.9, y: 0.5), lineWidth: 0.03, color: .brightBlue),
                    .ellipse(NormRect(x: 0.3, y: 0.6, width: 0.4, height: 0.3), lineWidth: 0.03, color: .brightGreen),
                ]
                let out = try await edited(edit, on: white)
                let arrow = try sample(out, 0.5, 0.2), line = try sample(out, 0.5, 0.5)
                let ovalTop = try sample(out, 0.5, 0.6 + 0.015), ovalMiddle = try sample(out, 0.5, 0.75), blank = try sample(out, 0.05, 0.95)
                guard arrow.red > 0.8, arrow.green < 0.35, line.blue > 0.8, line.red < 0.2, ovalTop.green > 0.6, ovalTop.red < 0.4,
                      ovalMiddle.red > 0.95, blank.red > 0.95 else {
                    throw ConversionError("arrow \(describe(arrow)), line \(describe(line)), oval \(describe(ovalTop)) / \(describe(ovalMiddle))")
                }
                return [out]
            }
            await check("Annotate: numbered steps") {
                var edit = ImageEdit()
                edit.annotations = [.step(1, at: NormPoint(x: 0.25, y: 0.5), diameter: 0.3, color: .brightBlue),
                                    .step(2, at: NormPoint(x: 0.75, y: 0.5), diameter: 0.3, color: .yellow)]
                let out = try await edited(edit, on: white)
                // Above the digit, inside the circle.
                let blue = try sample(out, 0.25, 0.5 - 0.11), yellow = try sample(out, 0.75, 0.5 - 0.11)
                let outside = try sample(out, 0.5, 0.5)
                guard blue.blue > 0.8, blue.red < 0.2, yellow.red > 0.85, yellow.blue < 0.3, outside.blue > 0.95, outside.red > 0.95 else {
                    throw ConversionError("step 1 \(describe(blue)), step 2 \(describe(yellow)), outside \(describe(outside))")
                }
                guard ImageEditEngine.stepTextColor(.yellow) == .black, ImageEditEngine.stepTextColor(.brightBlue) == .white else {
                    throw ConversionError("step text colours")
                }
                return [out]
            }
            await check("Annotate: spotlight dims everything else") {
                var edit = ImageEdit()
                edit.annotations = [.spotlight(NormRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)),
                                    .rectangle(NormRect(x: 0.02, y: 0.02, width: 0.1, height: 0.1), lineWidth: 0.05, color: .brightRed)]
                let out = try await edited(edit, on: white)
                let inside = try sample(out, 0.5, 0.5), outside = try sample(out, 0.9, 0.9), mark = try sample(out, 0.07, 0.07)
                guard inside.red > 0.97, outside.red < 0.6, outside.red > 0.3, mark.red > 0.8, mark.green < 0.35 else {
                    throw ConversionError("inside \(describe(inside)), outside \(describe(outside)), box on top \(describe(mark))")
                }
                return [out]
            }
            await check("Annotate: resize to half") {
                var edit = ImageEdit()
                edit.scale = 0.5
                let out = try await edited(edit, on: white)
                let image = try ImageConverter.loadCGImage(out)
                guard image.width == 200, image.height == 150 else { throw ConversionError("\(image.width)×\(image.height)") }
                return [out]
            }
        }
        await check("Annotate: pixelate turns fine detail into flat blocks") {
            let checker = try writePNG(SampleArt.checker(width: 400, height: 300, square: 2), "checker.png")
            var edit = ImageEdit()
            edit.redactions = [ImageEdit.Redaction(rect: NormRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6), style: .pixelate)]
            let out = try await edited(edit, on: checker)
            let a = try sample(out, 0.5, 0.5), b = try sample(out, 0.5 + 1.0 / 400, 0.5)
            guard a.red > 0.25, a.red < 0.75, abs(a.red - b.red) < 0.05 else {
                throw ConversionError("pixelated \(describe(a)) / \(describe(b))")
            }
            return [out]
        }

        // Text recognition.
        await check("Copy text: reads a line of text on this Mac") {
            guard let image = SampleArt.textImage("Spinform reads this text") else { throw ConversionError("art") }
            let result = try TextRecognizer.recognize(image)
            let text = result.text.lowercased()
            print("      read: \(result.text.debugDescription)")
            guard text.contains("spinform"), text.contains("text") else { throw ConversionError("read \(result.text.debugDescription)") }
            return []
        }
        await check("Copy text: reads a scanned PDF page and QR codes") {
            let picture = try writePNG(SampleArt.textImage("Invoice number 4821"), "scan.png")
            let pdf = try PDFTools.imagesToPDF([picture], options: options)
            let fromPDF = try TextRecognizer.recognize(fileAt: pdf)
            guard fromPDF.text.contains("4821") else { throw ConversionError("PDF read \(fromPDF.text.debugDescription)") }
            guard let qr = SampleArt.qrImage("https://example.com/spinform") else { throw ConversionError("qr") }
            let codes = try TextRecognizer.recognize(qr)
            guard codes.qrCodes == ["https://example.com/spinform"], codes.clipboardText.contains("example.com/spinform") else {
                throw ConversionError("QR \(codes.qrCodes)")
            }
            return [pdf]
        }
        record("Copy text: lines in reading order", [], {
            let pieces: [(box: CGRect, text: String)] = [
                (CGRect(x: 0.5, y: 0.8, width: 0.3, height: 0.05), "world"),
                (CGRect(x: 0.1, y: 0.4, width: 0.3, height: 0.05), "second"),
                (CGRect(x: 0.1, y: 0.81, width: 0.3, height: 0.05), "hello"),
            ]
            let text = TextRecognizer.assemble(pieces)
            return text == "hello world\nsecond" ? nil : "got \(text.debugDescription)"
        }())

        // History.
        await check("History: keeps, prunes, reloads, restores and deletes") {
            let store = dir.appendingPathComponent("history-\(UUID().uuidString)")
            let history = CaptureHistory(directory: store)
            let file = try writePNG(SampleArt.solid(0x8B5CF6, width: 40, height: 30), "history source.png")
            let now = Date()
            try history.add(file: file, kind: .screenshot, width: 40, height: 30, date: now)
            try history.add(file: file, kind: .scrolling, width: 40, height: 30, date: now.addingTimeInterval(-2 * 86_400))
            let old = try history.add(file: file, kind: .recording, width: 40, height: 30, duration: 3, date: now.addingTimeInterval(-10 * 86_400))
            guard history.items.count == 3, history.items.first?.kind == .screenshot else { throw ConversionError("items \(history.items)") }
            history.prune(keepingDays: 7, now: now)
            guard history.items.count == 2, !FileManager.default.fileExists(atPath: history.url(for: old).path) else {
                throw ConversionError("prune left \(history.items.count)")
            }
            let reloaded = CaptureHistory(directory: store)
            guard reloaded.items.map(\.id) == history.items.map(\.id) else { throw ConversionError("reload differs") }
            let restoreFolder = dir.appendingPathComponent("restored-\(UUID().uuidString)")
            let restored = try reloaded.restore(reloaded.items[0], to: restoreFolder)
            guard FileManager.default.fileExists(atPath: restored.path) else { throw ConversionError("restore missing") }
            let first = reloaded.items[0]
            reloaded.delete(first)
            guard reloaded.items.count == 1, !FileManager.default.fileExists(atPath: reloaded.url(for: first).path),
                  FileManager.default.fileExists(atPath: file.path) else { throw ConversionError("delete") }
            return [restored]
        }

        // Shortcuts.
        record("Shortcuts: parse, show and store", [], {
            guard let area = Hotkey(string: "ctrl+shift+4"), area.keyCode == 21, area.display == "⌃⇧4",
                  area.storageString == "ctrl+shift+4" else { return "ctrl+shift+4 → \(String(describing: Hotkey(string: "ctrl+shift+4")))" }
            guard Hotkey(string: "cmd+alt+f5")?.display == "⌥⌘F5", Hotkey(string: "F6") != nil else { return "F-keys" }
            guard Hotkey(string: "shift+4") == nil, Hotkey(string: "ctrl+banana") == nil, Hotkey(string: "") == nil else {
                return "accepted a bad shortcut"
            }
            guard let defaults = UserDefaults(suiteName: "spinform.selftest.hotkeys.\(UUID().uuidString)") else { return "defaults" }
            guard HotkeyStore.clashes(defaults: defaults).isEmpty else { return "default shortcuts clash" }
            let defaultsUsed = CaptureAction.allCases.compactMap { HotkeyStore.hotkey(for: $0, defaults: defaults) }
            guard !defaultsUsed.contains(where: { Hotkey.reserved.contains($0) }) else { return "a default takes macOS's ⌘⇧3/4/5" }
            HotkeyStore.set(Hotkey(string: "cmd+alt+k"), for: .area, defaults: defaults)
            guard HotkeyStore.hotkey(for: .area, defaults: defaults)?.display == "⌥⌘K" else { return "store" }
            HotkeyStore.set(Hotkey(string: "cmd+alt+k"), for: .window, defaults: defaults)
            guard HotkeyStore.clashes(defaults: defaults) == [.area, .window] else { return "clash not found" }
            HotkeyStore.set(nil, for: .window, defaults: defaults)
            guard HotkeyStore.hotkey(for: .window, defaults: defaults) == nil else { return "clear" }
            HotkeyStore.reset(.window, defaults: defaults)
            guard HotkeyStore.hotkey(for: .window, defaults: defaults) == CaptureAction.window.defaultHotkey else { return "reset" }
            return nil
        }())
        HotkeyCenter.shared.start()
        let missing = HotkeyCenter.shared.unavailable.map(\.rawValue).sorted()
        let defaultCount = CaptureAction.allCases.filter { $0.defaultHotkey != nil }.count
        record("Shortcuts: \(defaultCount) default shortcuts registered with macOS",
               [], missing.isEmpty ? nil : "couldn't register \(missing)")
        HotkeyCenter.shared.suspend(true)
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                                        windowNumber: 0, context: nil, characters: "k", charactersIgnoringModifiers: "k",
                                        isARepeat: false, keyCode: 40) {
            let shown = KeystrokeOverlay.describe(event)
            record("Recording: keystrokes are shown as symbols", [], shown == "⇧ ⌘ K" ? nil : "got \(shown)")
        }

        // Geometry and permissions.
        record("Capture: screen area to pixels", [], {
            let pixels = ScreenGrabber.pixelRect(of: CGRect(x: 100, y: 600, width: 200, height: 100),
                                                 in: (frame: CGRect(x: 0, y: 0, width: 1000, height: 800), width: 2000, height: 1600))
            return pixels == CGRect(x: 200, y: 200, width: 400, height: 200) ? nil : "got \(pixels)"
        }())
        let states = PermissionKind.allCases.map { "\($0.rawValue) \(CapturePermissions.state($0).rawValue)" }
        print("      permissions: \(states.joined(separator: ", "))")
        record("Capture: permission check answers without asking", [], states.count == 4 ? nil : "missing states")
        let windows = ScreenGrabber.onScreenWindows()
        print("      windows on screen: \(windows.count)")
        record("Capture: window list", [], nil)

        if CapturePermissions.screenRecording {
            await check("Capture: a real screenshot of this Mac's screen") {
                let shots = try await ScreenGrabber.captureAllScreens()
                guard let shot = shots.first, shot.image.width > 100, shot.image.height > 100 else { throw ConversionError("empty capture") }
                print("      captured \(shots.count) screen(s), first \(shot.image.width)×\(shot.image.height)")
                let area = CGRect(x: shot.frame.minX + 10, y: shot.frame.minY + 10, width: 200, height: 120)
                let live = try await ScreenGrabber.captureArea(area, excludingSelf: true)
                guard live.width >= 200, live.height >= 120 else { throw ConversionError("area \(live.width)×\(live.height)") }
                return [try writePNG(shot.image, "real screen.png")]
            }
            await check("Recording: a real 2-second screen recording") {
                guard let screen = NSScreen.main else { throw ConversionError("no screen") }
                let url = try await realRecording(screen: screen, seconds: 2)
                let asset = AVURLAsset(url: url)
                let seconds = CMTimeGetSeconds(try await asset.load(.duration))
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard tracks.count == 1, seconds > 1 else { throw ConversionError("\(tracks.count) video tracks, \(seconds) s") }
                print("      recorded \(String(format: "%.1f", seconds)) s")
                return [url]
            }
        } else {
            skipped += 2
            print("SKIP  Capture: real screenshot and recording: this runner hasn't given Spinform Screen Recording permission")
        }

        // Recording post-processing with the bundled ffmpeg.
        if Tools.ffmpeg != nil, let clip = inputs.first(where: { $0.lastPathComponent == "clip.mp4" }),
           let tone = inputs.first(where: { $0.lastPathComponent == "tone.wav" }), let ffmpeg = Tools.ffmpeg {
            await check("Recording: GIF export") {
                let gif = try await ScreenRecorder.convertToGIF(clip)
                guard let source = CGImageSourceCreateWithURL(gif as CFURL, nil), CGImageSourceGetCount(source) > 10 else {
                    throw ConversionError("too few frames")
                }
                return [gif]
            }
            await check("Recording: microphone and Mac sound mixed into one track") {
                let two = dir.appendingPathComponent("two tracks.mp4")
                try await Shell.check(ffmpeg, ["-hide_banner", "-nostdin", "-y", "-i", clip.path, "-i", tone.path,
                                               "-map", "0:v", "-map", "0:a", "-map", "1:a", "-c:v", "copy", "-c:a", "aac",
                                               "-shortest", two.path])
                let mixed = try await ScreenRecorder.mixAudio(two)
                let tracks = try await AVURLAsset(url: mixed).loadTracks(withMediaType: .audio)
                guard tracks.count == 1 else { throw ConversionError("\(tracks.count) audio tracks") }
                return [mixed]
            }
        } else {
            skipped += 2
            print("SKIP  Recording: GIF and audio mixing need ffmpeg and the clip.mp4 / tone.wav fixtures")
        }
        await moreCaptureChecks(dir: dir, options: options)
    }

    /// Records the screen straight through StreamWriter, without any of the on-screen controls.
    @MainActor
    private static func realRecording(screen: NSScreen, seconds: Double) async throws -> URL {
        let id = ScreenGrabber.displayID(of: screen)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == id }) else { throw ConversionError("no display") }
        let width = max(2, Int(screen.frame.width) / 2 * 2), height = max(2, Int(screen.frame.height) / 2 * 2)
        let url = OutputPaths.temporaryURL(ext: "mp4")
        let writer = try StreamWriter(url: url, width: width, height: height, fps: 30, high: false, systemAudio: false, microphone: false)
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: writer)
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
        try await stream.startCapture()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        try await stream.stopCapture()
        guard let out = await writer.finish() else { throw ConversionError("no frames arrived") }
        return out
    }
}

// MARK: - Window pictures

extension Snapshots {
    static func captureShots(suffix: String, output: URL, art: URL, fixtures: URL) async {
        let screenshotURL = art.appendingPathComponent("screenshot.png")
        if !FileManager.default.fileExists(atPath: screenshotURL.path),
           let image = SampleArt.fakeScreenshot(), let data = try? ImageConverter.data(from: image, type: .png) {
            try? data.write(to: screenshotURL)
        }
        guard let screenshot = try? ImageConverter.loadCGImage(screenshotURL) else {
            print("FAIL  capture pictures: no sample screenshot")
            return
        }

        await shoot("main-capture-\(suffix)", output, size: CGSize(width: 760, height: 640), wait: 2) {
            ContentView(initialArea: .capture).environmentObject(JobQueue.shared)
        }

        let result = CaptureResult(url: screenshotURL, kind: .screenshot, savedToFolder: true,
                                   pixelSize: CGSize(width: screenshot.width, height: screenshot.height))
        await shoot("capture-overlay-\(suffix)", output, size: QuickAccess.cardSize, wait: 2, clear: true) {
            QuickAccessCard(result: result, actions: QuickActions(), forceHover: true)
        }

        let shot = DisplayShot(image: screenshot, frame: CGRect(x: 0, y: 0, width: 960, height: 608), displayID: 0)
        await shoot("capture-selection-\(suffix)", output, size: CGSize(width: 960, height: 608), wait: 1, clear: true) {
            SelectionShowcase(shot: shot, selection: CGRect(x: 225, y: 258, width: 465, height: 280))
        }

        await shoot("frame-tool-\(suffix)", output, size: CGSize(width: 980, height: 660), wait: 3) {
            FrameToolView(url: screenshotURL, style: FrameStyle(background: .gradient(0x4338CA, 0xEC4899), padding: 0.07,
                                                                corners: 0.02, shadow: 0.7, aspect: .wide))
        }

        let markup: [ImageEdit.Annotation] = [
            .spotlight(NormRect(x: 0.235, y: 0.42, width: 0.48, height: 0.45)),
            .arrow(from: NormPoint(x: 0.86, y: 0.2), to: NormPoint(x: 0.68, y: 0.46), lineWidth: 0.012, color: .brightRed),
            .step(1, at: NormPoint(x: 0.27, y: 0.47), diameter: 0.06, color: .brightRed),
            .step(2, at: NormPoint(x: 0.66, y: 0.53), diameter: 0.06, color: .brightRed),
            .ellipse(NormRect(x: 0.225, y: 0.085, width: 0.3, height: 0.085), lineWidth: 0.007, color: RGBAColor(hex: 0x8B5CF6)),
            .text("Best week yet", at: NormPoint(x: 0.6, y: 0.12), size: 0.045, color: .brightRed),
        ]
        await shoot("annotate-\(suffix)", output, size: CGSize(width: 1040, height: 700), wait: 3) {
            ImageEditorView(url: screenshotURL, startOnMarkup: true, markup: markup, onSave: { _ in }, onCancel: {})
                .tint(Theme.accent)
        }

        if let image = NSImage(contentsOf: screenshotURL) {
            let pin = PinController.preview(image: image)
            await shoot("pin-\(suffix)", output, size: CGSize(width: 600, height: 380), wait: 1.5, clear: true) {
                PinView(pin: pin, forceToolbar: true)
            }
        }

        // A history with a few kinds of capture.
        let store = art.appendingPathComponent("history-\(suffix)")
        try? FileManager.default.removeItem(at: store)
        let history = CaptureHistory(directory: store)
        let now = Date()
        let framed = art.appendingPathComponent("framed.png")
        if let image = try? FrameRenderer.render(screenshot, style: FrameStyle(background: .gradient(0xFDBA74, 0xF43F5E))),
           let data = try? ImageConverter.data(from: image, type: .png) {
            try? data.write(to: framed)
        }
        let clip = fixtures.appendingPathComponent("clip.mp4")
        let page = art.appendingPathComponent("page.png")
        if let tall = SampleArt.tallPage(width: 300, height: 900), let data = try? ImageConverter.data(from: tall, type: .png) {
            try? data.write(to: page)
        }
        let entries: [(URL, HistoryItem.Kind, Double, Double?)] = [
            (screenshotURL, .screenshot, 60 * 5, nil), (framed, .screenshot, 60 * 40, nil), (clip, .recording, 60 * 90, 3),
            (page, .scrolling, 86_400 + 3600, nil), (screenshotURL, .screenshot, 86_400 + 7200, nil), (framed, .screenshot, 86_400 * 3, nil),
        ]
        for (url, kind, age, duration) in entries where FileManager.default.fileExists(atPath: url.path) {
            let size = (try? ImageConverter.loadCGImage(url)).map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: 320, height: 240)
            try? history.add(file: url, kind: kind, width: Int(size.width), height: Int(size.height), duration: duration,
                             date: now.addingTimeInterval(-age))
        }
        await shoot("history-\(suffix)", output, size: CGSize(width: 860, height: 620), wait: 3) {
            HistoryView(history: history)
        }

        await shoot("recording-controls-\(suffix)", output, size: CGSize(width: 260, height: 56), wait: 1, clear: true) {
            RecordingControlsBar(phase: .recording, elapsed: 42, micOn: true, audioOn: true).tint(Theme.accent)
        }

        await shoot("settings-capture-\(suffix)", output, size: CGSize(width: 520, height: 720), wait: 1.5) {
            Form { CaptureSettingsSections() }
                .formStyle(.grouped)
                .tint(Theme.accent)
        }
        await moreCaptureShots(suffix: suffix, output: output, art: art, fixtures: fixtures, screenshotURL: screenshotURL)
    }
}
