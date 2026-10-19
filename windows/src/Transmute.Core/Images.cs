using ImageMagick;
using ZXing;
using ZXing.Common;

namespace Transmute;

/// Images, through ImageMagick (Magick.NET), which reads nearly every format including HEIC, AVIF,
/// PSD, SVG and camera RAW files.
public static class ImageConverter
{
    public static bool IsAnimatedFormat(OutputFormat f) => f is OutputFormat.Gif or OutputFormat.Webp;

    public static MagickFormat MagickFormatFor(OutputFormat format) => format switch
    {
        OutputFormat.Jpeg => MagickFormat.Jpeg,
        OutputFormat.Png => MagickFormat.Png,
        OutputFormat.Webp => MagickFormat.WebP,
        OutputFormat.Heic => MagickFormat.Heic,
        OutputFormat.Avif => MagickFormat.Avif,
        OutputFormat.Tiff => MagickFormat.Tiff,
        OutputFormat.Bmp => MagickFormat.Bmp,
        OutputFormat.Gif => MagickFormat.Gif,
        OutputFormat.Ico => MagickFormat.Ico,
        _ => throw new ConversionException($"Images can't be converted to {format.Label()}."),
    };

    /// Reads every frame, with the photo turned upright.
    public static MagickImageCollection Load(string path)
    {
        var settings = new MagickReadSettings();
        if (Path.GetExtension(path).Equals(".svg", StringComparison.OrdinalIgnoreCase))
        {
            settings.Density = new Density(144);
            settings.BackgroundColor = MagickColors.Transparent;
        }
        MagickImageCollection images;
        try
        {
            images = new MagickImageCollection(path, settings);
        }
        catch (MagickException e)
        {
            throw new ConversionException($"Couldn't read {Path.GetFileName(path)} as a picture: {FirstLine(e.Message)}");
        }
        if (images.Count == 0) throw new ConversionException($"{Path.GetFileName(path)} has no picture in it.");
        foreach (var image in images) image.AutoOrient();
        return images;
    }

    /// The first frame, upright.
    public static MagickImage LoadFirst(string path)
    {
        using var all = Load(path);
        return new MagickImage(all[0]);
    }

    static string FirstLine(string text) => text.Split('\n')[0].Trim();

    public static async Task<string> Convert(string input, OutputFormat format, ConversionOptions options, CancellationToken token)
    {
        var output = OutputPaths.Destination(input, format.Extension(), null, options.OutputFolder);
        try
        {
            await Task.Run(() => Write(input, format, output, options.Quality, options.StripMetadata, null), token);
        }
        catch
        {
            OutputPaths.TryDelete(output);
            throw;
        }
        return output;
    }

    /// Re-encodes an image. Keeps animation for GIF and WebP output, keeps metadata unless `strip`,
    /// and shrinks so the longest side is at most `maxPixel` when given.
    public static void Write(string input, OutputFormat format, string output, double quality, bool strip, int? maxPixel)
    {
        switch (format)
        {
            case OutputFormat.Pdf:
                PdfTools.WriteImagesPdf([input], output);
                return;
            case OutputFormat.Svg:
                WriteSvg(input, output);
                return;
        }
        using var images = Load(input);
        var keepFrames = IsAnimatedFormat(format) && images.Count > 1;
        if (!keepFrames)
        {
            while (images.Count > 1) images.RemoveAt(images.Count - 1);
        }
        else
        {
            images.Coalesce();
        }
        foreach (var image in images)
        {
            Prepare(image, format, quality, strip, maxPixel);
        }
        if (format == OutputFormat.Ico)
        {
            var image = images[0];
            if (image.Width > 256 || image.Height > 256) image.Resize(new MagickGeometry(256, 256));
            image.Settings.SetDefine(MagickFormat.Ico, "auto-resize", "256,128,64,48,32,16");
        }
        try
        {
            if (keepFrames) images.Write(output, MagickFormatFor(format));
            else images[0].Write(output, MagickFormatFor(format));
        }
        catch (MagickException e)
        {
            throw new ConversionException($"Couldn't save as {format.Label()}: {FirstLine(e.Message)}");
        }
    }

    static void Prepare(IMagickImage<byte> image, OutputFormat format, double quality, bool strip, int? maxPixel)
    {
        if (maxPixel is { } max && Math.Max(image.Width, image.Height) > max)
            image.Resize(new MagickGeometry((uint)max, (uint)max));
        if (format is OutputFormat.Jpeg or OutputFormat.Bmp && image.HasAlpha)
        {
            image.BackgroundColor = MagickColors.White;
            image.Alpha(AlphaOption.Remove);
        }
        if (format is OutputFormat.Jpeg or OutputFormat.Webp or OutputFormat.Heic or OutputFormat.Avif)
            image.Quality = (uint)Math.Clamp(Math.Round(quality * 100), 1, 100);
        if (format == OutputFormat.Png) image.Quality = 95; // zlib level 9, adaptive filtering
        if (format == OutputFormat.Jpeg && image.ColorSpace == ColorSpace.CMYK) image.TransformColorSpace(ColorProfiles.SRGB);
        if (strip) image.Strip();
        // The pixels are upright now, so the orientation tag must not turn them again.
        image.Orientation = OrientationType.TopLeft;
        image.GetExifProfile()?.RemoveValue(ExifTag.Orientation);
    }

    /// An SVG file that holds the picture's pixels (it doesn't trace shapes).
    static void WriteSvg(string input, string output)
    {
        using var image = LoadFirst(input);
        image.Strip();
        var png = image.ToByteArray(MagickFormat.Png);
        var svg = $"""
            <?xml version="1.0" encoding="UTF-8"?>
            <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="{image.Width}" height="{image.Height}" viewBox="0 0 {image.Width} {image.Height}">
              <image width="{image.Width}" height="{image.Height}" xlink:href="data:image/png;base64,{System.Convert.ToBase64String(png)}"/>
            </svg>
            """;
        File.WriteAllText(output, svg);
    }

    // Compression

    public static async Task<JobResult> Compress(string input, long goal, ConversionOptions options, CancellationToken token)
    {
        var ext = Path.GetExtension(input).TrimStart('.').ToLowerInvariant();
        using var probe = LoadFirst(input);
        var format = ext switch
        {
            "jpg" or "jpeg" or "jfif" => OutputFormat.Jpeg,
            "webp" => OutputFormat.Webp,
            "heic" or "heif" => OutputFormat.Heic,
            "avif" => OutputFormat.Avif,
            "png" => OutputFormat.Png,
            "gif" => OutputFormat.Gif,
            _ => probe.HasAlpha ? OutputFormat.Png : OutputFormat.Jpeg,
        };
        var output = OutputPaths.Destination(input, format.Extension(), "compressed", options.OutputFolder);
        try
        {
            await Task.Run(() => CompressTo(input, format, output, goal, options.StripMetadata, token), token);
        }
        catch
        {
            OutputPaths.TryDelete(output);
            throw;
        }
        return MediaConverter.SizeResult(input, output, goal);
    }

    static void CompressTo(string input, OutputFormat format, string output, long goal, bool strip, CancellationToken token)
    {
        using var source = Load(input);
        int width = (int)source[0].Width, height = (int)source[0].Height;
        var longest = Math.Max(width, height);
        var lossy = format is OutputFormat.Jpeg or OutputFormat.Webp or OutputFormat.Heic or OutputFormat.Avif;

        byte[] Encode(double quality, int maxPixel, bool fewColors)
        {
            using var images = new MagickImageCollection();
            var animated = format == OutputFormat.Gif && source.Count > 1;
            if (animated) foreach (var frame in source) images.Add(new MagickImage(frame));
            else images.Add(new MagickImage(source[0]));
            if (animated) images.Coalesce();
            foreach (var image in images)
            {
                Prepare(image, format, quality, strip, maxPixel < longest ? maxPixel : null);
                if (fewColors && format == OutputFormat.Png)
                {
                    image.Quantize(new QuantizeSettings { Colors = 256, DitherMethod = DitherMethod.FloydSteinberg });
                    image.Settings.SetDefine(MagickFormat.Png, "format", image.HasAlpha ? "png32" : "png8");
                }
            }
            if (animated) images.Optimize();
            using var stream = new MemoryStream();
            if (animated) images.Write(stream, MagickFormatFor(format));
            else images[0].Write(stream, MagickFormatFor(format));
            return stream.ToArray();
        }

        byte[]? best = null;
        var scale = longest;
        for (var round = 0; round < 8; round++)
        {
            token.ThrowIfCancellationRequested();
            byte[] attempt;
            if (lossy)
            {
                // Highest quality that fits, by halving the range a few times.
                double low = 0.1, high = 0.92;
                byte[]? fit = null;
                var smallest = Encode(low, scale, false);
                if (smallest.Length <= goal)
                {
                    fit = smallest;
                    for (var i = 0; i < 6; i++)
                    {
                        var mid = (low + high) / 2;
                        var data = Encode(mid, scale, false);
                        if (data.Length <= goal) { fit = data; low = mid; } else high = mid;
                    }
                }
                attempt = fit ?? smallest;
            }
            else
            {
                attempt = Encode(1, scale, false);
                if (attempt.Length > goal && format == OutputFormat.Png) attempt = Encode(1, scale, true);
            }
            if (best is null || attempt.Length < best.Length) best = attempt;
            if (attempt.Length <= goal) { best = attempt; break; }
            // Too big even at the lowest quality: make the picture smaller and try again.
            var ratio = Math.Sqrt((double)goal / attempt.Length);
            scale = Math.Max(16, (int)(scale * Math.Clamp(ratio * 0.95, 0.3, 0.9)));
        }
        File.WriteAllBytes(output, best!);
    }

    public static async Task<string> StripMetadata(string input, ConversionOptions options, CancellationToken token)
    {
        var ext = Path.GetExtension(input).TrimStart('.');
        var format = Kinds.FormatFor(ext) is { } f && f is not (OutputFormat.Svg or OutputFormat.Pdf) && IsWritable(f) ? f : OutputFormat.Png;
        var output = OutputPaths.Destination(input, format == OutputFormat.Png && !ext.Equals("png", StringComparison.OrdinalIgnoreCase) ? "png" : ext, "clean", options.OutputFolder);
        try
        {
            await Task.Run(() =>
            {
                using var images = Load(input);
                foreach (var image in images)
                {
                    var q = image.Quality;
                    image.Strip();
                    image.Orientation = OrientationType.TopLeft;
                    if (q > 0) image.Quality = q;
                }
                if (images.Count > 1 && IsAnimatedFormat(format)) images.Write(output, MagickFormatFor(format));
                else images[0].Write(output, MagickFormatFor(format));
            }, token);
        }
        catch
        {
            OutputPaths.TryDelete(output);
            throw;
        }
        return output;
    }

    static bool IsWritable(OutputFormat f) => f is OutputFormat.Jpeg or OutputFormat.Png or OutputFormat.Webp or OutputFormat.Heic
        or OutputFormat.Avif or OutputFormat.Tiff or OutputFormat.Bmp or OutputFormat.Gif or OutputFormat.Ico;

    /// Half or quarter size, in the same format when Transmute can write it.
    public static async Task<string> Resize(string input, double scale, ConversionOptions options, CancellationToken token)
    {
        var ext = Path.GetExtension(input).TrimStart('.').ToLowerInvariant();
        var format = Kinds.FormatFor(ext) is { } f && IsWritable(f) ? f : OutputFormat.Png;
        var suffix = scale >= 0.5 ? "half size" : "quarter size";
        var output = OutputPaths.Destination(input, format == OutputFormat.Png ? "png" : ext, suffix, options.OutputFolder);
        try
        {
            await Task.Run(() =>
            {
                using var images = Load(input);
                if (!(images.Count > 1 && IsAnimatedFormat(format))) while (images.Count > 1) images.RemoveAt(1);
                else images.Coalesce();
                foreach (var image in images)
                {
                    image.Resize(new Percentage(scale * 100));
                    Prepare(image, format, options.Quality, options.StripMetadata, null);
                }
                if (images.Count > 1) images.Write(output, MagickFormatFor(format));
                else images[0].Write(output, MagickFormatFor(format));
            }, token);
        }
        catch
        {
            OutputPaths.TryDelete(output);
            throw;
        }
        return output;
    }

    // QR codes

    public static string ReadQr(string input)
    {
        using var image = LoadFirst(input);
        image.Alpha(AlphaOption.Remove);
        var tries = new List<IMagickImage<byte>> { image };
        if (Math.Max(image.Width, image.Height) > 1600)
        {
            var small = (MagickImage)image.Clone();
            small.Resize(new MagickGeometry(1600, 1600));
            tries.Add(small);
        }
        var reader = new BarcodeReaderGeneric
        {
            AutoRotate = true,
            Options = new DecodingOptions { TryHarder = true, PossibleFormats = [BarcodeFormat.QR_CODE], TryInverted = true },
        };
        var found = new List<string>();
        foreach (var candidate in tries)
        {
            var pixels = candidate.GetPixels().ToByteArray(PixelMapping.RGB)!;
            var source = new RGBLuminanceSource(pixels, (int)candidate.Width, (int)candidate.Height, RGBLuminanceSource.BitmapFormat.RGB24);
            var results = reader.DecodeMultiple(source);
            if (results is { Length: > 0 })
            {
                found.AddRange(results.Select(r => r.Text).Distinct());
                break;
            }
        }
        foreach (var extra in tries.Skip(1)) extra.Dispose();
        if (found.Count == 0) throw new ConversionException($"No QR code found in {Path.GetFileName(input)}.");
        return string.Join("\n", found);
    }

    /// Writes a QR code picture (used by the self-test).
    public static void WriteQr(string text, string path)
    {
        var writer = new BarcodeWriterPixelData { Format = BarcodeFormat.QR_CODE, Options = new EncodingOptions { Width = 300, Height = 300, Margin = 2 } };
        var data = writer.Write(text);
        using var image = new MagickImage(data.Pixels, new PixelReadSettings((uint)data.Width, (uint)data.Height, StorageType.Char, PixelMapping.BGRA));
        image.Write(path, MagickFormat.Png);
    }
}
