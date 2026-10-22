import AppKit
import AVFoundation
import CoreImage
import SwiftUI

// MARK: - More pictures for the tests

extension SampleArt {
    /// A short H.264 video made of the given frames, `seconds` long at 30 fps.
    static func makeVideo(at url: URL, seconds: Double, width: Int, height: Int,
                          frame: (Int) -> CGImage?) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ConversionError("couldn't write a video") }
        writer.startSession(atSourceTime: .zero)
        let count = Int(seconds * 30)
        let context = CIContext()
        for index in 0..<count {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let image = frame(index), let pool = adaptor.pixelBufferPool else { throw ConversionError("no frame") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw ConversionError("no buffer") }
            context.render(CIImage(cgImage: image), to: buffer)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ConversionError("video not finished") }
    }
}

// MARK: - Self-test

extension SelfTest {
    static func moreCaptureChecks(dir: URL, options: ConversionOptions) async {
        func writePNG(_ image: CGImage?, _ name: String) throws -> URL {
            guard let image else { throw ConversionError("couldn't draw \(name)") }
            let url = dir.appendingPathComponent(name)
            try ImageConverter.data(from: image, type: .png).write(to: url)
            return url
        }
        func sample(_ url: URL, _ x: Double, _ y: Double) throws -> RGBAColor {
            try ImageEditEngine.samplePixel(url, at: NormPoint(x: x, y: y))
        }
        func describe(_ c: RGBAColor) -> String { String(format: "r%.2f g%.2f b%.2f", c.red, c.green, c.blue) }
        func isRed(_ c: RGBAColor) -> Bool { c.red > 0.75 && c.green < 0.4 && c.blue < 0.4 }
        func isWhite(_ c: RGBAColor) -> Bool { c.red > 0.93 && c.green > 0.93 && c.blue > 0.93 }
        func edited(_ edit: ImageEdit, on input: URL) async throws -> URL {
            let result = try await Engine.perform(.editImage(edit), on: input, options: options) { _ in }
            guard let out = result.outputs.first else { throw ConversionError("no output") }
            return out
        }
        func defaults(_ name: String) throws -> UserDefaults {
            guard let d = UserDefaults(suiteName: "spinform.selftest.\(name).\(UUID().uuidString)") else { throw ConversionError("defaults") }
            return d
        }

        guard let white = try? writePNG(SampleArt.solid(0xFFFFFF, width: 400, height: 300), "white-2.png") else {
            record("Annotate: test canvas", nil, "couldn't draw the canvas")
            return
        }

        // Arrows.
        await check("Annotate: four arrow styles, including a curved one") {
            func render(_ style: ImageEdit.ArrowStyle, from: NormPoint, to: NormPoint, name: String) async throws -> URL {
                var edit = ImageEdit()
                edit.annotations = [ImageEdit.Annotation(kind: style == .solid ? .arrow(from: from, to: to) : .styledArrow(from: from, to: to, style: style),
                                                         color: .brightRed, size: 0.03)]
                let out = try await edited(edit, on: white)
                let named = dir.appendingPathComponent("arrow-\(name).png")
                try? FileManager.default.removeItem(at: named)
                try FileManager.default.moveItem(at: out, to: named)
                return named
            }
            let a = NormPoint(x: 0.1, y: 0.2), b = NormPoint(x: 0.9, y: 0.2)
            let solid = try await render(.solid, from: a, to: b, name: "solid")
            let double = try await render(.double, from: a, to: b, name: "double")
            let open = try await render(.open, from: a, to: b, name: "open")
            let curved = try await render(.curved, from: NormPoint(x: 0.1, y: 0.5), to: NormPoint(x: 0.9, y: 0.5), name: "curved")
            // Near the start, off the shaft: only the double arrow has a head there.
            let solidStart = try sample(solid, 0.15, 0.2 + 0.0267), doubleStart = try sample(double, 0.15, 0.2 + 0.0267)
            // Inside the head near the tip, off the shaft: filled for solid, empty for open.
            let solidHead = try sample(solid, 0.825, 0.2 + 0.03), openHead = try sample(open, 0.825, 0.2 + 0.03)
            // The curve bows up: red above the straight line's middle, white on it.
            let curveTop = try sample(curved, 0.5, 0.352), curveLine = try sample(curved, 0.5, 0.5)
            guard isWhite(solidStart), isRed(doubleStart) else {
                throw ConversionError("double start \(describe(doubleStart)), solid start \(describe(solidStart))")
            }
            guard isRed(solidHead), isWhite(openHead) else { throw ConversionError("solid head \(describe(solidHead)), open head \(describe(openHead))") }
            guard isRed(curveTop), isWhite(curveLine) else { throw ConversionError("curve \(describe(curveTop)) / \(describe(curveLine))") }
            return [solid, double, open, curved]
        }

        await check("Annotate: pencil smoothing, filled box and placed picture") {
            // A shaky horizontal stroke.
            var points: [NormPoint] = []
            for i in 0...200 {
                points.append(NormPoint(x: 0.1 + Double(i) * 0.004, y: 0.3 + (i % 2 == 0 ? 0.002 : -0.002)))
            }
            let smooth = StrokeSmoothing.smooth(points)
            let worst = smooth.map { abs($0.y - 0.3) }.max() ?? 1
            guard smooth.count < 20, smooth.count >= 2, worst < 0.002 else {
                throw ConversionError("\(smooth.count) points, wobble \(worst)")
            }
            guard let redPicture = SampleArt.solid(0xDC2626, width: 50, height: 50) else { throw ConversionError("art") }
            let picture = try writePNG(redPicture, "red-square.png")
            var edit = ImageEdit()
            edit.annotations = [
                ImageEdit.Annotation(kind: .pencil(smooth), color: .brightBlue, size: 0.03),
                ImageEdit.Annotation(kind: .filledRectangle(NormRect(x: 0.1, y: 0.6, width: 0.2, height: 0.2)), color: .brightGreen, size: 0.01),
                ImageEdit.Annotation(kind: .picture(picture.path, NormRect(x: 0.6, y: 0.55, width: 0.25, height: 0.3)), color: .black, size: 0),
            ]
            let out = try await edited(edit, on: white)
            let stroke = try sample(out, 0.5, 0.3), box = try sample(out, 0.2, 0.7), placed = try sample(out, 0.72, 0.7)
            guard stroke.blue > 0.8, stroke.red < 0.2, box.green > 0.6, box.red < 0.4, isRed(placed) else {
                throw ConversionError("stroke \(describe(stroke)), box \(describe(box)), picture \(describe(placed))")
            }
            let path = StrokeSmoothing.path(through: smooth.map { CGPoint(x: $0.x * 400, y: $0.y * 300) })
            guard !path.isEmpty else { throw ConversionError("empty path") }
            return [out]
        }

        await check("Annotate: seven text styles, the label style on a coloured box") {
            var outputs: [URL] = []
            var looks = Set<Data>()
            for style in ImageEdit.TextStyle.allCases {
                var edit = ImageEdit()
                edit.annotations = [ImageEdit.Annotation(kind: style == .bold ? .text("Hi there", at: NormPoint(x: 0.1, y: 0.1))
                                                         : .styledText("Hi there", at: NormPoint(x: 0.1, y: 0.1), style: style),
                                                         color: .brightBlue, size: 0.1)]
                let out = try await edited(edit, on: white)
                looks.insert(try Data(contentsOf: out))
                if style == .label {
                    let behind = try sample(out, 0.09, 0.15)
                    guard behind.blue > 0.8, behind.red < 0.2 else { throw ConversionError("label background \(describe(behind))") }
                    outputs.append(out)
                }
            }
            guard ImageEdit.TextStyle.allCases.count == 7, looks.count == 7 else { throw ConversionError("\(looks.count) different looks") }
            return outputs
        }

        await check("Annotate: pixelate is scrambled; secure blur leaves no detail") {
            let checker = try writePNG(SampleArt.checker(width: 400, height: 300, square: 3), "checker-2.png")
            var edit = ImageEdit()
            edit.redactions = [ImageEdit.Redaction(rect: NormRect(x: 0.1, y: 0.1, width: 0.4, height: 0.8), style: .pixelate),
                               ImageEdit.Redaction(rect: NormRect(x: 0.55, y: 0.1, width: 0.4, height: 0.8), style: .secureBlur)]
            let first = try await edited(edit, on: checker)
            let firstData = try Data(contentsOf: first)
            let second = try await edited(edit, on: checker)
            guard try Data(contentsOf: second) != firstData else { throw ConversionError("two runs came out the same") }
            var values: [Double] = []
            for i in 0..<10 { values.append(try sample(second, 0.6 + Double(i) * 0.03, 0.5).red) }
            let spread = (values.max() ?? 0) - (values.min() ?? 0)
            guard spread < 0.35, let mid = values.first, mid > 0.15, mid < 0.85 else { throw ConversionError("secure blur spread \(spread)") }
            return [first]
        }

        record("Annotate: highlighter fits the text line", [], {
            let lines = [NormRect(x: 0.1, y: 0.2, width: 0.6, height: 0.05), NormRect(x: 0.1, y: 0.3, width: 0.5, height: 0.05)]
            guard let fit = TextSnap.fit(NormRect(x: 0.2, y: 0.18, width: 0.3, height: 0.08), to: lines) else { return "no fit" }
            guard abs(fit.minX - 0.2) < 0.001, abs(fit.maxX - 0.5) < 0.001, fit.minY < 0.2, fit.minY > 0.19, fit.maxY > 0.25, fit.maxY < 0.26 else {
                return "fit \(fit)"
            }
            return TextSnap.fit(NormRect(x: 0.8, y: 0.8, width: 0.1, height: 0.1), to: lines) == nil ? nil : "fitted empty space"
        }())
        if let text = SampleArt.textImage("Highlight this line", width: 900, height: 160, size: 48) {
            let boxes = TextRecognizer.lineBoxes(in: text)
            record("Annotate: finds text lines for the highlighter", [], boxes.isEmpty ? "no lines found" : nil)
        }
        record("Annotate: crop snaps to edges and the middle", [], {
            let p = CropSnap.snapPoint(NormPoint(x: 0.99, y: 0.508))
            let moved = CropSnap.snapMove(NormRect(x: 0.01, y: 0.3, width: 0.4, height: 0.2))
            guard p == NormPoint(x: 1, y: 0.5), abs(moved.x) < 0.0001, abs(moved.y - 0.3) < 0.0001 else { return "snap \(p), \(moved)" }
            return CropSnap.snap(0.3) == 0.3 ? nil : "snapped a free value"
        }())
        record("Annotate: my colours are kept", [], {
            guard let d = try? defaults("palette") else { return "defaults" }
            MarkupPalette.add(RGBAColor(hex: 0x123456), defaults: d)
            MarkupPalette.add(RGBAColor(hex: 0xABCDEF), defaults: d)
            MarkupPalette.add(RGBAColor(hex: 0x123456), defaults: d)
            let kept = MarkupPalette.colors(defaults: d).map(\.hexValue)
            guard kept == [0xABCDEF, 0x123456] else { return "kept \(kept)" }
            MarkupPalette.remove(RGBAColor(hex: 0xABCDEF), defaults: d)
            return MarkupPalette.colors(defaults: d).map(\.hexValue) == [0x123456] ? nil : "not removed"
        }())
        record("Annotate: dropped pictures land where dropped", [], {
            let r = PicturePlacement.rect(pictureSize: CGSize(width: 200, height: 100), canvas: CGSize(width: 600, height: 400),
                                          centre: CGPoint(x: 300, y: 200))
            guard abs(r.width - 1.0 / 3) < 0.001, abs(r.height - 0.25) < 0.001, abs(r.midX - 0.5) < 0.001, abs(r.midY - 0.5) < 0.001 else {
                return "\(r)"
            }
            let corner = PicturePlacement.rect(pictureSize: CGSize(width: 100, height: 100), canvas: CGSize(width: 600, height: 400),
                                               centre: CGPoint(x: 590, y: 390))
            return corner.maxX <= 1.0001 && corner.maxY <= 1.0001 ? nil : "left the canvas \(corner)"
        }())

        await check("Annotate: .spinform project saves and reopens with everything editable") {
            guard let redPicture = SampleArt.solid(0xDC2626, width: 40, height: 40) else { throw ConversionError("art") }
            let picture = try writePNG(redPicture, "project-picture.png")
            var edit = ImageEdit()
            edit.quarterTurns = 1
            edit.crop = NormRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
            edit.redactions = [ImageEdit.Redaction(rect: NormRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .secureBlur)]
            edit.annotations = [
                .arrow(from: NormPoint(x: 0.1, y: 0.1), to: NormPoint(x: 0.5, y: 0.5)),
                ImageEdit.Annotation(kind: .styledArrow(from: NormPoint(x: 0.2, y: 0.2), to: NormPoint(x: 0.6, y: 0.3), style: .curved), color: .orange, size: 0.01),
                ImageEdit.Annotation(kind: .styledText("Note", at: NormPoint(x: 0.3, y: 0.3), style: .label), color: .yellow, size: 0.05),
                ImageEdit.Annotation(kind: .pencil([NormPoint(x: 0.1, y: 0.9), NormPoint(x: 0.2, y: 0.8)]), color: .black, size: 0.01),
                ImageEdit.Annotation(kind: .picture(picture.path, NormRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2)), color: .black, size: 0),
                .step(3, at: NormPoint(x: 0.7, y: 0.7)),
            ]
            edit.background = BackgroundEdit(fill: .color(.white))
            edit.outputFormat = .png
            let project = dir.appendingPathComponent("Shot.spinform")
            try SpinformProject.save(image: white, edit: edit, to: project)
            let opened = try SpinformProject.open(project, into: dir.appendingPathComponent("opened-project"))
            guard try Data(contentsOf: opened.image) == (try Data(contentsOf: white)) else { throw ConversionError("picture changed") }
            guard opened.edit.annotations.count == edit.annotations.count, opened.edit.redactions == edit.redactions,
                  opened.edit.crop == edit.crop, opened.edit.quarterTurns == 1, opened.edit.background == edit.background,
                  opened.edit.outputFormat == .png else { throw ConversionError("edit changed") }
            for (a, b) in zip(opened.edit.annotations, edit.annotations) {
                if case .picture(let path, let rect) = a.kind {
                    guard case .picture(_, let original) = b.kind, rect == original,
                          FileManager.default.fileExists(atPath: path), path != picture.path else { throw ConversionError("picture not carried") }
                } else if a != b {
                    throw ConversionError("annotation \(a.kind) changed")
                }
            }
            guard (try? SpinformProject.open(white)) == nil else { throw ConversionError("opened a PNG as a project") }
            return [project]
        }

        // Background tool.
        await check("Background frame: alignment, auto balance, picture and desktop backgrounds") {
            let size = CGSize(width: 400, height: 300)
            var style = FrameStyle(background: .solid(0xFFFFFF), padding: 0.1, corners: 0, shadow: 0, aspect: .square)
            style.alignment = .topLeft
            let topLeft = FrameLayout.layout(imageSize: size, style: style)
            style.alignment = .bottomRight
            let bottomRight = FrameLayout.layout(imageSize: size, style: style)
            guard topLeft.imageRect.origin == CGPoint(x: 40, y: 40), bottomRight.imageRect.origin == CGPoint(x: 40, y: 140) else {
                throw ConversionError("aligned \(topLeft.imageRect) / \(bottomRight.imageRect)")
            }
            // A picture whose content sits on the left moves right when balanced.
            guard let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw ConversionError("canvas") }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.2, blue: 0.8, alpha: 1))
            ctx.fill(CGRect(x: 30, y: 100, width: 90, height: 100))
            guard let lopsided = ctx.makeImage(), let focus = FrameBalance.visualCentre(of: lopsided) else { throw ConversionError("no focus") }
            guard focus.x < 0.25, abs(focus.y - 0.5) < 0.08 else { throw ConversionError("focus \(focus)") }
            var balanced = FrameStyle(background: .solid(0xFFFFFF), padding: 0.1, corners: 0, shadow: 0, aspect: .auto)
            let plain = FrameLayout.layout(imageSize: size, style: balanced, focus: focus)
            balanced.balance = true
            let moved = FrameLayout.layout(imageSize: size, style: balanced, focus: focus)
            guard moved.imageRect.minX > plain.imageRect.minX + 20 else { throw ConversionError("balanced \(moved.imageRect) vs \(plain.imageRect)") }
            // A picture background.
            guard let green = SampleArt.solid(0x16A34A, width: 64, height: 64) else { throw ConversionError("art") }
            let backgroundFile = try writePNG(green, "frame-background.png")
            guard let red = SampleArt.solid(0xDC2626, width: 200, height: 100) else { throw ConversionError("art") }
            let framed = try writePNG(try FrameRenderer.render(red, style: FrameStyle(background: .image(backgroundFile.path), padding: 0.15,
                                                                                       corners: 0, shadow: 0, aspect: .auto)), "framed-picture.png")
            let corner = try sample(framed, 0.02, 0.02)
            guard corner.green > 0.5, corner.red < 0.3 else { throw ConversionError("picture background \(describe(corner))") }
            DesktopPicture.refresh()
            _ = try FrameRenderer.render(red, style: FrameStyle(background: .desktop))
            // Looks saved before alignment existed still load.
            let old = Data(#"{"background":{"solid":{"_0":255}},"padding":0.1,"corners":0.02,"shadow":0.5,"aspect":"square"}"#.utf8)
            let decoded = try JSONDecoder().decode(FrameStyle.self, from: old)
            guard decoded.alignment == .center, !decoded.balance, decoded.aspect == .square else { throw ConversionError("old look \(decoded)") }
            return [framed]
        }
        record("Window capture: backdrop choices become frame looks", [], {
            let color = CaptureCoordinator.backdropStyle(.color, color: 0x123456, picture: nil, padding: 0.5)
            let picture = CaptureCoordinator.backdropStyle(.image, color: 0, picture: URL(fileURLWithPath: "/tmp/x.png"), padding: 0.05)
            let desktop = CaptureCoordinator.backdropStyle(.desktop, color: 0, picture: nil, padding: 0.05)
            guard color.background == .solid(0x123456), color.padding == 0.25, picture.background == .image("/tmp/x.png"),
                  desktop.background == .desktop, color.corners == 0 else { return "styles" }
            return WindowBackdrop.transparent.usesBackground || !WindowBackdrop.color.usesBackground ? "usesBackground" : nil
        }())

        // Capture.
        await check("Scrolling capture: sideways frames stitch into a wide picture") {
            guard let tall = SampleArt.tallPage(width: 300, height: 1500, seed: 9),
                  let wide = ScrollStitcher.turn(tall, clockwise: false) else { throw ConversionError("no page") }
            guard wide.width == 1500, wide.height == 300 else { throw ConversionError("turned \(wide.width)×\(wide.height)") }
            let stitcher = ScrollStitcher(axis: .horizontal)
            for left in [0, 260, 540, 820, 1000] {
                guard let frame = wide.cropping(to: CGRect(x: left, y: 0, width: 500, height: 300)) else { throw ConversionError("crop") }
                stitcher.add(frame)
            }
            guard let result = stitcher.makeImage() else { throw ConversionError("no result") }
            guard result.width == 1500, result.height == 300, stitcher.outputSize == CGSize(width: 1500, height: 300) else {
                throw ConversionError("stitched \(result.width)×\(result.height)")
            }
            let out = try writePNG(result, "stitched-sideways.png")
            let original = try writePNG(wide, "sideways-page.png")
            for x in [0.1, 0.5, 0.9] {
                let a = try sample(out, x, 0.5), b = try sample(original, x, 0.5)
                guard abs(a.red - b.red) < 0.05, abs(a.blue - b.blue) < 0.05 else { throw ConversionError("differs at \(x)") }
            }
            return [out]
        }
        record("All-in-one: sizes, shape lock and memory", [], {
            guard let d = try? defaults("chooser") else { return "defaults" }
            guard CaptureChooserMemory.parse(" 1,920 ") == 1920, CaptureChooserMemory.parse("4") == nil,
                  CaptureChooserMemory.parse("99999") == 16_384 else { return "parse" }
            CaptureChooserMemory.remember(.action(.window), size: CGSize(width: 800, height: 600), lock: true, defaults: d)
            guard CaptureChooserMemory.lastMode(defaults: d) == .window, CaptureChooserMemory.size(defaults: d) == CGSize(width: 800, height: 600),
                  CaptureChooserMemory.lockAspect(defaults: d) else { return "memory" }
            let end = SelectionView.constrained(start: .zero, end: CGPoint(x: 300, y: 50), ratio: 2)
            let up = SelectionView.constrained(start: CGPoint(x: 100, y: 100), end: CGPoint(x: 90, y: 0), ratio: 0.5)
            guard end == CGPoint(x: 300, y: 150), up == CGPoint(x: 50, y: 0) else { return "aspect \(end) \(up)" }
            return CaptureAction.allInOne.defaultHotkey?.display == "⌃⇧2" ? nil : "hotkey"
        }())
        record("Quick access: corners, sizes and file info", [], {
            let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
            let size = CGSize(width: 300, height: 214)
            let bottomLeft = QuickAccess.frame(index: 0, size: size, in: visible, right: false, top: false)
            let topRight = QuickAccess.frame(index: 1, size: size, in: visible, right: true, top: true)
            guard bottomLeft.origin == CGPoint(x: 10, y: 10), topRight.maxX == 990, topRight.maxY == 800 - 10 - 210 else {
                return "\(bottomLeft) \(topRight)"
            }
            return FileInfo.size(of: white) == nil ? "no size" : nil
        }())
        record("Pin: arrow keys nudge", [], {
            guard let left = KeyPanel.arrowStep(keyCode: 123, shift: false), let up = KeyPanel.arrowStep(keyCode: 126, shift: true) else {
                return "no step"
            }
            return left.dx == -1 && left.dy == 0 && up.dy == 10 && KeyPanel.arrowStep(keyCode: 0, shift: false) == nil ? nil : "steps"
        }())
        record("Recording: options for keys, clicks, camera and resolution", [], {
            guard KeystrokeOverlay.shouldShow(keyCode: 0, flags: [], shortcutsOnly: false),
                  !KeystrokeOverlay.shouldShow(keyCode: 0, flags: [.shift], shortcutsOnly: true),
                  KeystrokeOverlay.shouldShow(keyCode: 0, flags: [.command], shortcutsOnly: true),
                  KeystrokeOverlay.shouldShow(keyCode: 53, flags: [], shortcutsOnly: true) else { return "shortcuts only" }
            let capped = ScreenRecorder.capped(width: 3840, height: 2160, maxHeight: 1080)
            let portrait = ScreenRecorder.capped(width: 1000, height: 2000, maxHeight: 720)
            let small = ScreenRecorder.capped(width: 640, height: 480, maxHeight: 720)
            guard capped.width == 1920, capped.height == 1080, portrait.width == 720, portrait.height == 1440,
                  small.width == 640, small.height == 480 else { return "capped \(capped) \(portrait)" }
            let area = CGRect(x: 0, y: 0, width: 1000, height: 600)
            let bubble = WebcamStyle(corner: .topLeft, side: 120, rounded: true, full: false)
            guard bubble.frame(in: area) == CGRect(x: 24, y: 600 - 120 - 24, width: 120, height: 120),
                  WebcamStyle(full: true).frame(in: area) == area, bubble.cornerRadius < 60 else { return "camera" }
            let keys = KeystrokeLook(position: .top, scale: 1, light: true).frame(on: area, visible: area)
            return keys.maxY == 600 - 40 ? nil : "keys \(keys)"
        }())

        // Text recognition.
        record("Copy text: languages and line breaks", [], {
            guard !TextRecognizer.supportedLanguages.isEmpty else { return "no languages" }
            let joined = TextRecognizer.strippingLineBreaks("one\ntwo\n\nthree\nfour")
            return joined == "one two\n\nthree four" ? nil : "joined \(joined.debugDescription)"
        }())
        await check("Copy text: a chosen language, and a frame of a video") {
            guard let picture = SampleArt.textImage("Spinform reads video frames", width: 960, height: 180, size: 52) else {
                throw ConversionError("art")
            }
            let english = try TextRecognizer.recognize(picture, options: TextRecognizer.Options(language: "en-US", keepLineBreaks: false))
            guard english.text.contains("Spinform") else { throw ConversionError("read \(english.text.debugDescription)") }
            let video = dir.appendingPathComponent("text-video.mp4")
            let blank = SampleArt.solid(0xFFFFFF, width: 960, height: 180)
            try await SampleArt.makeVideo(at: video, seconds: 2, width: 960, height: 180) { index in index < 30 ? blank : picture }
            let early = try await TextRecognizer.recognize(videoAt: video, seconds: 0.3)
            let late = try await TextRecognizer.recognize(videoAt: video, seconds: 1.5)
            guard early.text.isEmpty, late.text.contains("video") else {
                throw ConversionError("early \(early.text.debugDescription), late \(late.text.debugDescription)")
            }
            return [video]
        }

        // History and automation.
        await check("History: recognised text is kept and filtered by type") {
            let store = CaptureHistory(directory: dir.appendingPathComponent("history-text"))
            let note = dir.appendingPathComponent("note.txt")
            try "Hello from OCR".write(to: note, atomically: true, encoding: .utf8)
            let item = try store.add(file: note, kind: .text, width: 0, height: 0)
            let shot = try store.add(file: white, kind: .screenshot, width: 400, height: 300)
            guard HistoryView.Filter.text.includes(item.kind), !HistoryView.Filter.text.includes(shot.kind),
                  HistoryView.Filter.screenshots.includes(shot.kind), HistoryView.Filter.all.includes(item.kind) else {
                throw ConversionError("filters")
            }
            guard (try? String(contentsOf: store.url(for: item), encoding: .utf8)) == "Hello from OCR" else { throw ConversionError("text lost") }
            return []
        }
        record("Automation: spinform:// links", [], {
            func parse(_ text: String) -> AutomationCommand? { URL(string: text).flatMap(AutomationCommand.parse) }
            let expected: [(String, AutomationCommand)] = [
                ("spinform://capture-area", .action(.area)), ("spinform://capture-window", .action(.window)),
                ("spinform://capture", .action(.allInOne)), ("spinform://record", .action(.recordArea)),
                ("spinform://ocr", .action(.text)), ("spinform://stop-recording", .stopRecording),
                ("spinform://restore-overlay", .restoreOverlay), ("SPINFORM://Capture-Screen", .action(.fullscreen)),
                ("spinform://pin?file=/tmp/a.png", .pin(URL(fileURLWithPath: "/tmp/a.png"))),
                ("spinform://ocr?file=/tmp/b.pdf", .textFromFile(URL(fileURLWithPath: "/tmp/b.pdf"))),
            ]
            for (text, command) in expected where parse(text) != command { return "\(text) → \(String(describing: parse(text)))" }
            return parse("spinform://nonsense") == nil && parse("https://capture-area") == nil && parse("spinform://pin") == nil
                ? nil : "accepted a bad link"
        }())

        // Studio.
        record("Studio: automatic zooms, smoothing and framing", [], {
            let zooms = StudioEngine.autoZooms(clicks: [1.0, 1.5, 6.0], duration: 8, scale: 2)
            guard zooms.count == 2, zooms[0].start == 0.4, abs(zooms[0].end - 3.7) < 0.001 else { return "zooms \(zooms)" }
            var track = CursorTrack()
            for i in 0...120 {
                let t = Double(i) / 60
                track.samples.append(.init(t: t, x: 0.5 + (i % 2 == 0 ? 0.02 : -0.02), y: 0.5))
            }
            let raw = StudioEngine.cursor(at: 1.0, track: track, smooth: false)?.x ?? 0
            let smooth = StudioEngine.cursor(at: 1.0, track: track, smooth: true)?.x ?? 0
            guard abs(raw - 0.52) < 0.001, abs(smooth - 0.5) < 0.008 else { return "smoothing \(raw) → \(smooth)" }
            let segment = ZoomSegment(start: 1, end: 3, scale: 2, centre: NormPoint(x: 0.95, y: 0.05))
            let middle = StudioEngine.zoomState(at: 2, zooms: [segment], track: nil, smooth: true)
            let outside = StudioEngine.zoomState(at: 0.5, zooms: [segment], track: nil, smooth: true)
            let easing = StudioEngine.zoomState(at: 1.1, zooms: [segment], track: nil, smooth: true)
            guard middle.scale == 2, middle.centre == NormPoint(x: 0.75, y: 0.25), outside.scale == 1,
                  easing.scale > 1, easing.scale < 2 else { return "zoom state \(middle) \(easing)" }
            let source = CGSize(width: 1600, height: 1000)
            guard StudioEngine.outputSize(source: source, aspect: .landscape) == CGSize(width: 1920, height: 1080),
                  StudioEngine.outputSize(source: source, aspect: .vertical) == CGSize(width: 1080, height: 1920),
                  StudioEngine.outputSize(source: source, aspect: .square, base: 540) == CGSize(width: 540, height: 540) else { return "sizes" }
            let content = StudioEngine.contentRect(source: source, output: CGSize(width: 1080, height: 1920), padding: 0.1)
            return abs(content.width - 864) < 1 && abs(content.midY - 960) < 1 ? nil : "content \(content)"
        }())
        await check("Studio: exports a trimmed, zoomed, square video with background and pointer") {
            StudioEngine.preparePointer()
            let source = dir.appendingPathComponent("studio-source.mp4")
            try await SampleArt.makeVideo(at: source, seconds: 3, width: 640, height: 360) { index in
                SampleArt.solid(index < 45 ? 0x2563EB : 0xF97316, width: 640, height: 360)
            }
            var track = CursorTrack(areaWidth: 640, areaHeight: 360)
            for i in 0...180 { track.samples.append(.init(t: Double(i) / 60, x: 0.2 + Double(i) / 300, y: 0.4)) }
            track.clicks = [.init(t: 1.2, x: 0.6, y: 0.4)]
            var settings = StudioSettings()
            settings.output = .square
            settings.background = .solid(0x16A34A)
            settings.padding = 0.1
            settings.trimStart = 0.5
            settings.trimEnd = 2.5
            settings.motionBlur = true
            settings.cursorSize = 1.5
            let out = dir.appendingPathComponent("studio-export.mp4")
            let done = try await StudioEngine.export(url: source, settings: settings, track: track, to: out, base: 540)
            let info = try await StudioEngine.info(of: done)
            guard info.size == CGSize(width: 540, height: 540), abs(info.duration - 2) < 0.2 else {
                throw ConversionError("exported \(info.size), \(info.duration)s")
            }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: done))
            let frame = try await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
            let still = try writePNG(frame, "studio-frame.png")
            let corner = try sample(still, 0.03, 0.03), middle = try sample(still, 0.5, 0.5)
            guard corner.green > 0.45, corner.red < 0.3, middle.blue > 0.6 else {
                throw ConversionError("corner \(describe(corner)), middle \(describe(middle))")
            }
            let preview = try await StudioEngine.previewFrame(url: source, seconds: 1.5, settings: settings, track: track)
            guard preview.width == 540 else { throw ConversionError("preview \(preview.width)") }
            let tracks = dir.appendingPathComponent("studio-tracks")
            StudioTracks.save(track, for: [source], in: tracks)
            guard StudioTracks.load(for: source, in: tracks) == track else { throw ConversionError("track not kept") }
            return [done, still]
        }
    }
}

// MARK: - More window pictures

extension Snapshots {
    static func moreCaptureShots(suffix: String, output: URL, art: URL, fixtures: URL, screenshotURL: URL) async {
        await shoot("capture-chooser-\(suffix)", output, size: CGSize(width: 540, height: 350), wait: 1.5, clear: true) {
            CaptureChooserView()
        }

        let picture = art.appendingPathComponent("logo-tile.png")
        if !FileManager.default.fileExists(atPath: picture.path),
           let tile = SampleArt.solid(0x8B5CF6, width: 120, height: 120), let data = try? ImageConverter.data(from: tile, type: .png) {
            try? data.write(to: picture)
        }
        let markup: [ImageEdit.Annotation] = [
            ImageEdit.Annotation(kind: .styledArrow(from: NormPoint(x: 0.12, y: 0.86), to: NormPoint(x: 0.3, y: 0.55), style: .curved),
                                 color: .brightRed, size: 0.01),
            ImageEdit.Annotation(kind: .styledArrow(from: NormPoint(x: 0.88, y: 0.9), to: NormPoint(x: 0.76, y: 0.62), style: .open),
                                 color: RGBAColor(hex: 0x8B5CF6), size: 0.009),
            ImageEdit.Annotation(kind: .styledText("New this week", at: NormPoint(x: 0.6, y: 0.1), style: .label),
                                 color: RGBAColor(hex: 0xEC4899), size: 0.04),
            ImageEdit.Annotation(kind: .highlight(NormRect(x: 0.235, y: 0.175, width: 0.38, height: 0.04)), color: .yellow, size: 0),
            ImageEdit.Annotation(kind: .pencil(StrokeSmoothing.smooth((0...40).map { i in
                NormPoint(x: 0.25 + Double(i) * 0.0105, y: 0.255 + sin(Double(i) / 3) * 0.006)
            })), color: .brightBlue, size: 0.006),
            ImageEdit.Annotation(kind: .filledRectangle(NormRect(x: 0.74, y: 0.53, width: 0.2, height: 0.05)), color: .black, size: 0.01),
            ImageEdit.Annotation(kind: .picture(picture.path, NormRect(x: 0.03, y: 0.07, width: 0.08, height: 0.12)), color: .black, size: 0),
        ]
        await shoot("annotate-tools-\(suffix)", output, size: CGSize(width: 1040, height: 760), wait: 3) {
            ImageEditorView(url: screenshotURL, markup: markup, markupTool: "Text", onSave: { _ in }, onCancel: {})
                .tint(Theme.accent)
        }

        var look = FrameStyle(background: .gradient(0xFF8A65, 0xF43F5E), padding: 0.08, corners: 0.02, shadow: 0.7, aspect: .square)
        look.alignment = .bottom
        await shoot("frame-position-\(suffix)", output, size: CGSize(width: 980, height: 760), wait: 3) {
            FrameToolView(url: screenshotURL, style: look)
        }

        let clip = fixtures.appendingPathComponent("clip.mp4")
        if FileManager.default.fileExists(atPath: clip.path) {
            var track = CursorTrack(areaWidth: 640, areaHeight: 360)
            for i in 0...600 { track.samples.append(.init(t: Double(i) / 60, x: 0.3 + Double(i) / 1500, y: 0.35 + Double(i) / 3000)) }
            track.clicks = [.init(t: 1.0, x: 0.36, y: 0.38), .init(t: 4.0, x: 0.6, y: 0.5)]
            var settings = StudioSettings()
            settings.background = .gradient(0x4338CA, 0xEC4899)
            settings.zooms = [ZoomSegment(start: 6, end: 7.5, scale: 1.8, centre: NormPoint(x: 0.5, y: 0.5), manual: true)]
            StudioEngine.preparePointer()
            await shoot("studio-\(suffix)", output, size: CGSize(width: 1100, height: 720), wait: 4) {
                StudioView(url: clip, settings: settings, track: track, time: 1.6)
            }
        } else {
            print("FAIL  studio picture: no clip.mp4 fixture")
        }

        let result = CaptureResult(url: screenshotURL, kind: .screenshot, savedToFolder: true, pixelSize: CGSize(width: 1200, height: 760))
        await shoot("capture-overlay-tools-\(suffix)", output, size: QuickAccess.cardSize, wait: 2, clear: true) {
            QuickAccessCard(result: result, actions: QuickActions(), forceHover: true)
        }
    }
}
