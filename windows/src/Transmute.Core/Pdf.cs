using ImageMagick;
using PdfSharp.Drawing;
using PdfSharp.Fonts;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.IO;
using UglyToad.PdfPig.DocumentLayoutAnalysis.TextExtractor;

namespace Transmute;

/// PDF tools: merge, split, images to PDF, pages to pictures, compress, clean and read text.
public static class PdfTools
{
    static PdfTools() => Fonts.Install();

    static PdfDocument Open(string path, PdfDocumentOpenMode mode)
    {
        try { return PdfReader.Open(path, mode); }
        catch (PdfReaderException e) when (e.Message.Contains("password", StringComparison.OrdinalIgnoreCase))
        {
            throw new ConversionException($"{Path.GetFileName(path)} is protected with a password.");
        }
        catch (Exception e) when (e is not ConversionException)
        {
            throw new ConversionException($"Couldn't read {Path.GetFileName(path)} as a PDF: {e.Message}");
        }
    }

    public static string Merge(IReadOnlyList<string> inputs, ConversionOptions options)
    {
        if (inputs.Count < 2) throw new ConversionException("Choose at least two PDFs to merge.");
        var dir = options.OutputFolder ?? Path.GetDirectoryName(Path.GetFullPath(inputs[0]))!;
        var output = OutputPaths.Unique(dir, "Merged", "pdf");
        using var merged = new PdfDocument();
        foreach (var input in inputs)
        {
            using var source = Open(input, PdfDocumentOpenMode.Import);
            foreach (var page in source.Pages) merged.AddPage(page);
        }
        merged.Save(output);
        return output;
    }

    /// One PDF per page, in a new folder.
    public static string Split(string input, ConversionOptions options)
    {
        using var source = Open(input, PdfDocumentOpenMode.Import);
        if (source.PageCount == 0) throw new ConversionException($"{Path.GetFileName(input)} has no pages.");
        var folder = OutputPaths.Destination(input, "", "pages", options.OutputFolder);
        Directory.CreateDirectory(folder);
        var name = OutputPaths.BaseName(input);
        var digits = source.PageCount.ToString().Length;
        for (var i = 0; i < source.PageCount; i++)
        {
            using var single = new PdfDocument();
            single.AddPage(source.Pages[i]);
            single.Save(Path.Combine(folder, $"{name} page {(i + 1).ToString().PadLeft(digits, '0')}.pdf"));
        }
        return folder;
    }

    public static string ImagesToPdf(IReadOnlyList<string> inputs, ConversionOptions options)
    {
        if (inputs.Count == 0) throw new ConversionException("Choose some images first.");
        var dir = options.OutputFolder ?? Path.GetDirectoryName(Path.GetFullPath(inputs[0]))!;
        var output = OutputPaths.Unique(dir, inputs.Count == 1 ? OutputPaths.BaseName(inputs[0]) : "Images", "pdf");
        try { WriteImagesPdf(inputs, output); }
        catch { OutputPaths.TryDelete(output); throw; }
        return output;
    }

    /// One page per picture, each page the size of its picture.
    public static void WriteImagesPdf(IEnumerable<string> inputs, string output)
    {
        using var document = new PdfDocument();
        foreach (var input in inputs)
        {
            using var image = ImageConverter.LoadFirst(input);
            var alpha = image.HasAlpha;
            using var stream = new MemoryStream(image.ToByteArray(alpha ? MagickFormat.Png : MagickFormat.Jpeg));
            using var x = XImage.FromStream(stream);
            var page = document.AddPage();
            // 96 pixels to the inch, like Windows; points are 1/72 inch.
            page.Width = XUnit.FromPoint(image.Width * 0.75);
            page.Height = XUnit.FromPoint(image.Height * 0.75);
            using var gfx = XGraphics.FromPdfPage(page);
            gfx.DrawImage(x, 0, 0, page.Width.Point, page.Height.Point);
        }
        document.Save(output);
    }

    public static int PageCount(string input)
    {
        using var document = Open(input, PdfDocumentOpenMode.Import);
        return document.PageCount;
    }

    /// Each page as a picture. One page gives one file; more give a file per page.
    public static async Task<List<string>> Rasterize(string input, OutputFormat format, ConversionOptions options, CancellationToken token)
    {
        if (format is not (OutputFormat.Png or OutputFormat.Jpeg)) throw new ConversionException($"PDF pages can't be saved as {format.Label()}.");
        var bytes = await File.ReadAllBytesAsync(input, token);
        var count = PDFtoImage.Conversion.GetPageCount(bytes);
        var outputs = new List<string>();
        try
        {
            for (var i = 0; i < count; i++)
            {
                token.ThrowIfCancellationRequested();
                var output = OutputPaths.Destination(input, format.Extension(), count == 1 ? null : $"page {i + 1}", options.OutputFolder);
                outputs.Add(output);
                await Task.Run(() => RenderPage(bytes, i, format, output, 150, options.Quality), token);
            }
        }
        catch
        {
            outputs.ForEach(OutputPaths.TryDelete);
            throw;
        }
        return outputs;
    }

    public static void RenderPage(byte[] pdf, int page, OutputFormat format, string output, int dpi, double quality = 0.9)
    {
        var options = new PDFtoImage.RenderOptions(Dpi: dpi, WithAnnotations: true, BackgroundColor: SkiaSharp.SKColors.White);
        if (format == OutputFormat.Jpeg)
            PDFtoImage.Conversion.SaveJpeg(output, pdf, page, null, options);
        else
            PDFtoImage.Conversion.SavePng(output, pdf, page, null, options);
        if (format == OutputFormat.Jpeg && quality < 0.99)
        {
            using var image = new MagickImage(output);
            image.Quality = (uint)Math.Clamp(quality * 100, 1, 100);
            image.Write(output);
        }
    }

    // Compression

    /// Re-saves the photos inside a PDF at a lower JPEG quality (and at most 2000 pixels across).
    public static JobResult Compress(string input, ConversionOptions options, long? goal = null)
    {
        var output = OutputPaths.Destination(input, "pdf", "compressed", options.OutputFolder);
        try
        {
            var original = OutputPaths.FileSize(input);
            var settings = new (double Quality, int MaxPixel)[] { (0.6, 2000), (0.45, 1400), (0.35, 1000), (0.25, 700) };
            foreach (var (quality, max) in settings)
            {
                using var document = Open(input, PdfDocumentOpenMode.Modify);
                RecompressImages(document, quality, max);
                if (options.StripMetadata) ClearMetadata(document);
                document.Options.CompressContentStreams = true;
                document.Options.NoCompression = false;
                document.Options.UseFlateDecoderForJpegImages = PdfUseFlateDecoderForJpegImages.Never;
                document.Save(output);
                if (goal is null || OutputPaths.FileSize(output) <= goal) break;
            }
            if (OutputPaths.FileSize(output) >= original)
            {
                File.Copy(input, output, true);
                return new JobResult([output], "This PDF is already as small as Transmute can make it (it has no large pictures).");
            }
            return MediaConverter.SizeResult(input, output, goal ?? OutputPaths.FileSize(output));
        }
        catch
        {
            OutputPaths.TryDelete(output);
            throw;
        }
    }

    static void RecompressImages(PdfDocument document, double quality, int maxPixel)
    {
        foreach (var item in document.Internals.GetAllObjects())
        {
            if (item is not PdfDictionary dict || dict.Stream is null) continue;
            if (dict.Elements.GetName("/Subtype") != "/Image") continue;
            if (dict.Elements.ContainsKey("/SMask") || dict.Elements.ContainsKey("/Mask") || dict.Elements.GetBoolean("/ImageMask")) continue;
            try
            {
                var replacement = Recompressed(dict, quality, maxPixel);
                if (replacement is null) continue;
                var (jpeg, width, height, gray) = replacement.Value;
                if (jpeg.Length >= dict.Stream.Value.Length) continue;
                dict.Stream.Value = jpeg;
                dict.Elements.SetName("/Filter", "/DCTDecode");
                dict.Elements.Remove("/DecodeParms");
                dict.Elements.Remove("/Decode");
                dict.Elements.SetInteger("/Width", width);
                dict.Elements.SetInteger("/Height", height);
                dict.Elements.SetInteger("/BitsPerComponent", 8);
                dict.Elements.SetName("/ColorSpace", gray ? "/DeviceGray" : "/DeviceRGB");
                dict.Elements.SetInteger("/Length", jpeg.Length);
            }
            catch
            {
                // Leave pictures Transmute can't decode as they are.
            }
        }
    }

    static (byte[] Jpeg, int Width, int Height, bool Gray)? Recompressed(PdfDictionary dict, double quality, int maxPixel)
    {
        var filter = dict.Elements["/Filter"];
        var filterName = filter switch
        {
            PdfName n => n.Value,
            PdfArray { Elements.Count: 1 } a => (a.Elements[0] as PdfName)?.Value,
            _ => null,
        };
        MagickImage image;
        if (filterName == "/DCTDecode")
        {
            image = new MagickImage(dict.Stream.Value);
            if (image.ColorSpace == ColorSpace.CMYK) image.Negate(); // PDF CMYK JPEGs are usually stored inverted (Adobe)
        }
        else if (filterName == "/FlateDecode")
        {
            if (dict.Elements.GetInteger("/BitsPerComponent") != 8) return null;
            var colorSpace = dict.Elements["/ColorSpace"] is PdfName cs ? cs.Value : null;
            var mapping = colorSpace switch { "/DeviceRGB" => PixelMapping.RGB, "/DeviceGray" => (PixelMapping?)null, _ => (PixelMapping?)PixelMapping.RGB };
            if (colorSpace is not ("/DeviceRGB" or "/DeviceGray")) return null;
            int w = dict.Elements.GetInteger("/Width"), h = dict.Elements.GetInteger("/Height");
            if (dict.Elements["/DecodeParms"] is not null)
            {
                // Predictor-encoded pixels; PDFsharp's decoder undoes the predictor for us.
            }
            var raw = dict.Stream.UnfilteredValue;
            var channels = colorSpace == "/DeviceGray" ? 1 : 3;
            if (raw.Length < w * h * channels) return null;
            var settings = new PixelReadSettings((uint)w, (uint)h, StorageType.Char, channels == 1 ? "R" : "RGB");
            image = new MagickImage(raw, settings);
            if (channels == 1) image.ColorSpace = ColorSpace.Gray;
            // Small or flat pictures (logos, line art) stay lossless.
            if (w * h < 200 * 200) { image.Dispose(); return null; }
        }
        else return null;

        using (image)
        {
            if (Math.Max(image.Width, image.Height) > maxPixel) image.Resize(new MagickGeometry((uint)maxPixel, (uint)maxPixel));
            var gray = image.ColorSpace == ColorSpace.Gray || image.ChannelCount == 1;
            if (!gray && image.ColorSpace != ColorSpace.sRGB) image.ColorSpace = ColorSpace.sRGB;
            image.Strip();
            image.Quality = (uint)(quality * 100);
            var jpeg = image.ToByteArray(MagickFormat.Jpeg);
            return (jpeg, (int)image.Width, (int)image.Height, gray);
        }
    }

    // Metadata

    public static string StripMetadata(string input, ConversionOptions options)
    {
        var output = OutputPaths.Destination(input, "pdf", "clean", options.OutputFolder);
        using var document = Open(input, PdfDocumentOpenMode.Modify);
        ClearMetadata(document);
        document.Save(output);
        return output;
    }

    static void ClearMetadata(PdfDocument document)
    {
        document.Info.Elements.Clear();
        document.Internals.Catalog.Elements.Remove("/Metadata");
    }

    public static Dictionary<string, string> ReadInfo(string input)
    {
        using var document = Open(input, PdfDocumentOpenMode.Import);
        var info = document.Info;
        var result = new Dictionary<string, string>
        {
            ["title"] = info.Title,
            ["author"] = info.Author,
            ["subject"] = info.Subject,
            ["keywords"] = info.Keywords,
            ["creator"] = info.Creator,
            ["producer"] = info.Producer,
            ["pages"] = document.PageCount.ToString(),
        };
        if (info.Elements.ContainsKey("/CreationDate")) result["created"] = info.CreationDate.ToString("yyyy-MM-dd HH:mm");
        if (info.Elements.ContainsKey("/ModDate")) result["modified"] = info.ModificationDate.ToString("yyyy-MM-dd HH:mm");
        if (document.PageCount > 0)
        {
            var page = document.Pages[0];
            result["pageSize"] = $"{page.Width.Millimeter:0} × {page.Height.Millimeter:0} mm";
        }
        return result;
    }

    public static string WriteInfo(string input, IReadOnlyDictionary<string, string> changes, ConversionOptions options)
    {
        var output = OutputPaths.Destination(input, "pdf", "edited", options.OutputFolder);
        using var document = Open(input, PdfDocumentOpenMode.Modify);
        foreach (var (key, value) in changes)
        {
            switch (key)
            {
                case "title": document.Info.Title = value; break;
                case "author": document.Info.Author = value; break;
                case "subject": document.Info.Subject = value; break;
                case "keywords": document.Info.Keywords = value; break;
                case "creator": document.Info.Creator = value; break;
            }
        }
        document.Save(output);
        return output;
    }

    // Text

    /// The text of each page, in reading order.
    public static List<string> PageTexts(string input)
    {
        try
        {
            using var document = UglyToad.PdfPig.PdfDocument.Open(input);
            return document.GetPages().Select(p => ContentOrderTextExtractor.GetText(p, true)).ToList();
        }
        catch (Exception e)
        {
            throw new ConversionException($"Couldn't read the text in {Path.GetFileName(input)}: {e.Message}");
        }
    }
}

/// Tells PDFsharp where fonts are: Windows' own fonts, or common Linux ones for the self-test.
public static class Fonts
{
    static readonly object Gate = new();
    static bool installed;

    public const string Sans = "Transmute Sans";
    public const string Mono = "Transmute Mono";

    public static void Install()
    {
        lock (Gate)
        {
            if (installed) return;
            if (GlobalFontSettings.FontResolver is null) GlobalFontSettings.FontResolver = new Resolver();
            installed = true;
        }
    }

    sealed class Resolver : IFontResolver
    {
        // Regular, bold, italic, bold italic, by preference.
        static readonly string[][] SansFiles =
        [
            ["segoeui.ttf", "segoeuib.ttf", "segoeuii.ttf", "segoeuiz.ttf"],
            ["arial.ttf", "arialbd.ttf", "ariali.ttf", "arialbi.ttf"],
            ["LiberationSans-Regular.ttf", "LiberationSans-Bold.ttf", "LiberationSans-Italic.ttf", "LiberationSans-BoldItalic.ttf"],
            ["DejaVuSans.ttf", "DejaVuSans-Bold.ttf", "DejaVuSans-Oblique.ttf", "DejaVuSans-BoldOblique.ttf"],
        ];
        static readonly string[][] MonoFiles =
        [
            ["consola.ttf", "consolab.ttf", "consolai.ttf", "consolaz.ttf"],
            ["cour.ttf", "courbd.ttf", "couri.ttf", "courbi.ttf"],
            ["LiberationMono-Regular.ttf", "LiberationMono-Bold.ttf", "LiberationMono-Italic.ttf", "LiberationMono-BoldItalic.ttf"],
            ["DejaVuSansMono.ttf", "DejaVuSansMono-Bold.ttf", "DejaVuSansMono-Oblique.ttf", "DejaVuSansMono-BoldOblique.ttf"],
        ];

        static Dictionary<string, string>? index;

        /// File name (lower case) → full path, for every font on the machine.
        static Dictionary<string, string> Index()
        {
            if (index is not null) return index;
            var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            var dirs = new List<string>();
            if (OperatingSystem.IsWindows())
            {
                dirs.Add(Environment.GetFolderPath(Environment.SpecialFolder.Fonts));
                dirs.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "Windows", "Fonts"));
            }
            else
            {
                dirs.AddRange(["/usr/share/fonts", "/usr/local/share/fonts", "/Library/Fonts", "/System/Library/Fonts"]);
            }
            foreach (var dir in dirs.Where(Directory.Exists))
            {
                try
                {
                    foreach (var file in Directory.EnumerateFiles(dir, "*.tt?", SearchOption.AllDirectories))
                        map.TryAdd(Path.GetFileName(file), file);
                }
                catch { }
            }
            return index = map;
        }

        public FontResolverInfo? ResolveTypeface(string familyName, bool isBold, bool isItalic)
        {
            var sets = familyName == Mono ? MonoFiles : SansFiles;
            var files = Index();
            foreach (var set in sets)
            {
                if (!files.ContainsKey(set[0])) continue;
                var style = (isBold ? 1 : 0) + (isItalic ? 2 : 0);
                var wanted = set[style];
                if (files.ContainsKey(wanted)) return new FontResolverInfo(wanted);
                // Fake the missing style from the regular face.
                return new FontResolverInfo(set[0], isBold, isItalic);
            }
            // Anything at all, rather than failing.
            var any = files.Keys.FirstOrDefault(k => k.EndsWith(".ttf", StringComparison.OrdinalIgnoreCase));
            return any is null ? null : new FontResolverInfo(any, isBold, isItalic);
        }

        public byte[]? GetFont(string faceName) =>
            Index().TryGetValue(faceName, out var path) ? File.ReadAllBytes(path) : null;
    }
}
