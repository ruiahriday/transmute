using System.IO.Compression;
using System.Net;
using System.Text;
using DocumentFormat.OpenXml;
using DocumentFormat.OpenXml.Packaging;
using ImageMagick;
using MigraDoc.DocumentObjectModel;
using MigraDoc.Rendering;
using W = DocumentFormat.OpenXml.Wordprocessing;

namespace Transmute;

/// Writes a Doc as text, Markdown, HTML, RTF, Word, OpenDocument, EPUB or PDF.
public static class DocWriters
{
    public static void Write(Doc doc, OutputFormat format, string output)
    {
        switch (format)
        {
            case OutputFormat.Txt: File.WriteAllText(output, ToText(doc), new UTF8Encoding(false)); break;
            case OutputFormat.Md: File.WriteAllText(output, ToMarkdown(doc), new UTF8Encoding(false)); break;
            case OutputFormat.Html: File.WriteAllText(output, ToHtml(doc), new UTF8Encoding(false)); break;
            case OutputFormat.Rtf: File.WriteAllText(output, Rtf.Write(doc), Encoding.ASCII); break;
            case OutputFormat.Docx: WriteDocx(doc, output); break;
            case OutputFormat.Odt: WriteOdt(doc, output); break;
            case OutputFormat.Epub: WriteEpub(doc, output); break;
            case OutputFormat.Pdf: WritePdf(doc, output); break;
            default: throw new ConversionException($"Documents can't be saved as {format.Label()}.");
        }
    }

    // Plain text and Markdown

    public static string ToText(Doc doc)
    {
        var sb = new StringBuilder();
        var number = 0;
        foreach (var block in doc.Blocks)
        {
            if (block is not Block.ListItem { Ordered: true }) number = 0;
            switch (block)
            {
                case Block.Heading h: sb.Append(Doc.Text(h.Runs)).Append("\n\n"); break;
                case Block.Paragraph p: sb.Append(Doc.Text(p.Runs)).Append("\n\n"); break;
                case Block.ListItem li:
                    sb.Append(new string(' ', li.Level * 4)).Append(li.Ordered ? $"{++number}. " : "• ").Append(Doc.Text(li.Runs)).Append('\n');
                    break;
                case Block.Table t:
                    foreach (var row in t.Rows) sb.Append(string.Join("\t", row)).Append('\n');
                    sb.Append('\n');
                    break;
                case Block.Code c: sb.Append(c.Text).Append("\n\n"); break;
                case Block.PageBreak: sb.Append('\n'); break;
            }
            if (block is Block.ListItem) continue;
        }
        return sb.ToString().TrimEnd('\n') + "\n";
    }

    public static string ToMarkdown(Doc doc)
    {
        var sb = new StringBuilder();
        var number = 0;
        Block? previous = null;
        foreach (var block in doc.Blocks)
        {
            if (block is not Block.ListItem { Ordered: true }) number = 0;
            if (previous is Block.ListItem && block is not Block.ListItem) sb.Append('\n');
            switch (block)
            {
                case Block.Heading h: sb.Append(new string('#', h.Level)).Append(' ').Append(MdRuns(h.Runs)).Append("\n\n"); break;
                case Block.Paragraph p: sb.Append(MdRuns(p.Runs).Replace("\n", "  \n")).Append("\n\n"); break;
                case Block.ListItem li:
                    sb.Append(new string(' ', li.Level * 4)).Append(li.Ordered ? $"{++number}. " : "- ").Append(MdRuns(li.Runs)).Append('\n');
                    break;
                case Block.Table t:
                    var columns = t.Rows.Max(r => r.Count);
                    for (var r = 0; r < t.Rows.Count; r++)
                    {
                        sb.Append("| ").Append(string.Join(" | ", Enumerable.Range(0, columns).Select(c => c < t.Rows[r].Count ? t.Rows[r][c].Replace("|", "\\|") : ""))).Append(" |\n");
                        if (r == 0) sb.Append('|').Append(string.Concat(Enumerable.Repeat(" --- |", columns))).Append('\n');
                    }
                    sb.Append('\n');
                    break;
                case Block.Code c: sb.Append("```\n").Append(c.Text).Append("\n```\n\n"); break;
                case Block.Picture pic:
                    sb.Append("![").Append(pic.Alt ?? "picture").Append("](data:").Append(Mime(pic.Data)).Append(";base64,")
                        .Append(Convert.ToBase64String(pic.Data)).Append(")\n\n");
                    break;
                case Block.PageBreak: sb.Append("---\n\n"); break;
            }
            previous = block;
        }
        return sb.ToString().TrimEnd('\n') + "\n";
    }

    static string MdRuns(IEnumerable<Run> runs) => string.Concat(runs.Select(r =>
    {
        var text = r.Text.Replace("*", "\\*").Replace("_", "\\_");
        if (text.Trim().Length == 0) return text;
        var lead = text[..(text.Length - text.TrimStart().Length)];
        var trail = text[text.TrimEnd().Length..];
        var core = text.Trim();
        if (r.Bold) core = $"**{core}**";
        if (r.Italic) core = $"*{core}*";
        if (r.Link is not null) core = $"[{core}]({r.Link})";
        return lead + core + trail;
    }));

    public static string Mime(byte[] data) =>
        data.Length > 3 && data[0] == 0xFF && data[1] == 0xD8 ? "image/jpeg"
        : data.Length > 3 && data[0] == 0x47 && data[1] == 0x49 ? "image/gif"
        : "image/png";

    // HTML

    public static string ToHtml(Doc doc)
    {
        var title = WebUtility.HtmlEncode(doc.GuessTitle("Document"));
        var sb = new StringBuilder();
        sb.Append("<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n");
        sb.Append($"<title>{title}</title>\n");
        sb.Append("<style>body{font-family:\"Segoe UI\",Arial,sans-serif;max-width:46em;margin:2em auto;padding:0 1em;line-height:1.5}");
        sb.Append("table{border-collapse:collapse}td,th{border:1px solid #999;padding:4px 8px}img{max-width:100%}pre{background:#f4f4f4;padding:8px;overflow:auto}</style>\n");
        sb.Append("</head>\n<body>\n");
        sb.Append(HtmlBody(doc.Blocks, pic => $"data:{Mime(pic.Data)};base64,{Convert.ToBase64String(pic.Data)}", false));
        sb.Append("</body>\n</html>\n");
        return sb.ToString();
    }

    /// The blocks as HTML (or XHTML for EPUB), with pictures pointing wherever `pictureSource` says.
    public static string HtmlBody(IEnumerable<Block> blocks, Func<Block.Picture, string> pictureSource, bool xhtml)
    {
        var sb = new StringBuilder();
        var openLists = new Stack<bool>(); // true = ordered
        string br = xhtml ? "<br/>" : "<br>";
        void CloseListsTo(int depth)
        {
            while (openLists.Count > depth) sb.Append(openLists.Pop() ? "</ol>\n" : "</ul>\n");
        }
        foreach (var block in blocks)
        {
            if (block is Block.ListItem li)
            {
                while (openLists.Count > li.Level + 1) sb.Append(openLists.Pop() ? "</ol>\n" : "</ul>\n");
                if (openLists.Count == li.Level + 1 && openLists.Peek() != li.Ordered) sb.Append(openLists.Pop() ? "</ol>\n" : "</ul>\n");
                while (openLists.Count < li.Level + 1)
                {
                    sb.Append(li.Ordered ? "<ol>\n" : "<ul>\n");
                    openLists.Push(li.Ordered);
                }
                sb.Append("<li>").Append(HtmlRuns(li.Runs, br)).Append("</li>\n");
                continue;
            }
            CloseListsTo(0);
            switch (block)
            {
                case Block.Heading h: sb.Append($"<h{h.Level}>").Append(HtmlRuns(h.Runs, br)).Append($"</h{h.Level}>\n"); break;
                case Block.Paragraph p: sb.Append("<p>").Append(HtmlRuns(p.Runs, br)).Append("</p>\n"); break;
                case Block.Code c: sb.Append("<pre>").Append(WebUtility.HtmlEncode(c.Text)).Append("</pre>\n"); break;
                case Block.Table t:
                    sb.Append("<table>\n");
                    foreach (var row in t.Rows)
                        sb.Append("<tr>").Append(string.Concat(row.Select(c => $"<td>{WebUtility.HtmlEncode(c)}</td>"))).Append("</tr>\n");
                    sb.Append("</table>\n");
                    break;
                case Block.Picture pic:
                    var alt = WebUtility.HtmlEncode(pic.Alt ?? "");
                    sb.Append($"<p><img src=\"{pictureSource(pic)}\" alt=\"{alt}\"{(xhtml ? "/" : "")}></p>\n");
                    break;
                case Block.PageBreak: sb.Append(xhtml ? "<hr/>\n" : "<hr>\n"); break;
            }
        }
        CloseListsTo(0);
        return sb.ToString();
    }

    static string HtmlRuns(IEnumerable<Run> runs, string br)
    {
        var sb = new StringBuilder();
        foreach (var r in runs)
        {
            var text = WebUtility.HtmlEncode(r.Text).Replace("\n", br).Replace("\t", "&#160;&#160;&#160;&#160;");
            if (r.Bold) text = $"<strong>{text}</strong>";
            if (r.Italic) text = $"<em>{text}</em>";
            if (r.Underline) text = $"<u>{text}</u>";
            if (r.Link is not null) text = $"<a href=\"{WebUtility.HtmlEncode(r.Link)}\">{text}</a>";
            sb.Append(text);
        }
        return sb.ToString();
    }

    // Word

    public static void WriteDocx(Doc doc, string output)
    {
        using var word = WordprocessingDocument.Create(output, WordprocessingDocumentType.Document);
        var main = word.AddMainDocumentPart();
        main.Document = new W.Document(new W.Body());
        AddStyles(main);
        var numberingPart = main.AddNewPart<NumberingDefinitionsPart>();
        var numbering = new W.Numbering();
        numbering.Append(AbstractList(1, false), AbstractList(2, true));
        numbering.Append(new W.NumberingInstance(new W.AbstractNumId { Val = 1 }) { NumberID = 1 });
        var body = main.Document.Body!;
        var nextNum = 2;
        var currentOrdered = 0;
        var pictureId = 1u;
        var instances = new List<W.NumberingInstance>();
        if (doc.Title is { } title) word.PackageProperties.Title = title;
        if (doc.Author is { } author) word.PackageProperties.Creator = author;

        foreach (var block in doc.Blocks)
        {
            if (block is not Block.ListItem { Ordered: true }) currentOrdered = 0;
            switch (block)
            {
                case Block.Heading h:
                    body.Append(Para(main, h.Runs, $"Heading{Math.Clamp(h.Level, 1, 6)}"));
                    break;
                case Block.Paragraph p:
                    body.Append(Para(main, p.Runs, null));
                    break;
                case Block.ListItem li:
                    int numId;
                    if (li.Ordered)
                    {
                        if (currentOrdered == 0)
                        {
                            // Each numbered list starts again at 1.
                            currentOrdered = nextNum++;
                            instances.Add(new W.NumberingInstance(new W.AbstractNumId { Val = 2 },
                                new W.LevelOverride(new W.StartOverrideNumberingValue { Val = 1 }) { LevelIndex = 0 }) { NumberID = currentOrdered });
                        }
                        numId = currentOrdered;
                    }
                    else numId = 1;
                    var para = Para(main, li.Runs, "ListParagraph");
                    para.ParagraphProperties!.Append(new W.NumberingProperties(
                        new W.NumberingLevelReference { Val = Math.Clamp(li.Level, 0, 2) }, new W.NumberingId { Val = numId }));
                    body.Append(para);
                    break;
                case Block.Code c:
                    var code = new W.Paragraph(new W.ParagraphProperties(new W.ParagraphStyleId { Val = "Code" }));
                    var lines = c.Text.Split('\n');
                    var run = new W.Run();
                    for (var i = 0; i < lines.Length; i++)
                    {
                        if (i > 0) run.Append(new W.Break());
                        run.Append(new W.Text(lines[i]) { Space = SpaceProcessingModeValues.Preserve });
                    }
                    code.Append(run);
                    body.Append(code);
                    break;
                case Block.Table t:
                    body.Append(DocxTable(t));
                    body.Append(new W.Paragraph());
                    break;
                case Block.Picture pic:
                    if (DocxPicture(main, pic, pictureId++) is { } picture) body.Append(picture);
                    break;
                case Block.PageBreak:
                    body.Append(new W.Paragraph(new W.Run(new W.Break { Type = W.BreakValues.Page })));
                    break;
            }
        }
        foreach (var instance in instances) numbering.Append(instance);
        numberingPart.Numbering = numbering;
        body.Append(new W.SectionProperties(
            new W.PageSize { Width = 11906, Height = 16838 },
            new W.PageMargin { Top = 1134, Bottom = 1134, Left = 1134, Right = 1134, Header = 709, Footer = 709, Gutter = 0 }));
        main.Document.Save();
    }

    static W.Paragraph Para(MainDocumentPart main, IEnumerable<Run> runs, string? style)
    {
        var p = new W.Paragraph(new W.ParagraphProperties());
        if (style is not null) p.ParagraphProperties!.Append(new W.ParagraphStyleId { Val = style });
        foreach (var r in runs)
        {
            var run = new W.Run();
            var props = new W.RunProperties();
            if (r.Bold) props.Append(new W.Bold());
            if (r.Italic) props.Append(new W.Italic());
            if (r.Underline || r.Link is not null) props.Append(new W.Underline { Val = W.UnderlineValues.Single });
            if (r.Link is not null) props.Append(new W.Color { Val = "0563C1" });
            if (props.HasChildren) run.Append(props);
            var parts = r.Text.Split('\n');
            for (var i = 0; i < parts.Length; i++)
            {
                if (i > 0) run.Append(new W.Break());
                var tabs = parts[i].Split('\t');
                for (var j = 0; j < tabs.Length; j++)
                {
                    if (j > 0) run.Append(new W.TabChar());
                    if (tabs[j].Length > 0) run.Append(new W.Text(tabs[j]) { Space = SpaceProcessingModeValues.Preserve });
                }
            }
            if (r.Link is not null && Uri.TryCreate(r.Link, UriKind.Absolute, out var uri))
            {
                var rel = main.AddHyperlinkRelationship(uri, true);
                p.Append(new W.Hyperlink(run) { Id = rel.Id });
            }
            else p.Append(run);
        }
        return p;
    }

    static W.Table DocxTable(Block.Table t)
    {
        var table = new W.Table();
        uint Border() => 4;
        table.Append(new W.TableProperties(
            new W.TableWidth { Width = "5000", Type = W.TableWidthUnitValues.Pct },
            new W.TableBorders(
                new W.TopBorder { Val = W.BorderValues.Single, Size = Border() },
                new W.BottomBorder { Val = W.BorderValues.Single, Size = Border() },
                new W.LeftBorder { Val = W.BorderValues.Single, Size = Border() },
                new W.RightBorder { Val = W.BorderValues.Single, Size = Border() },
                new W.InsideHorizontalBorder { Val = W.BorderValues.Single, Size = Border() },
                new W.InsideVerticalBorder { Val = W.BorderValues.Single, Size = Border() })));
        var columns = t.Rows.Max(r => r.Count);
        foreach (var row in t.Rows)
        {
            var tr = new W.TableRow();
            for (var c = 0; c < columns; c++)
            {
                var text = c < row.Count ? row[c] : "";
                tr.Append(new W.TableCell(new W.Paragraph(new W.Run(new W.Text(text) { Space = SpaceProcessingModeValues.Preserve }))));
            }
            table.Append(tr);
        }
        return table;
    }

    static W.Paragraph? DocxPicture(MainDocumentPart main, Block.Picture pic, uint id)
    {
        int width, height;
        byte[] data;
        try
        {
            using var image = new MagickImage(pic.Data);
            width = (int)image.Width;
            height = (int)image.Height;
            var jpeg = Mime(pic.Data) == "image/jpeg";
            data = jpeg ? pic.Data : image.ToByteArray(MagickFormat.Png);
        }
        catch { return null; }
        var part = main.AddImagePart(Mime(data) == "image/jpeg" ? ImagePartType.Jpeg : ImagePartType.Png);
        using (var stream = new MemoryStream(data)) part.FeedData(stream);
        var rid = main.GetIdOfPart(part);
        // EMUs at 96 dpi, at most 16 cm wide.
        long cx = width * 9525L, cy = height * 9525L;
        const long maxWidth = 5760000;
        if (cx > maxWidth) { cy = cy * maxWidth / cx; cx = maxWidth; }
        var xml = $"""
            <w:drawing xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="{cx}" cy="{cy}"/><wp:docPr id="{id}" name="Picture {id}" descr="{WebUtility.HtmlEncode(pic.Alt ?? "")}"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="{id}" name="Picture {id}"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="{rid}"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="{cx}" cy="{cy}"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing>
            """;
        return new W.Paragraph(new W.Run(new W.Drawing(xml)));
    }

    static W.AbstractNum AbstractList(int id, bool ordered)
    {
        var abs = new W.AbstractNum { AbstractNumberId = id };
        abs.Append(new W.MultiLevelType { Val = W.MultiLevelValues.HybridMultilevel });
        string[] bullets = ["•", "◦", "▪"];
        for (var level = 0; level < 3; level++)
        {
            var indent = 720 + level * 360;
            abs.Append(new W.Level(
                new W.StartNumberingValue { Val = 1 },
                new W.NumberingFormat { Val = ordered ? (level == 1 ? W.NumberFormatValues.LowerLetter : level == 2 ? W.NumberFormatValues.LowerRoman : W.NumberFormatValues.Decimal) : W.NumberFormatValues.Bullet },
                new W.LevelText { Val = ordered ? $"%{level + 1}." : bullets[level] },
                new W.LevelJustification { Val = W.LevelJustificationValues.Left },
                new W.PreviousParagraphProperties(new W.Indentation { Left = indent.ToString(), Hanging = "360" }))
            { LevelIndex = level });
        }
        return abs;
    }

    static void AddStyles(MainDocumentPart main)
    {
        var part = main.AddNewPart<StyleDefinitionsPart>();
        var styles = new W.Styles();
        styles.Append(new W.DocDefaults(
            new W.RunPropertiesDefault(new W.RunPropertiesBaseStyle(
                new W.RunFonts { Ascii = "Calibri", HighAnsi = "Calibri", ComplexScript = "Calibri", EastAsia = "Calibri" },
                new W.FontSize { Val = "22" }, new W.FontSizeComplexScript { Val = "22" })),
            new W.ParagraphPropertiesDefault(new W.ParagraphPropertiesBaseStyle(
                new W.SpacingBetweenLines { After = "160", Line = "264", LineRule = W.LineSpacingRuleValues.Auto }))));
        styles.Append(new W.Style(new W.StyleName { Val = "Normal" }, new W.PrimaryStyle()) { Type = W.StyleValues.Paragraph, StyleId = "Normal", Default = true });
        int[] sizes = [40, 32, 28, 24, 22, 22];
        for (var level = 1; level <= 6; level++)
        {
            styles.Append(new W.Style(
                new W.StyleName { Val = $"heading {level}" },
                new W.BasedOn { Val = "Normal" },
                new W.NextParagraphStyle { Val = "Normal" },
                new W.PrimaryStyle(),
                new W.StyleParagraphProperties(new W.KeepNext(), new W.SpacingBetweenLines { Before = "240", After = "120" },
                    new W.OutlineLevel { Val = level - 1 }),
                new W.StyleRunProperties(new W.Bold(), new W.FontSize { Val = sizes[level - 1].ToString() }, new W.Color { Val = "1F3864" }))
            { Type = W.StyleValues.Paragraph, StyleId = $"Heading{level}" });
        }
        styles.Append(new W.Style(new W.StyleName { Val = "List Paragraph" }, new W.BasedOn { Val = "Normal" },
            new W.StyleParagraphProperties(new W.SpacingBetweenLines { After = "60" }, new W.ContextualSpacing()))
        { Type = W.StyleValues.Paragraph, StyleId = "ListParagraph" });
        styles.Append(new W.Style(new W.StyleName { Val = "Code" }, new W.BasedOn { Val = "Normal" },
            new W.StyleRunProperties(new W.RunFonts { Ascii = "Consolas", HighAnsi = "Consolas" }, new W.FontSize { Val = "20" }))
        { Type = W.StyleValues.Paragraph, StyleId = "Code" });
        part.Styles = styles;
    }

    // OpenDocument text

    public static void WriteOdt(Doc doc, string output)
    {
        var pictures = new List<(string Name, byte[] Data, int Width, int Height)>();
        var body = new StringBuilder();
        // One entry per open <text:list>: whether its current <text:list-item> is still open.
        var lists = new List<bool>();
        void CloseLists(int depth)
        {
            while (lists.Count > depth)
            {
                if (lists[^1]) body.Append("</text:list-item>");
                body.Append("</text:list>");
                lists.RemoveAt(lists.Count - 1);
            }
        }
        foreach (var block in doc.Blocks)
        {
            if (block is not Block.ListItem) CloseLists(0);
            switch (block)
            {
                case Block.Heading h:
                    body.Append($"<text:h text:style-name=\"Heading_20_{h.Level}\" text:outline-level=\"{h.Level}\">").Append(OdtRuns(h.Runs)).Append("</text:h>");
                    break;
                case Block.Paragraph p:
                    body.Append("<text:p text:style-name=\"Standard\">").Append(OdtRuns(p.Runs)).Append("</text:p>");
                    break;
                case Block.ListItem li:
                    var level = Math.Min(li.Level, 4);
                    CloseLists(level + 1);
                    if (lists.Count == level + 1 && lists[^1]) { body.Append("</text:list-item>"); lists[^1] = false; }
                    while (lists.Count < level + 1)
                    {
                        if (lists.Count > 0 && !lists[^1]) { body.Append("<text:list-item>"); lists[^1] = true; }
                        body.Append(lists.Count == 0 ? $"<text:list text:style-name=\"{(li.Ordered ? "LNum" : "LBullet")}\">" : "<text:list>");
                        lists.Add(false);
                    }
                    body.Append("<text:list-item><text:p text:style-name=\"Standard\">").Append(OdtRuns(li.Runs)).Append("</text:p>");
                    lists[^1] = true;
                    break;
                case Block.Code c:
                    foreach (var line in c.Text.Split('\n'))
                        body.Append("<text:p text:style-name=\"Code\">").Append(OdtText(line)).Append("</text:p>");
                    break;
                case Block.Table t:
                    var columns = t.Rows.Max(r => r.Count);
                    body.Append($"<table:table table:name=\"Table{body.Length}\" table:style-name=\"Tbl\"><table:table-column table:number-columns-repeated=\"{columns}\"/>");
                    foreach (var row in t.Rows)
                    {
                        body.Append("<table:table-row>");
                        for (var col = 0; col < columns; col++)
                            body.Append("<table:table-cell table:style-name=\"Cell\" office:value-type=\"string\"><text:p>")
                                .Append(OdtText(col < row.Count ? row[col] : "")).Append("</text:p></table:table-cell>");
                        body.Append("</table:table-row>");
                    }
                    body.Append("</table:table>");
                    break;
                case Block.Picture pic:
                    try
                    {
                        using var image = new MagickImage(pic.Data);
                        var png = Mime(pic.Data) == "image/jpeg" ? pic.Data : image.ToByteArray(MagickFormat.Png);
                        var name = $"Pictures/image{pictures.Count + 1}.{(Mime(png) == "image/jpeg" ? "jpg" : "png")}";
                        pictures.Add((name, png, (int)image.Width, (int)image.Height));
                        double w = image.Width / 96.0 * 2.54, h = image.Height / 96.0 * 2.54;
                        if (w > 16) { h *= 16 / w; w = 16; }
                        body.Append($"<text:p text:style-name=\"Standard\"><draw:frame draw:name=\"{name}\" text:anchor-type=\"as-char\" svg:width=\"{w.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture)}cm\" svg:height=\"{h.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture)}cm\"><draw:image xlink:href=\"{name}\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\"/></draw:frame></text:p>");
                    }
                    catch { }
                    break;
                case Block.PageBreak:
                    body.Append("<text:p text:style-name=\"PageBreak\"/>");
                    break;
            }
        }
        CloseLists(0);

        const string ns = "xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:style=\"urn:oasis:names:tc:opendocument:xmlns:style:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" xmlns:draw=\"urn:oasis:names:tc:opendocument:xmlns:drawing:1.0\" xmlns:fo=\"urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:meta=\"urn:oasis:names:tc:opendocument:xmlns:meta:1.0\" xmlns:svg=\"urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0\" office:version=\"1.3\"";
        var headingStyles = string.Concat(Enumerable.Range(1, 6).Select(l =>
            $"<style:style style:name=\"Heading_20_{l}\" style:display-name=\"Heading {l}\" style:family=\"paragraph\" style:parent-style-name=\"Standard\" style:next-style-name=\"Standard\" style:default-outline-level=\"{l}\"><style:paragraph-properties fo:margin-top=\"0.42cm\" fo:margin-bottom=\"0.21cm\" fo:keep-with-next=\"always\"/><style:text-properties fo:font-size=\"{new[] { 20, 16, 14, 12, 11, 11 }[l - 1]}pt\" fo:font-weight=\"bold\"/></style:style>"));
        var styles = $"""
            <?xml version="1.0" encoding="UTF-8"?>
            <office:document-styles {ns}><office:font-face-decls/><office:styles><style:default-style style:family="paragraph"><style:text-properties style:font-name="Liberation Sans" fo:font-family="'Segoe UI', Arial" fo:font-size="11pt"/></style:default-style><style:style style:name="Standard" style:family="paragraph"><style:paragraph-properties fo:margin-bottom="0.25cm"/></style:style>{headingStyles}<style:style style:name="Code" style:family="paragraph" style:parent-style-name="Standard"><style:paragraph-properties fo:margin-bottom="0cm"/><style:text-properties fo:font-family="Consolas, monospace" fo:font-size="10pt"/></style:style></office:styles><office:automatic-styles><style:page-layout style:name="pm1"><style:page-layout-properties fo:page-width="21cm" fo:page-height="29.7cm" fo:margin-top="2cm" fo:margin-bottom="2cm" fo:margin-left="2cm" fo:margin-right="2cm"/></style:page-layout></office:automatic-styles><office:master-styles><style:master-page style:name="Standard" style:page-layout-name="pm1"/></office:master-styles></office:document-styles>
            """;
        var content = $"""
            <?xml version="1.0" encoding="UTF-8"?>
            <office:document-content {ns}><office:automatic-styles><style:style style:name="TB" style:family="text"><style:text-properties fo:font-weight="bold"/></style:style><style:style style:name="TI" style:family="text"><style:text-properties fo:font-style="italic"/></style:style><style:style style:name="TBI" style:family="text"><style:text-properties fo:font-weight="bold" fo:font-style="italic"/></style:style><style:style style:name="TU" style:family="text"><style:text-properties style:text-underline-style="solid" style:text-underline-width="auto" style:text-underline-color="font-color"/></style:style><style:style style:name="PageBreak" style:family="paragraph" style:parent-style-name="Standard"><style:paragraph-properties fo:break-after="page"/></style:style><style:style style:name="Tbl" style:family="table"><style:table-properties style:width="17cm" table:align="margins"/></style:style><style:style style:name="Cell" style:family="table-cell"><style:table-cell-properties fo:padding="0.1cm" fo:border="0.5pt solid #000000"/></style:style><text:list-style style:name="LBullet"><text:list-level-style-bullet text:level="1" text:bullet-char="•"><style:list-level-properties text:list-level-position-and-space-mode="label-alignment"><style:list-level-label-alignment text:label-followed-by="listtab" fo:text-indent="-0.6cm" fo:margin-left="1.2cm"/></style:list-level-properties></text:list-level-style-bullet><text:list-level-style-bullet text:level="2" text:bullet-char="◦"><style:list-level-properties text:list-level-position-and-space-mode="label-alignment"><style:list-level-label-alignment text:label-followed-by="listtab" fo:text-indent="-0.6cm" fo:margin-left="1.8cm"/></style:list-level-properties></text:list-level-style-bullet></text:list-style><text:list-style style:name="LNum"><text:list-level-style-number text:level="1" style:num-suffix="." style:num-format="1"><style:list-level-properties text:list-level-position-and-space-mode="label-alignment"><style:list-level-label-alignment text:label-followed-by="listtab" fo:text-indent="-0.6cm" fo:margin-left="1.2cm"/></style:list-level-properties></text:list-level-style-number><text:list-level-style-number text:level="2" style:num-suffix="." style:num-format="a"><style:list-level-properties text:list-level-position-and-space-mode="label-alignment"><style:list-level-label-alignment text:label-followed-by="listtab" fo:text-indent="-0.6cm" fo:margin-left="1.8cm"/></style:list-level-properties></text:list-level-style-number></text:list-style></office:automatic-styles><office:body><office:text>{body}</office:text></office:body></office:document-content>
            """;
        var title = WebUtility.HtmlEncode(doc.GuessTitle(""));
        var meta = $"""
            <?xml version="1.0" encoding="UTF-8"?>
            <office:document-meta {ns}><office:meta><meta:generator>Transmute</meta:generator><dc:title>{title}</dc:title></office:meta></office:document-meta>
            """;
        var manifest = new StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.3\">");
        manifest.Append("<manifest:file-entry manifest:full-path=\"/\" manifest:version=\"1.3\" manifest:media-type=\"application/vnd.oasis.opendocument.text\"/>");
        foreach (var part in new[] { "content.xml", "styles.xml", "meta.xml" })
            manifest.Append($"<manifest:file-entry manifest:full-path=\"{part}\" manifest:media-type=\"text/xml\"/>");
        foreach (var p in pictures)
            manifest.Append($"<manifest:file-entry manifest:full-path=\"{p.Name}\" manifest:media-type=\"{Mime(p.Data)}\"/>");
        manifest.Append("</manifest:manifest>");

        using var zip = ZipFile.Open(output, ZipArchiveMode.Create);
        StoredEntry(zip, "mimetype", "application/vnd.oasis.opendocument.text");
        Entry(zip, "content.xml", content.Trim());
        Entry(zip, "styles.xml", styles.Trim());
        Entry(zip, "meta.xml", meta.Trim());
        Entry(zip, "META-INF/manifest.xml", manifest.ToString());
        foreach (var p in pictures)
        {
            var e = zip.CreateEntry(p.Name, CompressionLevel.NoCompression);
            using var s = e.Open();
            s.Write(p.Data);
        }
    }

    static string OdtText(string text)
    {
        var sb = new StringBuilder();
        var escaped = WebUtility.HtmlEncode(text);
        foreach (var c in escaped)
        {
            if (c == '\n') sb.Append("<text:line-break/>");
            else if (c == '\t') sb.Append("<text:tab/>");
            else sb.Append(c);
        }
        // Runs of spaces collapse in XML unless spelled out.
        return System.Text.RegularExpressions.Regex.Replace(sb.ToString(), "  +", m => " " + $"<text:s text:c=\"{m.Length - 1}\"/>");
    }

    static string OdtRuns(IEnumerable<Run> runs) => string.Concat(runs.Select(r =>
    {
        var text = OdtText(r.Text);
        var style = r.Bold && r.Italic ? "TBI" : r.Bold ? "TB" : r.Italic ? "TI" : r.Underline ? "TU" : null;
        if (style is not null) text = $"<text:span text:style-name=\"{style}\">{text}</text:span>";
        if (r.Link is not null) text = $"<text:a xlink:type=\"simple\" xlink:href=\"{WebUtility.HtmlEncode(r.Link)}\">{text}</text:a>";
        return text;
    }));

    static void StoredEntry(ZipArchive zip, string name, string text)
    {
        var entry = zip.CreateEntry(name, CompressionLevel.NoCompression);
        using var stream = entry.Open();
        stream.Write(Encoding.ASCII.GetBytes(text));
    }

    static void Entry(ZipArchive zip, string name, string text)
    {
        var entry = zip.CreateEntry(name, CompressionLevel.Optimal);
        using var stream = entry.Open();
        stream.Write(new UTF8Encoding(false).GetBytes(text));
    }

    // EPUB

    public static void WriteEpub(Doc doc, string output)
    {
        var title = doc.GuessTitle(Path.GetFileNameWithoutExtension(output));
        // A new chapter at every top-level heading and page break.
        var chapters = new List<List<Block>> { new() };
        var topLevel = doc.Blocks.OfType<Block.Heading>().Select(h => h.Level).DefaultIfEmpty(1).Min();
        foreach (var block in doc.Blocks)
        {
            var starts = block is Block.PageBreak || block is Block.Heading h && h.Level == topLevel;
            if (starts && chapters[^1].Count > 0) chapters.Add([]);
            if (block is not Block.PageBreak) chapters[^1].Add(block);
        }
        chapters.RemoveAll(c => c.Count == 0);
        if (chapters.Count == 0) chapters.Add([new Block.Paragraph([new Run(" ")])]);

        var pictures = new List<(string Name, byte[] Data)>();
        var id = $"urn:uuid:{Guid.NewGuid()}";
        using var zip = ZipFile.Open(output, ZipArchiveMode.Create);
        StoredEntry(zip, "mimetype", "application/epub+zip");
        Entry(zip, "META-INF/container.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>");
        Entry(zip, "OEBPS/style.css", "body{font-family:serif;line-height:1.5;margin:0 5%}h1,h2,h3{font-family:sans-serif}img{max-width:100%}table{border-collapse:collapse}td{border:1px solid #888;padding:2px 6px}pre{white-space:pre-wrap;font-size:0.9em}");
        var titles = new List<string>();
        for (var i = 0; i < chapters.Count; i++)
        {
            var chapterTitle = chapters[i].OfType<Block.Heading>().Select(h => Doc.Text(h.Runs)).FirstOrDefault() ?? (chapters.Count == 1 ? title : $"Part {i + 1}");
            titles.Add(chapterTitle);
            var html = HtmlBody(chapters[i], pic =>
            {
                var ext = Mime(pic.Data) == "image/jpeg" ? "jpg" : Mime(pic.Data) == "image/gif" ? "gif" : "png";
                var data = pic.Data;
                if (ext == "png" && !(data[0] == 0x89 && data[1] == 0x50))
                {
                    try { using var m = new MagickImage(data); data = m.ToByteArray(MagickFormat.Png); } catch { }
                }
                var name = $"images/image{pictures.Count + 1}.{ext}";
                pictures.Add((name, data));
                return name;
            }, true);
            Entry(zip, $"OEBPS/chapter{i + 1}.xhtml",
                $"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE html>\n<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><meta charset=\"UTF-8\"/><title>{WebUtility.HtmlEncode(chapterTitle)}</title><link rel=\"stylesheet\" type=\"text/css\" href=\"style.css\"/></head><body>\n{html}</body></html>");
        }
        foreach (var (name, data) in pictures)
        {
            var e = zip.CreateEntry("OEBPS/" + name, CompressionLevel.NoCompression);
            using var s = e.Open();
            s.Write(data);
        }
        var nav = new StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE html>\n<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><meta charset=\"UTF-8\"/><title>Contents</title></head><body><nav epub:type=\"toc\" id=\"toc\"><h1>Contents</h1><ol>");
        var ncx = new StringBuilder($"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\"><head><meta name=\"dtb:uid\" content=\"{id}\"/></head><docTitle><text>{WebUtility.HtmlEncode(title)}</text></docTitle><navMap>");
        for (var i = 0; i < chapters.Count; i++)
        {
            nav.Append($"<li><a href=\"chapter{i + 1}.xhtml\">{WebUtility.HtmlEncode(titles[i])}</a></li>");
            ncx.Append($"<navPoint id=\"np{i + 1}\" playOrder=\"{i + 1}\"><navLabel><text>{WebUtility.HtmlEncode(titles[i])}</text></navLabel><content src=\"chapter{i + 1}.xhtml\"/></navPoint>");
        }
        nav.Append("</ol></nav></body></html>");
        ncx.Append("</navMap></ncx>");
        Entry(zip, "OEBPS/nav.xhtml", nav.ToString());
        Entry(zip, "OEBPS/toc.ncx", ncx.ToString());
        var opf = new StringBuilder($"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"bookid\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"bookid\">{id}</dc:identifier><dc:title>{WebUtility.HtmlEncode(title)}</dc:title><dc:language>en</dc:language>");
        if (doc.Author is { } author) opf.Append($"<dc:creator>{WebUtility.HtmlEncode(author)}</dc:creator>");
        opf.Append($"<meta property=\"dcterms:modified\">{DateTime.UtcNow:yyyy-MM-ddTHH:mm:ssZ}</meta></metadata><manifest>");
        opf.Append("<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/><item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/><item id=\"css\" href=\"style.css\" media-type=\"text/css\"/>");
        for (var i = 0; i < chapters.Count; i++) opf.Append($"<item id=\"c{i + 1}\" href=\"chapter{i + 1}.xhtml\" media-type=\"application/xhtml+xml\"/>");
        for (var i = 0; i < pictures.Count; i++) opf.Append($"<item id=\"img{i + 1}\" href=\"{pictures[i].Name}\" media-type=\"{Mime(pictures[i].Data)}\"/>");
        opf.Append("</manifest><spine toc=\"ncx\">");
        for (var i = 0; i < chapters.Count; i++) opf.Append($"<itemref idref=\"c{i + 1}\"/>");
        opf.Append("</spine></package>");
        Entry(zip, "OEBPS/content.opf", opf.ToString());
    }

    // PDF

    /// `slides` makes widescreen pages with bigger type, one slide per page.
    public static void WritePdf(Doc doc, string output, bool slides = false)
    {
        Fonts.Install();
        var document = new Document();
        document.Info.Title = doc.GuessTitle("");
        if (doc.Author is { } author) document.Info.Author = author;
        var normal = document.Styles[StyleNames.Normal]!;
        normal.Font.Name = Fonts.Sans;
        normal.Font.Size = slides ? 18 : 11;
        normal.ParagraphFormat.SpaceAfter = Unit.FromPoint(6);
        normal.ParagraphFormat.LineSpacingRule = MigraDoc.DocumentObjectModel.LineSpacingRule.Multiple;
        normal.ParagraphFormat.LineSpacing = 1.15;
        double[] sizes = [20, 16, 14, 12, 11, 11];
        for (var level = 1; level <= 6; level++)
        {
            var style = document.Styles[$"Heading{level}"]!;
            style.Font.Size = slides ? 30 : sizes[level - 1];
            style.Font.Bold = true;
            style.ParagraphFormat.SpaceBefore = Unit.FromPoint(level == 1 ? 14 : 10);
            style.ParagraphFormat.SpaceAfter = Unit.FromPoint(6);
            style.ParagraphFormat.KeepWithNext = true;
        }
        var code = document.Styles.AddStyle("Code", StyleNames.Normal);
        code.Font.Name = Fonts.Mono;
        code.Font.Size = 9.5;

        var section = document.AddSection();
        section.PageSetup = document.DefaultPageSetup.Clone();
        section.PageSetup.PageFormat = PageFormat.A4;
        section.PageSetup.PageWidth = Unit.FromCentimeter(slides ? 33.867 : 21);
        section.PageSetup.PageHeight = Unit.FromCentimeter(slides ? 19.05 : 29.7);
        section.PageSetup.LeftMargin = section.PageSetup.RightMargin = Unit.FromCentimeter(2);
        section.PageSetup.TopMargin = section.PageSetup.BottomMargin = Unit.FromCentimeter(slides ? 1.5 : 2);
        var usable = slides ? 29.867 : 17.0; // cm
        var maxPictureHeight = slides ? 11.0 : 24.0;

        var temp = new List<string>();
        try
        {
            var number = 0;
            foreach (var block in doc.Blocks)
            {
                if (block is not Block.ListItem { Ordered: true }) number = 0;
                switch (block)
                {
                    case Block.Heading h:
                        var hp = section.AddParagraph();
                        hp.Style = $"Heading{Math.Clamp(h.Level, 1, 6)}";
                        AddRuns(hp, h.Runs);
                        break;
                    case Block.Paragraph p:
                        AddRuns(section.AddParagraph(), p.Runs);
                        break;
                    case Block.ListItem li:
                        var lp = section.AddParagraph();
                        var indent = 0.6 + li.Level * 0.6;
                        lp.Format.LeftIndent = Unit.FromCentimeter(indent);
                        lp.Format.FirstLineIndent = Unit.FromCentimeter(-0.5);
                        lp.Format.SpaceAfter = Unit.FromPoint(2);
                        lp.Format.TabStops.AddTabStop(Unit.FromCentimeter(indent));
                        lp.AddText(li.Ordered ? $"{++number}." : li.Level == 0 ? "•" : "◦");
                        lp.AddTab();
                        AddRuns(lp, li.Runs);
                        break;
                    case Block.Code c:
                        var cp = section.AddParagraph();
                        cp.Style = "Code";
                        var lines = c.Text.Split('\n');
                        for (var i = 0; i < lines.Length; i++)
                        {
                            if (i > 0) cp.AddLineBreak();
                            cp.AddText(lines[i].Replace("\t", "    "));
                        }
                        break;
                    case Block.Table t:
                        var columns = t.Rows.Max(r => r.Count);
                        var table = section.AddTable();
                        table.Borders.Width = 0.5;
                        table.Format.Font.Size = 10;
                        for (var col = 0; col < columns; col++) table.AddColumn(Unit.FromCentimeter(usable / columns));
                        foreach (var row in t.Rows)
                        {
                            var tr = table.AddRow();
                            for (var col = 0; col < columns; col++)
                                tr.Cells[col].AddParagraph(col < row.Count ? row[col] : "");
                        }
                        section.AddParagraph();
                        break;
                    case Block.Picture pic:
                        try
                        {
                            using var image = new MagickImage(pic.Data);
                            var path = OutputPaths.TempFile(image.HasAlpha ? "png" : "jpg");
                            image.Strip();
                            image.Write(path, image.HasAlpha ? MagickFormat.Png : MagickFormat.Jpeg);
                            temp.Add(path);
                            var width = Math.Min(usable, image.Width / 96.0 * 2.54);
                            // Tall pictures are limited by height instead.
                            width = Math.Min(width, maxPictureHeight * image.Width / Math.Max(1.0, image.Height));
                            var picture = section.AddParagraph().AddImage(path);
                            picture.Width = Unit.FromCentimeter(width);
                            picture.LockAspectRatio = true;
                        }
                        catch { }
                        break;
                    case Block.PageBreak:
                        section.AddPageBreak();
                        break;
                }
            }
            if (doc.Blocks.Count == 0) section.AddParagraph();
            var renderer = new PdfDocumentRenderer { Document = document };
            renderer.RenderDocument();
            renderer.PdfDocument.Save(output);
        }
        finally
        {
            temp.ForEach(OutputPaths.TryDelete);
        }
    }

    static void AddRuns(MigraDoc.DocumentObjectModel.Paragraph paragraph, IEnumerable<Run> runs)
    {
        foreach (var r in runs)
        {
            FormattedText target;
            if (r.Link is not null)
            {
                var link = paragraph.AddHyperlink(r.Link, HyperlinkType.Web);
                target = link.AddFormattedText();
                target.Color = Colors.DarkBlue;
                target.Underline = Underline.Single;
            }
            else target = paragraph.AddFormattedText();
            if (r.Bold) target.Bold = true;
            if (r.Italic) target.Italic = true;
            if (r.Underline) target.Underline = Underline.Single;
            var lines = r.Text.Split('\n');
            for (var i = 0; i < lines.Length; i++)
            {
                if (i > 0) target.AddLineBreak();
                var tabs = lines[i].Split('\t');
                for (var j = 0; j < tabs.Length; j++)
                {
                    if (j > 0) target.AddTab();
                    if (tabs[j].Length > 0) target.AddText(tabs[j]);
                }
            }
        }
    }
}
