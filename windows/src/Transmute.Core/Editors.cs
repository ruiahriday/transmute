using System.Globalization;
using ImageMagick;
using ImageMagick.Drawing;

namespace Transmute;

// Shared geometry: positions are fractions (0…1) of the picture, origin top-left, so they don't
// depend on how big the editor's preview is.

public readonly record struct NormPoint(double X, double Y)
{
    public NormPoint Clamped => new(Math.Clamp(X, 0, 1), Math.Clamp(Y, 0, 1));
}

public readonly record struct NormRect(double X, double Y, double Width, double Height)
{
    public static readonly NormRect Full = new(0, 0, 1, 1);
    public double MaxX => X + Width;
    public double MaxY => Y + Height;

    public static NormRect Between(NormPoint a, NormPoint b) =>
        new(Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Abs(a.X - b.X), Math.Abs(a.Y - b.Y));

    public NormRect Clamped
    {
        get
        {
            double x0 = Math.Clamp(X, 0, 1), y0 = Math.Clamp(Y, 0, 1), x1 = Math.Clamp(MaxX, 0, 1), y1 = Math.Clamp(MaxY, 0, 1);
            return new(x0, y0, Math.Max(0, x1 - x0), Math.Max(0, y1 - y0));
        }
    }

    public bool IsFull => X <= 0.0005 && Y <= 0.0005 && MaxX >= 0.9995 && MaxY >= 0.9995;

    /// Whole pixels in a picture of this size; never empty and never outside it.
    public (int X, int Y, int Width, int Height) Pixels(int width, int height)
    {
        var c = Clamped;
        var x0 = Math.Min((int)Math.Round(c.X * width), Math.Max(0, width - 1));
        var y0 = Math.Min((int)Math.Round(c.Y * height), Math.Max(0, height - 1));
        var x1 = Math.Max(x0 + 1, Math.Min((int)Math.Round(c.MaxX * width), width));
        var y1 = Math.Max(y0 + 1, Math.Min((int)Math.Round(c.MaxY * height), height));
        return (x0, y0, x1 - x0, y1 - y0);
    }
}

/// An sRGB colour, components 0…1.
public readonly record struct Rgba(double R, double G, double B, double A = 1)
{
    public static readonly Rgba Black = new(0, 0, 0), White = new(1, 1, 1), Red = new(0.93, 0.19, 0.16),
        Orange = new(1, 0.58, 0), Yellow = new(1, 0.84, 0.04), Green = new(0.2, 0.78, 0.35), Blue = new(0, 0.48, 1);
    public static readonly Rgba[] Swatches = [Red, Orange, Yellow, Green, Blue, White, Black];

    public Rgba WithAlpha(double a) => this with { A = a };
    static byte B8(double v) => (byte)Math.Round(Math.Clamp(v, 0, 1) * 255);
    public MagickColor Magick => MagickColor.FromRgba(B8(R), B8(G), B8(B), B8(A));
    public string Hex => $"{B8(R):X2}{B8(G):X2}{B8(B):X2}";
}

/// Pixelate scrambles each block a little so the original can't be rebuilt from it; Blur is a
/// smooth blur; SecureBlur shrinks, scrambles and blurs, so nothing readable survives.
public enum RedactionStyle { Blackout, Pixelate, Blur, SecureBlur }

public sealed record Redaction(NormRect Rect, RedactionStyle Style);

/// A picture dropped onto the editor's canvas, stretched into `Rect`.
public sealed record PlacedImage(string Path, NormRect Rect);

public enum AnnotationKind { Text, Rectangle, Arrow, Highlight, Ellipse, Line, Step, Spotlight, FilledRectangle, Pencil }

/// Arrow looks: a filled head, an open head, heads at both ends, or a curve.
public enum ArrowStyle { Filled, Open, Double, Curved }

/// Text looks: plain, with a contrasting outline, on a filled label, or with a soft shadow.
public enum TextStyle { Plain, Outlined, Label, Shadow }

/// Text: `Text` at `From` (its top-left). Rectangle, filled rectangle, oval, highlight and
/// spotlight: the box from `From` to `To`. Arrow and line: from `From` to `To`. Step: a numbered
/// circle centred on `From` showing `Text`. Pencil: the stroke through `Points`. `Size` is a
/// fraction of the picture's height: the font size for text and steps, the line width for the
/// rest. `Style` is an ArrowStyle for arrows and a TextStyle for text.
public sealed record Annotation(AnnotationKind Kind, NormPoint From, NormPoint To, Rgba Color, double Size, string Text = "",
    int Style = 0, IReadOnlyList<NormPoint>? Points = null);

/// Everything the photo editor can do to one picture.
public sealed record ImageEdit
{
    public NormRect? Crop { get; init; }
    /// Clockwise quarter turns.
    public int QuarterTurns { get; init; }
    public bool FlipHorizontal { get; init; }
    public bool FlipVertical { get; init; }
    /// -0.5…0.5
    public double Brightness { get; init; }
    /// 0.5…2
    public double Contrast { get; init; } = 1;
    /// 0…2
    public double Saturation { get; init; } = 1;
    /// -2…2 stops
    public double Exposure { get; init; }
    public IReadOnlyList<Redaction> Redactions { get; init; } = [];
    public IReadOnlyList<Annotation> Annotations { get; init; } = [];
    /// Remove or replace the background (null or Keep leaves it).
    public BackgroundEdit? Background { get; init; }
    /// null keeps the input format when Spinform can write it, otherwise PNG.
    public OutputFormat? OutputFormat { get; init; }
    /// 0.05…1: the result's size as a fraction of the (cropped) picture.
    public double Scale { get; init; } = 1;
    /// Other pictures placed on top, in the original's coordinates.
    public IReadOnlyList<PlacedImage> Overlays { get; init; } = [];

    public int Turns => ((QuarterTurns % 4) + 4) % 4;
    public bool HasColorAdjustments => Brightness != 0 || Contrast != 1 || Saturation != 1 || Exposure != 0;
}

public static class ImageEditEngine
{
    public static readonly OutputFormat[] Formats =
        [OutputFormat.Jpeg, OutputFormat.Png, OutputFormat.Webp, OutputFormat.Heic, OutputFormat.Tiff, OutputFormat.Bmp, OutputFormat.Gif];

    public static OutputFormat FormatFor(ImageEdit edit, string input)
    {
        if (edit.OutputFormat is { } chosen && Formats.Contains(chosen)) return chosen;
        var transparent = edit.Background is { KeepsTransparency: true };
        if (Kinds.FormatFor(Path.GetExtension(input)) is { } same && Formats.Contains(same) && (!transparent || Backgrounds.HoldsTransparency(same))) return same;
        return OutputFormat.Png;
    }

    public static async Task<JobResult> Apply(ImageEdit edit, string input, ConversionOptions options, CancellationToken token)
    {
        var format = FormatFor(edit, input);
        var output = OutputPaths.Destination(input, format.Extension(), "edited", options.OutputFolder);
        try
        {
            await Task.Run(() =>
            {
                using var image = Render(input, edit);
                image.Orientation = OrientationType.TopLeft;
                image.GetExifProfile()?.RemoveValue(ExifTag.Orientation);
                if (options.StripMetadata) image.Strip();
                if (format is OutputFormat.Jpeg or OutputFormat.Bmp && image.HasAlpha)
                {
                    image.BackgroundColor = MagickColors.White;
                    image.Alpha(AlphaOption.Remove);
                }
                if (format is OutputFormat.Jpeg or OutputFormat.Webp or OutputFormat.Heic) image.Quality = (uint)Math.Clamp(options.Quality * 100, 1, 100);
                image.Write(output, ImageConverter.MagickFormatFor(format));
            }, token);
        }
        catch
        {
            OutputPaths.TryDelete(output);
            throw;
        }
        return JobResult.Of(output);
    }

    /// The edited picture. Marks go on first, in the coordinates of the upright original, then the
    /// crop, colour changes, turns and flips.
    public static MagickImage Render(string input, ImageEdit edit)
    {
        var image = ImageConverter.LoadFirst(input);
        try
        {
            // The background first, so the subject is found in the untouched picture.
            if (edit.Background is { Mode: not BackgroundMode.Keep } background)
            {
                var replaced = Backgrounds.Apply(image, input, background);
                image.Dispose();
                image = replaced;
            }
            int w = (int)image.Width, h = (int)image.Height;
            foreach (var o in edit.Overlays) Place(image, o, w, h);
            foreach (var r in edit.Redactions) Redact(image, r, w, h);
            Spotlight(image, edit.Annotations.Where(a => a.Kind == AnnotationKind.Spotlight).ToList(), w, h);
            foreach (var a in edit.Annotations) Annotate(image, a, w, h);
            if (edit.Crop is { } crop && !crop.Clamped.IsFull)
            {
                var px = crop.Pixels(w, h);
                image.Crop(new MagickGeometry(px.X, px.Y, (uint)px.Width, (uint)px.Height));
                image.ResetPage();
            }
            if (edit.Exposure != 0) image.Evaluate(Channels.RGB, EvaluateOperator.Multiply, Math.Pow(2, Math.Clamp(edit.Exposure, -2, 2)));
            if (edit.Brightness != 0 || edit.Contrast != 1)
            {
                // Contrast around the middle grey, then brightness as an offset.
                var c = Math.Clamp(edit.Contrast, 0.5, 2);
                var b = Math.Clamp(edit.Brightness, -0.5, 0.5);
                var expression = $"(u-0.5)*{Num.D(c)}+0.5+{Num.D(b)}";
                image.Fx(expression, Channels.RGB);
            }
            if (edit.Saturation != 1) image.Modulate(new Percentage(100), new Percentage(Math.Clamp(edit.Saturation, 0, 2) * 100), new Percentage(100));
            if (edit.Turns != 0) image.Rotate(90 * edit.Turns);
            if (edit.FlipHorizontal) image.Flop();
            if (edit.FlipVertical) image.Flip();
            if (edit.Scale is > 0 and < 0.999)
            {
                var scale = Math.Clamp(edit.Scale, 0.05, 1);
                image.Resize(new MagickGeometry((uint)Math.Max(1, Math.Round(image.Width * scale)), (uint)Math.Max(1, Math.Round(image.Height * scale))) { IgnoreAspectRatio = true });
            }
            return image;
        }
        catch
        {
            image.Dispose();
            throw;
        }
    }

    static void Redact(MagickImage image, Redaction redaction, int w, int h)
    {
        var px = redaction.Rect.Pixels(w, h);
        if (px.Width < 1 || px.Height < 1) return;
        var area = new MagickGeometry(px.X, px.Y, (uint)px.Width, (uint)px.Height);
        // The same marks always give the same picture, so previews don't flicker.
        var random = new Random(HashCode.Combine(px.X, px.Y, px.Width, px.Height));
        switch (redaction.Style)
        {
            case RedactionStyle.Blackout:
                new Drawables().FillColor(MagickColors.Black).StrokeColor(MagickColors.Transparent)
                    .Rectangle(px.X, px.Y, px.X + px.Width, px.Y + px.Height).Draw(image);
                break;
            case RedactionStyle.Pixelate:
            {
                using var piece = (MagickImage)image.CloneArea(area);
                // Blocks about 1/40 of the picture's longer side, at least 8 pixels.
                var block = Math.Max(8, Math.Max(w, h) / 40);
                piece.FilterType = FilterType.Box;
                piece.Resize(new MagickGeometry((uint)Math.Max(1, px.Width / block), (uint)Math.Max(1, px.Height / block)) { IgnoreAspectRatio = true });
                Scramble(piece, random, 18);
                piece.FilterType = FilterType.Point;
                piece.Resize(new MagickGeometry((uint)px.Width, (uint)px.Height) { IgnoreAspectRatio = true });
                image.Composite(piece, px.X, px.Y, CompositeOperator.Over);
                break;
            }
            case RedactionStyle.Blur:
            {
                using var piece = (MagickImage)image.CloneArea(area);
                var sigma = Math.Max(6, Math.Max(w, h) / 90.0);
                piece.Blur(0, sigma);
                image.Composite(piece, px.X, px.Y, CompositeOperator.Over);
                break;
            }
            case RedactionStyle.SecureBlur:
            {
                using var piece = (MagickImage)image.CloneArea(area);
                var sigma = Math.Max(8, Math.Max(w, h) / 60.0);
                // Shrinking and scrambling first makes a heavy blur fast and impossible to undo.
                var small = Math.Max(4, Math.Max(w, h) / 120);
                piece.Resize(new MagickGeometry((uint)Math.Max(1, px.Width / small), (uint)Math.Max(1, px.Height / small)) { IgnoreAspectRatio = true });
                Scramble(piece, random, 24);
                piece.Resize(new MagickGeometry((uint)px.Width, (uint)px.Height) { IgnoreAspectRatio = true });
                piece.Blur(0, sigma / 2);
                image.Composite(piece, px.X, px.Y, CompositeOperator.Over);
                break;
            }
        }
    }

    /// Nudges every pixel of a (small) picture by a random amount, and swaps a few neighbours,
    /// so the blocks no longer hold the exact averages of what was under them.
    static void Scramble(MagickImage piece, Random random, int amount)
    {
        var data = piece.GetPixels().ToByteArray(PixelMapping.RGBA)!;
        const int stride = 4;
        for (var i = 0; i < data.Length; i += stride)
        {
            var shift = random.Next(-amount, amount + 1);
            for (var c = 0; c < 3; c++) data[i + c] = (byte)Math.Clamp(data[i + c] + shift + random.Next(-amount / 3, amount / 3 + 1), 0, 255);
        }
        var count = data.Length / stride;
        for (var n = 0; n < count / 6; n++)
        {
            int a = random.Next(count), b = Math.Clamp(a + random.Next(-2, 3), 0, count - 1);
            for (var c = 0; c < 3; c++) (data[a * stride + c], data[b * stride + c]) = (data[b * stride + c], data[a * stride + c]);
        }
        piece.ReadPixels(data, new PixelReadSettings(piece.Width, piece.Height, StorageType.Char, PixelMapping.RGBA));
    }

    static void Place(MagickImage image, PlacedImage placed, int w, int h)
    {
        if (!File.Exists(placed.Path)) return;
        var px = placed.Rect.Pixels(w, h);
        using var other = ImageConverter.LoadFirst(placed.Path);
        other.Resize(new MagickGeometry((uint)px.Width, (uint)px.Height) { IgnoreAspectRatio = true });
        image.Composite(other, px.X, px.Y, CompositeOperator.Over);
    }

    /// Dims everything outside the spotlit boxes.
    static void Spotlight(MagickImage image, IReadOnlyList<Annotation> spots, int w, int h)
    {
        if (spots.Count == 0) return;
        using var mask = new MagickImage(MagickColors.White, (uint)w, (uint)h);
        IDrawables<byte> d = new Drawables().FillColor(MagickColors.Black).StrokeColor(MagickColors.Transparent);
        foreach (var s in spots)
        {
            var r = NormRect.Between(s.From, s.To);
            var radius = Math.Min(r.Width * w, r.Height * h) * 0.08;
            d = d.RoundRectangle(r.X * w, r.Y * h, r.MaxX * w, r.MaxY * h, radius, radius);
        }
        d.Draw(mask);
        mask.Alpha(AlphaOption.Off);
        using var dim = new MagickImage(MagickColors.Black, (uint)w, (uint)h);
        dim.Alpha(AlphaOption.Set);
        dim.Composite(mask, CompositeOperator.CopyAlpha);
        dim.Evaluate(Channels.Alpha, EvaluateOperator.Multiply, 0.6);
        image.Composite(dim, 0, 0, CompositeOperator.Over);
    }

    static IDrawables<byte> TextDrawables(MagickColor fill, double size)
    {
        IDrawables<byte> d = new Drawables().FillColor(fill).StrokeColor(MagickColors.Transparent).FontPointSize(size).Gravity(Gravity.Northwest);
        if (Fonts.BoldSansFile() is { } font) d = d.Font(font);
        return d;
    }

    /// The colour that reads best on top of `c`: white on dark colours, near-black on light ones.
    public static Rgba Contrast(Rgba c) => 0.2126 * c.R + 0.7152 * c.G + 0.0722 * c.B > 0.6 ? new Rgba(0.08, 0.08, 0.12) : Rgba.White;

    static void Annotate(MagickImage image, Annotation a, int w, int h)
    {
        var size = Math.Max(1, a.Size * h);
        double x0 = a.From.X * w, y0 = a.From.Y * h, x1 = a.To.X * w, y1 = a.To.Y * h;
        var color = a.Color.Magick;
        switch (a.Kind)
        {
            case AnnotationKind.Text:
            {
                if (string.IsNullOrWhiteSpace(a.Text)) return;
                // Lines one under the other, the first with its top at the point.
                var lines = a.Text.Replace("\r", "").Split('\n');
                var style = (TextStyle)a.Style;
                if (style == TextStyle.Label)
                {
                    // A rounded label behind the text, sized from the longest line.
                    var longest = lines.Max(l => l.Length);
                    double bw = longest * size * 0.6 + size * 0.8, bh = lines.Length * size * 1.2 + size * 0.4;
                    new Drawables().FillColor(color).StrokeColor(MagickColors.Transparent)
                        .RoundRectangle(x0 - size * 0.4, y0 - size * 0.2, x0 - size * 0.4 + bw, y0 - size * 0.2 + bh, size * 0.3, size * 0.3).Draw(image);
                    color = Contrast(a.Color).Magick;
                }
                if (style is TextStyle.Outlined or TextStyle.Shadow)
                {
                    var under = style == TextStyle.Outlined ? Contrast(a.Color).Magick : MagickColor.FromRgba(0, 0, 0, 110);
                    var reach = style == TextStyle.Outlined ? Math.Max(1, size * 0.06) : Math.Max(1, size * 0.08);
                    var offsets = style == TextStyle.Outlined
                        ? new[] { (-1.0, 0.0), (1.0, 0.0), (0.0, -1.0), (0.0, 1.0), (-0.7, -0.7), (0.7, 0.7), (-0.7, 0.7), (0.7, -0.7) }
                        : new[] { (0.6, 0.9) };
                    foreach (var (ox, oy) in offsets)
                    {
                        var back = TextDrawables(under, size);
                        for (var i = 0; i < lines.Length; i++) back = back.Text(x0 + ox * reach, y0 + oy * reach + i * size * 1.2, lines[i]);
                        back.Draw(image);
                    }
                }
                var d = TextDrawables(color, size);
                for (var i = 0; i < lines.Length; i++) d = d.Text(x0, y0 + i * size * 1.2, lines[i]);
                d.Draw(image);
                break;
            }
            case AnnotationKind.Rectangle:
            {
                var r = NormRect.Between(a.From, a.To);
                new Drawables().FillColor(MagickColors.Transparent).StrokeColor(color).StrokeWidth(size).StrokeLineJoin(LineJoin.Round)
                    .Rectangle(r.X * w, r.Y * h, r.MaxX * w, r.MaxY * h).Draw(image);
                break;
            }
            case AnnotationKind.FilledRectangle:
            {
                var r = NormRect.Between(a.From, a.To);
                new Drawables().FillColor(color).StrokeColor(MagickColors.Transparent)
                    .Rectangle(r.X * w, r.Y * h, r.MaxX * w, r.MaxY * h).Draw(image);
                break;
            }
            case AnnotationKind.Ellipse:
            {
                var r = NormRect.Between(a.From, a.To);
                double rx = r.Width * w / 2, ry = r.Height * h / 2;
                if (rx < 1 || ry < 1) return;
                new Drawables().FillColor(MagickColors.Transparent).StrokeColor(color).StrokeWidth(size)
                    .Ellipse(r.X * w + rx, r.Y * h + ry, rx, ry, 0, 360).Draw(image);
                break;
            }
            case AnnotationKind.Highlight:
            {
                var r = NormRect.Between(a.From, a.To);
                new Drawables().FillColor(a.Color.WithAlpha(0.35).Magick).StrokeColor(MagickColors.Transparent)
                    .Rectangle(r.X * w, r.Y * h, r.MaxX * w, r.MaxY * h).Draw(image);
                break;
            }
            case AnnotationKind.Spotlight:
                break; // drawn together, before the other marks
            case AnnotationKind.Line:
                if (Math.Abs(x1 - x0) + Math.Abs(y1 - y0) < 1) return;
                new Drawables().StrokeColor(color).StrokeWidth(size).StrokeLineCap(LineCap.Round).FillColor(MagickColors.Transparent)
                    .Line(x0, y0, x1, y1).Draw(image);
                break;
            case AnnotationKind.Pencil:
            {
                var points = (a.Points ?? []).Select(p => new PointD(p.X * w, p.Y * h)).ToList();
                if (points.Count == 0) return;
                if (points.Count == 1) points.Add(new PointD(points[0].X + 0.5, points[0].Y + 0.5));
                new Drawables().StrokeColor(color).StrokeWidth(size).StrokeLineCap(LineCap.Round).StrokeLineJoin(LineJoin.Round)
                    .FillColor(MagickColors.Transparent).Polyline(points).Draw(image);
                break;
            }
            case AnnotationKind.Step:
            {
                var radius = Math.Max(6, size * 0.9);
                new Drawables().FillColor(color).StrokeColor(Rgba.White.Magick).StrokeWidth(Math.Max(1, radius * 0.12))
                    .Circle(x0, y0, x0 + radius, y0).Draw(image);
                var label = string.IsNullOrWhiteSpace(a.Text) ? "1" : a.Text.Trim();
                var font = radius * (label.Length > 1 ? 0.95 : 1.15);
                var d = new Drawables().FillColor(Contrast(a.Color).Magick).StrokeColor(MagickColors.Transparent).FontPointSize(font)
                    .TextAlignment(TextAlignment.Center);
                if (Fonts.BoldSansFile() is { } bold) d = d.Font(bold);
                d.Text(x0, y0 + font * 0.36, label).Draw(image);
                break;
            }
            case AnnotationKind.Arrow:
            {
                var length = Math.Sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0));
                if (length < 1) return;
                var style = (ArrowStyle)a.Style;
                var head = Math.Min(length * 0.5, size * 4.5);
                if (style == ArrowStyle.Curved)
                {
                    // A gentle bend to the left of the direction of travel; the head follows the curve's end.
                    double mx = (x0 + x1) / 2, my = (y0 + y1) / 2, nx = -(y1 - y0) / length, ny = (x1 - x0) / length;
                    double cx = mx + nx * length * 0.22, cy = my + ny * length * 0.22;
                    var curve = new List<PointD>();
                    for (var i = 0; i <= 32; i++)
                    {
                        var t = i / 32.0;
                        curve.Add(new PointD((1 - t) * (1 - t) * x0 + 2 * (1 - t) * t * cx + t * t * x1, (1 - t) * (1 - t) * y0 + 2 * (1 - t) * t * cy + t * t * y1));
                    }
                    double tx = x1 - cx, ty = y1 - cy, tl = Math.Max(1e-6, Math.Sqrt(tx * tx + ty * ty));
                    double ux = tx / tl, uy = ty / tl;
                    var shaft = curve.Where(p => (p.X - x1) * (p.X - x1) + (p.Y - y1) * (p.Y - y1) > head * head * 0.6).ToList();
                    if (shaft.Count >= 2)
                        new Drawables().StrokeColor(color).StrokeWidth(size).StrokeLineCap(LineCap.Round).StrokeLineJoin(LineJoin.Round)
                            .FillColor(MagickColors.Transparent).Polyline(shaft).Draw(image);
                    Head(image, x1, y1, ux, uy, head, size, color, filled: true);
                    break;
                }
                {
                    double ux = (x1 - x0) / length, uy = (y1 - y0) / length;
                    var filled = style != ArrowStyle.Open;
                    // The shaft stops where a filled head starts so its square end doesn't poke out.
                    double sx = x0, sy = y0, ex = filled ? x1 - ux * head * 0.8 : x1, ey = filled ? y1 - uy * head * 0.8 : y1;
                    if (style == ArrowStyle.Double) { sx = x0 + ux * head * 0.8; sy = y0 + uy * head * 0.8; }
                    new Drawables().StrokeColor(color).StrokeWidth(size).StrokeLineCap(LineCap.Round).FillColor(MagickColors.Transparent)
                        .Line(sx, sy, ex, ey).Draw(image);
                    Head(image, x1, y1, ux, uy, head, size, color, filled);
                    if (style == ArrowStyle.Double) Head(image, x0, y0, -ux, -uy, head, size, color, true);
                }
                break;
            }
        }
    }

    /// An arrowhead with its tip at (x, y) pointing along (ux, uy).
    static void Head(MagickImage image, double x, double y, double ux, double uy, double head, double size, MagickColor color, bool filled)
    {
        double bx = x - ux * head, by = y - uy * head;
        double px = -uy * head * 0.55, py = ux * head * 0.55;
        if (filled)
            new Drawables().FillColor(color).StrokeColor(MagickColors.Transparent)
                .Polygon(new PointD(x, y), new PointD(bx + px, by + py), new PointD(bx - px, by - py)).Draw(image);
        else
            new Drawables().StrokeColor(color).StrokeWidth(size).StrokeLineCap(LineCap.Round).StrokeLineJoin(LineJoin.Round).FillColor(MagickColors.Transparent)
                .Polyline(new PointD(bx + px, by + py), new PointD(x, y), new PointD(bx - px, by - py)).Draw(image);
    }
}

// Video

public enum CropAspect { Original, Square, Portrait9x16, Landscape16x9, Classic4x3 }

public sealed record VideoEdit
{
    public double TrimStart { get; init; }
    /// null means the end of the video.
    public double? TrimEnd { get; init; }
    /// 0.25…4
    public double Speed { get; init; } = 1;
    public CropAspect Crop { get; init; }
    public int QuarterTurns { get; init; }
    public bool FlipHorizontal { get; init; }
    public bool Mute { get; init; }
    /// 0…2
    public double Volume { get; init; } = 1;
    /// When set, the result is two files split here (seconds into the original).
    public double? SplitAt { get; init; }
    public OutputFormat? OutputFormat { get; init; }
}

public static class VideoEditEngine
{
    public static readonly OutputFormat[] Formats = [OutputFormat.Mp4, OutputFormat.Mov, OutputFormat.Mkv, OutputFormat.Webm];

    public static string Label(this CropAspect aspect) => aspect switch
    {
        CropAspect.Square => "Square 1:1",
        CropAspect.Portrait9x16 => "Portrait 9:16",
        CropAspect.Landscape16x9 => "Landscape 16:9",
        CropAspect.Classic4x3 => "Classic 4:3",
        _ => "Original",
    };

    static (int W, int H)? Ratio(CropAspect aspect) => aspect switch
    {
        CropAspect.Square => (1, 1),
        CropAspect.Portrait9x16 => (9, 16),
        CropAspect.Landscape16x9 => (16, 9),
        CropAspect.Classic4x3 => (4, 3),
        _ => null,
    };

    public static OutputFormat FormatFor(VideoEdit edit, string input)
    {
        if (edit.OutputFormat is { } chosen && Formats.Contains(chosen)) return chosen;
        if (Kinds.FormatFor(Path.GetExtension(input)) is { } same && Formats.Contains(same)) return same;
        return OutputFormat.Mp4;
    }

    sealed record Segment(double Start, double? End, string Suffix)
    {
        public double Length(double total) => (End ?? total) > Start ? (End ?? total) - Start : 0;
    }

    public static async Task<JobResult> Apply(VideoEdit edit, string input, ConversionOptions options, ProgressHandler progress, CancellationToken token)
    {
        var ffmpeg = Tools.RequireFfmpeg("Editing video");
        if (edit.OutputFormat is { } chosen && !Formats.Contains(chosen))
            throw new ConversionException($"Edited videos can be saved as MP4, MOV, MKV or WebM, not {chosen.Label()}.");
        var format = FormatFor(edit, input);
        var banner = await MediaInfo.Banner(input, token);
        var sourceLength = MediaInfo.ParseDuration(banner) ?? 0;
        var speed = double.IsFinite(edit.Speed) ? Math.Clamp(edit.Speed, 0.25, 4) : 1;

        var start = double.IsFinite(edit.TrimStart) ? Math.Max(0, edit.TrimStart) : 0;
        var stop = edit.TrimEnd is { } e && double.IsFinite(e) ? e : (double?)null;
        if (stop is { } end1 && sourceLength > 0 && end1 >= sourceLength - 0.001) stop = null;
        if (sourceLength > 0 && start >= sourceLength - 0.01) throw new ConversionException("The start point is past the end of the video.");
        if (stop is { } end2 && end2 <= start + 0.01) throw new ConversionException("The end point has to come after the start point.");

        List<Segment> segments;
        if (edit.SplitAt is { } split)
        {
            var last = stop ?? (sourceLength > 0 ? sourceLength : double.PositiveInfinity);
            if (!double.IsFinite(split) || split <= start + 0.05 || split >= last - 0.05)
                throw new ConversionException("The split point has to fall inside the part you're keeping.");
            segments = [new(start, split, "part 1"), new(split, stop, "part 2")];
        }
        else segments = [new(start, stop, "edited")];

        var keepAudio = !edit.Mute && MediaInfo.StreamLines(banner, "Audio").Any();
        // The sound track ffmpeg can decode (iPhones add a spatial-audio one it can't).
        var audioMap = MediaStreams.Parse(banner).AudioSpec ?? "0:a:0";
        var videoChain = string.Join(",", VideoFilters(edit, speed));
        var audioChain = string.Join(",", AudioFilters(edit, speed));
        var totalWork = segments.Sum(s => s.Length(sourceLength));
        var outputs = new List<string>();
        var finished = 0.0;
        try
        {
            foreach (var segment in segments)
            {
                var output = OutputPaths.Destination(input, format.Extension(), segment.Suffix, options.OutputFolder);
                outputs.Add(output);
                var part = segment.Length(sourceLength);
                var before = finished;
                ProgressHandler report = f => { if (totalWork > 0) progress(Math.Min(1, (before + f * part) / totalWork)); };
                var args = new List<string> { "-hide_banner", "-nostdin", "-y", "-progress", "pipe:1", "-nostats" };
                // -ss/-t before -i seek fast and stay frame-accurate because the video is re-encoded.
                if (segment.Start > 0) args.AddRange(["-ss", Num.D(segment.Start, 3)]);
                if (segment.End is { } end) args.AddRange(["-t", Num.D(end - segment.Start, 3)]);
                args.AddRange(["-i", input, "-map", "0:V:0"]);
                if (keepAudio)
                {
                    args.AddRange(["-map", audioMap]);
                    if (audioChain.Length > 0) args.AddRange(["-af", audioChain]);
                }
                else args.Add("-an");
                args.AddRange(["-vf", videoChain, "-map_chapters", "-1"]);
                if (options.StripMetadata) args.AddRange(["-map_metadata", "-1"]);
                args.AddRange(EncoderArgs(format, keepAudio));
                args.Add(output);
                await Shell.Check(ffmpeg, args, token, onStdoutLine: FfmpegProgress.ForSeconds(part / speed, report));
                finished += part;
            }
        }
        catch
        {
            outputs.ForEach(OutputPaths.TryDelete);
            throw;
        }
        progress(1);
        var lengths = segments.Select(s => s.Length(sourceLength) / speed).ToList();
        string? message = lengths.Any(l => l <= 0) ? null
            : lengths.Count == 2 ? $"Parts: {MediaInfo.TimeLabel(lengths[0], true)} and {MediaInfo.TimeLabel(lengths[1], true)}"
            : $"Length {MediaInfo.TimeLabel(lengths[0], true)}";
        return new JobResult(outputs, message);
    }

    public static List<string> VideoFilters(VideoEdit edit, double speed)
    {
        var filters = new List<string>();
        if (Math.Abs(speed - 1) > 0.001) filters.Add($"setpts=(PTS-STARTPTS)/{Num.D(speed)}");
        if (Ratio(edit.Crop) is { } r)
        {
            filters.Add("scale=w='trunc(iw*sar/2)*2':h=ih");
            filters.Add("setsar=1");
            filters.Add($"crop=w='trunc(min(iw,ih*{r.W}/{r.H})/2)*2':h='trunc(min(ih,iw*{r.H}/{r.W})/2)*2'");
        }
        switch (((edit.QuarterTurns % 4) + 4) % 4)
        {
            case 1: filters.Add("transpose=1"); break;
            case 2: filters.AddRange(["hflip", "vflip"]); break;
            case 3: filters.Add("transpose=2"); break;
        }
        if (edit.FlipHorizontal) filters.Add("hflip");
        filters.Add("scale=trunc(iw/2)*2:trunc(ih/2)*2");
        return filters;
    }

    public static List<string> AudioFilters(VideoEdit edit, double speed)
    {
        var filters = AtempoStages(speed).Select(s => $"atempo={Num.D(s)}").ToList();
        var volume = double.IsFinite(edit.Volume) ? Math.Clamp(edit.Volume, 0, 2) : 1;
        if (Math.Abs(volume - 1) > 0.001) filters.Add($"volume={Num.D(volume)}");
        return filters;
    }

    /// atempo only takes 0.5…2 per stage, so bigger changes are chained.
    public static List<double> AtempoStages(double speed)
    {
        var stages = new List<double>();
        var rest = speed;
        while (rest > 2.000001) { stages.Add(2); rest /= 2; }
        while (rest < 0.499999) { stages.Add(0.5); rest /= 0.5; }
        if (Math.Abs(rest - 1) > 0.000001) stages.Add(rest);
        return stages;
    }

    static List<string> EncoderArgs(OutputFormat format, bool audio)
    {
        List<string> args;
        if (format == OutputFormat.Webm)
        {
            args = [.. Tools.WebmVideo(30, null), "-pix_fmt", "yuv420p"];
            if (audio) args.AddRange(["-c:a", "libopus", "-b:a", "128k"]);
        }
        else
        {
            args = ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p"];
            if (audio) args.AddRange(["-c:a", "aac", "-b:a", "192k"]);
            if (format != OutputFormat.Mkv) args.AddRange(["-movflags", "+faststart"]);
        }
        return args;
    }

    /// Plays several videos one after another in one MP4, each fitted into the first one's frame.
    public static async Task<string> Join(IReadOnlyList<string> inputs, ConversionOptions options, ProgressHandler progress, CancellationToken token)
    {
        if (inputs.Count < 2) throw new ConversionException("Choose at least two videos to join.");
        var ffmpeg = Tools.RequireFfmpeg("Joining videos");
        var banners = new List<string>();
        foreach (var input in inputs) banners.Add(await MediaInfo.Banner(input, token));
        var size = MediaInfo.ParseFrameSize(banners[0]) ?? (1920, 1080);
        int width = Math.Max(2, size.Width / 2 * 2), height = Math.Max(2, size.Height / 2 * 2);
        var durations = banners.Select(b => MediaInfo.ParseDuration(b) ?? 0).ToList();
        var sound = banners.Select(b => MediaInfo.StreamLines(b, "Audio").Any()).ToList();
        var withAudio = sound.Contains(true);
        const string audioFormat = "aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo";

        var args = new List<string> { "-hide_banner", "-nostdin", "-y", "-progress", "pipe:1", "-nostats" };
        foreach (var input in inputs) args.AddRange(["-i", input]);
        var graph = new List<string>();
        var concat = "";
        for (var i = 0; i < inputs.Count; i++)
        {
            graph.Add($"[{i}:v:0]scale={width}:{height}:force_original_aspect_ratio=decrease,pad={width}:{height}:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,fps=30,format=yuv420p,setpts=PTS-STARTPTS[v{i}]");
            concat += $"[v{i}]";
            if (!withAudio) continue;
            if (sound[i]) graph.Add($"[{i}:a:0]aresample=48000,{audioFormat},asetpts=PTS-STARTPTS[a{i}]");
            else
            {
                var silence = durations[i] > 0 ? durations[i] : 0.1;
                graph.Add($"anullsrc=channel_layout=stereo:sample_rate=48000,atrim=duration={Num.D(silence)},{audioFormat},asetpts=PTS-STARTPTS[a{i}]");
            }
            concat += $"[a{i}]";
        }
        graph.Add($"{concat}concat=n={inputs.Count}:v=1:a={(withAudio ? 1 : 0)}[outv]{(withAudio ? "[outa]" : "")}");
        args.AddRange(["-filter_complex", string.Join(";", graph), "-map", "[outv]"]);
        if (withAudio) args.AddRange(["-map", "[outa]"]);
        args.AddRange(["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p"]);
        if (withAudio) args.AddRange(["-c:a", "aac", "-b:a", "192k"]);
        args.AddRange(["-movflags", "+faststart"]);
        if (options.StripMetadata) args.AddRange(["-map_metadata", "-1"]);
        var dir = options.OutputFolder ?? Path.GetDirectoryName(Path.GetFullPath(inputs[0]))!;
        var output = OutputPaths.Unique(dir, "Joined", "mp4");
        args.Add(output);
        try
        {
            await Shell.Check(ffmpeg, args, token, onStdoutLine: FfmpegProgress.ForSeconds(durations.Sum(), progress));
        }
        catch
        {
            OutputPaths.TryDelete(output);
            throw;
        }
        progress(1);
        return output;
    }

    /// The frame at `seconds` as a PNG.
    public static async Task<string> Snapshot(string input, double seconds, ConversionOptions options, CancellationToken token)
    {
        var ffmpeg = Tools.RequireFfmpeg("Taking a snapshot");
        var time = double.IsFinite(seconds) ? Math.Max(0, seconds) : 0;
        var length = await MediaInfo.Duration(input, token);
        if (length > 0 && time > length - 0.04) time = Math.Max(0, length - 0.04);
        var output = OutputPaths.Destination(input, "png", $"frame {Num.Compact(time)}s", options.OutputFolder);
        try
        {
            await Shell.Check(ffmpeg, ["-hide_banner", "-nostdin", "-y", "-ss", Num.D(time, 3), "-i", input,
                "-map", "0:V:0", "-frames:v", "1", "-update", "1", output], token);
            if (OutputPaths.FileSize(output) == 0) throw new ConversionException($"There's no frame at {MediaInfo.TimeLabel(time, true)}.");
        }
        catch
        {
            OutputPaths.TryDelete(output);
            throw;
        }
        return output;
    }

    /// A small JPEG of the frame at `seconds`, for the editor's preview.
    public static async Task<byte[]?> PreviewFrame(string input, double seconds, int maxWidth, CancellationToken token)
    {
        var ffmpeg = Tools.Ffmpeg;
        if (ffmpeg is null) return null;
        var temp = OutputPaths.TempFile("jpg");
        try
        {
            var result = await Shell.Run(ffmpeg, ["-hide_banner", "-nostdin", "-y", "-ss", Num.D(Math.Max(0, seconds), 3), "-i", input,
                "-map", "0:V:0", "-frames:v", "1", "-vf", $"scale='min({maxWidth},iw)':-2", "-q:v", "4", "-update", "1", temp], token);
            return result.Status == 0 && File.Exists(temp) ? await File.ReadAllBytesAsync(temp, token) : null;
        }
        finally
        {
            OutputPaths.TryDelete(temp);
        }
    }
}

// Audio

public enum ChannelMode { Keep, Mono, Stereo, SwapLeftRight }

public sealed record BleepRange(double Start, double End);

public sealed record AudioEdit
{
    public double TrimStart { get; init; }
    public double? TrimEnd { get; init; }
    /// EBU R128 loudness to -16 LUFS.
    public bool Normalize { get; init; }
    /// -20…20 dB
    public double VolumeDb { get; init; }
    public double FadeIn { get; init; }
    public double FadeOut { get; init; }
    public IReadOnlyList<BleepRange> Bleeps { get; init; } = [];
    public ChannelMode Channels { get; init; }
    public OutputFormat? OutputFormat { get; init; }
}

public static class AudioEditEngine
{
    public static readonly OutputFormat[] Formats =
        [OutputFormat.Mp3, OutputFormat.M4a, OutputFormat.Wav, OutputFormat.Flac, OutputFormat.Ogg, OutputFormat.Opus, OutputFormat.Aiff];

    public static string Label(this ChannelMode mode) => mode switch
    {
        ChannelMode.Mono => "Mono",
        ChannelMode.Stereo => "Stereo",
        ChannelMode.SwapLeftRight => "Swap left and right",
        _ => "Keep",
    };

    public static OutputFormat FormatFor(AudioEdit edit, string input)
    {
        if (edit.OutputFormat is { } chosen && Formats.Contains(chosen)) return chosen;
        if (Kinds.FormatFor(Path.GetExtension(input)) is { } same && Formats.Contains(same)) return same;
        return OutputFormat.M4a;
    }

    const string OutputLabel = "aout";

    public static async Task<JobResult> Apply(AudioEdit edit, string input, ConversionOptions options, ProgressHandler progress, CancellationToken token)
    {
        var ffmpeg = Tools.RequireFfmpeg("Editing audio");
        if (edit.OutputFormat is { } chosen && !Formats.Contains(chosen))
            throw new ConversionException($"Edited audio can be saved as MP3, M4A, WAV, FLAC, OGG, Opus or AIFF, not {chosen.Label()}.");
        var banner = await MediaInfo.Banner(input, token);
        var track = MediaInfo.ParseSoundTrack(banner) ?? throw new ConversionException($"{Path.GetFileName(input)} has no sound to edit.");
        var format = FormatFor(edit, input);
        var plan = FilterGraph(edit, MediaInfo.ParseDuration(banner) ?? 0, track);
        if (MediaStreams.Parse(banner).AudioSpec is { } spec && spec != "0:a:0")
            plan.Graph = plan.Graph.Replace("[0:a:0]", $"[{spec}]");
        var output = OutputPaths.Destination(input, format.Extension(), "edited", options.OutputFolder);
        var args = new List<string> { "-hide_banner", "-nostdin", "-y", "-progress", "pipe:1", "-nostats", "-i", input,
            "-filter_complex", plan.Graph, "-map", $"[{OutputLabel}]", "-vn", "-map_chapters", "-1" };
        if (options.StripMetadata) args.AddRange(["-map_metadata", "-1"]);
        args.AddRange(EncoderArgs(format));
        args.Add(output);
        try
        {
            await Shell.Check(ffmpeg, args, token, onStdoutLine: FfmpegProgress.ForSeconds(plan.Seconds, progress));
        }
        catch
        {
            OutputPaths.TryDelete(output);
            throw;
        }
        progress(1);
        return new JobResult([output], plan.Seconds > 0 ? $"Length {MediaInfo.TimeLabel(plan.Seconds, true)}" : null);
    }

    /// The -filter_complex graph and the result's length (0 when unknown). Bleeps come first so
    /// their times are on the original timeline, then trim, loudness, gain, fades and channels.
    public static (string Graph, double Seconds) FilterGraph(AudioEdit edit, double sourceLength, MediaInfo.SoundTrack track)
    {
        var start = double.IsFinite(edit.TrimStart) ? Math.Max(0, edit.TrimStart) : 0;
        var stop = edit.TrimEnd is { } e && double.IsFinite(e) ? e : (double?)null;
        if (stop is { } end1 && sourceLength > 0 && end1 >= sourceLength - 0.001) stop = null;
        if (sourceLength > 0 && start >= sourceLength - 0.01) throw new ConversionException("The start point is past the end of the audio.");
        if (stop is { } end2 && end2 <= start + 0.01) throw new ConversionException("The end point has to come after the start point.");
        var keptEnd = stop ?? sourceLength;
        var seconds = keptEnd > start ? keptEnd - start : 0;

        var chain = new List<string>();
        if (start > 0.0005 || stop is not null)
        {
            var trim = $"atrim=start={Num.D(start)}";
            if (stop is { } end) trim += $":end={Num.D(end)}";
            chain.AddRange([trim, "asetpts=PTS-STARTPTS"]);
        }
        var rate = track.SampleRate ?? 48000;
        if (edit.Normalize) chain.AddRange(["loudnorm=I=-16:TP=-1.5:LRA=11", $"aresample={rate}", "asetpts=STARTPTS+N/SR/TB"]);
        var gain = double.IsFinite(edit.VolumeDb) ? Math.Clamp(edit.VolumeDb, -20, 20) : 0;
        if (Math.Abs(gain) > 0.01) chain.Add($"volume={Num.D(Math.Pow(10, gain / 20))}");
        var fadeIn = double.IsFinite(edit.FadeIn) ? Math.Max(0, edit.FadeIn) : 0;
        if (seconds > 0) fadeIn = Math.Min(fadeIn, seconds);
        if (fadeIn > 0.001) chain.Add($"afade=t=in:st=0:d={Num.D(fadeIn)}");
        var fadeOut = double.IsFinite(edit.FadeOut) ? Math.Max(0, edit.FadeOut) : 0;
        if (fadeOut > 0.001)
        {
            if (seconds <= 0) throw new ConversionException("Couldn't read the length of the audio, which the fade-out needs.");
            var length = Math.Min(fadeOut, seconds);
            chain.Add($"afade=t=out:st={Num.D(seconds - length)}:d={Num.D(length)}");
        }
        chain.AddRange(ChannelFilters(edit.Channels, track.Channels));
        var tail = chain.Count == 0 ? "anull" : string.Join(",", chain);
        var ranges = edit.Bleeps
            .Where(r => double.IsFinite(r.Start) && double.IsFinite(r.End) && r.End > Math.Max(0, r.Start) + 0.001)
            .Select(r => r with { Start = Math.Max(0, r.Start) }).OrderBy(r => r.Start).ToList();
        if (ranges.Count == 0) return ($"[0:a:0]{tail}[{OutputLabel}]", seconds);
        // Each bleeped sample becomes a 1 kHz tone at -12 dBFS on every channel.
        var inside = string.Join("+", ranges.Select(r => $"between(t,{Num.D(r.Start)},{Num.D(r.End)})"));
        var near = string.Join("+", ranges.Select(r => $"between(t,{Num.D(Math.Max(0, r.Start - 0.1))},{Num.D(r.End)})"));
        var bleep = $"aeval=exprs='if({inside},0.25*sin(2*PI*1000*t),val(ch))':c=same:enable='{near}'";
        return ($"[0:a:0]asetnsamples=n=256:p=0,{bleep},{tail}[{OutputLabel}]", seconds);
    }

    public static List<string> ChannelFilters(ChannelMode mode, int? inputChannels) => mode switch
    {
        ChannelMode.Mono => inputChannels == 1 ? [] : inputChannels == 2 ? ["pan=mono|c0=0.5*c0+0.5*c1"] : ["aformat=channel_layouts=mono"],
        ChannelMode.Stereo => inputChannels == 1 ? ["pan=stereo|c0=c0|c1=c0"] : inputChannels == 2 ? [] : ["aformat=channel_layouts=stereo"],
        ChannelMode.SwapLeftRight => inputChannels == 1 ? [] : inputChannels == 2 ? ["pan=stereo|c0=c1|c1=c0"] : ["aformat=channel_layouts=stereo", "pan=stereo|c0=c1|c1=c0"],
        _ => [],
    };

    static string[] EncoderArgs(OutputFormat format) => format switch
    {
        OutputFormat.Mp3 => ["-c:a", "libmp3lame", "-q:a", "2"],
        OutputFormat.Wav => ["-c:a", "pcm_s16le"],
        OutputFormat.Flac => ["-c:a", "flac"],
        OutputFormat.Ogg => ["-c:a", "libvorbis", "-q:a", "5"],
        OutputFormat.Opus => ["-c:a", "libopus", "-b:a", "128k"],
        OutputFormat.Aiff => ["-c:a", "pcm_s16be"],
        _ => ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"],
    };

    /// Peak levels 0…1 in `buckets` equal slices of the whole file, for drawing.
    public static async Task<float[]> Waveform(string input, int buckets, CancellationToken token)
    {
        var ffmpeg = Tools.RequireFfmpeg("Drawing the waveform");
        var raw = OutputPaths.TempFile("pcm");
        try
        {
            var banner = await MediaInfo.Banner(input, token);
            if (MediaInfo.ParseSoundTrack(banner) is null) throw new ConversionException($"{Path.GetFileName(input)} has no sound.");
            var audioMap = MediaStreams.Parse(banner).AudioSpec ?? "0:a:0";
            await Shell.Check(ffmpeg, ["-hide_banner", "-nostdin", "-nostats", "-loglevel", "error", "-i", input, "-map", audioMap, "-vn",
                "-af", "aresample=async=1:first_pts=0", "-f", "s16le", "-ac", "1", "-ar", "8000", "-"], token, stdoutFile: raw);
            return Peaks(await File.ReadAllBytesAsync(raw, token), Math.Max(1, buckets));
        }
        finally
        {
            OutputPaths.TryDelete(raw);
        }
    }

    public static float[] Peaks(byte[] pcm16, int buckets)
    {
        var samples = pcm16.Length / 2;
        if (samples == 0 || buckets <= 0) return [];
        var levels = new float[buckets];
        for (var b = 0; b < buckets; b++)
        {
            var from = Math.Min(samples - 1, (int)((long)b * samples / buckets));
            var to = Math.Min(samples, Math.Max(from + 1, (int)((long)(b + 1) * samples / buckets)));
            var peak = 0;
            for (var i = from; i < to; i++)
                peak = Math.Max(peak, Math.Abs((int)BitConverter.ToInt16(pcm16, 2 * i)));
            levels[b] = peak / 32768f;
        }
        return levels;
    }
}
