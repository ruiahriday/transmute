import AppKit
import AVFoundation
import CoreImage
import CoreML
import PDFKit
import Vision

/// Text and QR codes from pictures, on this Mac only (Vision), never uploaded.
enum TextRecognizer {
    struct Result: Sendable {
        var text: String
        var qrCodes: [String]
        /// The text with its line breaks, whatever the setting, for the result window's switch.
        var lines: String = ""

        var isEmpty: Bool { text.isEmpty && qrCodes.isEmpty }

        /// What goes on the clipboard: the text, then any QR code contents not already in it.
        var clipboardText: String {
            let extra = qrCodes.filter { !text.contains($0) }
            return ([text] + extra).filter { !$0.isEmpty }.joined(separator: "\n")
        }

        var wordCount: Int { text.split(whereSeparator: { $0.isWhitespace }).count }
    }

    /// How text is read: which language to expect (nil: work it out) and whether to keep line breaks.
    struct Options: Equatable, Sendable {
        var language: String? = nil
        var keepLineBreaks = true

        static var fromSettings: Options {
            let defaults = UserDefaults.standard
            let language = defaults.string(forKey: Prefs.ocrLanguage) ?? ""
            return Options(language: language.isEmpty ? nil : language,
                           keepLineBreaks: defaults.object(forKey: Prefs.ocrKeepLineBreaks) as? Bool ?? true)
        }
    }

    /// Languages this Mac's Vision can read, as codes ("en-US", "fr-FR", "zh-Hans", …).
    static var supportedLanguages: [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
    }

    /// "French (France)" for "fr-FR".
    static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }

    static func recognize(_ image: CGImage, options: Options = .fromSettings) throws -> Result {
        let codes = qrCodes(in: image)
        do {
            let lines = try lines(in: image, options: options)
            return Result(text: options.keepLineBreaks ? lines : strippingLineBreaks(lines), qrCodes: codes, lines: lines)
        } catch {
            // A QR code is still worth copying when the text reader gives up.
            if !codes.isEmpty { return Result(text: "", qrCodes: codes) }
            throw error
        }
    }

    // MARK: Robust reading

    /// A plain 8-bit sRGB picture, upright, on white, that Vision always accepts: whatever the source
    /// (16-bit, P3, IOSurface-backed, transparent), it's redrawn into a fresh bitmap. Huge pictures are
    /// shrunk to 4096 px on the long side; small crops are enlarged so their text is big enough to read.
    static func prepared(_ image: CGImage, maxSide: Int = 4096) -> CGImage {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return image }
        let longest = Double(max(w, h)), shortest = Double(min(w, h))
        var scale = 1.0
        if longest > Double(maxSide) {
            scale = Double(maxSide) / longest
        } else if shortest < 120 {
            scale = min(4, max(2, (64 / shortest).rounded(.up)), Double(maxSide) / longest)
        }
        let width = max(1, Int((Double(w) * scale).rounded())), height = max(1, Int((Double(h) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? image
    }

    /// The ways of reading tried in turn, stopping at the first that works.
    enum Attempt: String, CaseIterable {
        case accurate = "Vision accurate (latest revision)"
        case fast = "Vision fast"
        case cpu = "Vision on the CPU only"
        case swiftVision = "Vision RecognizeTextRequest (macOS 15)"
        case olderRevision = "Vision older revision"
    }

    /// Text with its line breaks, trying each way of reading until one works.
    static func lines(in image: CGImage, options: Options = .fromSettings) throws -> String {
        let source = prepared(image)
        var failures: [RecognitionFailure.Attempt] = []
        for attempt in Attempt.allCases {
            do {
                guard let pieces = try read(source, attempt: attempt, options: options) else { continue }
                return assemble(pieces)
            } catch {
                failures.append(RecognitionFailure.Attempt(name: attempt.rawValue, error: error as NSError))
            }
        }
        throw RecognitionFailure(attempts: failures)
    }

    /// One way of reading; nil when it isn't available here.
    static func read(_ image: CGImage, attempt: Attempt, options: Options) throws -> [(box: CGRect, text: String)]? {
        if attempt == .swiftVision {
            if #available(macOS 15.0, *) { return try readWithSwiftVision(image) }
            return nil
        }
        let request = VNRecognizeTextRequest()
        let revisions = VNRecognizeTextRequest.supportedRevisions.sorted()
        if attempt == .olderRevision {
            guard revisions.count > 1, let older = revisions.dropLast().last else { return nil }
            request.revision = older
        } else if let latest = revisions.last {
            request.revision = latest
        }
        request.recognitionLevel = attempt == .fast ? .fast : .accurate
        request.usesLanguageCorrection = attempt != .fast
        if attempt == .cpu { useCPU(request) }
        setLanguages(request, options)
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return (observation.boundingBox, candidate.string)
        }
    }

    /// Only languages this Mac's Vision lists; anything else (an old setting, another Mac's code) means "work it out".
    static func setLanguages(_ request: VNRecognizeTextRequest, _ options: Options) {
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        if let wanted = options.language, let match = matchLanguage(wanted, in: supported) {
            request.recognitionLanguages = [match]
            request.automaticallyDetectsLanguage = false
        } else if request.recognitionLevel == .accurate, request.revision >= VNRecognizeTextRequestRevision3 {
            request.automaticallyDetectsLanguage = true
        }
    }

    /// "fr-FR" for "fr-FR", or for "fr" when only "fr-FR" is listed; nil when this Mac can't read it.
    static func matchLanguage(_ wanted: String, in supported: [String]) -> String? {
        if supported.contains(wanted) { return wanted }
        let base = wanted.split(separator: "-").first.map(String.init)?.lowercased() ?? wanted.lowercased()
        return supported.first { $0.split(separator: "-").first.map(String.init)?.lowercased() == base }
    }

    private static func useCPU(_ request: VNRecognizeTextRequest) {
        if #available(macOS 14.0, *) {
            if let devices = try? request.supportedComputeStageDevices[.main],
               let cpu = devices.first(where: { if case .cpu = $0 { return true } else { return false } }) {
                request.setComputeDevice(cpu, for: .main)
                return
            }
        }
        request.usesCPUOnly = true
    }

    private final class Outcome: @unchecked Sendable {
        var pieces: [(box: CGRect, text: String)] = []
        var error: Error?
    }

    /// The newer Swift Vision reader. It's async, so it's waited for here (never on the main thread).
    @available(macOS 15.0, *)
    private static func readWithSwiftVision(_ image: CGImage) throws -> [(box: CGRect, text: String)]? {
        guard !Thread.isMainThread else { return nil }
        let box = ImageEditEngine.PreviewImage(image: image, originalSize: .zero)
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do {
                var request = RecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let observations = try await request.perform(on: box.image, orientation: .up)
                outcome.pieces = observations.compactMap { observation in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return (observation.boundingBox.cgRect, candidate.string)
                }
            } catch {
                outcome.error = error
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + 30) == .success else { throw CaptureFailure.timedOut("Reading text") }
        if let error = outcome.error { throw error }
        return outcome.pieces
    }

    /// Where the lines of text are (normalized, top-left origin), for the highlighter. Fast and rough.
    static func lineBoxes(in image: CGImage) -> [NormRect] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: prepared(image), orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? []).map { observation in
            let box = observation.boundingBox
            return NormRect(x: Double(box.minX), y: Double(1 - box.maxY), width: Double(box.width), height: Double(box.height))
        }
    }

    /// Joins lines into one paragraph per block when line breaks aren't wanted (a blank line still separates blocks).
    static func strippingLineBreaks(_ text: String) -> String {
        text.components(separatedBy: "\n\n").map { block in
            block.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        }.joined(separator: "\n\n")
    }

    /// One frame of a video, read for text.
    static func recognize(videoAt url: URL, seconds: Double, options: Options = .fromSettings) async throws -> Result {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        let frame: CGImage
        do {
            frame = try await generator.image(at: CMTime(seconds: max(0, seconds), preferredTimescale: 600)).image
        } catch {
            throw ConversionError("Couldn't read that frame: \(error.localizedDescription)")
        }
        let box = ImageEditEngine.PreviewImage(image: frame, originalSize: .zero)
        return try await Task.detached(priority: .userInitiated) { try recognize(box.image, options: options) }.value
    }

    /// Lines of text top to bottom, words left to right.
    static func text(in image: CGImage, options: Options = .fromSettings) throws -> String {
        let text = try lines(in: image, options: options)
        return options.keepLineBreaks ? text : strippingLineBreaks(text)
    }

    /// Groups Vision's boxes (normalized, bottom-left origin) into lines.
    static func assemble(_ pieces: [(box: CGRect, text: String)]) -> String {
        let sorted = pieces.sorted { $0.box.midY > $1.box.midY }
        var lines: [[(box: CGRect, text: String)]] = []
        for piece in sorted {
            if let last = lines.last?.last, abs(last.box.midY - piece.box.midY) < max(last.box.height, piece.box.height) * 0.5 {
                lines[lines.count - 1].append(piece)
            } else {
                lines.append([piece])
            }
        }
        return lines.map { line in
            line.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// The same detector as the Tools tab's Read QR Codes.
    /// Read from the same cleaned-up picture as the text, with Vision's barcode reader as a fallback.
    static func qrCodes(in image: CGImage) -> [String] {
        let source = prepared(image)
        let found = ImageConverter.qrMessages(in: CIImage(cgImage: source))
        if !found.isEmpty { return found }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: source, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        var codes: [String] = []
        for payload in (request.results ?? []).compactMap(\.payloadStringValue) where !codes.contains(payload) {
            codes.append(payload)
        }
        return codes
    }

    /// Text from an image file, or from every page of a PDF (up to 30 pages).
    static func recognize(fileAt url: URL) throws -> Result {
        if FileKind.of(url) == .pdf {
            guard let document = PDFDocument(url: url) else { throw ConversionError("Couldn't open \(url.lastPathComponent).") }
            var texts: [String] = []
            var codes: [String] = []
            for index in 0..<min(document.pageCount, 30) {
                guard let page = document.page(at: index) else { continue }
                // A PDF that already has text: use it as it is.
                if let existing = page.string?.trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
                    texts.append(existing)
                    continue
                }
                guard let picture = render(page) else { continue }
                let result = try recognize(picture)
                texts.append(result.text)
                codes += result.qrCodes
            }
            return Result(text: texts.filter { !$0.isEmpty }.joined(separator: "\n\n"), qrCodes: codes)
        }
        return try recognize(try ImageConverter.loadCGImage(url))
    }

    /// A PDF page at about 200 dpi on white.
    static func render(_ page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let scale: CGFloat = 200.0 / 72.0
        let width = Int(box.width * scale), height = Int(box.height * scale)
        guard width > 0, height > 0, width < 12000, height < 12000,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    /// Copies the result (only the text, replacing whatever was on the clipboard), says so, and
    /// shows it in a small window to check or edit.
    @MainActor
    static func deliver(_ result: Result, showWindow: Bool = true) {
        guard !result.isEmpty else {
            Toast.show("No text found", detail: "Try a larger area, or text with more contrast.", symbol: "exclamationmark.triangle.fill")
            return
        }
        copyText(result.clipboardText)
        let preview = result.clipboardText.replacingOccurrences(of: "\n", with: " ")
        let short = preview.count > 80 ? String(preview.prefix(80)) + "…" : preview
        if result.text.isEmpty {
            Toast.show("QR code copied — paste anywhere", detail: short, symbol: "qrcode")
        } else {
            Toast.show("Text copied — paste anywhere", detail: short, symbol: "text.viewfinder")
        }
        if showWindow { TextResultPanel.show(result) }
    }

    /// Puts only this string on the clipboard.
    @MainActor
    static func copyText(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.declareTypes([.string], owner: nil)
        board.setString(text, forType: .string)
    }

    /// The toast for a failed read, with the real error and a Copy Details button.
    @MainActor
    static func showFailure(_ error: Error) {
        let symbol = "exclamationmark.triangle.fill"
        if let failure = error as? RecognitionFailure {
            Toast.show("Couldn't read text", detail: failure.errorDescription, symbol: symbol, copyDetails: failure.details)
        } else {
            let ns = error as NSError
            Toast.show("Couldn't read text", detail: error.localizedDescription, symbol: symbol,
                       copyDetails: RecognitionFailure.header + ["\(ns.domain) \(ns.code): \(ns.localizedDescription)"].joined(separator: "\n"))
        }
    }
}

/// Every way of reading failed; carries each error so the owner can send them to us.
struct RecognitionFailure: LocalizedError, @unchecked Sendable {
    struct Attempt { let name: String; let error: NSError }
    let attempts: [Attempt]

    var errorDescription: String? {
        guard let first = attempts.first?.error else { return "macOS's text reader isn't available." }
        return "macOS's text reader refused this picture (\(Self.short(first.domain)) error \(first.code)). Copy the details and send them to us."
    }

    static var header: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Spinform \(version) (\(build)), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
    }

    var details: String {
        var lines: [String] = []
        for attempt in attempts {
            let e = attempt.error
            lines.append("\(attempt.name): \(e.domain) \(e.code): \(e.localizedDescription)")
            if let under = e.userInfo[NSUnderlyingErrorKey] as? NSError {
                lines.append("    underlying: \(under.domain) \(under.code): \(under.localizedDescription)")
            }
        }
        return Self.header + "Text recognition failed:\n" + lines.joined(separator: "\n")
    }

    /// "CRImageReaderError" for "TextRecognition.CRImageReaderError".
    static func short(_ domain: String) -> String { domain.split(separator: ".").last.map(String.init) ?? domain }
}

/// A small floating window with the recognised text: edit it, switch line breaks, copy again.
@MainActor
final class TextResultPanel: NSObject, NSWindowDelegate {
    static private(set) var current: TextResultPanel?

    let panel: NSPanel
    let textView: NSTextView
    let lineBreaks: NSButton
    private let lines: String

    static func show(_ result: TextRecognizer.Result) {
        current?.close()
        let window = TextResultPanel(result)
        current = window
        window.panel.makeKeyAndOrderFront(nil)
        window.panel.orderFrontRegardless()
    }

    private init(_ result: TextRecognizer.Result) {
        let base = result.lines.isEmpty ? result.text : result.lines
        let extra = result.qrCodes.filter { !base.contains($0) }
        lines = ([base] + extra).filter { !$0.isEmpty }.joined(separator: "\n")
        let size = NSSize(width: 420, height: 260)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        lineBreaks = NSButton(checkboxWithTitle: "Keep line breaks", target: nil, action: nil)
        super.init()
        panel.title = "Copied Text"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.minSize = NSSize(width: 300, height: 160)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true

        lineBreaks.target = self
        lineBreaks.action = #selector(toggleLineBreaks)
        lineBreaks.state = TextRecognizer.Options.fromSettings.keepLineBreaks ? .on : .off
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyText))
        copy.bezelColor = .controlAccentColor
        copy.keyEquivalent = "c"
        copy.keyEquivalentModifierMask = [.command, .shift]
        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        close.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [lineBreaks, spacer, close, copy])
        row.orientation = .horizontal
        row.spacing = 8
        let stack = NSStackView(views: [scroll, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
        panel.contentView = content
        textView.string = shownText
        // Near the capture cards, at the bottom corner of the screen in use.
        if let screen = ScreenGrabber.screenUnderMouse ?? NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrame(NSRect(x: visible.maxX - size.width - 24, y: visible.minY + 220, width: size.width, height: size.height),
                           display: false)
        }
    }

    private var shownText: String { lineBreaks.state == .on ? lines : TextRecognizer.strippingLineBreaks(lines) }

    @objc private func toggleLineBreaks() { textView.string = shownText }

    @objc func copyText() {
        TextRecognizer.copyText(textView.string)
        Toast.show("Text copied — paste anywhere", symbol: "text.viewfinder")
    }

    @objc private func closeWindow() { close() }

    func close() {
        panel.orderOut(nil)
        if Self.current === self { Self.current = nil }
    }

    func windowWillClose(_ notification: Notification) {
        if Self.current === self { Self.current = nil }
    }
}
