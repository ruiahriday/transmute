using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using ImageMagick;
using ImageMagick.Drawing;

namespace Transmute;

/// Where the pointer was at a moment of a recording, in the recording's pixels.
public sealed record StudioSample(double Time, int X, int Y, bool Click);

/// The pointer movements saved with a recording (pointer.json).
public sealed record PointerTrack(int Width, int Height, double Scale, List<StudioSample> Samples, bool CursorDrawn = true)
{
    public static PointerTrack? Load(string path)
    {
        try
        {
            var track = JsonSerializer.Deserialize<PointerTrack>(File.ReadAllText(path), new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            return track is { Samples: not null } ? track : null;
        }
        catch { return null; }
    }
}

/// A zoom placed by hand: from Start to End seconds, Zoom times closer, centred on (X, Y) (0…1).
public sealed record StudioZoom(double Start, double End, double Zoom, double X, double Y);

/// The shape of the exported video.
public enum StudioShape { Original, Landscape, Square, Vertical }

public sealed record StudioOptions
{
    /// Zoom in around each click, following the pointer.
    public bool AutoZoom { get; init; } = true;
    public double ZoomLevel { get; init; } = 1.8;
    public IReadOnlyList<StudioZoom> Zooms { get; init; } = [];
    /// Draw the pointer from the saved movements (when the recording was made without it).
    public bool DrawCursor { get; init; }
    public bool SmoothCursor { get; init; } = true;
    public double CursorSize { get; init; } = 1;
    public StudioShape Shape { get; init; } = StudioShape.Original;
    /// The background around the video; null keeps the video edge to edge.
    public FrameStyle? Background { get; init; }
    public bool MotionBlur { get; init; }
    public double TrimStart { get; init; }
    public double? TrimEnd { get; init; }
    public string Encoder { get; init; } = "libx264";
    public RecordingQuality Quality { get; init; } = RecordingQuality.High;

    public static string Label(StudioShape shape) => shape switch
    {
        StudioShape.Landscape => "Landscape 16:9",
        StudioShape.Square => "Square 1:1",
        StudioShape.Vertical => "Vertical 9:16",
        _ => "Same as the recording",
    };
}

/// The pointer's path, filled in between samples and smoothed, so the camera glides and the
/// drawn pointer doesn't jitter.
public sealed class PointerPath
{
    const double Rate = 60;
    readonly double[] xs, ys;
    readonly double duration;

    public PointerPath(IReadOnlyList<StudioSample> samples, double duration, double smoothing)
    {
        this.duration = Math.Max(duration, samples.Count > 0 ? samples[^1].Time : 0);
        var n = Math.Max(2, (int)Math.Ceiling(this.duration * Rate) + 2);
        xs = new double[n];
        ys = new double[n];
        var k = 0;
        double x = samples.Count > 0 ? samples[0].X : 0, y = samples.Count > 0 ? samples[0].Y : 0;
        for (var i = 0; i < n; i++)
        {
            var t = i / Rate;
            while (k < samples.Count && samples[k].Time <= t) { x = samples[k].X; y = samples[k].Y; k++; }
            xs[i] = x;
            ys[i] = y;
        }
        if (smoothing > 0)
        {
            Blur(xs, smoothing * Rate);
            Blur(ys, smoothing * Rate);
        }
    }

    static void Blur(double[] values, double sigma)
    {
        var radius = (int)Math.Ceiling(sigma * 2.5);
        if (radius < 1) return;
        var kernel = new double[radius * 2 + 1];
        for (var i = -radius; i <= radius; i++) kernel[i + radius] = Math.Exp(-i * i / (2 * sigma * sigma));
        var copy = (double[])values.Clone();
        for (var i = 0; i < values.Length; i++)
        {
            double sum = 0, weight = 0;
            for (var j = -radius; j <= radius; j++)
            {
                var at = Math.Clamp(i + j, 0, values.Length - 1);
                sum += copy[at] * kernel[j + radius];
                weight += kernel[j + radius];
            }
            values[i] = sum / weight;
        }
    }

    public (double X, double Y) At(double t)
    {
        var f = Math.Clamp(t, 0, duration) * Rate;
        var i = Math.Min((int)f, xs.Length - 2);
        var frac = f - i;
        return (xs[i] + (xs[i + 1] - xs[i]) * frac, ys[i] + (ys[i + 1] - ys[i]) * frac);
    }
}

/// Where the virtual camera looks at each moment: how close, and centred where (0…1).
public readonly record struct StudioCamera(double Zoom, double X, double Y);

public static class StudioDirector
{
    const double Ramp = 0.45;

    /// One zoom per burst of clicks: starting a little before the first, holding until a while
    /// after the last.
    public static List<(double Start, double End)> ClickZooms(IReadOnlyList<StudioSample> samples)
    {
        var windows = new List<(double Start, double End)>();
        foreach (var click in samples.Where(s => s.Click).Select(s => s.Time).Order())
        {
            var (start, end) = (Math.Max(0, click - 0.55), click + 1.7);
            if (windows.Count > 0 && start <= windows[^1].End + 0.4) windows[^1] = (windows[^1].Start, end);
            else windows.Add((start, end));
        }
        return windows;
    }

    static double Ease(double v) { v = Math.Clamp(v, 0, 1); return v * v * (3 - 2 * v); }

    static double Strength(double t, double start, double end) =>
        t < start || t > end ? 0 : Ease((t - start) / Ramp) * Ease((end - t) / Ramp);

    public static StudioCamera At(double t, StudioOptions options, IReadOnlyList<(double Start, double End)> auto, PointerPath? camera, int width, int height)
    {
        double zoom = 1, x = 0.5, y = 0.5;
        foreach (var manual in options.Zooms)
        {
            var s = Strength(t, manual.Start, manual.End);
            if (s <= 0) continue;
            zoom = 1 + (manual.Zoom - 1) * s;
            x = 0.5 + (manual.X - 0.5) * s;
            y = 0.5 + (manual.Y - 0.5) * s;
            return Clamp(zoom, x, y);
        }
        if (options.AutoZoom && camera is not null)
        {
            foreach (var (start, end) in auto)
            {
                var s = Strength(t, start, end);
                if (s <= 0) continue;
                var (px, py) = camera.At(t);
                zoom = 1 + (options.ZoomLevel - 1) * s;
                x = 0.5 + (px / Math.Max(1, width) - 0.5) * s;
                y = 0.5 + (py / Math.Max(1, height) - 0.5) * s;
                break;
            }
        }
        return Clamp(zoom, x, y);
    }

    static StudioCamera Clamp(double zoom, double x, double y)
    {
        zoom = Math.Max(1, zoom);
        var half = 0.5 / zoom;
        return new StudioCamera(zoom, Math.Clamp(x, half, 1 - half), Math.Clamp(y, half, 1 - half));
    }
}

/// Draws each frame of a studio export: the background (with its shadow) made once, then the
/// recording through the camera into a rounded box on it, and the pointer on top.
public sealed class StudioRenderer
{
    readonly int srcW, srcH;
    readonly StudioOptions options;
    readonly PointerPath? cursorPath, cameraPath;
    readonly List<(double Start, double End)> auto;
    readonly BgraImage canvas;
    readonly byte[] mask;
    readonly BgraImage? cursor;
    readonly double displayScale;
    public int Width { get; }
    public int Height { get; }
    public PixelRect Content { get; }

    public StudioRenderer(int sourceWidth, int sourceHeight, StudioOptions options, PointerTrack? track, double duration)
    {
        srcW = sourceWidth;
        srcH = sourceHeight;
        this.options = options;
        displayScale = track?.Scale ?? 1;
        if (track is not null && track.Samples.Count > 0)
        {
            // The pointer data is in the recording's pixels; fit it to this video's size.
            var sx = (double)srcW / Math.Max(1, track.Width);
            var sy = (double)srcH / Math.Max(1, track.Height);
            var samples = track.Samples.Select(s => s with { X = (int)Math.Round(s.X * sx), Y = (int)Math.Round(s.Y * sy) }).ToList();
            cameraPath = new PointerPath(samples, duration, 0.35);
            cursorPath = new PointerPath(samples, duration, options.SmoothCursor ? 0.06 : 0);
            auto = StudioDirector.ClickZooms(samples);
        }
        else auto = [];
        (Width, Height) = Size(srcW, srcH, options);
        var style = options.Background ?? (options.Shape == StudioShape.Original ? null : new FrameStyle { Background = FrameBackground.Solid, From = "0F0F14", Padding = 0, Corners = 0, Shadow = 0 });
        if (style is null)
        {
            Content = new PixelRect(0, 0, Width, Height);
            canvas = new BgraImage(Width, Height);
            mask = [];
        }
        else
        {
            var pad = (int)Math.Round(style.Padding * Math.Min(Width, Height));
            double availW = Width - 2 * pad, availH = Height - 2 * pad;
            var scale = Math.Min(availW / srcW, availH / srcH);
            int cw = Math.Max(2, (int)Math.Round(srcW * scale) / 2 * 2), ch = Math.Max(2, (int)Math.Round(srcH * scale) / 2 * 2);
            Content = new PixelRect((Width - cw) / 2, (Height - ch) / 2, cw, ch);
            using var background = Frames.Background(Width, Height, style);
            double radius = Frames.CornerRadius(cw, ch, style);
            if (style.Shadow > 0)
            {
                using var shadow = new MagickImage(MagickColors.Transparent, (uint)Width, (uint)Height);
                new Drawables().FillColor(MagickColor.FromRgba(0, 0, 0, (byte)Math.Round(150 * Math.Clamp(style.Shadow, 0, 1)))).StrokeColor(MagickColors.Transparent)
                    .RoundRectangle(Content.X, Content.Y + ch * 0.02, Content.Right, Content.Bottom + ch * 0.02, radius, radius).Draw(shadow);
                shadow.Blur(0, Math.Max(2, Math.Min(cw, ch) * 0.03));
                background.Composite(shadow, 0, 0, CompositeOperator.Over);
            }
            background.Alpha(AlphaOption.Off);
            canvas = BgraImage.FromMagick(background);
            mask = RoundedMask(cw, ch, radius);
        }
        if (options.DrawCursor && cursorPath is not null) cursor = CursorSprite(options.CursorSize * displayScale);
    }

    /// The exported video's size: the recording's own for Original, otherwise a standard size.
    public static (int Width, int Height) Size(int srcW, int srcH, StudioOptions options)
    {
        var big = Math.Max(srcW, srcH) >= 1280;
        return options.Shape switch
        {
            StudioShape.Landscape => big ? (1920, 1080) : (1280, 720),
            StudioShape.Square => big ? (1080, 1080) : (720, 720),
            StudioShape.Vertical => big ? (1080, 1920) : (720, 1280),
            _ => options.Background is { } b ? Even(srcW * (1 + 2 * b.Padding), srcH * (1 + 2 * b.Padding)) : Even(srcW, srcH),
        };
    }

    static (int, int) Even(double w, double h) => (Math.Max(2, (int)Math.Round(w) / 2 * 2), Math.Max(2, (int)Math.Round(h) / 2 * 2));

    static byte[] RoundedMask(int w, int h, double radius)
    {
        var mask = new byte[w * h];
        Array.Fill(mask, (byte)255);
        if (radius < 1) return mask;
        var r = Math.Min(radius, Math.Min(w, h) / 2.0);
        var ri = (int)Math.Ceiling(r);
        for (var y = 0; y < ri; y++)
            for (var x = 0; x < ri; x++)
            {
                var dx = r - x - 0.5; var dy = r - y - 0.5;
                var d = Math.Sqrt(dx * dx + dy * dy) - r;
                var a = (byte)Math.Round(Math.Clamp(0.5 - d, 0, 1) * 255);
                mask[y * w + x] = a;
                mask[y * w + (w - 1 - x)] = a;
                mask[(h - 1 - y) * w + x] = a;
                mask[(h - 1 - y) * w + (w - 1 - x)] = a;
            }
        return mask;
    }

    /// A plain arrow pointer, white with a dark edge.
    static BgraImage CursorSprite(double scale)
    {
        var s = Math.Max(0.5, scale) * 1.15;
        var size = (int)Math.Ceiling(24 * s);
        using var image = new MagickImage(MagickColors.Transparent, (uint)size, (uint)size);
        PointD P(double x, double y) => new(1 + x * s, 1 + y * s);
        new Drawables().FillColor(MagickColors.White).StrokeColor(MagickColor.FromRgb(20, 20, 24)).StrokeWidth(Math.Max(1, 1.3 * s)).StrokeLineJoin(LineJoin.Round)
            .Polygon(P(0, 0), P(0, 16), P(4, 12.5), P(6.8, 18.6), P(9.4, 17.4), P(6.7, 11.5), P(11.6, 11.5)).Draw(image);
        return BgraImage.FromMagick(image);
    }

    public StudioCamera CameraAt(double t) => StudioDirector.At(t, options, auto, cameraPath, srcW, srcH);

    /// Renders the frame at `t` seconds (of the original recording) into `output`.
    public void Render(BgraImage source, double t, BgraImage output, BgraImage? previous = null)
    {
        Buffer.BlockCopy(canvas.Pixels, 0, output.Pixels, 0, canvas.Pixels.Length);
        var cam = CameraAt(t);
        var c = Content;
        double viewW = srcW / cam.Zoom, viewH = srcH / cam.Zoom;
        double left = cam.X * srcW - viewW / 2, top = cam.Y * srcH - viewH / 2;
        double stepX = viewW / c.Width, stepY = viewH / c.Height;
        var src = source.Pixels;
        var dst = output.Pixels;
        var hasMask = mask.Length > 0;
        Parallel.For(0, c.Height, row =>
        {
            var sy = top + (row + 0.5) * stepY - 0.5;
            var y0 = Math.Clamp((int)Math.Floor(sy), 0, srcH - 1);
            var y1 = Math.Min(y0 + 1, srcH - 1);
            var fy = Math.Clamp(sy - y0, 0, 1);
            var o = ((c.Y + row) * Width + c.X) * 4;
            for (var col = 0; col < c.Width; col++, o += 4)
            {
                var sx = left + (col + 0.5) * stepX - 0.5;
                var x0 = Math.Clamp((int)Math.Floor(sx), 0, srcW - 1);
                var x1 = Math.Min(x0 + 1, srcW - 1);
                var fx = Math.Clamp(sx - x0, 0, 1);
                int a = (y0 * srcW + x0) * 4, b = (y0 * srcW + x1) * 4, cc = (y1 * srcW + x0) * 4, d = (y1 * srcW + x1) * 4;
                var alpha = hasMask ? mask[row * c.Width + col] : 255;
                for (var ch = 0; ch < 3; ch++)
                {
                    var top0 = src[a + ch] + (src[b + ch] - src[a + ch]) * fx;
                    var bottom0 = src[cc + ch] + (src[d + ch] - src[cc + ch]) * fx;
                    var v = top0 + (bottom0 - top0) * fy;
                    dst[o + ch] = alpha == 255 ? (byte)(v + 0.5) : (byte)((v * alpha + dst[o + ch] * (255 - alpha)) / 255 + 0.5);
                }
                dst[o + 3] = 255;
            }
        });
        if (cursor is not null && cursorPath is not null)
        {
            var (px, py) = cursorPath.At(t);
            var ox = c.X + (px - left) / stepX;
            var oy = c.Y + (py - top) / stepY;
            Blend(output, cursor, (int)Math.Round(ox), (int)Math.Round(oy), cam.Zoom * c.Width / srcW, c);
        }
        if (options.MotionBlur && previous is not null)
        {
            // Blend with the frame before while the camera moves.
            var before = CameraAt(t - 1.0 / 30);
            var moving = Math.Abs(before.Zoom - cam.Zoom) > 0.002 || Math.Abs(before.X - cam.X) > 0.0015 || Math.Abs(before.Y - cam.Y) > 0.0015;
            if (moving)
            {
                var p = previous.Pixels;
                for (var i = 0; i < dst.Length; i++) dst[i] = (byte)((dst[i] * 3 + p[i] * 2) / 5);
            }
        }
    }

    static void Blend(BgraImage target, BgraImage sprite, int x, int y, double scale, PixelRect clip)
    {
        var w = Math.Max(4, (int)Math.Round(sprite.Width * scale));
        var h = Math.Max(4, (int)Math.Round(sprite.Height * scale));
        for (var row = 0; row < h; row++)
        {
            var ty = y + row;
            if (ty < clip.Y || ty >= clip.Bottom) continue;
            var sy = Math.Min(sprite.Height - 1, (int)(row / scale));
            for (var col = 0; col < w; col++)
            {
                var tx = x + col;
                if (tx < clip.X || tx >= clip.Right) continue;
                var sx = Math.Min(sprite.Width - 1, (int)(col / scale));
                var si = (sy * sprite.Width + sx) * 4;
                var a = sprite.Pixels[si + 3];
                if (a == 0) continue;
                var ti = (ty * target.Width + tx) * 4;
                for (var ch = 0; ch < 3; ch++) target.Pixels[ti + ch] = (byte)((sprite.Pixels[si + ch] * a + target.Pixels[ti + ch] * (255 - a)) / 255);
            }
        }
    }
}

/// Exports a recording through the studio: decodes it with ffmpeg, renders every frame and
/// encodes the result (on the graphics card when one works), keeping the sound.
public static class VideoStudio
{
    public static double? ParseFps(string banner)
    {
        var m = Regex.Match(banner, @"(\d+(?:\.\d+)?) fps");
        return m.Success ? double.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture) : null;
    }

    public static async Task<string> Export(string input, PointerTrack? track, StudioOptions options, string output, ProgressHandler progress, CancellationToken token)
    {
        var ffmpeg = Tools.RequireFfmpeg("The video studio");
        var banner = await MediaInfo.Banner(input, token);
        var (w, h) = MediaInfo.ParseFrameSize(banner) ?? throw new ConversionException("That file has no picture to edit.");
        var fps = Math.Clamp(ParseFps(banner) ?? 30, 5, 60);
        var duration = MediaInfo.ParseDuration(banner) ?? 0;
        var start = Math.Clamp(options.TrimStart, 0, Math.Max(0, duration - 0.1));
        var end = Math.Clamp(options.TrimEnd ?? duration, start + 0.1, Math.Max(start + 0.1, duration));
        var renderer = new StudioRenderer(w, h, options, track, duration);
        var hasAudio = MediaInfo.StreamLines(banner, "Audio").Any();

        var decode = new ProcessStartInfo(ffmpeg) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
        foreach (var a in new[] { "-hide_banner", "-nostdin", "-loglevel", "error", "-ss", N(start), "-to", N(end), "-i", input, "-an", "-f", "rawvideo", "-pix_fmt", "bgra", "-r", N(fps), "pipe:1" })
            decode.ArgumentList.Add(a);
        var encode = new ProcessStartInfo(ffmpeg) { UseShellExecute = false, RedirectStandardInput = true, RedirectStandardError = true, CreateNoWindow = true };
        var encodeArgs = new List<string>
        {
            "-hide_banner", "-nostdin", "-y", "-loglevel", "error",
            "-f", "rawvideo", "-pix_fmt", "bgra", "-video_size", $"{renderer.Width}x{renderer.Height}", "-framerate", N(fps), "-i", "pipe:0",
        };
        if (hasAudio) encodeArgs.AddRange(["-ss", N(start), "-to", N(end), "-i", input, "-map", "0:v", "-map", "1:a"]);
        encodeArgs.AddRange(["-vf", "format=yuv420p"]);
        encodeArgs.AddRange(ScreenRecording.EncoderArgs(options.Encoder, options.Quality));
        if (hasAudio) encodeArgs.AddRange(["-c:a", "aac", "-b:a", "160k", "-shortest"]);
        encodeArgs.AddRange(["-pix_fmt", "yuv420p", "-movflags", "+faststart", output]);
        foreach (var a in encodeArgs) encode.ArgumentList.Add(a);

        using var decoder = Process.Start(decode) ?? throw new ConversionException("Couldn't start ffmpeg.");
        using var encoder = Process.Start(encode) ?? throw new ConversionException("Couldn't start ffmpeg.");
        var errors = new System.Text.StringBuilder();
        decoder.ErrorDataReceived += (_, e) => { if (e.Data is { } l) lock (errors) errors.AppendLine(l); };
        encoder.ErrorDataReceived += (_, e) => { if (e.Data is { } l) lock (errors) errors.AppendLine(l); };
        decoder.BeginErrorReadLine();
        encoder.BeginErrorReadLine();
        using var cancel = token.Register(() => { try { decoder.Kill(true); } catch { } try { encoder.Kill(true); } catch { } });
        try
        {
            await Task.Run(() =>
            {
                var frame = new BgraImage(w, h);
                var current = new BgraImage(renderer.Width, renderer.Height);
                var previous = new BgraImage(renderer.Width, renderer.Height);
                var input = decoder.StandardOutput.BaseStream;
                var outStream = encoder.StandardInput.BaseStream;
                var total = Math.Max(1, (int)Math.Round((end - start) * fps));
                var index = 0;
                while (ReadFull(input, frame.Pixels))
                {
                    token.ThrowIfCancellationRequested();
                    var t = start + index / fps;
                    renderer.Render(frame, t, current, index > 0 ? previous : null);
                    outStream.Write(current.Pixels);
                    (current, previous) = (previous, current);
                    index++;
                    progress(Math.Min(0.99, (double)index / total));
                }
                outStream.Close();
            }, token);
            await decoder.WaitForExitAsync(token);
            await encoder.WaitForExitAsync(token);
        }
        catch (IOException)
        {
            // ffmpeg stopped early; its message says why.
            try { decoder.Kill(true); } catch { }
            encoder.WaitForExit(30_000);
        }
        if (encoder.ExitCode != 0 || !File.Exists(output))
        {
            string detail;
            lock (errors) detail = string.Join(" ", errors.ToString().Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0).TakeLast(3));
            throw new ConversionException($"The video couldn't be made. {detail}".Trim());
        }
        progress(1);
        return output;
    }

    static bool ReadFull(Stream stream, byte[] buffer)
    {
        var read = 0;
        while (read < buffer.Length)
        {
            var n = stream.Read(buffer, read, buffer.Length - read);
            if (n == 0) return false;
            read += n;
        }
        return true;
    }

    static string N(double v) => v.ToString("0.###", CultureInfo.InvariantCulture);
}
