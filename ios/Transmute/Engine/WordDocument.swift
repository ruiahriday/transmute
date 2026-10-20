import Foundation
import UIKit

/// Reads and writes Word (.docx) files. macOS does this inside NSAttributedString; iOS can't,
/// so this handles the parts that matter for converting: paragraphs, headings, bold, italic,
/// underline, text size, lists, tables (as paragraphs) and links.
enum WordDocument {
    static let bodySize: CGFloat = 12

    // MARK: Reading

    static func read(_ url: URL) throws -> NSAttributedString {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("transmute-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try ZipArchive.extract(url, to: folder)
        } catch {
            throw ConversionError("\(url.lastPathComponent) isn't a Word document Transmute can read.")
        }
        let documentURL = folder.appendingPathComponent("word/document.xml")
        guard let document = try? Data(contentsOf: documentURL) else {
            throw ConversionError("\(url.lastPathComponent) has no text Transmute can find.")
        }
        let links = relationships(folder.appendingPathComponent("word/_rels/document.xml.rels"))
        let parser = DocxParser(links: links)
        let xml = XMLParser(data: document)
        xml.shouldProcessNamespaces = false
        xml.delegate = parser
        guard xml.parse() else {
            throw ConversionError("\(url.lastPathComponent) is damaged: \(xml.parserError?.localizedDescription ?? "unreadable XML")")
        }
        return parser.result
    }

    /// Relationship id → target, for hyperlinks.
    private static func relationships(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        final class Reader: NSObject, XMLParserDelegate {
            var map: [String: String] = [:]
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String] = [:]) {
                if name.hasSuffix("Relationship"), let id = attributes["Id"], let target = attributes["Target"] {
                    map[id] = target
                }
            }
        }
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.map
    }

    private final class DocxParser: NSObject, XMLParserDelegate {
        let links: [String: String]
        let result = NSMutableAttributedString()

        private var paragraph = NSMutableAttributedString()
        private var paragraphSize: CGFloat?
        private var paragraphBold = false
        private var listItem = false
        private var inRun = false
        private var inText = false
        private var bold = false
        private var italic = false
        private var underline = false
        private var size: CGFloat?
        private var link: String?
        private var inRunProperties = false
        private var inParagraphProperties = false

        init(links: [String: String]) { self.links = links }

        private func local(_ name: String) -> String {
            name.split(separator: ":").last.map(String.init) ?? name
        }

        private func isOn(_ attributes: [String: String]) -> Bool {
            let value = (attributes["w:val"] ?? "true").lowercased()
            return !["0", "false", "off", "none"].contains(value)
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            switch local(name) {
            case "p":
                paragraph = NSMutableAttributedString()
                paragraphSize = nil
                paragraphBold = false
                listItem = false
            case "pPr": inParagraphProperties = true
            case "pStyle":
                let style = (attributes["w:val"] ?? "").lowercased()
                if style == "title" {
                    paragraphSize = 24; paragraphBold = true
                } else if style.hasPrefix("heading"), let level = Int(style.dropFirst("heading".count)) {
                    let sizes: [CGFloat] = [20, 16, 14, 13, 12, 12]
                    paragraphSize = sizes[min(max(level, 1), 6) - 1]
                    paragraphBold = true
                } else if style.contains("list") {
                    listItem = true
                }
            case "numPr": if inParagraphProperties { listItem = true }
            case "r":
                inRun = true
                bold = paragraphBold; italic = false; underline = false; size = paragraphSize
            case "rPr": inRunProperties = inRun
            case "b" where inRunProperties: bold = isOn(attributes)
            case "i" where inRunProperties: italic = isOn(attributes)
            case "u" where inRunProperties: underline = isOn(attributes)
            case "sz" where inRunProperties:
                if let half = Double(attributes["w:val"] ?? "") { size = CGFloat(half / 2) }
            case "t": inText = true
            case "tab" where inRun: append("\t")
            case "br" where inRun, "cr" where inRun: append("\u{2028}")
            case "hyperlink":
                if let id = attributes["r:id"], let target = links[id] { link = target }
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch local(name) {
            case "p":
                if listItem && paragraph.length > 0 {
                    paragraph.insert(NSAttributedString(string: "• ", attributes: attributes()), at: 0)
                }
                if result.length > 0 { result.append(NSAttributedString(string: "\n", attributes: attributes())) }
                result.append(paragraph)
            case "pPr": inParagraphProperties = false
            case "r": inRun = false
            case "rPr": inRunProperties = false
            case "t": inText = false
            case "hyperlink": link = nil
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { append(string) }
        }

        private func append(_ text: String) {
            paragraph.append(NSAttributedString(string: text, attributes: attributes()))
        }

        private func attributes() -> [NSAttributedString.Key: Any] {
            let pointSize = size ?? paragraphSize ?? WordDocument.bodySize
            var font = UIFont.systemFont(ofSize: pointSize, weight: bold ? .bold : .regular)
            if italic, let descriptor = font.fontDescriptor.withSymbolicTraits(
                font.fontDescriptor.symbolicTraits.union(.traitItalic)) {
                font = UIFont(descriptor: descriptor, size: pointSize)
            }
            var result: [NSAttributedString.Key: Any] = [.font: font]
            if underline { result[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if let link, let url = URL(string: link) { result[.link] = url }
            return result
        }
    }

    // MARK: Writing

    static func write(_ text: NSAttributedString, to out: URL) throws {
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("transmute-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }

        var links: [String] = []
        var body = ""
        let ns = text.string as NSString
        var location = 0
        repeat {
            let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            var runs = ""
            text.enumerateAttributes(in: range) { attributes, runRange, _ in
                var piece = ns.substring(with: runRange)
                piece = piece.trimmingCharacters(in: CharacterSet(charactersIn: "\n\r\u{2029}"))
                guard !piece.isEmpty else { return }
                let font = attributes[.font] as? UIFont
                var props = ""
                if font?.isBold == true { props += "<w:b/>" }
                if font?.isItalic == true { props += "<w:i/>" }
                if let style = attributes[.underlineStyle] as? Int, style != 0 { props += "<w:u w:val=\"single\"/>" }
                if let size = font?.pointSize, abs(size - bodySize) > 0.5 {
                    props += "<w:sz w:val=\"\(Int((size * 2).rounded()))\"/>"
                }
                var run = "<w:r>" + (props.isEmpty ? "" : "<w:rPr>\(props)</w:rPr>")
                let segments = piece.components(separatedBy: CharacterSet(charactersIn: "\t\u{2028}"))
                var index = piece.startIndex
                for (n, segment) in segments.enumerated() {
                    if n > 0 {
                        run += piece[index] == "\t" ? "<w:tab/>" : "<w:br/>"
                        index = piece.index(after: index)
                    }
                    if !segment.isEmpty { run += "<w:t xml:space=\"preserve\">\(escape(segment))</w:t>" }
                    index = piece.index(index, offsetBy: segment.count)
                }
                run += "</w:r>"
                let target = (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String
                if let target, ["http", "https", "mailto"].contains(URL(string: target)?.scheme?.lowercased() ?? "") {
                    links.append(target)
                    run = "<w:hyperlink r:id=\"rLink\(links.count)\">\(run)</w:hyperlink>"
                }
                runs += run
            }
            body += "<w:p>\(runs)</w:p>"
        } while location < ns.length

        let document = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
            <w:body>\(body)<w:sectPr><w:pgSz w:w="12240" w:h="15840"/>\
            <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>\
            </w:sectPr></w:body></w:document>
            """
        let linkRels = links.enumerated().map { n, target in
            "<Relationship Id=\"rLink\(n + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(escape(target))\" TargetMode=\"External\"/>"
        }.joined()
        let files: [(String, String)] = [
            ("[Content_Types].xml", """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
                <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
                <Default Extension="xml" ContentType="application/xml"/>\
                <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
                <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
                </Types>
                """),
            ("_rels/.rels", """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
                </Relationships>
                """),
            ("word/_rels/document.xml.rels", """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
                \(linkRels)</Relationships>
                """),
            ("word/styles.xml", """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
                <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Helvetica" w:hAnsi="Helvetica" w:cs="Helvetica"/>\
                <w:sz w:val="\(Int(bodySize * 2))"/></w:rPr></w:rPrDefault>\
                <w:pPrDefault><w:pPr><w:spacing w:after="120"/></w:pPr></w:pPrDefault></w:docDefaults>\
                </w:styles>
                """),
            ("word/document.xml", document),
        ]
        for (path, content) in files {
            let url = stage.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
        try ZipArchive.create(out, from: stage, items: ["[Content_Types].xml", "_rels", "word"])
    }

    private static func escape(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        // XML 1.0 can't hold most control characters.
        result.unicodeScalars.removeAll { $0.value < 0x20 && $0 != "\t" && $0 != "\n" && $0 != "\r" }
        return result
    }
}
