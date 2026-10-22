using System.IO.Compression;
using System.Text;
using ImageMagick;

namespace Transmute.SelfTest;

/// One sample file of every supported kind.
static class Fixtures
{
    public static async Task Make(string dir)
    {
        Directory.CreateDirectory(dir);
        var ffmpeg = Tools.Ffmpeg ?? throw new Exception("ffmpeg is needed to make the sample files");
        async Task Ff(params string[] args) => await Shell.Check(ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", .. args]);
        string P(string name) => Path.Combine(dir, name);

        // Images
        await Ff("-f", "lavfi", "-i", "testsrc=size=640x480", "-frames:v", "1", P("sample.png"));
        using (var image = new MagickImage(P("sample.png")))
        {
            var exif = new ExifProfile();
            exif.SetValue(ExifTag.Make, "Transmute");
            exif.SetValue(ExifTag.Model, "Test Camera");
            exif.SetValue(ExifTag.Artist, "Fixture Artist");
            exif.SetValue(ExifTag.DateTimeOriginal, "2024:05:31 14:30:00");
            exif.SetValue(ExifTag.GPSLatitudeRef, "N");
            exif.SetValue(ExifTag.GPSLatitude, [new Rational(19, 1), new Rational(4, 1), new Rational(30, 1)]);
            exif.SetValue(ExifTag.GPSLongitudeRef, "E");
            exif.SetValue(ExifTag.GPSLongitude, [new Rational(72, 1), new Rational(52, 1), new Rational(0, 1)]);
            image.SetProfile(exif);
            image.Quality = 90;
            image.Write(P("photo.jpg"), MagickFormat.Jpeg);
        }
        using (var image = new MagickImage(P("sample.png"))) image.Write(P("scan.tiff"), MagickFormat.Tiff);
        using (var image = new MagickImage(P("sample.png"))) image.Write(P("web.webp"), MagickFormat.WebP);
        try
        {
            using var image = new MagickImage(P("sample.png"));
            image.Write(P("phone.heic"), MagickFormat.Heic);
            using var check = new MagickImage(P("phone.heic"));
        }
        catch (Exception e)
        {
            File.Delete(P("phone.heic"));
            Console.WriteLine($"warning: no HEIC sample ({e.Message.Split('\n')[0]})");
        }
        await Ff("-f", "lavfi", "-i", "testsrc=size=320x240:rate=10", "-t", "1", "-loop", "0", P("anim.gif"));
        File.WriteAllText(P("logo.svg"), """
            <svg xmlns="http://www.w3.org/2000/svg" width="200" height="120" viewBox="0 0 200 120">
              <rect width="200" height="120" rx="16" fill="#2c7be5"/>
              <circle cx="60" cy="60" r="30" fill="#ffffff"/>
            </svg>
            """);
        // A product shot: a lit ball on a plain studio backdrop, for background removal.
        using (var product = ProductShot(800, 600)) { product.Quality = 92; product.Write(P("product.jpg"), MagickFormat.Jpeg); }

        // Video and audio
        await Ff("-f", "lavfi", "-i", "testsrc=duration=3:size=320x240:rate=25", "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", P("clip.mp4"));
        await Ff("-i", P("clip.mp4"), "-c", "copy", P("movie.mkv"));
        // A camcorder-style file with 5.1 sound, which MP3, WMA and Opus can't take as it is.
        await Ff("-f", "lavfi", "-i", "testsrc=duration=2:size=320x240:rate=25", "-f", "lavfi", "-i", "sine=frequency=330:duration=2",
            "-filter_complex", "[1]pan=5.1(side)|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0[a]", "-map", "0", "-map", "[a]",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "ac3", "-f", "mpegts", P("surround.mts"));
        // Like a recent iPhone video: a normal stereo track plus a default spatial-audio (APAC) track
        // ffmpeg can't decode. The second track is made as AAC and relabelled.
        await Ff("-f", "lavfi", "-i", "testsrc=duration=2:size=320x240:rate=30", "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
            "-f", "lavfi", "-i", "sine=frequency=220:duration=2", "-filter_complex", "[2]pan=quad|c0=c0|c1=c0|c2=c0|c3=c0[q]",
            "-map", "0", "-map", "1", "-map", "[q]", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-ac:a:0", "2",
            "-disposition:a:0", "0", "-disposition:a:1", "default", P("spatial-src.mov"));
        var movie = await File.ReadAllBytesAsync(P("spatial-src.mov"));
        static int Find(byte[] data, string tag, int from, bool last = false)
        {
            var t = System.Text.Encoding.ASCII.GetBytes(tag);
            int found = -1;
            for (var i = from; i <= data.Length - 4; i++)
                if (data[i] == t[0] && data[i + 1] == t[1] && data[i + 2] == t[2] && data[i + 3] == t[3]) { found = i; if (!last) break; }
            return found;
        }
        var trak = Find(movie, "trak", 0, last: true);
        var sampleEntry = Find(movie, "mp4a", trak);
        var esds = Find(movie, "esds", sampleEntry);
        System.Text.Encoding.ASCII.GetBytes("apac").CopyTo(movie, sampleEntry);
        System.Text.Encoding.ASCII.GetBytes("free").CopyTo(movie, esds);
        await File.WriteAllBytesAsync(P("spatial.mov"), movie);
        File.Delete(P("spatial-src.mov"));
        await Ff("-f", "lavfi", "-i", "sine=frequency=440:duration=3", P("tone.wav"));
        await Ff("-i", P("tone.wav"), "-c:a", "libmp3lame", P("song.mp3"));

        // Documents
        const string note = "Hello from Transmute\n\nThis is a test document with a few lines of text.\nSecond paragraph.\n";
        File.WriteAllText(P("note.txt"), note);
        File.WriteAllText(P("readme.md"), "# Read Me\n\nHello from **Transmute**, in *Markdown*.\n\n- first point\n- second point\n\n1. one\n2. two\n\n| A | B |\n|---|---|\n| 1 | 2 |\n");
        File.WriteAllText(P("letter.rtf"),
            "{\\rtf1\\ansi\\ansicpg1252\\deff0{\\fonttbl{\\f0\\fswiss Helvetica;}}{\\colortbl;\\red0\\green0\\blue0;}\n" +
            "\\pard\\f0\\fs24 Hello from Transmute\\par\n\\par\nThis is {\\b bold} and {\\i italic} text with caf\\'e9 and \\u8364? euro.\\par\n}");
        File.WriteAllText(P("page.html"), "<!DOCTYPE html><html><head><title>Fixture Page</title><style>p{color:red}</style></head><body><h1>Hello from Transmute</h1><p>Some <b>bold</b> and <i>italic</i> text, and a <a href=\"https://example.com\">link</a>.</p><ul><li>one</li><li>two<ul><li>nested</li></ul></li></ul><table><tr><th>Name</th><th>Qty</th></tr><tr><td>Apples</td><td>3</td></tr></table><p><img src=\"sample.png\" alt=\"test\"></p></body></html>");
        var doc = new Doc { Title = "Fixture Report" };
        doc.Blocks.Add(new Block.Heading(1, [new Run("Quarterly Report")]));
        doc.Blocks.Add(new Block.Paragraph([new Run("Hello from Transmute, with "), new Run("bold", Bold: true), new Run(" and "), new Run("italic", Italic: true), new Run(" words.")]));
        doc.Blocks.Add(new Block.ListItem(false, 0, [new Run("first point")]));
        doc.Blocks.Add(new Block.ListItem(false, 1, [new Run("nested point")]));
        doc.Blocks.Add(new Block.ListItem(true, 0, [new Run("numbered")]));
        doc.Blocks.Add(new Block.Table([["Item", "Cost"], ["Rent", "1200"]]));
        doc.Blocks.Add(new Block.Picture(File.ReadAllBytes(P("sample.png")), "sample"));
        doc.Blocks.Add(new Block.Heading(2, [new Run("Second section")]));
        doc.Blocks.Add(new Block.Paragraph([new Run("Second paragraph.")]));
        DocWriters.WriteDocx(doc, P("report.docx"));
        DocWriters.WriteOdt(doc, P("essay.odt"));

        // Spreadsheets
        File.WriteAllText(P("table.csv"), "Name,Qty,Price\nApples,3,1.25\n\"Pears, green\",12,0.8\n");
        WriteZip(P("budget.xlsx"), new()
        {
            ["[Content_Types].xml"] = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/><Override PartName=\"/xl/sharedStrings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml\"/></Types>",
            ["_rels/.rels"] = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>",
            ["xl/workbook.xml"] = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"Budget\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>",
            ["xl/_rels/workbook.xml.rels"] = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" Target=\"sharedStrings.xml\"/></Relationships>",
            ["xl/sharedStrings.xml"] = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" count=\"4\" uniqueCount=\"4\"><si><t>Item</t></si><si><t>Cost</t></si><si><t>Rent</t></si><si><r><t>Food </t></r><r><t>&amp; drink</t></r></si></sst>",
            ["xl/worksheets/sheet1.xml"] = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData><row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c><c r=\"B1\" t=\"s\"><v>1</v></c></row><row r=\"2\"><c r=\"A2\" t=\"s\"><v>2</v></c><c r=\"B2\"><v>1200</v></c></row><row r=\"3\"><c r=\"A3\" t=\"s\"><v>3</v></c><c r=\"C3\"><v>310.5</v></c></row></sheetData></worksheet>",
        });
        WriteZip(P("ledger.ods"), new()
        {
            ["mimetype"] = "application/vnd.oasis.opendocument.spreadsheet",
            ["META-INF/manifest.xml"] = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.2\"><manifest:file-entry manifest:full-path=\"/\" manifest:media-type=\"application/vnd.oasis.opendocument.spreadsheet\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/></manifest:manifest>",
            ["content.xml"] = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" office:version=\"1.2\"><office:body><office:spreadsheet><table:table table:name=\"Ledger\"><table:table-row><table:table-cell office:value-type=\"string\"><text:p>Item</text:p></table:table-cell><table:table-cell office:value-type=\"string\"><text:p>Cost</text:p></table:table-cell></table:table-row><table:table-row><table:table-cell office:value-type=\"string\"><text:p>Tea</text:p></table:table-cell><table:table-cell office:value-type=\"float\" office:value=\"2.5\"><text:p>2.50</text:p></table:table-cell></table:table-row><table:table-row table:number-rows-repeated=\"3\"><table:table-cell table:number-columns-repeated=\"1024\"/></table:table-row></table:table></office:spreadsheet></office:body></office:document-content>",
        });

        // Presentations
        const string pml = "http://schemas.openxmlformats.org/presentationml/2006/main";
        const string dml = "http://schemas.openxmlformats.org/drawingml/2006/main";
        const string rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
        string Slide(string title, string body) =>
            $"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><p:sld xmlns:a=\"{dml}\" xmlns:r=\"{rel}\" xmlns:p=\"{pml}\"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>" +
            $"<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"Body\"/><p:cNvSpPr/><p:nvPr><p:ph idx=\"1\"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:p><a:r><a:t>{body}</a:t></a:r></a:p><a:p><a:pPr lvl=\"1\"/><a:r><a:t>Detail</a:t></a:r></a:p></p:txBody></p:sp>" +
            $"<p:sp><p:nvSpPr><p:cNvPr id=\"3\" name=\"Title\"/><p:cNvSpPr/><p:nvPr><p:ph type=\"title\"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:p><a:r><a:t>{title}</a:t></a:r></a:p></p:txBody></p:sp>" +
            "</p:spTree></p:cSld></p:sld>";
        WriteZip(P("deck.pptx"), new()
        {
            ["[Content_Types].xml"] = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/><Override PartName=\"/ppt/slides/slide1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/><Override PartName=\"/ppt/slides/slide2.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/></Types>",
            ["_rels/.rels"] = $"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"{rel}/officeDocument\" Target=\"ppt/presentation.xml\"/></Relationships>",
            ["ppt/presentation.xml"] = $"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><p:presentation xmlns:a=\"{dml}\" xmlns:r=\"{rel}\" xmlns:p=\"{pml}\"><p:sldIdLst><p:sldId id=\"257\" r:id=\"rId3\"/><p:sldId id=\"256\" r:id=\"rId2\"/></p:sldIdLst><p:sldSz cx=\"12192000\" cy=\"6858000\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>",
            ["ppt/_rels/presentation.xml.rels"] = $"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId2\" Type=\"{rel}/slide\" Target=\"slides/slide2.xml\"/><Relationship Id=\"rId3\" Type=\"{rel}/slide\" Target=\"slides/slide1.xml\"/></Relationships>",
            ["ppt/slides/slide1.xml"] = Slide("Opening Slide", "Hello from Transmute"),
            ["ppt/slides/slide2.xml"] = Slide("Closing Slide", "Thanks for watching"),
        });
        WriteZip(P("talk.odp"), new()
        {
            ["mimetype"] = "application/vnd.oasis.opendocument.presentation",
            ["META-INF/manifest.xml"] = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.2\"><manifest:file-entry manifest:full-path=\"/\" manifest:media-type=\"application/vnd.oasis.opendocument.presentation\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/></manifest:manifest>",
            ["content.xml"] = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:draw=\"urn:oasis:names:tc:opendocument:xmlns:drawing:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" xmlns:presentation=\"urn:oasis:names:tc:opendocument:xmlns:presentation:1.0\" office:version=\"1.2\"><office:body><office:presentation><draw:page draw:name=\"page1\"><draw:frame presentation:class=\"title\"><draw:text-box><text:p>ODP Title</text:p></draw:text-box></draw:frame><draw:frame presentation:class=\"outline\"><draw:text-box><text:list><text:list-item><text:p>Hello from Transmute</text:p></text:list-item></text:list></draw:text-box></draw:frame></draw:page></office:presentation></office:body></office:document-content>",
        });

        // E-book: two chapters listed out of order, a stylesheet, a picture and a link
        var png = File.ReadAllBytes(P("sample.png"));
        string Chapter(string title, string body) =>
            $"<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>{title}</title><link rel=\"stylesheet\" type=\"text/css\" href=\"../Styles/book.css\"/></head><body>{body}</body></html>";
        using (var zip = ZipFile.Open(P("book.epub"), ZipArchiveMode.Create))
        {
            Add(zip, "mimetype", "application/epub+zip", CompressionLevel.NoCompression);
            Add(zip, "META-INF/container.xml", "<?xml version=\"1.0\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OPS/book.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>");
            Add(zip, "OPS/book.opf", "<?xml version=\"1.0\" encoding=\"utf-8\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"id\">urn:uuid:12345678-1234-1234-1234-123456789abc</dc:identifier><dc:title>Fixture Book</dc:title><dc:language>en</dc:language></metadata><manifest><item id=\"c2\" href=\"Text/chapter%20two.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"c1\" href=\"Text/chapter%20one.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"css\" href=\"Styles/book.css\" media-type=\"text/css\"/><item id=\"img\" href=\"Images/dot.png\" media-type=\"image/png\"/></manifest><spine><itemref idref=\"c1\"/><itemref idref=\"c2\"/></spine></package>");
            Add(zip, "OPS/Text/chapter one.xhtml", Chapter("One", "<h1>Chapter One</h1><p><a id=\"p1\"/>First chapter text. <a href=\"chapter%20two.xhtml#end\">Jump</a></p><p><img src=\"../Images/dot.png\" alt=\"dot\"/></p>"));
            Add(zip, "OPS/Text/chapter two.xhtml", Chapter("Two", "<h1>Chapter Two</h1><p id=\"end\">Second chapter text.</p>"));
            Add(zip, "OPS/Styles/book.css", "h1 { color: #333; }");
            var entry = zip.CreateEntry("OPS/Images/dot.png");
            using (var s = entry.Open()) s.Write(png);
        }

        // Subtitles
        File.WriteAllText(P("subs.srt"), "1\n00:00:01,000 --> 00:00:03,500\nHello there.\n\n2\n00:00:04,000 --> 00:00:06,000\n<i>Second line</i>\n");
        File.WriteAllText(P("captions.vtt"), "WEBVTT\n\nNOTE a comment block\n\n00:01.000 --> 00:03.500 align:start\n<v Narrator>Hello there.\n\nintro\n00:04.000 --> 00:06.000\nSecond line\n");

        // Archives
        var stuff = Path.Combine(dir, "stuff");
        Directory.CreateDirectory(stuff);
        File.Copy(P("note.txt"), Path.Combine(stuff, "note.txt"));
        File.Copy(P("sample.png"), Path.Combine(stuff, "sample.png"));
        await Archives.Compress([stuff], OutputFormat.Zip, "bundle", new ConversionOptions { OutputFolder = dir }, default);
        await Archives.Compress([stuff], OutputFormat.Tgz, "backup", new ConversionOptions { OutputFolder = dir }, default);
        Directory.Delete(stuff, true);

        foreach (var file in Directory.GetFiles(dir).OrderBy(f => f))
            Console.WriteLine($"{new FileInfo(file).Length,10:N0}  {Path.GetFileName(file)}");
    }

    static void Add(ZipArchive zip, string name, string text, CompressionLevel level = CompressionLevel.Optimal)
    {
        var entry = zip.CreateEntry(name, level);
        using var stream = entry.Open();
        stream.Write(Encoding.UTF8.GetBytes(text));
    }

    public static void WriteZip(string path, Dictionary<string, string> files)
    {
        using var zip = ZipFile.Open(path, ZipArchiveMode.Create);
        foreach (var (name, text) in files) Add(zip, name, text, name == "mimetype" ? CompressionLevel.NoCompression : CompressionLevel.Optimal);
    }

    /// A photo-like picture with one clear subject: an orange ball lit from the top left, with a
    /// soft shadow, on a light grey backdrop with a little grain.
    public static MagickImage ProductShot(int w, int h)
    {
        var pixels = new byte[w * h * 3];
        var random = new Random(7);
        double cx = w * 0.5, cy = h * 0.47, r = Math.Min(w, h) * 0.3;
        // Light from the upper left, towards the viewer.
        double lx = -0.45, ly = -0.55, lz = 0.7, ll = Math.Sqrt(lx * lx + ly * ly + lz * lz);
        lx /= ll; ly /= ll; lz /= ll;
        for (var y = 0; y < h; y++)
        for (var x = 0; x < w; x++)
        {
            // Backdrop: a gentle fall-off from top to bottom, darker under the ball.
            double bg = 236 - 18.0 * y / h;
            double sx = (x - cx) / (r * 1.1), sy = (y - (cy + r * 0.98)) / (r * 0.22);
            bg -= 60 * Math.Exp(-(sx * sx + sy * sy) * 1.6);
            double red = bg, green = bg + 2, blue = bg + 6;
            double dx = (x - cx) / r, dy = (y - cy) / r, d2 = dx * dx + dy * dy;
            if (d2 <= 1)
            {
                var dz = Math.Sqrt(1 - d2);
                var diffuse = Math.Max(0, dx * lx + dy * ly + dz * lz);
                var hz = dz + lz; var hx = dx + lx; var hy = dy + ly;
                var spec = Math.Pow(Math.Max(0, (hx * lx + hy * ly + hz * lz) / Math.Sqrt(hx * hx + hy * hy + hz * hz)), 40);
                var shade = 0.22 + 0.78 * diffuse;
                // Anti-aliased rim.
                var edge = Math.Clamp((1 - Math.Sqrt(d2)) * r, 0, 1);
                double br = 236 * shade + 255 * spec * 0.8, bgc = 112 * shade + 255 * spec * 0.8, bb = 38 * shade + 255 * spec * 0.8;
                red = red + (br - red) * edge; green = green + (bgc - green) * edge; blue = blue + (bb - blue) * edge;
            }
            var grain = (random.NextDouble() - 0.5) * 6;
            var i = (y * w + x) * 3;
            pixels[i] = (byte)Math.Clamp(red + grain, 0, 255);
            pixels[i + 1] = (byte)Math.Clamp(green + grain, 0, 255);
            pixels[i + 2] = (byte)Math.Clamp(blue + grain, 0, 255);
        }
        return new MagickImage(pixels, new PixelReadSettings((uint)w, (uint)h, StorageType.Char, PixelMapping.RGB));
    }
}
