using System.Xml.Linq;
using DocumentFormat.OpenXml.Packaging;
using A = DocumentFormat.OpenXml.Drawing;
using P = DocumentFormat.OpenXml.Presentation;

namespace Transmute;

/// Presentations without PowerPoint: the words and pictures of each slide, one page per slide.
public static class Slides
{
    public static Doc Read(string path)
    {
        var ext = Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        return ext switch
        {
            "pptx" => ReadPptx(path),
            "odp" => ReadOdp(path),
            "ppt" => throw new ConversionException("Old PowerPoint files (.ppt) need Microsoft PowerPoint or the free LibreOffice installed. Spinform uses them automatically when they're there."),
            _ => throw new ConversionException($"Spinform can't read {ext.ToUpperInvariant()} presentations."),
        };
    }

    static Doc ReadPptx(string path)
    {
        PresentationDocument deck;
        try { deck = PresentationDocument.Open(path, false); }
        catch (Exception e) { throw new ConversionException($"Couldn't open {Path.GetFileName(path)} as a PowerPoint file: {e.Message}"); }
        using (deck)
        {
            var doc = new Doc { Title = deck.PackageProperties.Title, Author = deck.PackageProperties.Creator };
            var part = deck.PresentationPart ?? throw new ConversionException("The presentation is empty.");
            var ids = part.Presentation?.SlideIdList?.Elements<P.SlideId>() ?? [];
            var first = true;
            foreach (var id in ids)
            {
                if (id.RelationshipId?.Value is not { } rid || part.GetPartById(rid) is not SlidePart slide) continue;
                if (slide.Slide?.Show?.Value == false) continue;
                if (!first) doc.Blocks.Add(new Block.PageBreak());
                first = false;
                var start = doc.Blocks.Count;
                foreach (var element in slide.Slide?.CommonSlideData?.ShapeTree?.Descendants() ?? [])
                {
                    switch (element)
                    {
                        case P.Shape shape:
                            var placeholder = shape.NonVisualShapeProperties?.ApplicationNonVisualDrawingProperties?.PlaceholderShape?.Type?.Value;
                            var isTitle = placeholder == P.PlaceholderValues.Title || placeholder == P.PlaceholderValues.CenteredTitle;
                            foreach (var para in shape.TextBody?.Elements<A.Paragraph>() ?? [])
                            {
                                var runs = Doc.Tidy(para.Elements().Select(e => e switch
                                {
                                    A.Run r => new Run(r.Text?.Text ?? "", r.RunProperties?.Bold?.Value == true, r.RunProperties?.Italic?.Value == true),
                                    A.Break => new Run("\n"),
                                    A.Field f => new Run(f.Text?.Text ?? ""),
                                    _ => new Run(""),
                                }));
                                if (runs.Count == 0) continue;
                                var level = para.ParagraphProperties?.Level?.Value ?? 0;
                                if (isTitle) doc.Blocks.Add(new Block.Heading(1, runs));
                                else if (placeholder is not null && placeholder != P.PlaceholderValues.SubTitle) doc.Blocks.Add(new Block.ListItem(false, level, runs));
                                else doc.Blocks.Add(new Block.Paragraph(runs));
                            }
                            break;
                        case P.Picture picture:
                            var embed = picture.BlipFill?.Blip?.Embed?.Value;
                            if (embed is not null && slide.GetPartById(embed) is ImagePart image)
                            {
                                using var s = image.GetStream();
                                using var m = new MemoryStream();
                                s.CopyTo(m);
                                if (DocReaders.LooksLikePicture(m.ToArray())) doc.Blocks.Add(new Block.Picture(m.ToArray()));
                            }
                            break;
                        case P.GraphicFrame frame when frame.Descendants<A.Table>().FirstOrDefault() is { } table:
                            var rows = table.Elements<A.TableRow>()
                                .Select(r => r.Elements<A.TableCell>().Select(c => c.InnerText.Trim()).ToList()).ToList();
                            if (rows.Count > 0) doc.Blocks.Add(new Block.Table(rows));
                            break;
                    }
                }
                // Titles first, whatever order the shapes were drawn in.
                var titleIndex = doc.Blocks.FindIndex(start, b => b is Block.Heading);
                if (titleIndex > start)
                {
                    var title = doc.Blocks[titleIndex];
                    doc.Blocks.RemoveAt(titleIndex);
                    doc.Blocks.Insert(start, title);
                }
                if (doc.Blocks.Count == start) doc.Blocks.Add(new Block.Paragraph([new Run(" ")]));
            }
            return doc;
        }
    }

    static readonly XNamespace Draw = "urn:oasis:names:tc:opendocument:xmlns:drawing:1.0";
    static readonly XNamespace Text = "urn:oasis:names:tc:opendocument:xmlns:text:1.0";
    static readonly XNamespace Presentation = "urn:oasis:names:tc:opendocument:xmlns:presentation:1.0";
    static readonly XNamespace Xlink = "http://www.w3.org/1999/xlink";

    static Doc ReadOdp(string path)
    {
        using var zip = DocReaders.OpenZip(path);
        var content = DocReaders.LoadXml(zip, "content.xml") ?? throw new ConversionException("The presentation has no content.");
        var doc = new Doc();
        var first = true;
        foreach (var page in content.Descendants(Draw + "page"))
        {
            if (!first) doc.Blocks.Add(new Block.PageBreak());
            first = false;
            var start = doc.Blocks.Count;
            foreach (var frame in page.Elements(Draw + "frame"))
            {
                var kind = (string?)frame.Attribute(Presentation + "class");
                var image = frame.Element(Draw + "image");
                var href = (string?)image?.Attribute(Xlink + "href");
                if (href is not null && zip.GetEntry(href) is { } entry && image!.Element(Text + "p") is null)
                {
                    var data = DocReaders.ReadEntry(entry);
                    if (DocReaders.LooksLikePicture(data)) doc.Blocks.Add(new Block.Picture(data));
                    continue;
                }
                foreach (var p in frame.Descendants(Text + "p"))
                {
                    var text = p.Value.Trim();
                    if (text.Length == 0) continue;
                    var inList = p.Ancestors(Text + "list").Count();
                    if (kind == "title") doc.Blocks.Add(new Block.Heading(1, [new Run(text)]));
                    else if (inList > 0) doc.Blocks.Add(new Block.ListItem(false, inList - 1, [new Run(text)]));
                    else doc.Blocks.Add(new Block.Paragraph([new Run(text)]));
                }
            }
            if (doc.Blocks.Count == start) doc.Blocks.Add(new Block.Paragraph([new Run(" ")]));
        }
        return doc;
    }

    /// The picture a presentation (or an iWork file) carries of its first slide, if any.
    public static byte[]? Thumbnail(string path)
    {
        try
        {
            using var zip = DocReaders.OpenZip(path);
            foreach (var name in new[] { "preview.jpg", "QuickLook/Thumbnail.jpg", "docProps/thumbnail.jpeg", "Thumbnails/thumbnail.png", "preview-web.jpg" })
                if (zip.GetEntry(name) is { } entry) return DocReaders.ReadEntry(entry);
        }
        catch { }
        return null;
    }
}

/// Pages, Keynote and Numbers files: they can only be opened by Apple's apps, but most carry
/// a preview (a PDF of the whole document, or a picture of the first page).
public static class IWork
{
    public static bool IsIWork(string path) =>
        Path.GetExtension(path).ToLowerInvariant() is ".pages" or ".key" or ".numbers";

    /// Copies the preview out to a temporary file: a .pdf, a .jpg, or null when there's none.
    public static string? ExtractPreview(string path)
    {
        if (Directory.Exists(path))
        {
            var pdf = Path.Combine(path, "QuickLook", "Preview.pdf");
            if (File.Exists(pdf)) { var t = OutputPaths.TempFile("pdf"); File.Copy(pdf, t); return t; }
            var jpg = Path.Combine(path, "preview.jpg");
            if (File.Exists(jpg)) { var t = OutputPaths.TempFile("jpg"); File.Copy(jpg, t); return t; }
            return null;
        }
        try
        {
            using var zip = DocReaders.OpenZip(path);
            if (zip.GetEntry("QuickLook/Preview.pdf") is { } entry)
            {
                var t = OutputPaths.TempFile("pdf");
                File.WriteAllBytes(t, DocReaders.ReadEntry(entry));
                return t;
            }
            foreach (var name in new[] { "preview.jpg", "QuickLook/Thumbnail.jpg" })
                if (zip.GetEntry(name) is { } image)
                {
                    var t = OutputPaths.TempFile("jpg");
                    File.WriteAllBytes(t, DocReaders.ReadEntry(image));
                    return t;
                }
        }
        catch { }
        return null;
    }

    public static string AppName(string path) => Path.GetExtension(path).ToLowerInvariant() switch
    {
        ".pages" => "Pages",
        ".key" => "Keynote",
        _ => "Numbers",
    };
}
