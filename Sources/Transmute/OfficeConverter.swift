import AppKit
import CoreText
import PDFKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// E-books, iWork and Office files. EPUB, XLSX, ODS, CSV and TSV are read and written
/// natively; Pages, Keynote and Numbers do the rest through AppleScript when installed.
enum OfficeConverter {
    /// Spreadsheet formats Transmute reads without Numbers.
    private static let nativeSpreadsheets: Set<String> = ["xlsx", "csv", "tsv", "ods"]

    static func convert(_ input: URL, kind: FileKind, to format: OutputFormat, options: ConversionOptions) async throws -> [URL] {
        try await run(input, kind: kind, to: format, options: options).outputs
    }

    /// Like `convert`, plus a note when the result is partial (first slide only, made from a preview…).
    static func run(_ input: URL, kind: FileKind, to format: OutputFormat, options: ConversionOptions) async throws -> JobResult {
        let ext = input.pathExtension.lowercased()
        // Same format in and out (CSV is re-quoted instead).
        if ext == format.fileExtension && format != .csv {
            let out = OutputPaths.destination(for: input, ext: ext, folder: options.outputFolder)
            try FileManager.default.copyItem(at: input, to: out)
            return JobResult(outputs: [out], message: "Already \(format.label), so this is a copy")
        }
        switch kind {
        case .ebook:
            return JobResult(outputs: [try await convertEPUB(input, to: format, options: options)])
        case .document where ext == "pages":
            return try await convertPages(input, to: format, options: options)
        case .document:
            return JobResult(outputs: [try await convertDocument(input, kind: kind, to: format, options: options)])
        case .presentation:
            return try await convertPresentation(input, to: format, options: options)
        case .spreadsheet:
            return try await convertSpreadsheet(input, ext: ext, to: format, options: options)
        default:
            throw ConversionError("Can't convert \(input.lastPathComponent) to \(format.label).")
        }
    }

    /// "Pages", "Keynote" or "Numbers" when this conversion needs that app and it isn't installed;
    /// nil when it can run on this Mac.
    static func requiredApp(for input: URL, to format: OutputFormat) -> String? {
        guard let app = appNeeded(for: input, to: format), !isInstalled(app) else { return nil }
        return app.rawValue
    }

    // MARK: iWork apps

    private enum IWorkApp: String {
        case pages = "Pages", keynote = "Keynote", numbers = "Numbers"
        var bundleID: String { "com.apple.iWork.\(rawValue)" }
    }

    /// Which app a conversion can't do without, ignoring whether it's installed.
    private static func appNeeded(for input: URL, to format: OutputFormat) -> IWorkApp? {
        let ext = input.pathExtension.lowercased()
        if ext == format.fileExtension && format != .csv { return nil } // saved as a copy
        switch FileKind.of(input) {
        case .document:
            if ext == "pages" { return hasPagesPreview(input) ? nil : .pages }
            return format == .pages ? .pages : nil
        case .presentation:
            // Without Keynote, Quick Look still draws the first slide.
            return format == .png || format == .jpeg ? nil : .keynote
        case .spreadsheet:
            if format == .numbers { return .numbers }
            return nativeSpreadsheets.contains(ext) ? nil : .numbers
        default:
            return nil
        }
    }

    private static func isInstalled(_ app: IWorkApp) -> Bool {
        // Lets the self-test exercise the fallbacks on a Mac that has iWork.
        if ProcessInfo.processInfo.environment["TRANSMUTE_NO_IWORK"] != nil { return false }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) != nil
    }

    private static func missingApp(_ app: IWorkApp, _ what: String) -> ConversionError {
        ConversionError("\(what) needs Apple's free \(app.rawValue) app. Install it from the App Store, then try again.")
    }

    /// Opens a private copy of `source` in an iWork app and exports it (`export` is the AppleScript
    /// format, e.g. "PDF") or saves it in the app's own format (`export` nil). Returns the path the
    /// app wrote to, inside `work`; for slide images and multi-table CSV that's a folder.
    private static func iWorkExport(_ app: IWorkApp, _ source: URL, export clause: String?, ext: String,
                                    work: URL) async throws -> URL {
        // A copy, so closing without saving can never throw away edits the user has open in the app.
        let copy = try stageCopy(source, in: work.appendingPathComponent("in", isDirectory: true))
        let outDir = work.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let name = OutputPaths.baseName(of: source)
        let target = outDir.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
        try await runAppleScript(app, open: copy, export: clause, to: target)
        return target
    }

    private static func runAppleScript(_ app: IWorkApp, open file: URL, export clause: String?, to target: URL) async throws {
        let command = clause.map { "export theDoc to outFile as \($0)" } ?? "save theDoc in outFile"
        let script = """
            set inFile to POSIX file \(appleScriptString(file.path))
            set outFile to POSIX file \(appleScriptString(target.path))
            tell application id \(appleScriptString(app.bundleID))
                with timeout of 1800 seconds
                    set theDoc to open inFile
                    try
                        \(command)
                    on error errorText number errorNumber
                        close theDoc saving no
                        error errorText number errorNumber
                    end try
                    close theDoc saving no
                end timeout
            end tell
            """
        await launchHidden(app)
        do {
            try await Shell.check("/usr/bin/osascript", ["-e", script])
        } catch let error as CancellationError {
            throw error
        } catch {
            let text = error.localizedDescription
            if text.contains("-1743") || text.localizedCaseInsensitiveContains("not authori") {
                throw ConversionError("Transmute isn't allowed to control \(app.rawValue). Allow it in System Settings → Privacy & Security → Automation, then try again.")
            }
            if text.contains("-1712") { throw ConversionError("\(app.rawValue) took too long to respond.") }
            var detail = text
            if let range = detail.range(of: "execution error: ") { detail = String(detail[range.upperBound...]) }
            throw ConversionError(detail)
        }
    }

    /// Starts the app in the background so it doesn't jump in front of the user.
    private static func launchHidden(_ app: IWorkApp) async {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty else { return }
        _ = try? await Shell.run("/usr/bin/open", ["-g", "-j", "-b", app.bundleID])
    }

    /// A double-quoted AppleScript string literal.
    private static func appleScriptString(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    // MARK: Documents

    private static func convertDocument(_ input: URL, kind: FileKind, to format: OutputFormat,
                                        options: ConversionOptions) async throws -> URL {
        switch format {
        case .epub:
            return try await makeEPUB(from: input, kind: kind, named: input, options: options)
        case .pages:
            guard isInstalled(.pages) else { throw missingApp(.pages, "Saving as a Pages document") }
            let work = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: work) }
            var source = input
            if !["docx", "doc", "rtf", "txt"].contains(input.pathExtension.lowercased()) {
                // Pages can't open Markdown, HTML or ODT, so those go through a Word file.
                source = try await DocumentConverter.convert(input, kind: kind, to: .docx,
                                                             options: ConversionOptions(outputFolder: work))
            }
            let saved = try await iWorkExport(.pages, source, export: nil, ext: "pages", work: work)
            return try deliver(saved, for: input, ext: "pages", options: options)
        default:
            return try await DocumentConverter.convert(input, kind: kind, to: format, options: options)
        }
    }

    private static func convertPages(_ input: URL, to format: OutputFormat, options: ConversionOptions) async throws -> JobResult {
        let preview = hasPagesPreview(input)
        if preview && (format == .pdf || format == .txt) {
            return JobResult(outputs: [try await fromPagesPreview(input, to: format, options: options)])
        }
        if isInstalled(.pages) {
            return JobResult(outputs: [try await pagesExport(input, to: format, options: options)])
        }
        if preview {
            let out = try await fromPagesPreview(input, to: format, options: options)
            return JobResult(outputs: [out], message: "Made from the preview inside the Pages file. Install Pages (free) for an exact conversion.")
        }
        throw missingApp(.pages, "Opening Pages documents")
    }

    private static func pagesExport(_ input: URL, to format: OutputFormat, options: ConversionOptions) async throws -> URL {
        let work = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        let clause: String? = switch format {
        case .pdf: "PDF"
        case .docx: "Microsoft Word"
        case .rtf: "formatted text"
        case .txt: "unformatted text"
        case .epub: "EPUB"
        default: nil
        }
        if let clause {
            let exported = try await iWorkExport(.pages, input, export: clause, ext: format.fileExtension, work: work)
            return try deliver(exported, for: input, ext: format.fileExtension, options: options)
        }
        // Pages can't write HTML or ODT: go through a Word file.
        let word = try await iWorkExport(.pages, input, export: "Microsoft Word", ext: "docx", work: work)
        let made = try await DocumentConverter.convert(word, kind: .document, to: format,
                                                       options: ConversionOptions(outputFolder: work))
        return try deliver(made, for: input, ext: format.fileExtension, options: options)
    }

    /// Older Pages files (and newer ones saved with a preview) carry a PDF of the whole document.
    private static func hasPagesPreview(_ input: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: input.path, isDirectory: &isDirectory) else { return false }
        if isDirectory.boolValue {
            return FileManager.default.fileExists(atPath: input.appendingPathComponent("QuickLook/Preview.pdf").path)
        }
        // A zipped Pages file stores entry names uncompressed, so a byte search finds it.
        guard let data = try? Data(contentsOf: input, options: .mappedIfSafe) else { return false }
        return data.range(of: Data("QuickLook/Preview.pdf".utf8)) != nil
    }

    private static func fromPagesPreview(_ input: URL, to format: OutputFormat, options: ConversionOptions) async throws -> URL {
        let unpacked = try await unpack(input)
        defer { unpacked.remove() }
        let pdf = unpacked.root.appendingPathComponent("QuickLook/Preview.pdf")
        guard FileManager.default.fileExists(atPath: pdf.path) else { throw missingApp(.pages, "Opening this Pages document") }
        switch format {
        case .pdf:
            let out = OutputPaths.destination(for: input, ext: "pdf", folder: options.outputFolder)
            try FileManager.default.copyItem(at: pdf, to: out)
            return out
        case .txt:
            let document = try PDFTools.open(pdf)
            let out = OutputPaths.destination(for: input, ext: "txt", folder: options.outputFolder)
            try (document.string ?? "").write(to: out, atomically: true, encoding: .utf8)
            return out
        case .epub:
            return try await makeEPUB(from: pdf, kind: .pdf, named: input, options: options)
        default:
            let work = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: work) }
            let made = try await DocumentConverter.convert(pdf, kind: .pdf, to: format, options: ConversionOptions(outputFolder: work))
            return try deliver(made, for: input, ext: format.fileExtension, options: options)
        }
    }

    // MARK: EPUB reading

    private struct EPUBBook {
        var title: String
        /// Spine documents in reading order.
        var chapters: [URL]
    }

    private static func convertEPUB(_ input: URL, to format: OutputFormat, options: ConversionOptions) async throws -> URL {
        let unpacked = try await unpack(input)
        defer { unpacked.remove() }
        let book = try readEPUB(root: unpacked.root, name: input.lastPathComponent, fallbackTitle: OutputPaths.baseName(of: input))
        let out = OutputPaths.destination(for: input, ext: format.fileExtension, folder: options.outputFolder)
        do {
            switch format {
            case .html:
                // Pictures are embedded so the page still shows them once the unpacked book is gone.
                try combinedHTML(book, embedImages: true).write(to: out, atomically: true, encoding: .utf8)
            case .txt, .pdf, .docx, .rtf, .odt:
                let work = try makeTempDir()
                defer { try? FileManager.default.removeItem(at: work) }
                let page = work.appendingPathComponent("book.html")
                try combinedHTML(book, embedImages: false).write(to: page, atomically: true, encoding: .utf8)
                if format == .txt {
                    try await plainText(ofHTMLFile: page).write(to: out, atomically: true, encoding: .utf8)
                } else {
                    let made = try await DocumentConverter.convert(page, kind: .document, to: format,
                                                                   options: ConversionOptions(outputFolder: work))
                    try FileManager.default.moveItem(at: made, to: out)
                }
            default:
                throw ConversionError("E-books can't be converted to \(format.label).")
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }

    /// Follows META-INF/container.xml to the package file, then its manifest and spine.
    private static func readEPUB(root: URL, name: String, fallbackTitle: String) throws -> EPUBBook {
        let fm = FileManager.default
        if let encryption = try? parseXML(root.appendingPathComponent("META-INF/encryption.xml")) {
            // Obfuscated fonts are fine; encrypted chapters mean DRM.
            let protected = encryption.descendants("CipherReference")
                .compactMap { $0.attribute("URI") }
                .contains { ["xhtml", "html", "htm", "xml"].contains(($0 as NSString).pathExtension.lowercased()) }
            if protected { throw ConversionError("\(name) is copy-protected (DRM), so it can't be converted.") }
        }

        var packageFile: URL?
        if let container = try? parseXML(root.appendingPathComponent("META-INF/container.xml")) {
            let rootfiles = container.descendants("rootfile")
            let preferred = rootfiles.first { $0.attribute("media-type") == "application/oebps-package+xml" } ?? rootfiles.first
            if let path = preferred?.attribute("full-path") { packageFile = resolveReference(path, against: root) }
        }
        if packageFile == nil {
            packageFile = regularFiles(in: root).first { $0.pathExtension.lowercased() == "opf" }
        }
        guard let opf = packageFile, fm.fileExists(atPath: opf.path) else {
            throw ConversionError("\(name) isn't a valid EPUB (it has no package file).")
        }
        let opfTree = try parseXML(opf)

        struct Item { let url: URL; let type: String; let properties: String }
        var manifest: [String: Item] = [:]
        var manifestOrder: [String] = []
        for item in opfTree.descendants("item") {
            guard let id = item.attribute("id"), let href = item.attribute("href"),
                  let url = resolveReference(href, against: opf) else { continue }
            manifest[id] = Item(url: url, type: item.attribute("media-type") ?? "", properties: item.attribute("properties") ?? "")
            manifestOrder.append(id)
        }
        func isPage(_ item: Item) -> Bool {
            item.type == "application/xhtml+xml" || item.type == "text/html"
                || ["xhtml", "html", "htm"].contains(item.url.pathExtension.lowercased())
        }

        var chapters: [URL] = []
        for ref in opfTree.descendants("itemref") {
            if let id = ref.attribute("idref"), let item = manifest[id], isPage(item), !chapters.contains(item.url) {
                chapters.append(item.url)
            }
        }
        if chapters.isEmpty {
            // No usable spine: fall back to the pages in manifest order, minus the table of contents.
            chapters = manifestOrder.compactMap { manifest[$0] }
                .filter { isPage($0) && !$0.properties.contains("nav") }
                .map(\.url)
        }
        chapters = chapters.filter { fm.fileExists(atPath: $0.path) }
        guard !chapters.isEmpty else { throw ConversionError("\(name) has no readable chapters.") }

        let title = opfTree.firstDescendant("title")?.textContent.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return EPUBBook(title: title.isEmpty ? fallbackTitle : title, chapters: chapters)
    }

    /// The whole book as one HTML page: every spine document's body in order, with the books'
    /// style sheets inlined and links between chapters turned into in-page anchors.
    private static func combinedHTML(_ book: EPUBBook, embedImages: Bool) throws -> String {
        var chapterIndex: [String: Int] = [:]
        for (index, url) in book.chapters.enumerated() { chapterIndex[url.path] = index }
        var styles: [String] = []
        var seenStyles = Set<String>()
        var sections: [String] = []
        for (index, url) in book.chapters.enumerated() {
            guard let source = try? readText(url) else { continue }
            let parts = splitDocument(source)
            for css in stylesheets(inHead: parts.head, base: url) where seenStyles.insert(css).inserted {
                styles.append(css)
            }
            let body = rewriteReferences(closeSelfClosingTags(parts.body), base: url, chapters: chapterIndex,
                                         embedImages: embedImages)
            sections.append("<div class=\"transmute-chapter\" id=\"transmute-chapter-\(index + 1)\">\n\(body)\n</div>")
        }
        guard !sections.isEmpty else { throw ConversionError("Couldn't read any chapters of the e-book.") }
        let styleTags = styles.map { "<style>\n\($0)\n</style>" }.joined(separator: "\n")
        return """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <title>\(escape(book.title))</title>
            \(styleTags)
            </head>
            <body>
            \(sections.joined(separator: "\n"))
            </body>
            </html>

            """
    }

    /// Splits an (X)HTML file into what's before </head> and what's inside <body>.
    private static func splitDocument(_ source: String) -> (head: String, body: String) {
        let ns = source as NSString
        let headEnd = ns.range(of: "</head>", options: .caseInsensitive)
        let head = headEnd.location == NSNotFound ? "" : ns.substring(to: headEnd.location)
        let bodyStart = ns.range(of: "<body", options: .caseInsensitive)
        guard bodyStart.location != NSNotFound else {
            let afterHead = headEnd.location == NSNotFound ? 0 : NSMaxRange(headEnd)
            return (head, ns.substring(from: afterHead))
        }
        let searchFrom = NSMaxRange(bodyStart)
        let tagEnd = ns.range(of: ">", options: [], range: NSRange(location: searchFrom, length: ns.length - searchFrom))
        guard tagEnd.location != NSNotFound else { return (head, "") }
        let start = NSMaxRange(tagEnd)
        let bodyEnd = ns.range(of: "</body>", options: [.caseInsensitive, .backwards])
        let end = bodyEnd.location != NSNotFound && bodyEnd.location >= start ? bodyEnd.location : ns.length
        return (head, ns.substring(with: NSRange(location: start, length: end - start)))
    }

    /// CSS from <style> blocks and linked style sheets in a chapter's head.
    private static func stylesheets(inHead head: String, base: URL) -> [String] {
        let ns = head as NSString
        var css: [String] = []
        for match in matches("<link\\b[^>]*>", in: head) {
            let tag = ns.substring(with: match.range)
            guard tag.range(of: "stylesheet", options: .caseInsensitive) != nil,
                  let href = matches("\\bhref\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')", in: tag).first,
                  let value = group(href, 1, in: tag as NSString) ?? group(href, 2, in: tag as NSString),
                  let target = localTarget(value, base: base),
                  let text = try? readText(target.url) else { continue }
            css.append(text)
        }
        for match in matches("<style[^>]*>([\\s\\S]*?)</style>", in: head) {
            if let text = group(match, 1, in: ns) { css.append(text) }
        }
        return css
    }

    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
    ]

    /// XHTML allows `<a id="p5"/>`; read as HTML that never closes, so spell such tags out.
    private static func closeSelfClosingTags(_ html: String) -> String {
        let ns = html as NSString
        let found = matches("<([A-Za-z][A-Za-z0-9:_.-]*)(\\s[^<>]*?)?\\s*/>", in: html, options: [])
        guard !found.isEmpty else { return html }
        let result = NSMutableString(string: html)
        for match in found.reversed() {
            guard let name = group(match, 1, in: ns), !voidElements.contains(name.lowercased()) else { continue }
            let attributes = group(match, 2, in: ns) ?? ""
            result.replaceCharacters(in: match.range, with: "<\(name)\(attributes)></\(name)>")
        }
        return result as String
    }

    /// Makes relative `src`/`href` values absolute: chapter links become anchors, pictures become
    /// file URLs (or data URIs when `embedImages`), web links and anchors stay as they are.
    private static func rewriteReferences(_ html: String, base: URL, chapters: [String: Int], embedImages: Bool) -> String {
        let ns = html as NSString
        let found = matches("(?<=\\s)(src|href|xlink:href)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')", in: html)
        guard !found.isEmpty else { return html }
        let result = NSMutableString(string: html)
        for match in found.reversed() {
            guard let attribute = group(match, 1, in: ns)?.lowercased(),
                  let target = localTarget(group(match, 2, in: ns) ?? group(match, 3, in: ns) ?? "", base: base) else { continue }
            let value: String
            if attribute == "href", let index = chapters[target.url.path] {
                value = "#" + (target.fragment ?? "transmute-chapter-\(index + 1)")
            } else if embedImages, attribute != "href", let data = imageDataURI(target.url) {
                value = data
            } else {
                value = target.url.absoluteString
            }
            result.replaceCharacters(in: match.range, with: "\(attribute)=\"\(escape(value))\"")
        }
        return result as String
    }

    /// The file a relative reference points to, or nil for anchors, web links and data URIs.
    private static func localTarget(_ raw: String, base: URL) -> (url: URL, fragment: String?)? {
        let value = decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("#") else { return nil }
        if value.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil { return nil }
        var path = value
        var fragment: String?
        if let hash = path.firstIndex(of: "#") {
            let rest = String(path[path.index(after: hash)...])
            fragment = rest.isEmpty ? nil : (rest.removingPercentEncoding ?? rest)
            path = String(path[..<hash])
        }
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        guard let url = resolveReference(path, against: base) else { return nil }
        return (url, fragment)
    }

    /// Resolves a relative, possibly percent-encoded reference against a file or folder URL.
    private static func resolveReference(_ reference: String, against base: URL) -> URL? {
        guard !reference.isEmpty else { return nil }
        if let url = URL(string: reference, relativeTo: base) { return url.absoluteURL.standardizedFileURL }
        // Unencoded spaces and the like.
        if let encoded = reference.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: encoded, relativeTo: base) {
            return url.absoluteURL.standardizedFileURL
        }
        return nil
    }

    private static func imageDataURI(_ url: URL) -> String? {
        let types = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
                     "svg": "image/svg+xml", "webp": "image/webp", "bmp": "image/bmp"]
        guard let mime = types[url.pathExtension.lowercased()], let data = try? Data(contentsOf: url) else { return nil }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// The HTML importer needs the main thread. Attachment markers (pictures) are dropped.
    @MainActor
    private static func plainText(ofHTMLFile url: URL) throws -> String {
        try DocumentConverter.load(url, kind: .document).string.replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    // MARK: EPUB writing

    private struct XHTMLContent: Sendable {
        struct Heading: Sendable {
            var id: String
            var text: String
        }
        var body: String
        var headings: [Heading]
    }

    /// One stretch of text with the same formatting.
    private struct Run {
        var text: String
        var bold: Bool
        var italic: Bool
        var size: CGFloat
        var link: String?
    }

    private static func makeEPUB(from source: URL, kind: FileKind, named input: URL,
                                 options: ConversionOptions) async throws -> URL {
        let content = try await xhtmlContent(of: source, kind: kind)
        let out = OutputPaths.destination(for: input, ext: "epub", folder: options.outputFolder)
        try await writeEPUB(content, title: OutputPaths.baseName(of: input), to: out)
        return out
    }

    /// Turns a document into simple XHTML: paragraphs, headings (from larger fonts), bold, italic, links.
    @MainActor
    private static func xhtmlContent(of source: URL, kind: FileKind) throws -> XHTMLContent {
        let text = try DocumentConverter.load(source, kind: kind)
        let ns = text.string as NSString
        let full = NSRange(location: 0, length: ns.length)

        // The most common font size counts as body text.
        var sizeCounts: [CGFloat: Int] = [:]
        var index = 0
        while index < ns.length {
            var effective = NSRange(location: 0, length: 0)
            let font = text.attribute(.font, at: index, longestEffectiveRange: &effective, in: full) as? NSFont
            sizeCounts[(font?.pointSize ?? 12).rounded(), default: 0] += effective.length
            index = max(index + 1, NSMaxRange(effective))
        }
        let bodySize = max(1, sizeCounts.max { $0.value < $1.value }?.key ?? 12)

        let lineEnds: Set<unichar> = [0x0A, 0x0D, 0x2029]
        var html: [String] = []
        var headings: [XHTMLContent.Heading] = []
        var location = 0
        while location < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = max(location + 1, NSMaxRange(paragraph))
            var end = NSMaxRange(paragraph)
            while end > paragraph.location && lineEnds.contains(ns.character(at: end - 1)) { end -= 1 }
            let range = NSRange(location: paragraph.location, length: end - paragraph.location)
            guard range.length > 0 else { continue }

            var runs: [Run] = []
            var position = range.location
            while position < NSMaxRange(range) {
                var effective = NSRange(location: 0, length: 0)
                let attributes = text.attributes(at: position, longestEffectiveRange: &effective, in: range)
                let font = attributes[.font] as? NSFont
                let traits = font?.fontDescriptor.symbolicTraits ?? []
                var link: String?
                if let url = attributes[.link] as? URL {
                    link = url.absoluteString
                } else if let string = attributes[.link] as? String {
                    link = string
                }
                if let target = link, !["http", "https", "mailto"].contains(URL(string: target)?.scheme?.lowercased() ?? "") {
                    link = nil
                }
                runs.append(Run(text: ns.substring(with: effective), bold: traits.contains(.bold),
                                italic: traits.contains(.italic), size: font?.pointSize ?? bodySize, link: link))
                position = max(position + 1, NSMaxRange(effective))
            }

            let visible = runs.filter { !isBlank($0.text) }
            guard !visible.isEmpty else { continue }
            let size = visible.map(\.size).max() ?? bodySize
            let allBold = visible.allSatisfy(\.bold)
            let plain = visible.map(\.text).joined()
                .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
                .replacingOccurrences(of: "\u{FFFC}", with: "")
            let level: Int?
            if plain.count > 200 || plain.isEmpty {
                level = nil
            } else if size >= bodySize * 1.6 {
                level = 1
            } else if size >= bodySize * 1.3 {
                level = 2
            } else if size >= bodySize * 1.12 && allBold {
                level = 3
            } else {
                level = nil
            }
            if let level {
                let id = "s\(headings.count + 1)"
                headings.append(XHTMLContent.Heading(id: id, text: plain))
                html.append("<h\(level) id=\"\(id)\">\(inlineXHTML(runs, keepBold: false))</h\(level)>")
            } else {
                html.append("<p>\(inlineXHTML(runs, keepBold: true))</p>")
            }
        }
        return XHTMLContent(body: html.isEmpty ? "<p></p>" : html.joined(separator: "\n"), headings: headings)
    }

    private static func inlineXHTML(_ runs: [Run], keepBold: Bool) -> String {
        var merged: [Run] = []
        for run in runs {
            if let last = merged.last, last.bold == run.bold, last.italic == run.italic, last.link == run.link {
                merged[merged.count - 1].text += run.text
            } else {
                merged.append(run)
            }
        }
        var html = ""
        for run in merged {
            var piece = escape(run.text, lineBreaks: true)
            guard !piece.isEmpty else { continue }
            if !isBlank(run.text) {
                if run.italic { piece = "<em>\(piece)</em>" }
                if run.bold && keepBold { piece = "<strong>\(piece)</strong>" }
                if let link = run.link { piece = "<a href=\"\(escape(link))\">\(piece)</a>" }
            }
            html += piece
        }
        return html
    }

    private static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0) || $0.value == 0xFFFC || $0.value == 0x0B
        }
    }

    /// An EPUB 3 container: mimetype first and uncompressed, then META-INF and OEBPS.
    private static func writeEPUB(_ content: XHTMLContent, title rawTitle: String, to out: URL) async throws {
        let stage = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: stage) }
        let title = escape(rawTitle.isEmpty ? "Untitled" : rawTitle)
        let identifier = "urn:uuid:\(UUID().uuidString.lowercased())"
        let modified = ISO8601DateFormatter().string(from: Date())
        let toc = content.headings.isEmpty
            ? "      <li><a href=\"chapter1.xhtml\">\(title)</a></li>"
            : content.headings.map { "      <li><a href=\"chapter1.xhtml#\($0.id)\">\(escape($0.text))</a></li>" }
                .joined(separator: "\n")

        let container = """
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>

            """
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id" xml:lang="en">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="book-id">\(identifier)</dc:identifier>
                <dc:title>\(title)</dc:title>
                <dc:language>en</dc:language>
                <meta property="dcterms:modified">\(modified)</meta>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="style" href="style.css" media-type="text/css"/>
                <item id="chapter1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine>
                <itemref idref="chapter1"/>
              </spine>
            </package>

            """
        let nav = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en" lang="en">
            <head>
              <meta charset="utf-8"/>
              <title>\(title)</title>
            </head>
            <body>
              <nav epub:type="toc" id="toc">
                <h1>Contents</h1>
                <ol>
            \(toc)
                </ol>
              </nav>
            </body>
            </html>

            """
        let chapter = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
            <head>
              <meta charset="utf-8"/>
              <title>\(title)</title>
              <link rel="stylesheet" type="text/css" href="style.css"/>
            </head>
            <body>
            \(content.body)
            </body>
            </html>

            """
        let css = """
            body { font-family: Georgia, "Times New Roman", serif; line-height: 1.5; margin: 0 5%; }
            h1, h2, h3 { font-family: -apple-system, "Helvetica Neue", Helvetica, sans-serif; line-height: 1.25; }
            p { margin: 0 0 0.8em; }

            """
        let files: [(String, String)] = [
            ("mimetype", "application/epub+zip"), // no newline: readers check these exact bytes
            ("META-INF/container.xml", container),
            ("OEBPS/content.opf", opf),
            ("OEBPS/nav.xhtml", nav),
            ("OEBPS/chapter1.xhtml", chapter),
            ("OEBPS/style.css", css),
        ]
        for (path, text) in files {
            let url = stage.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        do {
            try await Shell.check("/usr/bin/zip", ["-X0", "-q", out.path, "mimetype"], currentDirectory: stage)
            try await Shell.check("/usr/bin/zip", ["-Xr9Dq", out.path, "META-INF", "OEBPS"], currentDirectory: stage)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
    }

    // MARK: Presentations

    private static func convertPresentation(_ input: URL, to format: OutputFormat, options: ConversionOptions) async throws -> JobResult {
        let hasKeynote = isInstalled(.keynote)
        switch format {
        case .png, .jpeg:
            guard hasKeynote else { return try await firstSlideImage(input, format: format, options: options) }
            let work = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: work) }
            let imageFormat = format == .png ? "PNG" : "JPEG"
            let clause = "slide images with properties {image format:\(imageFormat)}"
            _ = try await iWorkExport(.keynote, input, export: clause, ext: "", work: work)
            let imageTypes: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff"]
            let images = regularFiles(in: work.appendingPathComponent("out", isDirectory: true))
                .filter { imageTypes.contains($0.pathExtension.lowercased()) }
            guard let first = images.first else { throw ConversionError("Keynote didn't export any slides.") }
            if images.count == 1 {
                return JobResult(outputs: [try deliver(first, for: input, ext: format.fileExtension, options: options)])
            }
            // Several slides go into a folder, like PDF pages do.
            let folder = OutputPaths.destination(for: input, ext: "", suffix: "slides", folder: options.outputFolder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, image) in images.enumerated() {
                try FileManager.default.moveItem(at: image, to: folder.appendingPathComponent("Slide \(index + 1).\(format.fileExtension)"))
            }
            return JobResult(outputs: [folder])
        case .pdf, .pptx, .key:
            guard hasKeynote else { throw missingApp(.keynote, "Converting presentations to \(format.label)") }
            let work = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: work) }
            let clause: String? = switch format {
            case .pdf: "PDF"
            case .pptx: "Microsoft PowerPoint"
            default: nil
            }
            let exported = try await iWorkExport(.keynote, input, export: clause, ext: format.fileExtension, work: work)
            return JobResult(outputs: [try deliver(exported, for: input, ext: format.fileExtension, options: options)])
        default:
            throw ConversionError("Presentations can't be converted to \(format.label).")
        }
    }

    /// Without Keynote: Quick Look's picture of the first slide, or the preview stored in the file.
    private static func firstSlideImage(_ input: URL, format: OutputFormat, options: ConversionOptions) async throws -> JobResult {
        var picture: CGImage?
        do {
            picture = try await quickLookImage(of: input, maxPixel: 1920)
        } catch {
            picture = await embeddedPreview(of: input)
        }
        guard let slide = picture else {
            throw ConversionError("macOS couldn't draw \(input.lastPathComponent). Install Apple's free Keynote app from the App Store to convert presentations.")
        }
        let type: UTType = format == .png ? .png : .jpeg
        let out = OutputPaths.destination(for: input, ext: format.fileExtension, suffix: "first slide", folder: options.outputFolder)
        try ImageConverter.data(from: slide, type: type, quality: options.quality).write(to: out, options: .atomic)
        return JobResult(outputs: [out], message: "First slide only, up to 1920 pixels wide. Install Keynote (free) to export every slide.")
    }

    private static func quickLookImage(of url: URL, maxPixel: CGFloat) async throws -> CGImage {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: maxPixel, height: maxPixel),
                                                   scale: 1, representationTypes: .thumbnail)
        let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        return representation.cgImage
    }

    /// Keynote, Pages and PowerPoint files usually carry a small picture of the first page.
    private static func embeddedPreview(of input: URL) async -> CGImage? {
        guard let unpacked = try? await unpack(input) else { return nil }
        defer { unpacked.remove() }
        for path in ["preview.jpg", "QuickLook/Thumbnail.jpg", "docProps/thumbnail.jpeg", "Thumbnails/thumbnail.png"] {
            let url = unpacked.root.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path), let image = try? ImageConverter.loadCGImage(url) {
                return image
            }
        }
        return nil
    }

    // MARK: Spreadsheets

    private struct Table {
        /// The sheet's name, when the file has named sheets.
        var name: String?
        var rows: [[String]]
    }

    private static func convertSpreadsheet(_ input: URL, ext: String, to format: OutputFormat,
                                           options: ConversionOptions) async throws -> JobResult {
        if format == .numbers {
            guard isInstalled(.numbers) else { throw missingApp(.numbers, "Saving as a Numbers spreadsheet") }
            let work = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: work) }
            var source = input
            if ext == "tsv" || ext == "ods" {
                // Numbers opens Excel and CSV files, so these become a workbook first.
                let table = try await readTable(input, ext: ext)
                let base = OutputPaths.baseName(of: input)
                source = work.appendingPathComponent("\(base).xlsx")
                try await writeXLSX(table.rows, sheetName: sheetName(table.name ?? base), to: source)
            }
            let saved = try await iWorkExport(.numbers, source, export: nil, ext: "numbers", work: work)
            return JobResult(outputs: [try deliver(saved, for: input, ext: "numbers", options: options)])
        }
        if nativeSpreadsheets.contains(ext) {
            let table = try await readTable(input, ext: ext)
            return JobResult(outputs: [try await writeTable(table, as: format, for: input, options: options)])
        }
        return JobResult(outputs: [try await numbersConvert(input, to: format, options: options)])
    }

    /// XLS and Numbers files, through the Numbers app.
    private static func numbersConvert(_ input: URL, to format: OutputFormat, options: ConversionOptions) async throws -> URL {
        guard isInstalled(.numbers) else {
            throw missingApp(.numbers, "Converting \(input.pathExtension.uppercased()) spreadsheets")
        }
        let work = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        switch format {
        case .pdf, .xlsx:
            let clause = format == .pdf ? "PDF" : "Microsoft Excel"
            let exported = try await iWorkExport(.numbers, input, export: clause, ext: format.fileExtension, work: work)
            return try deliver(exported, for: input, ext: format.fileExtension, options: options)
        case .csv, .html:
            _ = try await iWorkExport(.numbers, input, export: "CSV", ext: "csv", work: work)
            // One CSV per table; Numbers puts them in a folder when there are several.
            let files = regularFiles(in: work.appendingPathComponent("out", isDirectory: true))
                .filter { $0.pathExtension.lowercased() == "csv" }
            guard let first = files.first else { throw ConversionError("Numbers didn't export anything.") }
            if format == .html {
                let rows = try normalized(parseDelimited(readText(first), delimiter: ","))
                let out = OutputPaths.destination(for: input, ext: "html", folder: options.outputFolder)
                try tableHTML(rows, title: OutputPaths.baseName(of: input)).write(to: out, atomically: true, encoding: .utf8)
                return out
            }
            if files.count == 1 { return try deliver(first, for: input, ext: "csv", options: options) }
            let folder = OutputPaths.destination(for: input, ext: "", suffix: "CSV", folder: options.outputFolder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in files {
                try FileManager.default.moveItem(at: file, to: OutputPaths.unique(in: folder, base: OutputPaths.baseName(of: file), ext: "csv"))
            }
            return folder
        default:
            throw ConversionError("Spreadsheets can't be converted to \(format.label).")
        }
    }

    private static func readTable(_ input: URL, ext: String) async throws -> Table {
        switch ext {
        case "csv", "tsv":
            let text = try readText(input)
            let delimiter: Unicode.Scalar = ext == "tsv" ? "\t" : guessDelimiter(text)
            return Table(name: nil, rows: normalized(parseDelimited(text, delimiter: delimiter)))
        case "xlsx":
            let unpacked = try await unpack(input)
            defer { unpacked.remove() }
            return try readXLSX(root: unpacked.root, name: input.lastPathComponent)
        case "ods":
            let unpacked = try await unpack(input)
            defer { unpacked.remove() }
            return try readODS(root: unpacked.root, name: input.lastPathComponent)
        default:
            throw ConversionError("\(ext.uppercased()) spreadsheets need the Numbers app.")
        }
    }

    private static func writeTable(_ table: Table, as format: OutputFormat, for input: URL,
                                   options: ConversionOptions) async throws -> URL {
        let base = OutputPaths.baseName(of: input)
        let title = table.name.map { "\(base) – \($0)" } ?? base
        let out = OutputPaths.destination(for: input, ext: format.fileExtension, folder: options.outputFolder)
        do {
            switch format {
            case .csv:
                try csvText(table.rows).write(to: out, atomically: true, encoding: .utf8)
            case .html:
                try tableHTML(table.rows, title: title).write(to: out, atomically: true, encoding: .utf8)
            case .pdf:
                try renderTablePDF(table.rows, title: title, to: out)
            case .xlsx:
                try await writeXLSX(table.rows, sheetName: sheetName(table.name ?? base), to: out)
            default:
                throw ConversionError("Spreadsheets can't be converted to \(format.label).")
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }

    // MARK: XLSX reading

    /// The first visible sheet's values. Formulas give their last saved result; dates come out as
    /// yyyy-MM-dd (HH:mm:ss); other number formatting isn't applied.
    private static func readXLSX(root: URL, name: String) throws -> Table {
        // The package relationships point at the workbook, and the workbook's at its parts.
        var workbookPath = "xl/workbook.xml"
        if let rels = try? parseXML(root.appendingPathComponent("_rels/.rels")),
           let office = rels.descendants("Relationship").first(where: { ($0.attribute("Type") ?? "").hasSuffix("/officeDocument") }),
           let target = office.attribute("Target") {
            workbookPath = packagePath(target, from: "")
        }
        guard let workbook = try? parseXML(root.appendingPathComponent(workbookPath)) else {
            throw ConversionError("\(name) isn't a valid Excel workbook.")
        }
        let workbookDir = (workbookPath as NSString).deletingLastPathComponent
        let relsPath = joinPath(workbookDir, "_rels/\((workbookPath as NSString).lastPathComponent).rels")
        var targets: [String: String] = [:] // relationship id → part
        var partsByType: [String: String] = [:] // last part of the relationship type → part
        if let rels = try? parseXML(root.appendingPathComponent(relsPath)) {
            for rel in rels.descendants("Relationship") {
                guard let id = rel.attribute("Id"), let target = rel.attribute("Target"),
                      rel.attribute("TargetMode") != "External" else { continue }
                let path = packagePath(target, from: workbookDir)
                targets[id] = path
                if let type = rel.attribute("Type")?.split(separator: "/").last { partsByType[String(type)] = path }
            }
        }

        let sheets = workbook.descendants("sheet")
        let visible = sheets.first { !["hidden", "veryHidden"].contains($0.attribute("state") ?? "") }
        guard let sheet = visible ?? sheets.first else { throw ConversionError("\(name) has no sheets.") }
        let defaultSheet = joinPath(workbookDir, "worksheets/sheet1.xml")
        let sheetPath = sheet.attribute("id").flatMap { targets[$0] } ?? defaultSheet
        let date1904 = ["1", "true"].contains(workbook.firstDescendant("workbookPr")?.attribute("date1904") ?? "")

        var sharedStrings: [String] = []
        let sharedPath = partsByType["sharedStrings"] ?? joinPath(workbookDir, "sharedStrings.xml")
        if let sst = try? parseXML(root.appendingPathComponent(sharedPath)) {
            sharedStrings = sst.descendants("si").map { richText($0) }
        }

        // Cell styles whose number format is a date or time.
        var dateStyles = Set<Int>()
        let stylesPath = partsByType["styles"] ?? joinPath(workbookDir, "styles.xml")
        if let styles = try? parseXML(root.appendingPathComponent(stylesPath)) {
            var codes: [Int: String] = [:]
            for numberFormat in styles.descendants("numFmt") {
                if let id = Int(numberFormat.attribute("numFmtId") ?? ""), let code = numberFormat.attribute("formatCode") {
                    codes[id] = code
                }
            }
            if let xfs = styles.firstDescendant("cellXfs") {
                for (index, xf) in xfs.elements("xf").enumerated() {
                    let id = Int(xf.attribute("numFmtId") ?? "") ?? 0
                    if isDateFormat(id: id, code: codes[id]) { dateStyles.insert(index) }
                }
            }
        }

        guard let sheetXML = try? parseXML(root.appendingPathComponent(sheetPath)) else {
            throw ConversionError("Couldn't read the first sheet of \(name).")
        }
        let dates = DateFormatter()
        dates.locale = Locale(identifier: "en_US_POSIX")
        dates.timeZone = TimeZone(identifier: "UTC")
        var cells: [Int: [Int: String]] = [:]
        var nextRow = 0
        for row in sheetXML.descendants("row") {
            let rowIndex = Int(row.attribute("r") ?? "").map { $0 - 1 } ?? nextRow
            nextRow = rowIndex + 1
            var nextColumn = 0
            for cell in row.elements("c") {
                // Empty cells are often left out, so positions come from the reference ("B3").
                let column = cell.attribute("r").flatMap { columnIndex($0) } ?? nextColumn
                nextColumn = column + 1
                let value = cellValue(cell, shared: sharedStrings, dateStyles: dateStyles, date1904: date1904, dates: dates)
                if !value.isEmpty && rowIndex >= 0 { cells[rowIndex, default: [:]][column] = value }
            }
        }
        let rows = try denseRows(cells)
        return Table(name: sheet.attribute("name"), rows: rows)
    }

    private static func cellValue(_ cell: OfficeXMLNode, shared: [String], dateStyles: Set<Int>,
                                  date1904: Bool, dates: DateFormatter) -> String {
        let raw = cell.element("v")?.textContent
        switch cell.attribute("t") ?? "n" {
        case "s":
            guard let number = Int((raw ?? "").trimmingCharacters(in: .whitespaces)),
                  shared.indices.contains(number) else { return "" }
            return shared[number]
        case "inlineStr":
            return cell.element("is").map { richText($0) } ?? (raw ?? "")
        case "b":
            guard let flag = raw else { return "" }
            return flag.trimmingCharacters(in: .whitespaces) == "1" ? "TRUE" : "FALSE"
        case "str", "e", "d":
            return raw ?? ""
        default:
            guard let number = raw, !number.isEmpty else { return "" }
            if let style = Int(cell.attribute("s") ?? ""), dateStyles.contains(style), let serial = Double(number) {
                return excelDate(serial, date1904: date1904, formatter: dates)
            }
            return formatNumber(number)
        }
    }

    /// A shared or inline string: plain `<t>`, or rich-text runs `<r><t>`. Phonetic hints are skipped.
    private static func richText(_ node: OfficeXMLNode) -> String {
        var text = ""
        for child in node.children {
            switch child.name {
            case "t": text += child.textContent
            case "r": text += child.elements("t").map(\.textContent).joined()
            default: break
            }
        }
        return text
    }

    private static func isDateFormat(id: Int, code: String?) -> Bool {
        // Built-in date and time formats.
        switch id {
        case 14...22, 27...36, 45...47, 50...58: return true
        default: break
        }
        guard var format = code?.lowercased(), format != "general" else { return false }
        // Drop quoted text, [colours]/[$locale] blocks, escaped characters and padding.
        for pattern in ["\"[^\"]*\"", "\\[[^\\]]*\\]", "\\\\.", "_.", "\\*."] {
            format = format.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return format.contains { "ydmhs".contains($0) }
    }

    /// Excel stores dates as days since 1899-12-30 (or 1904-01-01 on old Mac workbooks).
    private static func excelDate(_ serial: Double, date1904: Bool, formatter: DateFormatter) -> String {
        let seconds = (serial * 86_400).rounded()
        let epoch: Double = date1904 ? -2_082_844_800 : -2_209_161_600 // seconds from 1970
        if serial < 1 {
            formatter.dateFormat = "HH:mm:ss"
        } else if seconds.truncatingRemainder(dividingBy: 86_400) == 0 {
            formatter.dateFormat = "yyyy-MM-dd"
        } else {
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        }
        return formatter.string(from: Date(timeIntervalSince1970: epoch + seconds))
    }

    /// "1200" stays "1200"; float noise like 0.30000000000000004 becomes 0.3.
    private static func formatNumber(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed), value.isFinite else { return trimmed }
        if value == value.rounded() && abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%.15g", value)
    }

    /// Spreadsheet cells as a full grid from A1, so blank cells keep their place.
    private static func denseRows(_ cells: [Int: [Int: String]]) throws -> [[String]] {
        guard let lastRow = cells.keys.max() else { return [] }
        let lastColumn = cells.values.compactMap { $0.keys.max() }.max() ?? 0
        guard (lastRow + 1) * (lastColumn + 1) <= 10_000_000 else {
            throw ConversionError("This sheet is too large to convert (\(lastRow + 1) rows × \(lastColumn + 1) columns).")
        }
        var rows: [[String]] = []
        rows.reserveCapacity(lastRow + 1)
        for index in 0...lastRow {
            var row = [String](repeating: "", count: lastColumn + 1)
            for (column, value) in cells[index] ?? [:] { row[column] = value }
            rows.append(row)
        }
        return rows
    }

    /// "AB12" → 27 (zero-based).
    private static func columnIndex(_ reference: String) -> Int? {
        var index = 0
        var found = false
        for scalar in reference.unicodeScalars {
            let value = scalar.value
            if value >= 65 && value <= 90 {
                index = index * 26 + Int(value - 64)
            } else if value >= 97 && value <= 122 {
                index = index * 26 + Int(value - 96)
            } else if value == 36 { // "$"
                continue
            } else {
                break
            }
            found = true
        }
        return found ? index - 1 : nil
    }

    /// 0 → "A", 27 → "AB".
    private static func columnName(_ index: Int) -> String {
        var number = index + 1
        var name = ""
        while number > 0 {
            let remainder = (number - 1) % 26
            name = String(Character(Unicode.Scalar(UInt8(65 + remainder)))) + name
            number = (number - 1) / 26
        }
        return name
    }

    /// Resolves a relationship target against the folder of the part that refers to it.
    private static func packagePath(_ target: String, from folder: String) -> String {
        let decoded = target.removingPercentEncoding ?? target
        var parts: [String] = decoded.hasPrefix("/") ? [] : folder.split(separator: "/").map(String.init)
        for part in decoded.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(part))
            }
        }
        return parts.joined(separator: "/")
    }

    private static func joinPath(_ folder: String, _ file: String) -> String {
        folder.isEmpty ? file : "\(folder)/\(file)"
    }

    // MARK: ODS reading

    /// The first sheet of an OpenDocument spreadsheet (LibreOffice, Google Sheets export).
    private static func readODS(root: URL, name: String) throws -> Table {
        guard let content = try? parseXML(root.appendingPathComponent("content.xml")),
              let sheet = content.firstDescendant("table") else {
            throw ConversionError("\(name) isn't a valid OpenDocument spreadsheet.")
        }
        var cells: [Int: [Int: String]] = [:]
        var rowIndex = 0
        for row in tableRows(sheet) {
            // Runs of identical rows and cells are stored once with a repeat count; trailing
            // empty ones can repeat a million times, so only cells with values are expanded.
            let rowRepeat = max(1, Int(row.attribute("number-rows-repeated") ?? "") ?? 1)
            var values: [Int: String] = [:]
            var column = 0
            for cell in row.children where cell.name == "table-cell" || cell.name == "covered-table-cell" {
                let columnRepeat = max(1, Int(cell.attribute("number-columns-repeated") ?? "") ?? 1)
                let value = odsValue(cell)
                if !value.isEmpty && column < 16_384 {
                    for repeated in column..<min(column + columnRepeat, 16_384) { values[repeated] = value }
                }
                column += columnRepeat
            }
            if !values.isEmpty {
                for repeated in rowIndex..<(rowIndex + min(rowRepeat, 10_000)) { cells[repeated] = values }
            }
            rowIndex += rowRepeat
        }
        let rows = try denseRows(cells)
        return Table(name: sheet.attribute("name"), rows: rows)
    }

    private static func tableRows(_ node: OfficeXMLNode) -> [OfficeXMLNode] {
        var rows: [OfficeXMLNode] = []
        for child in node.children {
            if child.name == "table-row" {
                rows.append(child)
            } else if ["table-header-rows", "table-row-group", "table-rows"].contains(child.name) {
                rows += tableRows(child)
            }
        }
        return rows
    }

    private static func odsValue(_ cell: OfficeXMLNode) -> String {
        let text = cell.elements("p").map { odfText($0) }.joined(separator: "\n")
        // LibreOffice also writes calcext:value-type, which can differ ("error"), so office: comes first.
        func office(_ local: String) -> String? { cell.attributes["office:\(local)"] ?? cell.attribute(local) }
        switch office("value-type") ?? "" {
        case "float", "percentage", "currency":
            return office("value").map { formatNumber($0) } ?? text
        case "date":
            return office("date-value").map { $0.replacingOccurrences(of: "T", with: " ") } ?? text
        case "time":
            return text
        case "boolean":
            return office("boolean-value") == "true" ? "TRUE" : "FALSE"
        default:
            return text
        }
    }

    /// Paragraph text with ODF's spacing elements spelled out.
    private static func odfText(_ node: OfficeXMLNode) -> String {
        var text = ""
        for child in node.children {
            switch child.name {
            case "#text": text += child.text
            case "s": text += String(repeating: " ", count: max(1, Int(child.attribute("c") ?? "") ?? 1))
            case "tab": text += "\t"
            case "line-break": text += "\n"
            case "annotation", "note": break
            default: text += odfText(child)
            }
        }
        return text
    }

    // MARK: CSV

    /// Reads RFC 4180 CSV: quoted fields may hold the delimiter, doubled quotes and line breaks.
    private static func parseDelimited(_ text: String, delimiter: Unicode.Scalar) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var recordStarted = false
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < scalars.count && scalars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && field.isEmpty {
                inQuotes = true
                recordStarted = true
            } else if c == delimiter {
                row.append(String(field))
                field = String.UnicodeScalarView()
                recordStarted = true
            } else if c == "\n" || c == "\r" {
                if c == "\r" && i + 1 < scalars.count && scalars[i + 1] == "\n" { i += 1 }
                row.append(String(field))
                rows.append(row)
                row = []
                field = String.UnicodeScalarView()
                recordStarted = false
            } else {
                field.append(c)
                recordStarted = true
            }
            i += 1
        }
        if recordStarted || !field.isEmpty {
            row.append(String(field))
            rows.append(row)
        }
        return rows
    }

    /// Comma unless the header line has more semicolons or tabs (as European Excel writes).
    private static func guessDelimiter(_ text: String) -> Unicode.Scalar {
        var commas = 0, semicolons = 0, tabs = 0
        var inQuotes = false
        for scalar in text.unicodeScalars {
            if scalar == "\"" {
                inQuotes.toggle()
            } else if !inQuotes {
                if scalar == "\n" || scalar == "\r" { break }
                if scalar == "," { commas += 1 }
                if scalar == ";" { semicolons += 1 }
                if scalar == "\t" { tabs += 1 }
            }
        }
        if tabs > commas && tabs >= semicolons { return "\t" }
        if semicolons > commas { return ";" }
        return ","
    }

    /// Pads every row to the same width and drops blank rows at the end.
    private static func normalized(_ rows: [[String]]) -> [[String]] {
        var rows = rows
        while let last = rows.last, last.allSatisfy({ $0.isEmpty }) { rows.removeLast() }
        let width = rows.map(\.count).max() ?? 0
        return rows.map { $0 + [String](repeating: "", count: width - $0.count) }
    }

    private static func csvText(_ rows: [[String]]) -> String {
        rows.map { row in row.map { csvField($0) }.joined(separator: ",") + "\r\n" }.joined()
    }

    private static func csvField(_ text: String) -> String {
        let special: Set<Unicode.Scalar> = [",", "\"", "\n", "\r"]
        guard text.unicodeScalars.contains(where: { special.contains($0) }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Plain decimal numbers like 12, -3.5 or 1.2E3. Leading zeros ("007") and more than 15 digits
    /// (card numbers, IDs) stay text, as they would lose information as numbers.
    private static func isPlainNumber(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        func isDigit(_ index: Int) -> Bool { index < scalars.count && scalars[index].value >= 48 && scalars[index].value <= 57 }
        var i = 0
        if i < scalars.count && scalars[i] == "-" { i += 1 }
        let integerStart = i
        while isDigit(i) { i += 1 }
        let integerDigits = i - integerStart
        guard integerDigits > 0, integerDigits == 1 || scalars[integerStart] != "0" else { return false }
        var digits = integerDigits
        if i < scalars.count && scalars[i] == "." {
            i += 1
            let fractionStart = i
            while isDigit(i) { i += 1 }
            guard i > fractionStart else { return false }
            digits += i - fractionStart
        }
        if i < scalars.count && (scalars[i] == "e" || scalars[i] == "E") {
            i += 1
            if i < scalars.count && (scalars[i] == "+" || scalars[i] == "-") { i += 1 }
            let exponentStart = i
            while isDigit(i) { i += 1 }
            guard i > exponentStart else { return false }
        }
        return i == scalars.count && digits <= 15
    }

    // MARK: XLSX writing

    /// A minimal workbook Excel, Numbers and LibreOffice all open: one sheet, numbers as numbers,
    /// everything else as inline text.
    private static func writeXLSX(_ rows: [[String]], sheetName: String, to out: URL) async throws {
        let stage = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: stage) }
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let relationships = "http://schemas.openxmlformats.org/package/2006/relationships"
        let officeTypes = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

        var sheet = header + "<worksheet xmlns=\"\(main)\">"
        let width = rows.map(\.count).max() ?? 0
        if !rows.isEmpty && width > 0 { sheet += "<dimension ref=\"A1:\(columnName(width - 1))\(rows.count)\"/>" }
        sheet += "<sheetData>"
        for (r, row) in rows.enumerated() {
            var cells = ""
            for (c, value) in row.enumerated() where !value.isEmpty {
                let reference = "\(columnName(c))\(r + 1)"
                if isPlainNumber(value) {
                    cells += "<c r=\"\(reference)\"><v>\(value)</v></c>"
                } else {
                    let edgeSpace = value.first?.isWhitespace == true || value.last?.isWhitespace == true
                    let multiline = value.unicodeScalars.contains("\n") || value.unicodeScalars.contains("\r")
                    let space = edgeSpace || multiline ? " xml:space=\"preserve\"" : ""
                    cells += "<c r=\"\(reference)\" t=\"inlineStr\"><is><t\(space)>\(escape(value))</t></is></c>"
                }
            }
            if !cells.isEmpty { sheet += "<row r=\"\(r + 1)\">\(cells)</row>" }
        }
        sheet += "</sheetData></worksheet>"

        let contentTypes = header + """
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
            <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
            <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
            </Types>
            """
        let packageRels = header + """
            <Relationships xmlns="\(relationships)">\
            <Relationship Id="rId1" Type="\(officeTypes)/officeDocument" Target="xl/workbook.xml"/>\
            </Relationships>
            """
        let workbook = header + """
            <workbook xmlns="\(main)" xmlns:r="\(officeTypes)">\
            <sheets><sheet name="\(escape(sheetName))" sheetId="1" r:id="rId1"/></sheets>\
            </workbook>
            """
        let workbookRels = header + """
            <Relationships xmlns="\(relationships)">\
            <Relationship Id="rId1" Type="\(officeTypes)/worksheet" Target="worksheets/sheet1.xml"/>\
            <Relationship Id="rId2" Type="\(officeTypes)/styles" Target="styles.xml"/>\
            </Relationships>
            """
        let styles = header + """
            <styleSheet xmlns="\(main)">\
            <fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>\
            <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
            <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
            <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
            <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>\
            <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
            </styleSheet>
            """
        let files: [(String, String)] = [
            ("[Content_Types].xml", contentTypes),
            ("_rels/.rels", packageRels),
            ("xl/workbook.xml", workbook),
            ("xl/_rels/workbook.xml.rels", workbookRels),
            ("xl/styles.xml", styles),
            ("xl/worksheets/sheet1.xml", sheet),
        ]
        for (path, text) in files {
            let url = stage.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        do {
            try await Shell.check("/usr/bin/zip", ["-X", "-r", "-D", "-q", out.path, "."], currentDirectory: stage)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
    }

    /// Excel sheet names: at most 31 characters, none of : \ / ? * [ ].
    private static func sheetName(_ raw: String) -> String {
        var name = raw.components(separatedBy: CharacterSet(charactersIn: ":\\/?*[]")).joined(separator: " ")
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "' ").union(.whitespacesAndNewlines))
        name = String(name.prefix(31)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Sheet1" : name
    }

    // MARK: Table output

    private static func tableHTML(_ rows: [[String]], title: String) -> String {
        let hasHeader = rows.count > 1
        var body = ""
        for (index, row) in rows.enumerated() {
            let isHeader = hasHeader && index == 0
            let cells = row.map { cell -> String in
                let tag = isHeader ? "th" : "td"
                let numeric = !isHeader && isPlainNumber(cell)
                let content = escape(cell).replacingOccurrences(of: "\n", with: "<br>")
                let classAttribute = numeric ? " class=\"num\"" : ""
                return "<\(tag)\(classAttribute)>\(content)</\(tag)>"
            }.joined()
            if isHeader {
                body += "<thead>\n<tr>\(cells)</tr>\n</thead>\n<tbody>\n"
            } else {
                body += "<tr>\(cells)</tr>\n"
            }
        }
        if hasHeader { body += "</tbody>\n" }
        return """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <title>\(escape(title))</title>
            <style>
            body { font-family: -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; font-size: 14px; color: #1d1d1f; margin: 24px; }
            h1 { font-size: 20px; margin: 0 0 16px; }
            table { border-collapse: collapse; }
            th, td { border: 1px solid #c7c7cc; padding: 4px 10px; text-align: left; vertical-align: top; }
            th { background: #e8e8ed; font-weight: 600; }
            td.num { text-align: right; font-variant-numeric: tabular-nums; }
            tbody tr:nth-child(even) td { background: #f5f5f7; }
            </style>
            </head>
            <body>
            <h1>\(escape(title))</h1>
            <table>
            \(body)</table>
            </body>
            </html>

            """
    }

    /// Draws the table onto PDF pages with Core Text (the PDF text renderer ignores HTML tables).
    /// Cells wrap, the header row repeats on every page, and wide tables are scaled to fit.
    private static func renderTablePDF(_ rows: [[String]], title: String, to out: URL) throws {
        let columnCount = max(1, rows.map(\.count).max() ?? 0)
        let hasHeader = rows.count > 1
        let bodyFont = CTFontCreateWithName("Helvetica" as CFString, 9, nil)
        let headerFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 9, nil)
        let titleFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 15, nil)
        let leftAligned = paragraphStyle(.left)
        let rightAligned = paragraphStyle(.right)
        let padX: CGFloat = 4, padY: CGFloat = 3, margin: CGFloat = 36
        let minWidth: CGFloat = 28, maxWidth: CGFloat = 220

        func cellText(_ text: String, row: Int) -> CFAttributedString {
            let isHeader = hasHeader && row == 0
            let alignment = !isHeader && isPlainNumber(text) ? rightAligned : leftAligned
            let attributes: [NSAttributedString.Key: Any] = [
                .font: isHeader ? headerFont : bodyFont,
                .paragraphStyle: alignment,
            ]
            return NSAttributedString(string: text, attributes: attributes) as CFAttributedString
        }

        // Natural column widths (from the first rows), within limits.
        var widths = [CGFloat](repeating: minWidth, count: columnCount)
        for (r, row) in rows.prefix(2000).enumerated() {
            for (c, text) in row.enumerated() where !text.isEmpty {
                var widest: CGFloat = 0
                for line in text.components(separatedBy: "\n") {
                    let measured = CTLineCreateWithAttributedString(cellText(line, row: r))
                    widest = max(widest, CGFloat(CTLineGetTypographicBounds(measured, nil, nil, nil)))
                }
                widths[c] = min(maxWidth, max(widths[c], ceil(widest) + padX * 2 + 1))
            }
        }
        var tableWidth = widths.reduce(0, +)
        let portrait = CGSize(width: 612, height: 792), landscape = CGSize(width: 792, height: 612)
        let page = tableWidth > portrait.width - margin * 2 ? landscape : portrait
        let available = page.width - margin * 2
        if tableWidth / 2 > available {
            // Too wide even at half size: narrow the columns so text wraps more.
            let factor = available * 2 / tableWidth
            widths = widths.map { max(minWidth / 2, $0 * factor) }
            tableWidth = widths.reduce(0, +)
        }
        let scale = min(1, available / tableWidth)
        let contentHeight = (page.height - margin * 2) / scale

        let lineHeight = ceil(CTFontGetAscent(bodyFont) + CTFontGetDescent(bodyFont) + CTFontGetLeading(bodyFont))
        var heights: [CGFloat] = []
        heights.reserveCapacity(rows.count)
        for (r, row) in rows.enumerated() {
            var height = lineHeight
            for (c, text) in row.enumerated() where !text.isEmpty && c < columnCount {
                let setter = CTFramesetterCreateWithAttributedString(cellText(text, row: r))
                let size = CTFramesetterSuggestFrameSizeWithConstraints(
                    setter, CFRange(location: 0, length: 0), nil,
                    CGSize(width: widths[c] - padX * 2, height: CGFloat.greatestFiniteMagnitude), nil)
                height = max(height, ceil(size.height) + 1)
            }
            // A giant cell is cut off rather than allowed to swallow pages.
            heights.append(min(height + padY * 2, contentHeight / 2))
        }

        let titleString = NSAttributedString(string: title, attributes: [.font: titleFont]) as CFAttributedString
        let titleLine = CTLineCreateWithAttributedString(titleString)
        let titleHeight = ceil(CTFontGetAscent(titleFont) + CTFontGetDescent(titleFont)) + 10

        var mediaBox = CGRect(origin: .zero, size: page)
        let info = [kCGPDFContextTitle as String: title, kCGPDFContextCreator as String: "Transmute"] as CFDictionary
        guard let ctx = CGContext(out as CFURL, mediaBox: &mediaBox, info) else {
            throw ConversionError("Couldn't create the PDF.")
        }
        let border = CGColor(gray: 0.72, alpha: 1)
        let headerFill = CGColor(gray: 0.9, alpha: 1)
        let stripe = CGColor(gray: 0.965, alpha: 1)

        // Coordinates: x from the left margin, y up from the top margin, so rows go into negative y.
        func drawRow(_ r: Int, top: CGFloat) {
            let height = heights[r]
            let row = rows[r]
            var x: CGFloat = 0
            for c in 0..<columnCount {
                let cell = CGRect(x: x, y: -top - height, width: widths[c], height: height)
                if hasHeader && r == 0 {
                    ctx.setFillColor(headerFill)
                    ctx.fill(cell)
                } else if r % 2 == 0 {
                    ctx.setFillColor(stripe)
                    ctx.fill(cell)
                }
                ctx.setStrokeColor(border)
                ctx.setLineWidth(0.5)
                ctx.stroke(cell)
                if c < row.count && !row[c].isEmpty {
                    let setter = CTFramesetterCreateWithAttributedString(cellText(row[c], row: r))
                    let path = CGPath(rect: cell.insetBy(dx: padX, dy: padY), transform: nil)
                    CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil), ctx)
                }
                x += widths[c]
            }
        }

        var next = hasHeader ? 1 : 0
        var firstPage = true
        repeat {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: margin, y: page.height - margin)
            ctx.scaleBy(x: scale, y: scale)
            ctx.textMatrix = .identity
            var top: CGFloat = 0
            if firstPage {
                ctx.textPosition = CGPoint(x: 0, y: -CTFontGetAscent(titleFont))
                CTLineDraw(titleLine, ctx)
                top = titleHeight
            }
            if hasHeader {
                drawRow(0, top: top)
                top += heights[0]
            }
            var drewRow = false
            while next < rows.count && (!drewRow || top + heights[next] <= contentHeight) {
                drawRow(next, top: top)
                top += heights[next]
                next += 1
                drewRow = true
            }
            ctx.restoreGState()
            ctx.endPDFPage()
            firstPage = false
        } while next < rows.count
        ctx.closePDF()
    }

    private static func paragraphStyle(_ alignment: CTTextAlignment) -> CTParagraphStyle {
        var value = alignment
        return withUnsafeBytes(of: &value) { raw in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                                                  value: raw.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
    }

    // MARK: Files and text

    /// A folder holding an unpacked package (EPUB, XLSX, ODS, iWork), removed afterwards if temporary.
    private struct Unpacked {
        let root: URL
        let isTemporary: Bool
        func remove() {
            if isTemporary { try? FileManager.default.removeItem(at: root) }
        }
    }

    /// Unzips into a temporary folder, or uses the file as is when it's already a folder (Apple Books
    /// keeps EPUBs unzipped; Pages, Keynote and Numbers can save packages).
    private static func unpack(_ input: URL) async throws -> Unpacked {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: input.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return Unpacked(root: URL(fileURLWithPath: input.path, isDirectory: true), isTemporary: false)
        }
        let folder = try makeTempDir()
        do {
            try await Shell.check("/usr/bin/ditto", ["-x", "-k", input.path, folder.path])
        } catch let error as CancellationError {
            try? FileManager.default.removeItem(at: folder)
            throw error
        } catch {
            // ditto refuses a few zips that unzip accepts.
            do {
                try await Shell.check("/usr/bin/unzip", ["-qq", "-o", input.path, "-d", folder.path])
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw ConversionError("\(input.lastPathComponent) couldn't be opened; it may be damaged.")
            }
        }
        return Unpacked(root: folder, isTemporary: true)
    }

    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transmute-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copies the file (or package) into `folder` and returns the copy.
    private static func stageCopy(_ input: URL, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(input.lastPathComponent)
        try FileManager.default.copyItem(at: input, to: copy)
        return copy
    }

    /// Moves a finished file from a work folder to its final, uniquely named place.
    private static func deliver(_ file: URL, for input: URL, ext: String, options: ConversionOptions) throws -> URL {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw ConversionError("The conversion didn't produce a file.")
        }
        let out = OutputPaths.destination(for: input, ext: ext, folder: options.outputFolder)
        try FileManager.default.moveItem(at: file, to: out)
        return out
    }

    /// Every regular file under `folder`, in natural name order ("2" before "10").
    private static func regularFiles(in folder: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { files.append(url) }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// UTF-8 (with or without BOM), UTF-16 with BOM, else Windows Latin-1.
    private static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let text = String(data: data, encoding: .utf16) {
            return text
        }
        if var text = String(data: data, encoding: .utf8) {
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            return text
        }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    /// Escapes text for XML and HTML and drops characters XML can't hold. With `lineBreaks`,
    /// line separators become `<br/>` and attachment markers (pictures) are dropped.
    private static func escape(_ text: String, lineBreaks: Bool = false) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x26: out.append(contentsOf: "&amp;".unicodeScalars)
            case 0x3C: out.append(contentsOf: "&lt;".unicodeScalars)
            case 0x3E: out.append(contentsOf: "&gt;".unicodeScalars)
            case 0x22: out.append(contentsOf: "&quot;".unicodeScalars)
            case 0x09, 0x0A, 0x0D: out.append(scalar)
            case 0x2028 where lineBreaks, 0x0B where lineBreaks: out.append(contentsOf: "<br/>".unicodeScalars)
            case 0xFFFC where lineBreaks: continue
            case 0..<0x20, 0xFFFE, 0xFFFF: continue
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    private static func matches(_ pattern: String, in text: String,
                                options: NSRegularExpression.Options = [.caseInsensitive]) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in text: NSString) -> String? {
        let range = match.range(at: index)
        return range.location == NSNotFound ? nil : text.substring(with: range)
    }

    // MARK: XML

    private static func parseXML(_ url: URL) throws -> OfficeXMLNode {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw ConversionError("\(url.lastPathComponent) is missing.")
        }
        let parser = XMLParser(data: data)
        let builder = OfficeXMLBuilder()
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw ConversionError("Couldn't read \(url.lastPathComponent): \(parser.parserError?.localizedDescription ?? "invalid XML")")
        }
        return builder.root
    }
}

/// A small XML tree for package files. Element names drop their namespace prefix ("dc:title" → "title");
/// text is kept as "#text" children so mixed content stays in order.
private final class OfficeXMLNode {
    let name: String
    let attributes: [String: String]
    var children: [OfficeXMLNode] = []
    var text: String

    init(name: String, attributes: [String: String] = [:], text: String = "") {
        self.name = name
        self.attributes = attributes
        self.text = text
    }

    /// An attribute by local name, with or without a prefix ("id" also finds "r:id").
    func attribute(_ local: String) -> String? {
        if let value = attributes[local] { return value }
        let suffix = ":" + local
        return attributes.first { $0.key.hasSuffix(suffix) }?.value
    }

    func element(_ local: String) -> OfficeXMLNode? {
        children.first { $0.name == local }
    }

    func elements(_ local: String) -> [OfficeXMLNode] {
        children.filter { $0.name == local }
    }

    func descendants(_ local: String) -> [OfficeXMLNode] {
        var found: [OfficeXMLNode] = []
        collect(local, into: &found)
        return found
    }

    private func collect(_ local: String, into found: inout [OfficeXMLNode]) {
        for child in children {
            if child.name == local { found.append(child) }
            child.collect(local, into: &found)
        }
    }

    func firstDescendant(_ local: String) -> OfficeXMLNode? {
        for child in children {
            if child.name == local { return child }
            if let match = child.firstDescendant(local) { return match }
        }
        return nil
    }

    var textContent: String {
        if name == "#text" { return text }
        var result = ""
        for child in children { result += child.textContent }
        return result
    }

    func appendText(_ string: String) {
        if let last = children.last, last.name == "#text" {
            last.text += string
        } else {
            children.append(OfficeXMLNode(name: "#text", text: string))
        }
    }
}

private final class OfficeXMLBuilder: NSObject, XMLParserDelegate {
    let root = OfficeXMLNode(name: "#document")
    private var stack: [OfficeXMLNode] = []

    override init() {
        super.init()
        stack = [root]
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        let node = OfficeXMLNode(name: local, attributes: attributeDict)
        stack.last?.children.append(node)
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if stack.count > 1 { stack.removeLast() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.appendText(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.appendText(String(decoding: CDATABlock, as: UTF8.self))
    }
}
