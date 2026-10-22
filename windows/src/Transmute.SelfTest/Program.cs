using System.Diagnostics;
using System.IO.Compression;
using System.Text;
using ImageMagick;
using Transmute;
using Transmute.SelfTest;

Console.OutputEncoding = Encoding.UTF8;
if (args.Length == 2 && args[0] == "--make-fixtures")
{
    await Fixtures.Make(args[1]);
    return 0;
}
if (args.Length != 1 || !Directory.Exists(args[0]))
{
    Console.WriteLine("Usage: Transmute.SelfTest --make-fixtures <folder>\n       Transmute.SelfTest <folder>");
    return 2;
}
return await Tests.Run(args[0]);

static class Tests
{
    static int passed, skipped;
    static readonly List<string> Failed = [];
    static string outDir = "";

    public static async Task<int> Run(string inputDir)
    {
        var clock = Stopwatch.StartNew();
        outDir = Path.Combine(Path.GetTempPath(), "transmute-selftest-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(outDir);
        var options = new ConversionOptions { Quality = 0.8, OutputFolder = outDir, UseOfficeApps = false };
        Console.WriteLine($"ffmpeg: {Tools.Ffmpeg ?? "not available"}");
        Console.WriteLine($"Machine: {System.Runtime.InteropServices.RuntimeInformation.OSDescription} ({System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture})");
        Console.WriteLine($"ImageMagick: {MagickNET.Version}");
        Console.WriteLine($"HEIC writing: {(ImageConverter.CanWriteHeic ? "yes" : "no")}");
        Console.WriteLine($"output: {outDir}\n");

        var inputs = Directory.GetFiles(inputDir).Where(f => !Path.GetFileName(f).StartsWith('.')).OrderBy(f => f, StringComparer.Ordinal).ToList();
        string Fixture(string name) => inputs.FirstOrDefault(f => Path.GetFileName(f) == name) ?? throw new Exception($"fixture {name} missing");

        await WheelLayoutChecks();

        // Pass 1: every input through every operation it supports.
        foreach (var input in inputs) await Exercise(input, options);

        // Pass 2: PDFs and EPUBs made in pass 1 become inputs.
        var made = Directory.GetFiles(outDir);
        var textPdf = made.FirstOrDefault(f => Path.GetFileName(f) == "note.pdf") ?? made.FirstOrDefault(f => f.EndsWith(".pdf"));
        if (textPdf is not null) await Exercise(textPdf, options with { OutputFolder = Sub("pdf-pass") });
        else Record("PDF inputs", "no PDF was produced in pass 1");
        var epub = made.FirstOrDefault(f => Path.GetFileName(f) == "report.epub") ?? made.FirstOrDefault(f => f.EndsWith(".epub"));
        if (epub is not null) await Exercise(epub, options with { OutputFolder = Sub("epub-pass") });
        else Record("EPUB inputs", "no EPUB was produced in pass 1");

        // Content checks: the words (and some formatting) survive the trip.
        var content = options with { OutputFolder = Sub("content") };
        async Task<IReadOnlyList<string>> Convert(string input, OutputFormat format) =>
            (await Engine.Perform(new JobOperation.Convert(format), input, content, _ => { }, default)).Outputs;
        static string Text(string path) => File.ReadAllText(path).Replace("\r\n", "\n");

        await Check("budget.xlsx → CSV content", async () =>
        {
            var csv = await Convert(Fixture("budget.xlsx"), OutputFormat.Csv);
            Expect(Text(csv[0]) == "Item,Cost,\nRent,1200,\nFood & drink,,310.5\n", $"CSV was {Quote(Text(csv[0]))}");
            return csv;
        });
        await Check("table.csv → XLSX → CSV keeps the quoted comma", async () =>
        {
            var xlsx = await Convert(Fixture("table.csv"), OutputFormat.Xlsx);
            var sheet = ZipText(xlsx[0], "xl/worksheets/sheet1.xml");
            Expect(sheet.Contains("<x:v>12</x:v>") || sheet.Contains("<v>12</v>"), "12 isn't stored as a number");
            Expect(sheet.Contains("Pears, green"), "text cell missing");
            var back = await Convert(xlsx[0], OutputFormat.Csv);
            Expect(Text(back[0]).Contains("\"Pears, green\",12,0.8"), $"round trip gave {Quote(Text(back[0]))}");
            return [.. xlsx, .. back];
        });
        await Check("ledger.ods → CSV", async () =>
        {
            var csv = await Convert(Fixture("ledger.ods"), OutputFormat.Csv);
            Expect(Text(csv[0]) == "Item,Cost\nTea,2.5\n", $"CSV was {Quote(Text(csv[0]))}");
            return csv;
        });
        await Check("TSV → CSV and XLSX", async () =>
        {
            var tsv = Path.Combine(Sub("tsv"), "tabs.tsv");
            File.WriteAllText(tsv, "A\tB\n1\tx, y\n");
            var csv = await Convert(tsv, OutputFormat.Csv);
            Expect(Text(csv[0]) == "A,B\n1,\"x, y\"\n", $"CSV was {Quote(Text(csv[0]))}");
            return [.. csv, .. await Convert(tsv, OutputFormat.Xlsx)];
        });
        await Check("note.txt → EPUB → TXT", async () =>
        {
            var book = await Convert(Fixture("note.txt"), OutputFormat.Epub);
            var bytes = File.ReadAllBytes(book[0]);
            Expect(bytes.Length > 58 && Encoding.ASCII.GetString(bytes, 30, 8) == "mimetype" && Encoding.ASCII.GetString(bytes, 38, 20) == "application/epub+zip", "bad EPUB header");
            var txt = await Convert(book[0], OutputFormat.Txt);
            var s = Text(txt[0]);
            Expect(s.Contains("Hello from Transmute") && s.Contains("Second paragraph."), $"text was {Quote(s)}");
            return [.. book, .. txt];
        });
        await Check("book.epub → TXT keeps the chapters in spine order", async () =>
        {
            var txt = await Convert(Fixture("book.epub"), OutputFormat.Txt);
            var s = Text(txt[0]);
            var one = s.IndexOf("First chapter text.", StringComparison.Ordinal);
            var two = s.IndexOf("Second chapter text.", StringComparison.Ordinal);
            Expect(one >= 0 && two > one, $"text was {Quote(s)}");
            var html = await Convert(Fixture("book.epub"), OutputFormat.Html);
            Expect(Text(html[0]).Contains("data:image/png;base64,"), "the picture wasn't carried into the HTML");
            return [.. txt, .. html];
        });
        await Check("page.html → DOCX → HTML keeps headings, bold, lists, tables and the picture", async () =>
        {
            var docx = await Convert(Fixture("page.html"), OutputFormat.Docx);
            var html = await Convert(docx[0], OutputFormat.Html);
            var s = Text(html[0]);
            foreach (var bit in new[] { "<h1>Hello from Transmute</h1>", "<strong>bold</strong>", "<em>italic</em>", "<li>nested</li>", "<td>Apples</td>", "data:image/png", "https://example.com" })
                Expect(s.Contains(bit), $"missing {bit} in {Quote(s)}");
            return [.. docx, .. html];
        });
        await Check("report.docx → ODT → DOCX → TXT", async () =>
        {
            var odt = await Convert(Fixture("report.docx"), OutputFormat.Odt);
            var docx = await Convert(odt[0], OutputFormat.Docx);
            var txt = await Convert(docx[0], OutputFormat.Txt);
            var s = Text(txt[0]);
            foreach (var bit in new[] { "Quarterly Report", "Hello from Transmute", "nested point", "Rent\t1200", "Second paragraph." })
                Expect(s.Contains(bit), $"missing {bit} in {Quote(s)}");
            return [.. odt, .. docx, .. txt];
        });
        await Check("report.docx → RTF → TXT", async () =>
        {
            var rtf = await Convert(Fixture("report.docx"), OutputFormat.Rtf);
            var txt = await Convert(rtf[0], OutputFormat.Txt);
            var s = Text(txt[0]);
            Expect(s.Contains("Quarterly Report") && s.Contains("bold") && s.Contains("Second paragraph."), $"text was {Quote(s)}");
            return [.. rtf, .. txt];
        });
        await Check("letter.rtf → HTML: bold, italic and accents", async () =>
        {
            var html = await Convert(Fixture("letter.rtf"), OutputFormat.Html);
            var s = Text(html[0]);
            Expect(s.Contains("<strong>bold</strong>") && s.Contains("<em>italic</em>") && s.Contains("café") && s.Contains("€"), $"HTML was {Quote(s)}");
            return html;
        });
        await Check("readme.md → HTML", async () =>
        {
            var html = await Convert(Fixture("readme.md"), OutputFormat.Html);
            var s = Text(html[0]);
            Expect(s.Contains("<h1>Read Me</h1>") && s.Contains("<strong>Transmute</strong>") && s.Contains("<li>second point</li>") && s.Contains("<ol>"), $"HTML was {Quote(s)}");
            return html;
        });
        await Check("report.docx → PDF → TXT", async () =>
        {
            var pdf = await Convert(Fixture("report.docx"), OutputFormat.Pdf);
            var txt = await Convert(pdf[0], OutputFormat.Txt);
            Expect(Text(txt[0]).Contains("Quarterly Report"), $"PDF text was {Quote(Text(txt[0]))}");
            return [.. pdf, .. txt];
        });
        await Check("deck.pptx → PDF has both slides in order", async () =>
        {
            var pdf = await Convert(Fixture("deck.pptx"), OutputFormat.Pdf);
            Expect(PdfTools.PageCount(pdf[0]) == 2, "expected two pages");
            var s = string.Join("\n", PdfTools.PageTexts(pdf[0]));
            var a = s.IndexOf("Opening Slide", StringComparison.Ordinal);
            var b = s.IndexOf("Closing Slide", StringComparison.Ordinal);
            Expect(a >= 0 && b > a && s.Contains("Hello from Transmute"), $"PDF text was {Quote(s)}");
            return pdf;
        });
        await Check("deck.pptx → PNG, one per slide", async () =>
        {
            var png = await Convert(Fixture("deck.pptx"), OutputFormat.Png);
            Expect(png.Count == 2, $"expected 2 pictures, got {png.Count}");
            return png;
        });
        await Check("talk.odp → PDF", async () =>
        {
            var pdf = await Convert(Fixture("talk.odp"), OutputFormat.Pdf);
            Expect(string.Join("\n", PdfTools.PageTexts(pdf[0])).Contains("ODP Title"), "title missing");
            return pdf;
        });
        await Check("PowerPoint output without PowerPoint gives a clear message", async () =>
        {
            try { await Convert(Fixture("deck.pptx"), OutputFormat.Pptx); }
            catch (ConversionException e) when (e.Message.Contains("LibreOffice")) { return []; }
            throw new Exception("expected an error naming PowerPoint or LibreOffice");
        });
        await Check(".pages preview → TXT", async () =>
        {
            var pdf = await Convert(Fixture("note.txt"), OutputFormat.Pdf);
            var pages = Path.Combine(Sub("iwork"), "preview.pages");
            using (var zip = ZipFile.Open(pages, ZipArchiveMode.Create)) zip.CreateEntryFromFile(pdf[0], "QuickLook/Preview.pdf");
            var txt = await Convert(pages, OutputFormat.Txt);
            Expect(Text(txt[0]).Contains("Hello from Transmute"), "preview text missing");
            return txt;
        });
        await Check("subs.srt → VTT → SRT", async () =>
        {
            var vtt = await Convert(Fixture("subs.srt"), OutputFormat.Vtt);
            Expect(Text(vtt[0]).StartsWith("WEBVTT\n\n00:00:01.000 --> 00:00:03.500\nHello there."), $"VTT was {Quote(Text(vtt[0]))}");
            var srt = await Convert(Fixture("captions.vtt"), OutputFormat.Srt);
            Expect(Text(srt[0]) == "1\n00:00:01,000 --> 00:00:03,500\nHello there.\n\n2\n00:00:04,000 --> 00:00:06,000\nSecond line\n\n", $"SRT was {Quote(Text(srt[0]))}");
            return [.. vtt, .. srt];
        });
        await Check("bundle.zip and backup.tar.gz extract", async () =>
        {
            var zip = await Convert(Fixture("bundle.zip"), OutputFormat.Extract);
            var tgz = await Convert(Fixture("backup.tar.gz"), OutputFormat.Extract);
            foreach (var folder in zip.Concat(tgz))
                Expect(File.Exists(Path.Combine(folder, "note.txt")) && File.Exists(Path.Combine(folder, "sample.png")), $"files missing in {folder}");
            return [];
        });

        // Multi-file tools.
        var tools = options with { OutputFolder = Sub("tools") };
        var images = inputs.Where(i => Kinds.Of(i) == FileKind.Image).ToList();
        var pdfs = Directory.GetFiles(outDir, "*.pdf").Take(3).ToList();
        await Check("Merge PDFs", async () =>
        {
            Expect(pdfs.Count >= 2, $"need two PDFs, have {pdfs.Count}");
            var merged = await Engine.Batch(new BatchTool.MergePdfs(), pdfs, tools, _ => { }, default);
            Expect(PdfTools.PageCount(merged) == pdfs.Sum(PdfTools.PageCount), "page count doesn't add up");
            return [merged];
        });
        await Check("Images → PDF", async () =>
        {
            var pdf = await Engine.Batch(new BatchTool.ImagesToPdf(), images, tools, _ => { }, default);
            Expect(PdfTools.PageCount(pdf) == images.Count, "one page per picture expected");
            return [pdf];
        });
        await Check("Zip several files", async () =>
        {
            var zip = await Engine.Batch(new BatchTool.Archive(OutputFormat.Zip), [Fixture("note.txt"), Fixture("sample.png")], tools, _ => { }, default);
            using var archive = ZipFile.OpenRead(zip);
            Expect(archive.Entries.Count == 2, "expected two entries");
            return [zip];
        });
        await Check("Half and quarter size", async () =>
        {
            var half = await Engine.Perform(new JobOperation.Resize(0.5), Fixture("sample.png"), tools, _ => { }, default);
            using var image = new MagickImage(half.Outputs[0]);
            Expect(image.Width == 320 && image.Height == 240, $"size was {image.Width}×{image.Height}");
            return half.Outputs;
        });

        await PhotoEditorChecks(Fixture("sample.png"), options with { OutputFolder = Sub("photo-edit") });
        if (Tools.Ffmpeg is not null)
        {
            await VideoChecks(Fixture("clip.mp4"), Fixture("movie.mkv"), options with { OutputFolder = Sub("video-edit") });
            await AudioChecks(Fixture("tone.wav"), Fixture("song.mp3"), Fixture("clip.mp4"), options with { OutputFolder = Sub("audio-edit") });
        }
        await MetadataChecks(Fixture, options with { OutputFolder = Sub("metadata") });

        await Check("QR code read", async () =>
        {
            var qr = Path.Combine(Sub("qr"), "code.png");
            ImageConverter.WriteQr("https://example.com/transmute", qr);
            var result = await Engine.Perform(new JobOperation.ReadQr(), qr, options, _ => { }, default);
            Expect(result.Message == "https://example.com/transmute", $"read {Quote(result.Message ?? "")}");
            return [];
        });
        await Check("Compressing an image to half its size makes it smaller", async () =>
        {
            var result = await Engine.Perform(new JobOperation.Compress(new CompressionTarget.Percent(0.5)), Fixture("photo.jpg"), options with { OutputFolder = Sub("compress") }, _ => { }, default);
            Expect(OutputPaths.FileSize(result.Outputs[0]) <= OutputPaths.FileSize(Fixture("photo.jpg")) * 0.55, result.Message ?? "");
            return result.Outputs;
        });
        // Beta testers got "already as small as it can be" on 30 MB PDFs of photos.
        foreach (var (label, alpha, icc) in new[] { ("plain RGB", false, false), ("with transparency", true, false), ("ICC colour", false, true) })
        {
            await Check($"Photo PDF ({label}) compress 50% is at most 60% of the original", async () =>
            {
                var pdf = Path.Combine(Sub("pdf-compress"), $"photos {label}.pdf");
                MakePhotoPdf(pdf, 3, 2400, 3200, alpha, icc);
                var before = OutputPaths.FileSize(pdf);
                var result = await Engine.Perform(new JobOperation.Compress(new CompressionTarget.Percent(0.5)), pdf,
                    options with { OutputFolder = Sub("pdf-compress") }, _ => { }, default);
                var after = OutputPaths.FileSize(result.Outputs[0]);
                Expect(after <= before * 0.6, $"{before:N0} → {after:N0} bytes: {result.Message}");
                Console.WriteLine($"      {result.Message}");
                return result.Outputs;
            });
        }
        await Check("Removing metadata takes out the location", async () =>
        {
            var clean = await Engine.Perform(new JobOperation.StripMetadata(), Fixture("photo.jpg"), options with { OutputFolder = Sub("strip") }, _ => { }, default);
            var fields = await MetadataTool.Read(clean.Outputs[0]);
            Expect(!MetadataTool.HasLocation(fields) && string.IsNullOrEmpty(MetadataTool.Value("artist", fields)), "metadata still there");
            return clean.Outputs;
        });

        Console.WriteLine($"\n{passed} passed, {skipped} skipped, {Failed.Count} failed in {clock.Elapsed.TotalSeconds:0} s");
        foreach (var f in Failed) Console.WriteLine($"  FAILED: {f}");
        return Failed.Count == 0 ? 0 : 1;
    }

    /// A PDF with one big photo-like picture per page, stored losslessly (Flate) so it is large.
    static void MakePhotoPdf(string path, int pages, int width, int height, bool alpha, bool icc)
    {
        var random = new Random(7);
        using var document = new PdfSharp.Pdf.PdfDocument();
        for (var p = 0; p < pages; p++)
        {
            var channels = alpha ? 4 : 3;
            var pixels = new byte[width * height * channels];
            for (var y = 0; y < height; y++)
                for (var x = 0; x < width; x++)
                {
                    var i = (y * width + x) * channels;
                    var grain = random.Next(0, 40);
                    pixels[i] = (byte)((x * 200 / width + p * 20) % 216 + grain);
                    pixels[i + 1] = (byte)(y * 200 / height + grain);
                    pixels[i + 2] = (byte)((x + y) * 100 / (width + height) + 60 + grain);
                    if (alpha) pixels[i + 3] = (byte)(x < width / 10 ? 128 : 255);
                }
            var png = Path.ChangeExtension(path, $"{p}.png");
            using (var image = new MagickImage(pixels, new PixelReadSettings((uint)width, (uint)height, StorageType.Char, alpha ? "RGBA" : "RGB")))
                image.Write(png, MagickFormat.Png);
            var page = document.AddPage();
            page.Width = PdfSharp.Drawing.XUnit.FromPoint(595);
            page.Height = PdfSharp.Drawing.XUnit.FromPoint(842);
            using (var gfx = PdfSharp.Drawing.XGraphics.FromPdfPage(page))
            using (var picture = PdfSharp.Drawing.XImage.FromFile(png))
                gfx.DrawImage(picture, 0, 0, 595, 842);
            File.Delete(png);
        }
        if (icc)
        {
            // Point every picture at an ICC-based RGB colour space, as PDFs from design apps do.
            var profile = new PdfSharp.Pdf.PdfDictionary(document);
            profile.Elements.SetInteger("/N", 3);
            profile.CreateStream(new byte[] { 0 });
            document.Internals.AddObject(profile);
            foreach (var item in document.Internals.GetAllObjects())
                if (item is PdfSharp.Pdf.PdfDictionary d && d.Elements.GetName("/Subtype") == "/Image" && d.Elements.GetName("/ColorSpace") == "/DeviceRGB")
                    d.Elements["/ColorSpace"] = new PdfSharp.Pdf.PdfArray(document, new PdfSharp.Pdf.PdfName("/ICCBased"), profile.Reference!);
        }
        document.Save(path);
    }

    static string Sub(string name)
    {
        var dir = Path.Combine(outDir, name);
        Directory.CreateDirectory(dir);
        return dir;
    }

    // Pass 1

    static async Task Exercise(string input, ConversionOptions options)
    {
        var kind = Kinds.Of(input);
        var name = Path.GetFileName(input);
        foreach (var format in kind.ConvertTargets())
        {
            if (format == OutputFormat.Pptx) continue; // needs PowerPoint or LibreOffice; checked separately
            if (format == Kinds.FormatFor(Path.GetExtension(input)) && kind is FileKind.Subtitle) continue;
            await Check($"{name} → {format.Label()}", async () =>
                (await Engine.Perform(new JobOperation.Convert(format), input, options, _ => { }, default)).Outputs, SkipWhen(format));
        }
        if (kind.CanCompress())
            await Check($"{name} compress 50%", async () =>
                (await Engine.Perform(new JobOperation.Compress(new CompressionTarget.Percent(0.5)), input, options, _ => { }, default)).Outputs);
        if (kind.CanStripMetadata() && !(kind == FileKind.Image && Path.GetExtension(input) == ".svg"))
            await Check($"{name} remove metadata", async () =>
                (await Engine.Perform(new JobOperation.StripMetadata(), input, options, _ => { }, default)).Outputs);
        if (kind == FileKind.Pdf)
            await Check($"{name} split pages", async () =>
                (await Engine.Perform(new JobOperation.SplitPdf(), input, options, _ => { }, default)).Outputs);
    }

    /// Formats a machine may legitimately lack an encoder for.
    static Func<Exception, bool>? SkipWhen(OutputFormat format) => format switch
    {
        OutputFormat.Heic => e => e.Message.Contains("HEIC", StringComparison.OrdinalIgnoreCase) || e.Message.Contains("encoder", StringComparison.OrdinalIgnoreCase) || e.Message.Contains("delegate", StringComparison.OrdinalIgnoreCase),
        _ => null,
    };

    // Editors

    static async Task PhotoEditorChecks(string png, ConversionOptions options)
    {
        await Check("Photo editor: crop, turn, flip, black box, box outline, brightness", async () =>
        {
            var edit = new ImageEdit
            {
                Crop = new NormRect(0, 0, 0.5, 1),
                QuarterTurns = 1,
                FlipHorizontal = true,
                Brightness = 0.1,
                Redactions = [new Redaction(new NormRect(0, 0, 0.25, 0.25), RedactionStyle.Blackout)],
                Annotations = [new Annotation(AnnotationKind.Rectangle, new NormPoint(0.3, 0.6), new NormPoint(0.45, 0.9), Rgba.Red, 0.01),
                    new Annotation(AnnotationKind.Text, new NormPoint(0.05, 0.5), default, Rgba.White, 0.06, "Hi"),
                    new Annotation(AnnotationKind.Arrow, new NormPoint(0.1, 0.9), new NormPoint(0.4, 0.7), Rgba.Yellow, 0.01),
                    new Annotation(AnnotationKind.Highlight, new NormPoint(0.1, 0.4), new NormPoint(0.3, 0.45), Rgba.Yellow, 0.01)],
                OutputFormat = OutputFormat.Png,
            };
            var result = await Engine.Perform(new JobOperation.EditImage(edit), png, options, _ => { }, default);
            using var image = new MagickImage(result.Outputs[0]);
            // 320×480 cropped, turned to 480×320.
            Expect(image.Width == 480 && image.Height == 320, $"size was {image.Width}×{image.Height}");
            // The black box was the original's top-left corner: after a clockwise turn it's the
            // top-right, and the flip brings it back to the top-left.
            var pixel = image.GetPixels().GetPixel(10, 10).ToColor()!;
            Expect(pixel.R < 40 && pixel.G < 40 && pixel.B < 40, $"top-left was {pixel}, expected black");
            return result.Outputs;
        });
        await Check("Photo editor: pixelate, blur, saturation, exposure → JPEG", async () =>
        {
            var edit = new ImageEdit
            {
                Saturation = 0,
                Exposure = 0.5,
                Contrast = 1.2,
                Redactions = [new Redaction(new NormRect(0.5, 0.5, 0.3, 0.3), RedactionStyle.Pixelate), new Redaction(new NormRect(0.1, 0.5, 0.3, 0.3), RedactionStyle.Blur)],
                OutputFormat = OutputFormat.Jpeg,
            };
            var result = await Engine.Perform(new JobOperation.EditImage(edit), png, options, _ => { }, default);
            using var image = new MagickImage(result.Outputs[0]);
            var p = image.GetPixels().GetPixel(600, 20).ToColor()!;
            Expect(Math.Abs(p.R - p.G) < 12 && Math.Abs(p.G - p.B) < 12, $"saturation 0 should be grey, got {p}");
            return result.Outputs;
        });
    }

    static async Task<string> Banner(string path) => await MediaInfo.Banner(path);

    static async Task ExpectVideo(string path, double seconds, int width, int height, bool audio)
    {
        var banner = await Banner(path);
        var duration = MediaInfo.ParseDuration(banner) ?? 0;
        Expect(Math.Abs(duration - seconds) < 0.25, $"{Path.GetFileName(path)} is {duration:0.00} s, expected {seconds:0.00}");
        var size = MediaInfo.ParseFrameSize(banner);
        Expect(size == (width, height), $"{Path.GetFileName(path)} is {size}, expected {width}×{height}");
        Expect(MediaInfo.StreamLines(banner, "Audio").Any() == audio, audio ? "sound missing" : "sound should be gone");
    }

    static async Task VideoChecks(string mp4, string mkv, ConversionOptions options)
    {
        await Check("clip.mp4 edit: trim, 2× speed, 9:16 crop, rotate, flip, louder", async () =>
        {
            var edit = new VideoEdit { TrimStart = 0.5, TrimEnd = 2.5, Speed = 2, Crop = CropAspect.Portrait9x16, QuarterTurns = 1, FlipHorizontal = true, Volume = 1.5 };
            var result = await Engine.Perform(new JobOperation.EditVideo(edit), mp4, options, _ => { }, default);
            // 320×240 → 9:16 crop 134×240 → turned 240×134.
            await ExpectVideo(result.Outputs[0], 1.0, 240, 134, true);
            return result.Outputs;
        });
        await Check("movie.mkv edit: split at 1 s, half speed, muted, WebM", async () =>
        {
            var edit = new VideoEdit { SplitAt = 1, Speed = 0.5, Mute = true, OutputFormat = OutputFormat.Webm };
            var result = await Engine.Perform(new JobOperation.EditVideo(edit), mkv, options, _ => { }, default);
            Expect(result.Outputs.Count == 2, "expected two parts");
            await ExpectVideo(result.Outputs[0], 2.0, 320, 240, false);
            await ExpectVideo(result.Outputs[1], 4.0, 320, 240, false);
            return result.Outputs;
        });
        await Check("clip.mp4 edit: 4× speed keeps the sound", async () =>
        {
            var result = await Engine.Perform(new JobOperation.EditVideo(new VideoEdit { Speed = 4 }), mp4, options, _ => { }, default);
            await ExpectVideo(result.Outputs[0], 0.75, 320, 240, true);
            return result.Outputs;
        });
        await Check("Video edit rejects a split point outside the trim", async () =>
        {
            try { await Engine.Perform(new JobOperation.EditVideo(new VideoEdit { TrimEnd = 1, SplitAt = 2 }), mp4, options, _ => { }, default); }
            catch (ConversionException e) when (e.Message.Contains("split point")) { return []; }
            throw new Exception("expected an error");
        });
        await Check("movie.mkv snapshot at 2 s", async () =>
        {
            var result = await Engine.Perform(new JobOperation.Snapshot(2), mkv, options, _ => { }, default);
            using var image = new MagickImage(result.Outputs[0]);
            Expect(image.Width == 320 && image.Height == 240, "wrong frame size");
            return result.Outputs;
        });
        await Check("Join three videos of different sizes, one silent", async () =>
        {
            var silent = Path.Combine(Sub("join"), "silent.mp4");
            await Shell.Check(Tools.Ffmpeg!, ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=duration=1:size=640x360:rate=30",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", silent]);
            var joined = await Engine.Batch(new BatchTool.JoinVideos(), [mp4, silent, mkv], options, _ => { }, default);
            await ExpectVideo(joined, 7.0, 320, 240, true);
            return [joined];
        });
    }

    static async Task ExpectAudio(string path, double seconds, int channels, string ext)
    {
        Expect(Path.GetExtension(path) == "." + ext, $"saved as {Path.GetExtension(path)}, expected .{ext}");
        var banner = await Banner(path);
        var duration = MediaInfo.ParseDuration(banner) ?? 0;
        Expect(Math.Abs(duration - seconds) < 0.15, $"{Path.GetFileName(path)} is {duration:0.00} s, expected {seconds:0.00}");
        Expect(MediaInfo.ParseSoundTrack(banner)?.Channels == channels, $"expected {channels} channels: {MediaInfo.StreamLines(banner, "Audio").FirstOrDefault()}");
    }

    static async Task AudioChecks(string wav, string mp3, string mp4, ConversionOptions options)
    {
        await Check("tone.wav waveform", async () =>
        {
            var levels = await AudioEditEngine.Waveform(wav, 100, default);
            Expect(levels.Length == 100 && levels.Average() > 0.08 && levels.Min() > 0.05, $"levels averaged {levels.DefaultIfEmpty().Average():0.00}");
            return [];
        });
        await Check("tone.wav audio edit: trim, fade in and out, −6 dB", async () =>
        {
            var edit = new AudioEdit { TrimStart = 0.5, TrimEnd = 2.5, FadeIn = 0.5, FadeOut = 0.5, VolumeDb = -6 };
            var result = await Engine.Perform(new JobOperation.EditAudio(edit), wav, options, _ => { }, default);
            await ExpectAudio(result.Outputs[0], 2.0, 1, "wav");
            return result.Outputs;
        });
        await Check("song.mp3 audio edit: two bleeps, stereo, FLAC", async () =>
        {
            var edit = new AudioEdit { Bleeps = [new BleepRange(0.5, 1), new BleepRange(2, 2.2)], Channels = ChannelMode.Stereo, OutputFormat = OutputFormat.Flac };
            var result = await Engine.Perform(new JobOperation.EditAudio(edit), mp3, options, _ => { }, default);
            await ExpectAudio(result.Outputs[0], 3.0, 2, "flac");
            return result.Outputs;
        });
        await Check("clip.mp4 audio edit: normalize to −16 LUFS (M4A)", async () =>
        {
            var result = await Engine.Perform(new JobOperation.EditAudio(new AudioEdit { Normalize = true }), mp4, options, _ => { }, default);
            await ExpectAudio(result.Outputs[0], 3.0, 1, "m4a");
            return result.Outputs;
        });
        foreach (var format in AudioEditEngine.Formats)
            await Check($"tone.wav audio edit → {format.Label()}", async () =>
            {
                var result = await Engine.Perform(new JobOperation.EditAudio(new AudioEdit { TrimEnd = 1, OutputFormat = format }), wav, options, _ => { }, default);
                await ExpectAudio(result.Outputs[0], 1.0, 1, format.Extension());
                return result.Outputs;
            });
        await Check("Audio edit rejects a start past the end", async () =>
        {
            try { await Engine.Perform(new JobOperation.EditAudio(new AudioEdit { TrimStart = 10 }), wav, options, _ => { }, default); }
            catch (ConversionException e) when (e.Message.Contains("past the end")) { return []; }
            throw new Exception("expected an error");
        });
    }

    // Metadata

    static async Task MetadataChecks(Func<string, string> fixture, ConversionOptions options)
    {
        await Check("photo.jpg metadata: read camera and location, write, clear a field, remove location", async () =>
        {
            var before = await MetadataTool.Read(fixture("photo.jpg"));
            Expect(MetadataTool.Value("model", before) == "Test Camera", "camera model missing");
            Expect(MetadataTool.Value("location", before)?.StartsWith("19.0") == true, $"location was {MetadataTool.Value("location", before)}");
            var edit = new MetadataEdit(new Dictionary<string, string> { ["description"] = "A test card", ["artist"] = "", ["dateTaken"] = "2023-01-02 03:04" }, RemoveLocation: true);
            var output = await MetadataTool.Write(edit, fixture("photo.jpg"), options, default);
            var after = await MetadataTool.Read(output);
            Expect(MetadataTool.Value("description", after) == "A test card", "description not written");
            Expect(string.IsNullOrEmpty(MetadataTool.Value("artist", after)), "artist not cleared");
            Expect(MetadataTool.Value("dateTaken", after) == "2023:01:02 03:04:00", $"date was {MetadataTool.Value("dateTaken", after)}");
            Expect(!MetadataTool.HasLocation(after), "location still there");
            return [output];
        });
        await Check("sample.png metadata: description and artist", async () =>
        {
            var output = await MetadataTool.Write(new MetadataEdit(new Dictionary<string, string> { ["description"] = "PNG note", ["artist"] = "Me" }), fixture("sample.png"), options, default);
            var after = await MetadataTool.Read(output);
            Expect(MetadataTool.Value("description", after) == "PNG note" && MetadataTool.Value("artist", after) == "Me", "PNG fields not written");
            return [output];
        });
        await Check("PDF metadata: title, author, subject, keywords", async () =>
        {
            var pdf = Directory.GetFiles(outDir, "note.pdf").First();
            var output = await MetadataTool.Write(new MetadataEdit(new Dictionary<string, string> { ["title"] = "T", ["author"] = "A", ["subject"] = "S", ["keywords"] = "K" }), pdf, options, default);
            var after = await MetadataTool.Read(output);
            Expect(MetadataTool.Value("title", after) == "T" && MetadataTool.Value("author", after) == "A" && MetadataTool.Value("keywords", after) == "K", "PDF fields not written");
            return [output];
        });
        if (Tools.Ffmpeg is null) return;
        await Check("clip.mp4 info: codec, frame size, frame rate, sound", async () =>
        {
            var fields = await MetadataTool.Read(fixture("clip.mp4"));
            Expect(MetadataTool.Value("videoCodec", fields) == "h264" && MetadataTool.Value("frameSize", fields) == "320 × 240"
                && MetadataTool.Value("frameRate", fields) == "25 fps" && MetadataTool.Value("audioCodec", fields) == "aac", "info wrong");
            return [];
        });
        await Check("song.mp3 tags: write, read back, clear one", async () =>
        {
            var first = await MetadataTool.Write(new MetadataEdit(new Dictionary<string, string> { ["title"] = "Tone", ["artist"] = "Sine", ["album"] = "Tests", ["track"] = "3/12" }), fixture("song.mp3"), options, default);
            var fields = await MetadataTool.Read(first);
            Expect(MetadataTool.Value("title", fields) == "Tone" && MetadataTool.Value("artist", fields) == "Sine" && MetadataTool.Value("track", fields) == "3/12", "tags not written");
            var second = await MetadataTool.Write(new MetadataEdit(new Dictionary<string, string> { ["artist"] = "" }), first, options, default);
            var cleared = await MetadataTool.Read(second);
            Expect(string.IsNullOrEmpty(MetadataTool.Value("artist", cleared)) && MetadataTool.Value("title", cleared) == "Tone", "clearing went wrong");
            return [first, second];
        });
        await Check("clip.mp4 tags: title, comment and year keep the video intact", async () =>
        {
            var output = await MetadataTool.Write(new MetadataEdit(new Dictionary<string, string> { ["title"] = "Clip", ["comment"] = "Hi", ["date"] = "2024" }), fixture("clip.mp4"), options, default);
            var fields = await MetadataTool.Read(output);
            Expect(MetadataTool.Value("title", fields) == "Clip" && MetadataTool.Value("comment", fields) == "Hi" && MetadataTool.Value("date", fields) == "2024", "tags not written");
            await ExpectVideo(output, 3.0, 320, 240, true);
            return [output];
        });
        await Check("Ogg tags (kept on the sound track): write and read back", async () =>
        {
            var ogg = Path.Combine(Sub("ogg"), "tone.ogg");
            await Shell.Check(Tools.Ffmpeg!, ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-i", fixture("tone.wav"), "-c:a", "libvorbis", ogg]);
            var output = await MetadataTool.Write(new MetadataEdit(new Dictionary<string, string> { ["title"] = "Ogg title" }), ogg, options, default);
            Expect(MetadataTool.Value("title", await MetadataTool.Read(output)) == "Ogg title", "Ogg title missing");
            return [output];
        });
    }

    // Bookkeeping

    static async Task WheelLayoutChecks()
    {
        static Task<IReadOnlyList<string>> Done() => Task.FromResult<IReadOnlyList<string>>([]);
        static void Same(IEnumerable<string> got, params string[] want) =>
            Expect(got.SequenceEqual(want), $"got [{string.Join(", ", got)}], expected [{string.Join(", ", want)}]");
        await Check("Drag wheel: default layouts are the built-in ones", () =>
        {
            Same(WheelLayout.Resolve(WheelKind.Convert, [FileKind.Document], null), WheelLayout.Default(WheelKind.Convert, FileKind.Document).ToArray());
            Expect(WheelLayout.Resolve(WheelKind.Convert, [FileKind.Document], null)[0] == "convert:pdf", "PDF should come first for documents");
            Same(WheelLayout.Resolve(WheelKind.Tools, [FileKind.Pdf], null), "tool:half", "tool:quarter", "tool:clean", "tool:split", "tool:zip");
            Same(WheelLayout.Resolve(WheelKind.Tools, [FileKind.Pdf, FileKind.Pdf], null), "tool:half", "tool:quarter", "tool:clean", "tool:split", "tool:merge", "tool:zip");
            Same(WheelLayout.Resolve(WheelKind.Convert, [FileKind.Image, FileKind.Video], null), "convert:gif");
            return Done();
        });
        await Check("Drag wheel: a customized layout keeps its order, spaces and mixed-in items", () =>
        {
            var custom = new Dictionary<string, List<string>>
            {
                ["convert.document"] = ["gap", "convert:pdf", "gap", "convert:docx", "action:float", "tool:zip"],
            };
            Same(WheelLayout.Resolve(WheelKind.Convert, [FileKind.Document], custom), "gap", "convert:pdf", "gap", "convert:docx", "action:float", "tool:zip");
            // Other wheels and kinds keep their defaults.
            Same(WheelLayout.Resolve(WheelKind.Convert, [FileKind.Pdf], custom), WheelLayout.Default(WheelKind.Convert, FileKind.Pdf).ToArray());
            // Something that doesn't suit every file leaves its spot empty; nothing left means no wheel.
            Same(WheelLayout.Resolve(WheelKind.Convert, [FileKind.Document, FileKind.Ebook], custom), "gap", "convert:pdf", "gap", "convert:docx", "action:float", "tool:zip");
            Same(WheelLayout.Resolve(WheelKind.Convert, [FileKind.Document, FileKind.Image], custom), "gap", "convert:pdf", "gap", "gap", "action:float", "tool:zip");
            Same(WheelLayout.Resolve(WheelKind.Convert, [FileKind.Document, FileKind.Audio], custom), "gap", "gap", "gap", "gap", "action:float", "tool:zip");
            custom["tools.pdf"] = ["tool:merge"];
            Same(WheelLayout.Resolve(WheelKind.Tools, [FileKind.Pdf], custom));
            custom["tools.pdf"] = [];
            Same(WheelLayout.Resolve(WheelKind.Tools, [FileKind.Pdf], custom));
            return Done();
        });
        await Check("Drag wheel: saved layouts are cleaned up", () =>
        {
            var many = Enumerable.Repeat("gap", 20).Prepend("convert:pdf").Append("tool:qr").Append("convert:pdf").Append("nonsense");
            var clean = WheelLayout.Clean(many, FileKind.Document);
            Expect(clean.Count == WheelLayout.MaxSlots && clean[0] == "convert:pdf" && !clean.Contains("tool:qr") && !clean.Contains("nonsense"), string.Join(", ", clean));
            Same(WheelLayout.Clean(["convert:pdf", "convert:pdf", "gap"], FileKind.Document), "convert:pdf", "gap");
            Expect(WheelLayout.Available(FileKind.Image).Contains("tool:qr") && WheelLayout.Available(FileKind.Document).Contains("action:terminal"), "available items");
            return Done();
        });
    }

    static async Task Check(string name, Func<Task<IReadOnlyList<string>>> body, Func<Exception, bool>? skipWhen = null)
    {
        var clock = Stopwatch.StartNew();
        try
        {
            var outputs = await body();
            foreach (var output in outputs)
            {
                if (Problem(output) is { } problem) { Record(name, problem); return; }
            }
            passed++;
            Console.WriteLine($"PASS  {name}  ({clock.Elapsed.TotalSeconds:0.0} s)");
        }
        catch (Exception e) when (skipWhen?.Invoke(e) == true)
        {
            skipped++;
            Console.WriteLine($"SKIP  {name}: {First(e.Message)}");
        }
        catch (Exception e)
        {
            Record(name, e is ConversionException or CheckFailed ? e.Message : e.ToString());
        }
    }


    static void Record(string name, string error)
    {
        Failed.Add($"{name}: {First(error)}");
        Console.WriteLine($"FAIL  {name}: {error}");
    }

    static string First(string text) => text.Split('\n')[0];

    sealed class CheckFailed(string message) : Exception(message);

    static void Expect(bool condition, string message)
    {
        if (!condition) throw new CheckFailed(message);
    }

    static string Quote(string text) => "\"" + (text.Length > 300 ? text[..300] + "…" : text).Replace("\n", "\\n") + "\"";

    static string ZipText(string zip, string member)
    {
        using var archive = ZipFile.OpenRead(zip);
        var entry = archive.GetEntry(member) ?? throw new CheckFailed($"{member} missing");
        using var reader = new StreamReader(entry.Open());
        return reader.ReadToEnd();
    }

    /// Whether an output is a real, readable file of its kind.
    static string? Problem(string path)
    {
        if (Directory.Exists(path)) return Directory.EnumerateFileSystemEntries(path).Any() ? null : $"{Path.GetFileName(path)} is an empty folder";
        if (!File.Exists(path)) return $"{Path.GetFileName(path)} wasn't written";
        if (new FileInfo(path).Length == 0) return $"{Path.GetFileName(path)} is empty";
        var ext = Path.GetExtension(path).ToLowerInvariant();
        try
        {
            switch (Kinds.Of(path))
            {
                case FileKind.Image when ext != ".svg":
                    using (var image = new MagickImage(path)) if (image.Width == 0) return "picture has no pixels";
                    break;
                case FileKind.Pdf:
                    if (PdfTools.PageCount(path) == 0) return "PDF has no pages";
                    break;
                case FileKind.Video or FileKind.Audio when Tools.Ffmpeg is not null:
                    var banner = MediaInfo.Banner(path).GetAwaiter().GetResult();
                    if (MediaInfo.ParseDuration(banner) is null) return $"ffmpeg can't read {Path.GetFileName(path)}";
                    break;
            }
            if (ext is ".docx" or ".xlsx" or ".epub" or ".odt" or ".zip")
                using (ZipFile.OpenRead(path)) { }
            if (ext == ".docx")
                using (DocumentFormat.OpenXml.Packaging.WordprocessingDocument.Open(path, false)) { }
            if (ext == ".xlsx")
                using (DocumentFormat.OpenXml.Packaging.SpreadsheetDocument.Open(path, false)) { }
        }
        catch (Exception e)
        {
            return $"{Path.GetFileName(path)} can't be read back: {First(e.Message)}";
        }
        return null;
    }
}
