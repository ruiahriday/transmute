using System.IO.Compression;
using System.Text.Json;
using System.Text.Json.Serialization;
using ImageMagick;

namespace Transmute;

/// A ready-made text look: style, size and colour together.
public sealed record TextPreset(string Name, TextStyle Style, double SizeLevel, Rgba? Color);

/// Helpers for marking up screenshots: smoother pencil strokes, highlights that fit the text
/// under them, crops that snap to edges and keep a shape, text presets, and project files.
public static class Markup
{
    public static readonly TextPreset[] TextPresets =
    [
        new("Plain", TextStyle.Plain, 4, null),
        new("Title", TextStyle.Plain, 8, null),
        new("Outlined", TextStyle.Outlined, 5, null),
        new("Label", TextStyle.Label, 4, null),
        new("Shadow", TextStyle.Shadow, 5, null),
        new("Sticky note", TextStyle.Label, 3, new Rgba(0.99, 0.88, 0.28)),
        new("Small print", TextStyle.Plain, 2, null),
    ];

    /// Rounds off a hand-drawn stroke: drops points closer together than `minGap`, then cuts
    /// corners (Chaikin) a few times. Points are in any units; the ends stay where they were.
    public static List<NormPoint> Smooth(IReadOnlyList<NormPoint> points, int passes = 2, double minGap = 0.002)
    {
        if (points.Count < 3) return [.. points];
        var thinned = new List<NormPoint> { points[0] };
        foreach (var p in points.Skip(1))
        {
            var last = thinned[^1];
            if (Math.Abs(p.X - last.X) + Math.Abs(p.Y - last.Y) >= minGap) thinned.Add(p);
        }
        if (thinned[^1] != points[^1]) thinned.Add(points[^1]);
        var current = thinned;
        for (var pass = 0; pass < passes && current.Count >= 3; pass++)
        {
            var next = new List<NormPoint> { current[0] };
            for (var i = 0; i < current.Count - 1; i++)
            {
                var (a, b) = (current[i], current[i + 1]);
                next.Add(new NormPoint(0.75 * a.X + 0.25 * b.X, 0.75 * a.Y + 0.25 * b.Y));
                next.Add(new NormPoint(0.25 * a.X + 0.75 * b.X, 0.25 * a.Y + 0.75 * b.Y));
            }
            next.Add(current[^1]);
            current = next;
        }
        return current;
    }

    /// Shrinks a highlight's box, top and bottom, to the line of text inside it (with a little
    /// room), so a rough drag still marks the words neatly. Returns the box unchanged when there's
    /// no clear text in it.
    public static NormRect FitHighlight(BgraImage image, NormRect box)
    {
        int x0 = (int)Math.Floor(box.X * image.Width), y0 = (int)Math.Floor(box.Y * image.Height);
        int x1 = (int)Math.Ceiling(box.MaxX * image.Width), y1 = (int)Math.Ceiling(box.MaxY * image.Height);
        x0 = Math.Clamp(x0, 0, image.Width - 1); x1 = Math.Clamp(x1, x0 + 1, image.Width);
        y0 = Math.Clamp(y0, 0, image.Height - 1); y1 = Math.Clamp(y1, y0 + 1, image.Height);
        int w = x1 - x0, h = y1 - y0;
        if (w < 4 || h < 4) return box;
        // The background is the most common colour along the box's edges.
        var counts = new Dictionary<uint, int>();
        void Count(int x, int y) { var c = Pixel(image, x, y) & 0xF0F0F0; counts[c] = counts.GetValueOrDefault(c) + 1; }
        for (var x = x0; x < x1; x++) { Count(x, y0); Count(x, y1 - 1); }
        for (var y = y0; y < y1; y++) { Count(x0, y); Count(x1 - 1, y); }
        var bg = counts.MaxBy(kv => kv.Value).Key;
        int first = -1, last = -1;
        for (var y = y0; y < y1; y++)
        {
            var ink = 0;
            for (var x = x0; x < x1; x++) if (Distance(Pixel(image, x, y) & 0xF0F0F0, bg) > 60) ink++;
            if (ink > Math.Max(1, w / 100))
            {
                if (first < 0) first = y;
                last = y;
            }
        }
        if (first < 0 || last - first < 3) return box;
        var pad = Math.Max(2, (last - first + 1) * 0.18);
        var top = Math.Max(y0, first - pad);
        var bottom = Math.Min(y1, last + 1 + pad);
        return new NormRect(box.X, top / image.Height, box.Width, (bottom - top) / image.Height);
    }

    static uint Pixel(BgraImage image, int x, int y)
    {
        var i = (y * image.Width + x) * 4;
        return (uint)(image.Pixels[i] | image.Pixels[i + 1] << 8 | image.Pixels[i + 2] << 16);
    }

    static int Distance(uint a, uint b) =>
        Math.Abs((int)(a & 0xFF) - (int)(b & 0xFF)) + Math.Abs((int)(a >> 8 & 0xFF) - (int)(b >> 8 & 0xFF)) + Math.Abs((int)(a >> 16 & 0xFF) - (int)(b >> 16 & 0xFF));

    /// A crop dragged from `a` to `b`, kept to a width:height `ratio` (in pixels) when given,
    /// with edges that come within `snap` of the picture's edges or middle pulled onto them.
    public static NormRect Crop(NormPoint a, NormPoint b, int pixelWidth, int pixelHeight, double? ratio = null, double snap = 0.015)
    {
        double x0 = a.X, y0 = a.Y, x1 = b.X, y1 = b.Y;
        double S(double v) => Math.Abs(v) < snap ? 0 : Math.Abs(v - 1) < snap ? 1 : Math.Abs(v - 0.5) < snap / 2 ? 0.5 : v;
        x1 = S(x1); y1 = S(y1); x0 = S(x0); y0 = S(y0);
        if (ratio is { } r && r > 0)
        {
            var w = Math.Abs(x1 - x0) * pixelWidth;
            var h = Math.Abs(y1 - y0) * pixelHeight;
            if (w / Math.Max(1, h) > r) w = h * r; else h = w / r;
            x1 = x0 + Math.Sign(x1 - x0 == 0 ? 1 : x1 - x0) * w / pixelWidth;
            y1 = y0 + Math.Sign(y1 - y0 == 0 ? 1 : y1 - y0) * h / pixelHeight;
            // Keep it on the picture by sliding, not squashing.
            var rect = NormRect.Between(new NormPoint(x0, y0), new NormPoint(x1, y1));
            var dx = rect.X < 0 ? -rect.X : rect.MaxX > 1 ? 1 - rect.MaxX : 0;
            var dy = rect.Y < 0 ? -rect.Y : rect.MaxY > 1 ? 1 - rect.MaxY : 0;
            return new NormRect(Math.Max(0, rect.X + dx), Math.Max(0, rect.Y + dy), Math.Min(1, rect.Width), Math.Min(1, rect.Height));
        }
        return NormRect.Between(new NormPoint(Math.Clamp(x0, 0, 1), Math.Clamp(y0, 0, 1)), new NormPoint(Math.Clamp(x1, 0, 1), Math.Clamp(y1, 0, 1)));
    }

    /// The crop shapes offered in the editor; null is free.
    public static readonly (string Label, double? Ratio)[] CropShapes =
        [("Free", null), ("Square", 1), ("16:9", 16.0 / 9), ("4:3", 4.0 / 3), ("3:2", 1.5), ("4:5", 0.8), ("9:16", 9.0 / 16)];
}

/// A .spinform project: the original picture, any pictures placed on it and every edit, so the
/// marks stay editable later. It's a zip: edit.json, the original and the placed pictures.
public static class ImageProject
{
    public const string Extension = ".spinform";

    static readonly JsonSerializerOptions json = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    sealed record Manifest(int Version, string Original, ImageEdit Edit);

    public static void Save(string path, string original, ImageEdit edit)
    {
        var temp = path + ".saving";
        using (var zip = ZipFile.Open(temp, ZipArchiveMode.Create))
        {
            var name = "original" + Path.GetExtension(original).ToLowerInvariant();
            zip.CreateEntryFromFile(original, name, CompressionLevel.Fastest);
            var overlays = new List<PlacedImage>();
            for (var i = 0; i < edit.Overlays.Count; i++)
            {
                var o = edit.Overlays[i];
                if (!File.Exists(o.Path)) continue;
                var entry = $"pictures/{i}{Path.GetExtension(o.Path).ToLowerInvariant()}";
                zip.CreateEntryFromFile(o.Path, entry, CompressionLevel.Fastest);
                overlays.Add(o with { Path = entry });
            }
            var manifest = new Manifest(1, name, edit with { Overlays = overlays });
            using var stream = zip.CreateEntry("edit.json").Open();
            JsonSerializer.Serialize(stream, manifest, json);
        }
        File.Move(temp, path, true);
    }

    /// Unpacks a project into `folder`; returns the original's path there and the edit, with
    /// placed pictures pointing at their unpacked copies.
    public static (string Original, ImageEdit Edit) Load(string path, string folder)
    {
        Directory.CreateDirectory(folder);
        using var zip = ZipFile.OpenRead(path);
        var entry = zip.GetEntry("edit.json") ?? throw new ConversionException("That isn't a Spinform project.");
        Manifest manifest;
        using (var stream = entry.Open()) manifest = JsonSerializer.Deserialize<Manifest>(stream, json) ?? throw new ConversionException("That project is damaged.");
        string Extract(string name)
        {
            var target = Path.GetFullPath(Path.Combine(folder, name));
            if (!target.StartsWith(Path.GetFullPath(folder), StringComparison.OrdinalIgnoreCase)) throw new ConversionException("That project is damaged.");
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            (zip.GetEntry(name) ?? throw new ConversionException("That project is missing its picture.")).ExtractToFile(target, true);
            return target;
        }
        var original = Extract(manifest.Original);
        var overlays = manifest.Edit.Overlays.Select(o => o with { Path = Extract(o.Path) }).ToList();
        return (original, manifest.Edit with { Overlays = overlays });
    }
}
