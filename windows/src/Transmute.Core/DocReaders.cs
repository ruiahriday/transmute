using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using DocumentFormat.OpenXml.Packaging;
using HtmlAgilityPack;
using Markdig;
using W = DocumentFormat.OpenXml.Wordprocessing;

namespace Transmute;

/// Reads documents into a Doc.
public static class DocReaders
{
    public static Doc Read(string path)
    {
        var ext = Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        var doc = ext switch
        {
            "txt" => ReadText(ReadAllText(path)),
            "md" or "markdown" => ReadMarkdown(ReadAllText(path)),
            "html" or "htm" => ReadHtml(ReadAllText(path), rel => ResolveFile(path, rel)),
            "rtf" => Rtf.Read(File.ReadAllText(path, Encoding.Latin1)),
            "docx" => ReadDocx(path),
            "odt" => ReadOdt(path),
            "epub" => ReadEpub(path),
            "pdf" => ReadPdf(path),
            "doc" => throw new ConversionException("Old Word files (.doc) need Microsoft Word or the free LibreOffice installed. Transmute uses them automatically when they're there."),
            _ => throw new ConversionException($"Transmute can't read {ext.ToUpperInvariant()} documents."),
        };
        doc.Title ??= OutputPaths.BaseName(path);
        return doc;
    }

    /// Text in UTF-8 (with or without BOM), UTF-16, or else Windows' Western code page.
    public static string ReadAllText(string path)
    {
        var bytes = File.ReadAllBytes(path);
        if (bytes.Length >= 2 && (bytes[0] == 0xFF && bytes[1] == 0xFE || bytes[0] == 0xFE && bytes[1] == 0xFF))
            return new StreamReader(new MemoryStream(bytes), true).ReadToEnd();
        try
        {
            return new UTF8Encoding(false, true).GetString(bytes).TrimStart('﻿');
        }
        catch (DecoderFallbackException)
        {
            CodePages.Register();
            return Encoding.GetEncoding(1252).GetString(bytes);
        }
    }

    static byte[]? ResolveFile(string document, string reference)
    {
        if (reference.StartsWith("data:", StringComparison.OrdinalIgnoreCase)) return DataUri(reference);
        try
        {
            var relative = Uri.UnescapeDataString(reference.Split('#', '?')[0]);
            if (Uri.TryCreate(relative, UriKind.Absolute, out var abs) && !abs.IsFile) return null;
            var full = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(Path.GetFullPath(document))!, relative));
            return File.Exists(full) ? File.ReadAllBytes(full) : null;
        }
        catch { return null; }
    }

    static byte[]? DataUri(string uri)
    {
        var comma = uri.IndexOf(',');
        if (comma < 0 || !uri[..comma].EndsWith(";base64", StringComparison.OrdinalIgnoreCase)) return null;
        try { return Convert.FromBase64String(uri[(comma + 1)..]); } catch { return null; }
    }

    // Plain text and Markdown

    public static Doc ReadText(string text)
    {
        var doc = new Doc();
        text = text.Replace("\r\n", "\n").Replace('\r', '\n');
        foreach (var chunk in Regex.Split(text, @"\n[ \t]*\n"))
        {
            var para = chunk.Trim('\n');
            if (para.Trim().Length == 0) continue;
            if (para.Contains('\f'))
            {
                foreach (var (part, i) in para.Split('\f').Select((p, i) => (p, i)))
                {
                    if (i > 0) doc.Blocks.Add(new Block.PageBreak());
                    if (part.Trim().Length > 0) doc.Blocks.Add(new Block.Paragraph([new Run(part.Trim('\n'))]));
                }
                continue;
            }
            doc.Blocks.Add(new Block.Paragraph([new Run(para)]));
        }
        return doc;
    }

    public static Doc ReadMarkdown(string text)
    {
        var pipeline = new Markdig.MarkdownPipelineBuilder().UsePipeTables().UseEmphasisExtras().UseAutoLinks().Build();
        return ReadHtml(Markdig.Markdown.ToHtml(text, pipeline), _ => null);
    }

    // HTML (also used for EPUB chapters and Markdown)

    public static Doc ReadHtml(string html, Func<string, byte[]?> resolve)
    {
        var page = new HtmlDocument { OptionFixNestedTags = true };
        page.LoadHtml(html);
        var doc = new Doc();
        var title = page.DocumentNode.SelectSingleNode("//title")?.InnerText;
        if (!string.IsNullOrWhiteSpace(title)) doc.Title = HtmlEntity.DeEntitize(title).Trim();
        var body = page.DocumentNode.SelectSingleNode("//body") ?? page.DocumentNode;
        new HtmlWalker(doc.Blocks, resolve).Walk(body);
        return doc;
    }

    sealed class HtmlWalker(List<Block> blocks, Func<string, byte[]?> resolve)
    {
        readonly List<Run> current = [];
        static readonly HashSet<string> BlockTags =
        [
            "p", "div", "section", "article", "blockquote", "header", "footer", "main", "body", "figure", "figcaption",
            "center", "address", "dd", "dt", "dl", "nav", "aside", "form", "fieldset", "caption", "hr",
        ];
        static readonly HashSet<string> Skip = ["script", "style", "head", "title", "noscript", "svg", "template", "iframe", "object", "button", "select"];

        void Flush()
        {
            var runs = Doc.Tidy(current);
            current.Clear();
            if (runs.Count > 0) blocks.Add(new Block.Paragraph(runs));
        }

        public void Walk(HtmlNode node, Run? style = null, int listLevel = 0)
        {
            style ??= new Run("");
            WalkChildren(node, style, listLevel);
            Flush();
        }

        void WalkChildren(HtmlNode node, Run style, int listLevel)
        {
            foreach (var child in node.ChildNodes) Visit(child, style, listLevel);
        }

        void Visit(HtmlNode node, Run style, int listLevel)
        {
            if (node.NodeType == HtmlNodeType.Comment) return;
            if (node.NodeType == HtmlNodeType.Text)
            {
                var text = Regex.Replace(HtmlEntity.DeEntitize(node.InnerText), @"[ \t\r\n\f]+", " ");
                if (text.Length == 0) return;
                // No space at the start of a line.
                if (text == " " && (current.Count == 0 || current[^1].Text.EndsWith(' ') || current[^1].Text.EndsWith('\n'))) return;
                current.Add(style.With(text));
                return;
            }
            var name = node.Name.ToLowerInvariant();
            if (Skip.Contains(name)) return;
            switch (name)
            {
                case "br":
                    current.Add(style.With("\n"));
                    return;
                case "h1" or "h2" or "h3" or "h4" or "h5" or "h6":
                {
                    Flush();
                    WalkChildren(node, style with { Bold = false }, listLevel);
                    var runs = Doc.Tidy(current);
                    current.Clear();
                    if (runs.Count > 0) blocks.Add(new Block.Heading(name[1] - '0', runs));
                    return;
                }
                case "ul" or "ol" or "menu":
                {
                    Flush();
                    var ordered = name == "ol";
                    foreach (var li in node.ChildNodes)
                    {
                        if (li.NodeType != HtmlNodeType.Element) continue;
                        if (li.Name is "ul" or "ol") { Visit(li, style, listLevel + 1); continue; }
                        ListItem(li, ordered, style, listLevel);
                    }
                    return;
                }
                case "li":
                    Flush();
                    ListItem(node, false, style, listLevel);
                    return;
                case "table":
                {
                    Flush();
                    var rows = node.Descendants("tr")
                        .Select(tr => tr.ChildNodes.Where(c => c.Name is "td" or "th")
                            .Select(c => Regex.Replace(HtmlEntity.DeEntitize(c.InnerText), @"\s+", " ").Trim()).ToList())
                        .Where(r => r.Count > 0).ToList();
                    if (rows.Count > 0) blocks.Add(new Block.Table(rows));
                    return;
                }
                case "pre":
                    Flush();
                    blocks.Add(new Block.Code(HtmlEntity.DeEntitize(node.InnerText).TrimEnd('\n', '\r')));
                    return;
                case "img" or "image":
                {
                    var src = node.GetAttributeValue("src", null) ?? node.GetAttributeValue("xlink:href", null) ?? node.GetAttributeValue("href", null);
                    var data = src is null ? null : resolve(src);
                    if (data is not null && LooksLikePicture(data))
                    {
                        Flush();
                        blocks.Add(new Block.Picture(data, node.GetAttributeValue("alt", null)));
                    }
                    return;
                }
                case "b" or "strong":
                    WalkChildren(node, style with { Bold = true }, listLevel);
                    return;
                case "i" or "em" or "cite" or "var" or "dfn":
                    WalkChildren(node, style with { Italic = true }, listLevel);
                    return;
                case "u" or "ins":
                    WalkChildren(node, style with { Underline = true }, listLevel);
                    return;
                case "a":
                {
                    var href = node.GetAttributeValue("href", null);
                    var external = href is not null && Regex.IsMatch(href, "^(https?|mailto):", RegexOptions.IgnoreCase);
                    WalkChildren(node, external ? style with { Link = HtmlEntity.DeEntitize(href) } : style, listLevel);
                    return;
                }
                case "span" or "font":
                {
                    var css = node.GetAttributeValue("style", "").ToLowerInvariant().Replace(" ", "");
                    var s = style;
                    if (css.Contains("font-weight:bold") || Regex.IsMatch(css, "font-weight:[6-9]00")) s = s with { Bold = true };
                    if (css.Contains("font-style:italic")) s = s with { Italic = true };
                    if (css.Contains("text-decoration:underline")) s = s with { Underline = true };
                    WalkChildren(node, s, listLevel);
                    return;
                }
            }
            if (BlockTags.Contains(name))
            {
                Flush();
                WalkChildren(node, style, listLevel);
                Flush();
                return;
            }
            WalkChildren(node, style, listLevel);
        }

        void ListItem(HtmlNode li, bool ordered, Run style, int level)
        {
            var nested = new List<HtmlNode>();
            foreach (var child in li.ChildNodes)
            {
                if (child.Name is "ul" or "ol") nested.Add(child);
                else if (child.Name is "p" or "div") WalkChildren(child, style, level); // keep "<li><p>…</p></li>" on one line
                else Visit(child, style, level);
            }
            var runs = Doc.Tidy(current);
            current.Clear();
            if (runs.Count > 0) blocks.Add(new Block.ListItem(ordered, level, runs));
            foreach (var list in nested) Visit(list, style, level + 1);
        }
    }

    public static bool LooksLikePicture(byte[] data) =>
        data.Length > 8 && (
            data[0] == 0x89 && data[1] == 0x50 || // PNG
            data[0] == 0xFF && data[1] == 0xD8 || // JPEG
            data[0] == 0x47 && data[1] == 0x49 || // GIF
            data[0] == 0x42 && data[1] == 0x4D || // BMP
            data[0] == 0x52 && data[1] == 0x49 && data[8] == 0x57); // RIFF….WEBP

    // Word

    public static Doc ReadDocx(string path)
    {
        var doc = new Doc();
        WordprocessingDocument word;
        try { word = WordprocessingDocument.Open(path, false); }
        catch (Exception e) { throw new ConversionException($"Couldn't open {Path.GetFileName(path)} as a Word document: {e.Message}"); }
        using (word)
        {
            var main = word.MainDocumentPart ?? throw new ConversionException("The Word document is empty.");
            doc.Title = word.PackageProperties.Title;
            doc.Author = word.PackageProperties.Creator;
            var styles = main.StyleDefinitionsPart?.Styles?.Elements<W.Style>()
                .Where(s => s.StyleId?.Value is not null)
                .ToDictionary(s => s.StyleId!.Value!, s => s) ?? [];
            var numbering = main.NumberingDefinitionsPart?.Numbering;
            var body = main.Document?.Body;
            if (body is null) return doc;
            foreach (var element in body.Elements())
            {
                switch (element)
                {
                    case W.Paragraph p: DocxParagraph(p, main, styles, numbering, doc.Blocks); break;
                    case W.Table t:
                        var rows = t.Elements<W.TableRow>()
                            .Select(r => r.Elements<W.TableCell>().Select(c => string.Join(" ", c.Elements<W.Paragraph>().Select(ParagraphText)).Trim()).ToList())
                            .Where(r => r.Count > 0).ToList();
                        if (rows.Count > 0) doc.Blocks.Add(new Block.Table(rows));
                        break;
                    case W.SdtBlock sdt:
                        foreach (var p in sdt.Descendants<W.Paragraph>()) DocxParagraph(p, main, styles, numbering, doc.Blocks);
                        break;
                }
            }
        }
        return doc;
    }

    static string ParagraphText(W.Paragraph p) => string.Concat(p.Descendants<W.Text>().Select(t => t.Text));

    static void DocxParagraph(W.Paragraph p, MainDocumentPart main, Dictionary<string, W.Style> styles,
        W.Numbering? numbering, List<Block> blocks)
    {
        var props = p.ParagraphProperties;
        var styleId = props?.ParagraphStyleId?.Val?.Value;
        var heading = 0;
        if (styleId is not null && styles.TryGetValue(styleId, out var style))
        {
            var name = style.StyleName?.Val?.Value?.ToLowerInvariant() ?? "";
            if (name == "title") heading = 1;
            else if (name.StartsWith("heading ") && int.TryParse(name[8..], out var level)) heading = Math.Clamp(level, 1, 6);
            else if (style.StyleParagraphProperties?.OutlineLevel?.Val?.Value is { } outline && outline < 6) heading = outline + 1;
        }
        if (props?.OutlineLevel?.Val?.Value is { } own && own < 6) heading = own + 1;

        var runs = new List<Run>();
        var pictures = new List<byte[]>();
        void AddRun(W.Run r, string? link)
        {
            var rp = r.RunProperties;
            bool On(DocumentFormat.OpenXml.Wordprocessing.OnOffType? flag) => flag is not null && (flag.Val is null || flag.Val.Value);
            var bold = On(rp?.Bold);
            var italic = On(rp?.Italic);
            var underline = rp?.Underline?.Val is { } u && u.Value != W.UnderlineValues.None;
            var text = new StringBuilder();
            foreach (var child in r.ChildElements)
            {
                switch (child)
                {
                    case W.Text t: text.Append(t.Text); break;
                    case W.TabChar: text.Append('\t'); break;
                    case W.Break b when b.Type?.Value == W.BreakValues.Page:
                        break;
                    case W.Break or W.CarriageReturn: text.Append('\n'); break;
                    case W.NoBreakHyphen: text.Append('-'); break;
                    case W.Drawing or W.Picture:
                        foreach (var blip in child.Descendants<DocumentFormat.OpenXml.Drawing.Blip>())
                            if (blip.Embed?.Value is { } id && main.GetPartById(id) is ImagePart part)
                            {
                                using var s = part.GetStream();
                                using var m = new MemoryStream();
                                s.CopyTo(m);
                                pictures.Add(m.ToArray());
                            }
                        foreach (var image in child.Descendants().Where(e => e.LocalName == "imagedata"))
                        {
                            var rid = image.GetAttributes().FirstOrDefault(a => a.LocalName == "id").Value;
                            if (rid is not null && main.GetPartById(rid) is ImagePart part)
                            {
                                using var s = part.GetStream();
                                using var m = new MemoryStream();
                                s.CopyTo(m);
                                pictures.Add(m.ToArray());
                            }
                        }
                        break;
                }
            }
            if (text.Length > 0) runs.Add(new Run(text.ToString(), bold, italic, underline, link));
        }
        foreach (var child in p.ChildElements)
        {
            switch (child)
            {
                case W.Run r: AddRun(r, null); break;
                case W.Hyperlink h:
                    string? url = null;
                    if (h.Id?.Value is { } hid)
                        url = main.HyperlinkRelationships.FirstOrDefault(rel => rel.Id == hid)?.Uri.ToString();
                    foreach (var r in h.Elements<W.Run>()) AddRun(r, url);
                    break;
                case W.SimpleField or W.InsertedRun:
                    foreach (var r in child.Descendants<W.Run>()) AddRun(r, null);
                    break;
            }
        }
        var pageBreakBefore = p.Descendants<W.Break>().Any(b => b.Type?.Value == W.BreakValues.Page) || props?.PageBreakBefore is not null;
        if (pageBreakBefore && blocks.Count > 0) blocks.Add(new Block.PageBreak());
        var tidy = Doc.Tidy(runs);
        if (tidy.Count > 0)
        {
            if (heading > 0) blocks.Add(new Block.Heading(heading, tidy.Select(r => r with { Bold = false }).ToList()));
            else if (props?.NumberingProperties is { } numPr && numPr.NumberingId?.Val?.Value is { } numId && numId != 0)
            {
                var level = numPr.NumberingLevelReference?.Val?.Value ?? 0;
                blocks.Add(new Block.ListItem(IsOrdered(numbering, numId, level), level, tidy));
            }
            else if (styleId is not null && styleId.StartsWith("List", StringComparison.OrdinalIgnoreCase) && styleId.Contains("Bullet"))
                blocks.Add(new Block.ListItem(false, 0, tidy));
            else blocks.Add(new Block.Paragraph(tidy));
        }
        foreach (var picture in pictures) blocks.Add(new Block.Picture(picture));
    }

    static bool IsOrdered(W.Numbering? numbering, int numId, int level)
    {
        if (numbering is null) return false;
        var num = numbering.Elements<W.NumberingInstance>().FirstOrDefault(n => n.NumberID?.Value == numId);
        var abstractId = num?.AbstractNumId?.Val?.Value;
        var abs = numbering.Elements<W.AbstractNum>().FirstOrDefault(a => a.AbstractNumberId?.Value == abstractId);
        var lvl = abs?.Elements<W.Level>().FirstOrDefault(l => l.LevelIndex?.Value == level);
        var format = lvl?.NumberingFormat?.Val?.Value;
        return format is not null && format != W.NumberFormatValues.Bullet && format != W.NumberFormatValues.None;
    }

    // OpenDocument text

    static readonly XNamespace OText = "urn:oasis:names:tc:opendocument:xmlns:text:1.0";
    static readonly XNamespace OOffice = "urn:oasis:names:tc:opendocument:xmlns:office:1.0";
    static readonly XNamespace OStyle = "urn:oasis:names:tc:opendocument:xmlns:style:1.0";
    static readonly XNamespace OFo = "urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0";
    static readonly XNamespace OTable = "urn:oasis:names:tc:opendocument:xmlns:table:1.0";
    static readonly XNamespace ODraw = "urn:oasis:names:tc:opendocument:xmlns:drawing:1.0";
    static readonly XNamespace OXlink = "http://www.w3.org/1999/xlink";
    static readonly XNamespace ODc = "http://purl.org/dc/elements/1.1/";

    public static Doc ReadOdt(string path)
    {
        using var zip = OpenZip(path);
        var content = LoadXml(zip, "content.xml") ?? throw new ConversionException("The OpenDocument file has no content.");
        var doc = new Doc();
        var meta = LoadXml(zip, "meta.xml");
        doc.Title = meta?.Descendants(ODc + "title").FirstOrDefault()?.Value;
        // Automatic styles say which spans are bold or italic.
        var styleMap = new Dictionary<string, (bool Bold, bool Italic, bool Underline)>();
        foreach (var source in new[] { content, LoadXml(zip, "styles.xml") })
        {
            if (source is null) continue;
            foreach (var s in source.Descendants(OStyle + "style"))
            {
                var name = (string?)s.Attribute(OStyle + "name");
                var text = s.Element(OStyle + "text-properties");
                if (name is null || text is null) continue;
                styleMap[name] = ((string?)text.Attribute(OFo + "font-weight") is "bold" or "700" or "600" or "800",
                    (string?)text.Attribute(OFo + "font-style") == "italic",
                    (string?)text.Attribute(OStyle + "text-underline-style") is { } u && u != "none");
            }
        }
        var body = content.Descendants(OOffice + "text").FirstOrDefault();
        if (body is null) return doc;
        OdtBlocks(body, doc.Blocks, styleMap, zip, 0);
        return doc;
    }

    static void OdtBlocks(XElement parent, List<Block> blocks, Dictionary<string, (bool, bool, bool)> styles, ZipArchive zip, int listLevel)
    {
        foreach (var e in parent.Elements())
        {
            if (e.Name == OText + "h")
            {
                var level = (int?)e.Attribute(OText + "outline-level") ?? 1;
                var runs = Doc.Tidy(OdtRuns(e, styles, new Run("")));
                if (runs.Count > 0) blocks.Add(new Block.Heading(Math.Clamp(level, 1, 6), runs));
            }
            else if (e.Name == OText + "p")
            {
                var runs = Doc.Tidy(OdtRuns(e, styles, new Run("")));
                if (runs.Count > 0) blocks.Add(new Block.Paragraph(runs));
                OdtPictures(e, blocks, zip);
            }
            else if (e.Name == OText + "list")
            {
                foreach (var item in e.Elements(OText + "list-item"))
                {
                    foreach (var inner in item.Elements())
                    {
                        if (inner.Name == OText + "list") OdtBlocks(new XElement("wrap", inner), blocks, styles, zip, listLevel + 1);
                        else
                        {
                            var runs = Doc.Tidy(OdtRuns(inner, styles, new Run("")));
                            if (runs.Count > 0) blocks.Add(new Block.ListItem(false, listLevel, runs));
                        }
                    }
                }
            }
            else if (e.Name == OTable + "table")
            {
                var rows = e.Descendants(OTable + "table-row")
                    .Select(r => r.Elements(OTable + "table-cell").Select(c => string.Join(" ", c.Elements(OText + "p").Select(p => p.Value)).Trim()).ToList())
                    .Where(r => r.Count > 0).ToList();
                if (rows.Count > 0) blocks.Add(new Block.Table(rows));
            }
            else if (e.Name == OText + "section" || e.Name == OText + "soft-page-break")
            {
                OdtBlocks(e, blocks, styles, zip, listLevel);
            }
        }
    }

    static IEnumerable<Run> OdtRuns(XElement e, Dictionary<string, (bool Bold, bool Italic, bool Underline)> styles, Run style)
    {
        var own = (string?)e.Attribute(OText + "style-name");
        if (own is not null && styles.TryGetValue(own, out var s))
            style = style with { Bold = style.Bold || s.Bold, Italic = style.Italic || s.Italic, Underline = style.Underline || s.Underline };
        foreach (var node in e.Nodes())
        {
            if (node is XText t) { yield return style.With(t.Value); continue; }
            if (node is not XElement child) continue;
            if (child.Name == OText + "s") yield return style.With(new string(' ', (int?)child.Attribute(OText + "c") ?? 1));
            else if (child.Name == OText + "tab") yield return style.With("\t");
            else if (child.Name == OText + "line-break") yield return style.With("\n");
            else if (child.Name == OText + "a")
                foreach (var r in OdtRuns(child, styles, style with { Link = (string?)child.Attribute(OXlink + "href") })) yield return r;
            else if (child.Name == OText + "span")
                foreach (var r in OdtRuns(child, styles, style)) yield return r;
            else if (child.Name.Namespace == OText && child.Name.LocalName is "note" or "bookmark" or "bookmark-start" or "bookmark-end") continue;
        }
    }

    static void OdtPictures(XElement e, List<Block> blocks, ZipArchive zip)
    {
        foreach (var image in e.Descendants(ODraw + "image"))
        {
            var href = (string?)image.Attribute(OXlink + "href");
            if (href is null) continue;
            var entry = zip.GetEntry(href.TrimStart('.', '/'));
            if (entry is null) continue;
            var data = ReadEntry(entry);
            if (LooksLikePicture(data)) blocks.Add(new Block.Picture(data));
        }
    }

    // EPUB

    public static Doc ReadEpub(string path)
    {
        using var zip = OpenZip(path);
        var container = LoadXml(zip, "META-INF/container.xml") ?? throw new ConversionException("This EPUB has no container.xml.");
        var opfPath = container.Descendants().FirstOrDefault(e => e.Name.LocalName == "rootfile")?.Attribute("full-path")?.Value
            ?? throw new ConversionException("This EPUB doesn't say where its contents are.");
        var opf = LoadXml(zip, opfPath) ?? throw new ConversionException("This EPUB's package file is missing.");
        var baseDir = opfPath.Contains('/') ? opfPath[..(opfPath.LastIndexOf('/') + 1)] : "";
        var doc = new Doc
        {
            Title = opf.Descendants().FirstOrDefault(e => e.Name.LocalName == "title")?.Value,
            Author = opf.Descendants().FirstOrDefault(e => e.Name.LocalName == "creator")?.Value,
        };
        var manifest = opf.Descendants().Where(e => e.Name.LocalName == "item")
            .Where(e => e.Attribute("id") is not null && e.Attribute("href") is not null)
            .GroupBy(e => e.Attribute("id")!.Value)
            .ToDictionary(g => g.Key, g => g.First().Attribute("href")!.Value);
        var spine = opf.Descendants().Where(e => e.Name.LocalName == "itemref").Select(e => e.Attribute("idref")?.Value).OfType<string>().ToList();
        var first = true;
        foreach (var id in spine)
        {
            if (!manifest.TryGetValue(id, out var href)) continue;
            var chapterPath = CombineZipPath(baseDir, Uri.UnescapeDataString(href));
            var entry = zip.GetEntry(chapterPath);
            if (entry is null) continue;
            var html = Encoding.UTF8.GetString(ReadEntry(entry));
            var chapterDir = chapterPath.Contains('/') ? chapterPath[..(chapterPath.LastIndexOf('/') + 1)] : "";
            var chapter = ReadHtml(html, reference =>
            {
                if (reference.StartsWith("data:")) return DataUri(reference);
                var target = zip.GetEntry(CombineZipPath(chapterDir, Uri.UnescapeDataString(reference.Split('#')[0])));
                return target is null ? null : ReadEntry(target);
            });
            if (chapter.Blocks.Count == 0) continue;
            if (!first) doc.Blocks.Add(new Block.PageBreak());
            doc.Blocks.AddRange(chapter.Blocks);
            first = false;
        }
        return doc;
    }

    public static string CombineZipPath(string dir, string relative)
    {
        var parts = new List<string>((dir + relative).Split('/'));
        var result = new List<string>();
        foreach (var p in parts)
        {
            if (p == "..") { if (result.Count > 0) result.RemoveAt(result.Count - 1); }
            else if (p != "." && p.Length > 0) result.Add(p);
        }
        return string.Join("/", result);
    }

    // PDF

    public static Doc ReadPdf(string path)
    {
        var doc = new Doc();
        var pages = PdfTools.PageTexts(path);
        for (var i = 0; i < pages.Count; i++)
        {
            if (i > 0) doc.Blocks.Add(new Block.PageBreak());
            foreach (var chunk in Regex.Split(pages[i].Replace("\r\n", "\n"), @"\n\s*\n"))
            {
                var text = string.Join("\n", chunk.Split('\n').Select(l => l.TrimEnd())).Trim('\n');
                if (text.Trim().Length > 0) doc.Blocks.Add(new Block.Paragraph([new Run(text)]));
            }
        }
        if (doc.Blocks.All(b => b is Block.PageBreak))
            throw new ConversionException($"{Path.GetFileName(path)} has no text in it (it may be scanned pictures of pages). Convert it to PNG or JPEG instead.");
        return doc;
    }

    // Zip helpers

    public static ZipArchive OpenZip(string path)
    {
        try { return ZipFile.OpenRead(path); }
        catch (Exception e) { throw new ConversionException($"{Path.GetFileName(path)} is damaged or isn't the kind of file its name says: {e.Message}"); }
    }

    public static XDocument? LoadXml(ZipArchive zip, string name)
    {
        var entry = zip.GetEntry(name) ?? zip.Entries.FirstOrDefault(e => e.FullName.Equals(name, StringComparison.OrdinalIgnoreCase));
        if (entry is null) return null;
        using var stream = entry.Open();
        return XDocument.Load(stream);
    }

    public static byte[] ReadEntry(ZipArchiveEntry entry)
    {
        using var stream = entry.Open();
        using var memory = new MemoryStream();
        stream.CopyTo(memory);
        return memory.ToArray();
    }
}

static class CodePages
{
    static bool done;
    public static void Register()
    {
        if (done) return;
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        done = true;
    }
}
