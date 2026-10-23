using ImageMagick;
using ImageMagick.Drawing;

namespace Transmute;

public enum FrameBackground { Gradient, Solid, Picture, Transparent }

public enum FrameAspect { Fit, Square, Wide, Classic, Portrait, Story }

public enum FrameAlign { Center, Top, Bottom, Left, Right, TopLeft, TopRight, BottomLeft, BottomRight }

/// A picture placed on a background: space around it, rounded corners, a shadow and an optional
/// fixed shape. Colours are RRGGBB text so the style saves cleanly in settings.
public sealed record FrameStyle
{
    public FrameBackground Background { get; init; } = FrameBackground.Gradient;
    public string From { get; init; } = "4338CA";
    public string To { get; init; } = "EC4899";
    /// Degrees: 45 runs from the top-left corner to the bottom-right.
    public double Angle { get; init; } = 45;
    /// For Picture: the image behind (scaled to fill).
    public string? PicturePath { get; init; }
    /// Space around the picture, as a fraction of its longer side (0…0.5).
    public double Padding { get; init; } = 0.08;
    /// Corner radius, as a fraction of the picture's shorter side (0…0.25).
    public double Corners { get; init; } = 0.025;
    /// 0…1
    public double Shadow { get; init; } = 0.6;
    public FrameAspect Aspect { get; init; } = FrameAspect.Fit;
    public FrameAlign Align { get; init; } = FrameAlign.Center;
    /// Evens out lopsided plain margins in the picture so its content sits in the middle.
    public bool AutoBalance { get; init; }
}

public sealed record FramePreset(string Id, string Name, FrameStyle Style, bool Custom = false);

public static class Frames
{
    public static string Label(this FrameAspect aspect) => aspect switch
    {
        FrameAspect.Square => "1:1",
        FrameAspect.Wide => "16:9",
        FrameAspect.Classic => "4:3",
        FrameAspect.Portrait => "4:5",
        FrameAspect.Story => "9:16",
        _ => "Fit",
    };

    public static string Help(this FrameAspect aspect) => aspect switch
    {
        FrameAspect.Square => "Square, for social posts",
        FrameAspect.Wide => "Widescreen, for slides and video",
        FrameAspect.Classic => "4:3, for slides and documents",
        FrameAspect.Portrait => "4:5, for portrait posts",
        FrameAspect.Story => "9:16, for stories and reels",
        _ => "Just the space around the picture",
    };

    /// Width ÷ height, or null for Fit.
    public static double? Ratio(this FrameAspect aspect) => aspect switch
    {
        FrameAspect.Square => 1,
        FrameAspect.Wide => 16.0 / 9,
        FrameAspect.Classic => 4.0 / 3,
        FrameAspect.Portrait => 4.0 / 5,
        FrameAspect.Story => 9.0 / 16,
        _ => null,
    };

    static FramePreset Gradient(string name, string from, string to) =>
        new("builtin." + name, name, new FrameStyle { Background = FrameBackground.Gradient, From = from, To = to });

    static FramePreset Solid(string name, string color) =>
        new("builtin." + name, name, new FrameStyle { Background = FrameBackground.Solid, From = color, To = color });

    /// Twenty built-in looks; the first six are the Background tool's gradients.
    public static readonly FramePreset[] BuiltIn =
    [
        .. Backgrounds.Gradients.Select(g => Gradient(g.Name, g.From.Hex, g.To.Hex)),
        Gradient("Lavender", "EDE9FE", "A78BFA"),
        Gradient("Peach", "FFEDD5", "FB7185"),
        Gradient("Ocean", "38BDF8", "1E3A8A"),
        Gradient("Forest", "BBF7D0", "166534"),
        Gradient("Candy", "F9A8D4", "818CF8"),
        Gradient("Lagoon", "2DD4BF", "3B82F6"),
        Gradient("Citrus", "FDE68A", "F97316"),
        Gradient("Aurora", "34D399", "6366F1"),
        Gradient("Rose", "FECDD3", "E11D48"),
        Gradient("Sand", "FEF3C7", "D6A77A"),
        Gradient("Dusk", "818CF8", "312E81"),
        Solid("Paper", "FFFFFF"),
        Solid("Mist", "E2E8F0"),
        Solid("Graphite", "27272A"),
    ];

    /// The canvas size and where the picture goes on it, in pixels.
    public static (int CanvasWidth, int CanvasHeight, int X, int Y) Layout(int width, int height, FrameStyle style)
    {
        var w = Math.Max(1, width);
        var h = Math.Max(1, height);
        var pad = (int)Math.Round(Math.Clamp(style.Padding, 0, 0.5) * Math.Max(w, h));
        double cw = w + 2 * pad, ch = h + 2 * pad;
        if (style.Aspect.Ratio() is { } ratio)
        {
            if (cw / ch < ratio) cw = Math.Round(ch * ratio);
            else ch = Math.Round(cw / ratio);
        }
        int canvasW = (int)cw, canvasH = (int)ch;
        int left = Math.Min(pad, (canvasW - w) / 2), top = Math.Min(pad, (canvasH - h) / 2);
        int centreX = (canvasW - w) / 2, centreY = (canvasH - h) / 2;
        int right = canvasW - w - left, bottom = canvasH - h - top;
        var x = style.Align switch
        {
            FrameAlign.Left or FrameAlign.TopLeft or FrameAlign.BottomLeft => left,
            FrameAlign.Right or FrameAlign.TopRight or FrameAlign.BottomRight => right,
            _ => centreX,
        };
        var y = style.Align switch
        {
            FrameAlign.Top or FrameAlign.TopLeft or FrameAlign.TopRight => top,
            FrameAlign.Bottom or FrameAlign.BottomLeft or FrameAlign.BottomRight => bottom,
            _ => centreY,
        };
        return (canvasW, canvasH, x, y);
    }

    public static int CornerRadius(int width, int height, FrameStyle style) =>
        (int)Math.Round(Math.Clamp(style.Corners, 0, 0.25) * Math.Min(width, height));

    /// The picture's content box once plain margins are evened out: the part that differs from
    /// the corner colour, with the smaller margin kept on both sides of each axis.
    public static (int X, int Y, int Width, int Height) Balanced(BgraImage image)
    {
        int w = image.Width, h = image.Height;
        var p = image.Pixels;
        var corner = BitConverter.ToUInt32(p, 0);
        bool Differs(int x, int y)
        {
            var v = BitConverter.ToUInt32(p, (y * w + x) * 4);
            if (v == corner) return false;
            int db = Math.Abs((int)(v & 0xFF) - (int)(corner & 0xFF)), dg = Math.Abs((int)((v >> 8) & 0xFF) - (int)((corner >> 8) & 0xFF)),
                dr = Math.Abs((int)((v >> 16) & 0xFF) - (int)((corner >> 16) & 0xFF)), da = Math.Abs((int)(v >> 24) - (int)(corner >> 24));
            return db + dg + dr + da > 24;
        }
        int minX = w, minY = h, maxX = -1, maxY = -1;
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
                if (Differs(x, y)) { if (x < minX) minX = x; if (x > maxX) maxX = x; if (y < minY) minY = y; if (y > maxY) maxY = y; }
        if (maxX < 0) return (0, 0, w, h);
        int ml = minX, mr = w - 1 - maxX, mt = minY, mb = h - 1 - maxY;
        int mx = Math.Min(ml, mr), my = Math.Min(mt, mb);
        var x0 = minX - mx;
        var y0 = minY - my;
        return (x0, y0, maxX + mx - x0 + 1, maxY + my - y0 + 1);
    }

    public static MagickImage Background(int width, int height, FrameStyle style)
    {
        static Rgba Hex(string hex)
        {
            hex = (hex ?? "").TrimStart('#');
            if (hex.Length != 6) return Rgba.White;
            try
            {
                return new(System.Convert.ToInt32(hex[..2], 16) / 255.0, System.Convert.ToInt32(hex[2..4], 16) / 255.0, System.Convert.ToInt32(hex[4..6], 16) / 255.0);
            }
            catch { return Rgba.White; }
        }
        switch (style.Background)
        {
            case FrameBackground.Picture when style.PicturePath is { } path && File.Exists(path):
                try
                {
                    var picture = ImageConverter.LoadFirst(path);
                    picture.Alpha(AlphaOption.Off);
                    // Fill the canvas, cropping what doesn't fit.
                    picture.Resize(new MagickGeometry((uint)width, (uint)height) { FillArea = true });
                    picture.Crop(new MagickGeometry((uint)width, (uint)height) , Gravity.Center);
                    picture.ResetPage();
                    return picture;
                }
                catch { goto default; }
            case FrameBackground.Solid:
                return new MagickImage(Hex(style.From).Magick, (uint)width, (uint)height);
            case FrameBackground.Transparent:
                return new MagickImage(MagickColors.Transparent, (uint)width, (uint)height);
            case FrameBackground.Gradient:
                return Backgrounds.Gradient((uint)width, (uint)height, Hex(style.From), Hex(style.To), style.Angle);
            default:
                return new MagickImage(MagickColors.White, (uint)width, (uint)height);
        }
    }

    /// The framed picture.
    public static MagickImage Render(IMagickImage<byte> source, FrameStyle style)
    {
        using var picture = (MagickImage)source.Clone();
        if (style.AutoBalance)
        {
            var (bx, by, bw, bh) = Balanced(BgraImage.FromMagick(picture));
            if (bw != picture.Width || bh != picture.Height)
            {
                picture.Crop(new MagickGeometry(bx, by, (uint)bw, (uint)bh));
                picture.ResetPage();
            }
        }
        int w = (int)picture.Width, h = (int)picture.Height;
        var (cw, ch, x, y) = Layout(w, h, style);
        if ((long)cw * ch > 300_000_000) throw new ConversionException("That picture is too big to frame.");
        var canvas = Background(cw, ch, style);
        try
        {
            if (source.Density.X > 0) canvas.Density = source.Density; // same size on screen as the original
            canvas.Alpha(AlphaOption.Set);
            var radius = CornerRadius(w, h, style);
            picture.Alpha(AlphaOption.Set);
            if (radius > 0)
            {
                using var mask = new MagickImage(MagickColors.Transparent, (uint)w, (uint)h);
                new Drawables().FillColor(MagickColors.White).StrokeColor(MagickColors.Transparent)
                    .RoundRectangle(0, 0, w - 1, h - 1, radius, radius).Draw(mask);
                picture.Composite(mask, CompositeOperator.DstIn);
            }
            var shadow = Math.Clamp(style.Shadow, 0, 1);
            if (shadow > 0)
            {
                // Drawn and blurred at a quarter size: a big soft shadow at full size is slow.
                const int k = 4;
                var reach = Math.Max(w, h);
                var blur = reach * 0.045 * shadow / k;
                var offset = reach * 0.012 * shadow;
                using var layer = new MagickImage(MagickColors.Transparent, (uint)Math.Max(1, cw / k), (uint)Math.Max(1, ch / k));
                var alpha = (byte)Math.Round(0.45 * shadow * 255);
                new Drawables().FillColor(MagickColor.FromRgba(0, 0, 0, alpha)).StrokeColor(MagickColors.Transparent)
                    .RoundRectangle(x / (double)k, (y + offset) / k, (x + w) / (double)k, (y + h + offset) / k, radius / (double)k, radius / (double)k)
                    .Draw(layer);
                if (blur > 0.3) layer.Blur(0, blur);
                layer.Resize(new MagickGeometry((uint)cw, (uint)ch) { IgnoreAspectRatio = true });
                canvas.Composite(layer, 0, 0, CompositeOperator.Over);
            }
            canvas.Composite(picture, x, y, CompositeOperator.Over);
            return canvas;
        }
        catch
        {
            canvas.Dispose();
            throw;
        }
    }

    /// Frames a file and saves "<name> framed.png" beside it (or in the folder).
    public static string Save(string input, FrameStyle style, string? folder = null)
    {
        using var source = ImageConverter.LoadFirst(input);
        using var framed = Render(source, style);
        var output = OutputPaths.Destination(input, "png", "framed", folder);
        framed.Quality = 75;
        framed.Write(output, MagickFormat.Png);
        return output;
    }
}
