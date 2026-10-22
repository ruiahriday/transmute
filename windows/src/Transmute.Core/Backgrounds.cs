using ImageMagick;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

namespace Transmute;

public enum BackgroundMode { Keep, Remove, Color, Gradient, Blur, Picture }

/// What to do with a picture's background. The subject is found by a segmentation network that
/// ships with Spinform and runs on this PC (nothing is uploaded).
public sealed record BackgroundEdit
{
    public BackgroundMode Mode { get; init; } = BackgroundMode.Remove;
    public Rgba Color { get; init; } = Rgba.White;
    public Rgba GradientFrom { get; init; } = Backgrounds.Gradients[0].From;
    public Rgba GradientTo { get; init; } = Backgrounds.Gradients[0].To;
    /// Degrees: 0 runs left to right, 90 top to bottom.
    public double GradientAngle { get; init; } = Backgrounds.Gradients[0].Angle;
    /// 0…1, how strongly the original is blurred behind the subject.
    public double BlurAmount { get; init; } = 0.5;
    /// The picture to put behind the subject (scaled to fill), for Picture.
    public string? PicturePath { get; init; }
    /// 0…1, how soft the subject's edge is.
    public double Softness { get; init; } = 0.35;
    /// null picks one: PNG when the background is removed, otherwise the input's format.
    public OutputFormat? OutputFormat { get; init; }

    public bool KeepsTransparency => Mode == BackgroundMode.Remove;
}

public sealed record GradientPreset(string Name, Rgba From, Rgba To, double Angle);

public static class Backgrounds
{
    static Rgba Hex(string hex) => new(
        System.Convert.ToInt32(hex[..2], 16) / 255.0, System.Convert.ToInt32(hex[2..4], 16) / 255.0, System.Convert.ToInt32(hex[4..6], 16) / 255.0);

    public static readonly GradientPreset[] Gradients =
    [
        new("Spinform", Hex("4338CA"), Hex("EC4899"), 45),
        new("Sunset", Hex("FDBA74"), Hex("F43F5E"), 90),
        new("Sky", Hex("E0F2FE"), Hex("60A5FA"), 90),
        new("Mint", Hex("ECFDF5"), Hex("34D399"), 90),
        new("Studio", Hex("F8FAFC"), Hex("94A3B8"), 90),
        new("Night", Hex("1E1B4B"), Hex("0F172A"), 90),
    ];

    public static readonly (string Name, Rgba Color)[] Colors =
    [
        ("White", Rgba.White), ("Light grey", Hex("F1F5F9")), ("Black", Rgba.Black), ("Ink", Hex("1E1B3A")),
        ("Indigo", Hex("4338CA")), ("Rose", Hex("F43F5E")), ("Sky", Hex("BAE6FD")), ("Mint", Hex("BBF7D0")), ("Butter", Hex("FEF08A")),
    ];

    // The network

    const int Side = 1024;
    public const string ModelFile = "isnet-general-use.onnx";

    /// Where the network is: next to the app in models\, or TRANSMUTE_BACKGROUND_MODEL.
    public static string? ModelPath
    {
        get
        {
            var custom = Environment.GetEnvironmentVariable("TRANSMUTE_BACKGROUND_MODEL");
            if (!string.IsNullOrEmpty(custom) && File.Exists(custom)) return custom;
            var bundled = Path.Combine(AppContext.BaseDirectory, "models", ModelFile);
            return File.Exists(bundled) ? bundled : null;
        }
    }

    public static bool IsAvailable => ModelPath is not null;

    static InferenceSession? session;
    static readonly object SessionGate = new();
    // One picture at a time: the network needs a lot of memory while it runs.
    static readonly SemaphoreSlim RunGate = new(1, 1);

    static InferenceSession Session()
    {
        lock (SessionGate)
        {
            if (session is not null) return session;
            var path = ModelPath ?? throw new ConversionException("Spinform's background model is missing. Reinstalling Spinform brings it back.");
            var options = new SessionOptions { GraphOptimizationLevel = GraphOptimizationLevel.ORT_ENABLE_ALL };
            try
            {
                session = new InferenceSession(path, options);
            }
            catch (Exception e) when (e is OnnxRuntimeException or DllNotFoundException or TypeInitializationException)
            {
                throw new ConversionException($"Couldn't start the background model: {e.Message.Split('\n')[0]}");
            }
            return session;
        }
    }

    /// Loads the network ahead of time so the first picture is quicker.
    public static void Warm()
    {
        if (IsAvailable) try { Session(); } catch { }
    }

    /// How sure the network is that each pixel belongs to the subject, 0…1, as a grey picture the
    /// size of `image` (white is the subject).
    public static MagickImage FindSubject(IMagickImage<byte> image, CancellationToken token = default)
    {
        var input = new DenseTensor<float>([1, 3, Side, Side]);
        using (var small = (MagickImage)image.Clone())
        {
            // Transparent parts count as background: show them to the network as flat grey.
            if (small.HasAlpha)
            {
                small.BackgroundColor = new MagickColor(128, 128, 128);
                small.Alpha(AlphaOption.Remove);
            }
            small.ColorSpace = ColorSpace.sRGB;
            small.FilterType = FilterType.Triangle;
            small.Resize(new MagickGeometry(Side, Side) { IgnoreAspectRatio = true });
            var rgb = small.GetPixels().ToByteArray(PixelMapping.RGB)!;
            var plane = Side * Side;
            var buffer = input.Buffer.Span;
            for (int i = 0, p = 0; i < plane; i++, p += 3)
            {
                // The network was trained on values from -0.5 to 0.5.
                buffer[i] = rgb[p] / 255f - 0.5f;
                buffer[plane + i] = rgb[p + 1] / 255f - 0.5f;
                buffer[2 * plane + i] = rgb[p + 2] / 255f - 0.5f;
            }
        }
        token.ThrowIfCancellationRequested();
        var model = Session();
        float[] output;
        RunGate.Wait(token);
        try
        {
            var name = model.InputMetadata.Keys.First();
            using var results = model.Run([NamedOnnxValue.CreateFromTensor(name, input)], [model.OutputMetadata.Keys.First()]);
            output = results.First().AsEnumerable<float>().ToArray();
        }
        finally
        {
            RunGate.Release();
        }
        var bytes = new byte[output.Length];
        for (var i = 0; i < output.Length; i++) bytes[i] = (byte)Math.Round(Math.Clamp(output[i], 0f, 1f) * 255);
        var mask = new MagickImage(bytes, new PixelReadSettings(Side, Side, StorageType.Char, PixelMapping.RGB) { Mapping = "I" });
        mask.ColorType = ColorType.Grayscale;
        mask.FilterType = FilterType.Triangle;
        mask.Resize(new MagickGeometry(image.Width, image.Height) { IgnoreAspectRatio = true });
        return mask;
    }

    // Masks are kept for the last few pictures so the editor's preview stays quick while sliders move.
    static readonly List<(string Key, MagickImage Mask)> Cache = [];

    static MagickImage CachedSubject(string source, IMagickImage<byte> image, CancellationToken token)
    {
        string key;
        try { key = $"{Path.GetFullPath(source)}|{File.GetLastWriteTimeUtc(source).Ticks}|{image.Width}x{image.Height}"; }
        catch { key = $"{source}|{image.Width}x{image.Height}"; }
        lock (Cache)
        {
            var hit = Cache.FindIndex(c => c.Key == key);
            if (hit >= 0) return (MagickImage)Cache[hit].Mask.Clone();
        }
        var mask = FindSubject(image, token);
        lock (Cache)
        {
            Cache.Add((key, (MagickImage)mask.Clone()));
            while (Cache.Count > 4) { Cache[0].Mask.Dispose(); Cache.RemoveAt(0); }
        }
        return mask;
    }

    /// The finished alpha: a firmer edge (the network leaves a soft ramp), then a slight feather so
    /// the cut doesn't look jagged. Keeps any transparency the picture already had.
    static void ShapeEdge(MagickImage mask, IMagickImage<byte> image, double softness)
    {
        mask.Level(new Percentage(12), new Percentage(88));
        var longest = Math.Max(image.Width, image.Height);
        var sigma = Math.Clamp(softness, 0, 1) * Math.Max(0.6, longest / 1400.0) * 1.6;
        if (sigma > 0.05) mask.Blur(0, sigma);
        if (image.HasAlpha)
        {
            using var existing = image.Separate(Channels.Alpha).First();
            mask.Composite(existing, CompositeOperator.Multiply);
        }
    }

    /// The picture with `edit` applied to its background. `source` identifies the picture for the
    /// mask cache (its file path).
    public static MagickImage Apply(IMagickImage<byte> image, string source, BackgroundEdit edit, CancellationToken token = default)
    {
        var result = new MagickImage(image);
        if (edit.Mode == BackgroundMode.Keep) return result;
        try
        {
            using var mask = CachedSubject(source, image, token);
            ShapeEdge(mask, image, edit.Softness);
            result.Alpha(AlphaOption.Set);
            result.Composite(mask, CompositeOperator.CopyAlpha);
            if (edit.Mode == BackgroundMode.Remove) return result;
            using var backdrop = Backdrop(image, mask, edit);
            // A grey backdrop picture would turn the subject grey too.
            backdrop.ColorType = ColorType.TrueColor;
            backdrop.ColorSpace = ColorSpace.sRGB;
            backdrop.Composite(result, CompositeOperator.Over);
            backdrop.Alpha(AlphaOption.Off);
            result.Dispose();
            return new MagickImage(backdrop);
        }
        catch
        {
            result.Dispose();
            throw;
        }
    }

    /// What goes behind the subject, the size of the picture.
    static MagickImage Backdrop(IMagickImage<byte> image, IMagickImage<byte> mask, BackgroundEdit edit)
    {
        uint w = image.Width, h = image.Height;
        switch (edit.Mode)
        {
            case BackgroundMode.Color:
                return new MagickImage((edit.Color with { A = 1 }).Magick, w, h);
            case BackgroundMode.Gradient:
                return Gradient(w, h, edit.GradientFrom, edit.GradientTo, edit.GradientAngle);
            case BackgroundMode.Blur:
            {
                var blurred = new MagickImage(image);
                if (blurred.HasAlpha) { blurred.BackgroundColor = MagickColors.White; blurred.Alpha(AlphaOption.Remove); }
                blurred.ColorType = ColorType.TrueColor;
                // Blur only the background (the subject is made see-through first, and resizing and
                // blurring weigh by alpha), so the subject doesn't leave a coloured halo behind it.
                using (var behind = new MagickImage(mask))
                {
                    behind.Negate();
                    behind.Level(new Percentage(0), new Percentage(40));
                    blurred.Alpha(AlphaOption.Set);
                    blurred.Composite(behind, CompositeOperator.CopyAlpha);
                }
                var amount = Math.Clamp(edit.BlurAmount, 0.05, 1);
                // Shrinking first makes a strong blur quick even on big photos.
                blurred.Resize(new Percentage(25));
                blurred.Blur(0, amount * Math.Max(w, h) / 4 / 40.0 + 0.5);
                blurred.Resize(new MagickGeometry(w, h) { IgnoreAspectRatio = true });
                blurred.Blur(0, 1.5);
                blurred.BackgroundColor = new MagickColor(128, 128, 128);
                blurred.Alpha(AlphaOption.Off);
                return blurred;
            }
            case BackgroundMode.Picture:
            {
                if (string.IsNullOrEmpty(edit.PicturePath) || !File.Exists(edit.PicturePath))
                    throw new ConversionException("Choose a picture to put behind the subject.");
                var picture = ImageConverter.LoadFirst(edit.PicturePath);
                if (picture.HasAlpha) { picture.BackgroundColor = MagickColors.White; picture.Alpha(AlphaOption.Remove); }
                // Scale to fill, then crop the middle.
                var scale = Math.Max((double)w / picture.Width, (double)h / picture.Height);
                picture.FilterType = FilterType.Lanczos;
                picture.Resize(new MagickGeometry((uint)Math.Ceiling(picture.Width * scale), (uint)Math.Ceiling(picture.Height * scale)) { IgnoreAspectRatio = true });
                picture.Crop(new MagickGeometry((int)(picture.Width - w) / 2, (int)(picture.Height - h) / 2, w, h));
                picture.ResetPage();
                return picture;
            }
            default:
                return new MagickImage(MagickColors.White, w, h);
        }
    }

    /// A straight two-colour gradient at an angle (0° left to right, 90° top to bottom).
    public static MagickImage Gradient(uint w, uint h, Rgba from, Rgba to, double angle)
    {
        var radians = angle * Math.PI / 180;
        double dx = Math.Cos(radians), dy = Math.Sin(radians);
        // Project the corners so the gradient runs exactly from one corner side to the other.
        double[] ends = [0, w * dx, h * dy, w * dx + h * dy];
        double min = ends.Min(), span = Math.Max(1e-6, ends.Max() - min);
        var pixels = new byte[w * h * 3];
        static byte B(double v) => (byte)Math.Round(Math.Clamp(v, 0, 1) * 255);
        for (var y = 0; y < h; y++)
        {
            var row = y * (int)w * 3;
            for (var x = 0; x < w; x++)
            {
                var t = ((x + 0.5) * dx + (y + 0.5) * dy - min) / span;
                var i = row + x * 3;
                pixels[i] = B(from.R + (to.R - from.R) * t);
                pixels[i + 1] = B(from.G + (to.G - from.G) * t);
                pixels[i + 2] = B(from.B + (to.B - from.B) * t);
            }
        }
        return new MagickImage(pixels, new PixelReadSettings(w, h, StorageType.Char, PixelMapping.RGB));
    }

    // Saving

    static readonly OutputFormat[] Keepable = [Transmute.OutputFormat.Jpeg, Transmute.OutputFormat.Png, Transmute.OutputFormat.Webp,
        Transmute.OutputFormat.Tiff, Transmute.OutputFormat.Bmp, Transmute.OutputFormat.Gif, Transmute.OutputFormat.Avif];

    public static bool HoldsTransparency(OutputFormat f) =>
        f is Transmute.OutputFormat.Png or Transmute.OutputFormat.Webp or Transmute.OutputFormat.Tiff or Transmute.OutputFormat.Gif or Transmute.OutputFormat.Avif;

    /// PNG when the background is removed; otherwise the input's own format where Spinform can
    /// write it (a JPEG stays a JPEG), else JPEG for photos and PNG for drawings.
    public static OutputFormat FormatFor(BackgroundEdit edit, string input)
    {
        if (edit.OutputFormat is { } chosen) return chosen;
        if (edit.KeepsTransparency) return Transmute.OutputFormat.Png;
        var same = Kinds.FormatFor(Path.GetExtension(input));
        if (same is { } f && Keepable.Contains(f)) return f;
        return Path.GetExtension(input).Equals(".svg", StringComparison.OrdinalIgnoreCase) ? Transmute.OutputFormat.Png : Transmute.OutputFormat.Jpeg;
    }

    public static async Task<JobResult> Run(BackgroundEdit edit, string input, ConversionOptions options, ProgressHandler progress, CancellationToken token)
    {
        var format = FormatFor(edit, input);
        var suffix = edit.Mode == BackgroundMode.Remove ? "no background" : "new background";
        var output = OutputPaths.Destination(input, format.Extension(), suffix, options.OutputFolder);
        try
        {
            await Task.Run(() =>
            {
                progress(0.1);
                using var original = ImageConverter.LoadFirst(input);
                using var image = Apply(original, input, edit, token);
                progress(0.85);
                Save(image, format, output, options);
            }, token);
        }
        catch
        {
            OutputPaths.TryDelete(output);
            throw;
        }
        progress(1);
        return JobResult.Of(output);
    }

    static void Save(MagickImage image, OutputFormat format, string output, ConversionOptions options)
    {
        image.Orientation = OrientationType.TopLeft;
        image.GetExifProfile()?.RemoveValue(ExifTag.Orientation);
        if (options.StripMetadata) image.Strip();
        if (!HoldsTransparency(format) && image.HasAlpha)
        {
            image.BackgroundColor = MagickColors.White;
            image.Alpha(AlphaOption.Remove);
        }
        if (format is Transmute.OutputFormat.Jpeg or Transmute.OutputFormat.Webp or Transmute.OutputFormat.Avif)
            image.Quality = (uint)Math.Clamp(Math.Round(options.Quality * 100), 1, 100);
        // zlib level 7 (5 for very big pictures) with adaptive filters: level 9 takes over a minute
        // on a 24-megapixel photo for a file only about 5% smaller.
        if (format == Transmute.OutputFormat.Png) image.Quality = image.Width * image.Height > 8_000_000 ? 55u : 75u;
        try
        {
            image.Write(output, ImageConverter.MagickFormatFor(format));
        }
        catch (MagickException e)
        {
            throw new ConversionException($"Couldn't save as {format.Label()}: {e.Message.Split('\n')[0]}");
        }
    }
}
