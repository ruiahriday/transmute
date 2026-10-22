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

public enum RedactionStyle { Blackout, Pixelate, Blur }

public sealed record Redaction(NormRect Rect, RedactionStyle Style);

public enum AnnotationKind { Text, Rectangle, Arrow, Highlight }

/// Text: `Text` at `From` (its top-left). Rectangle and highlight: the box from `From` to `To`.
/// Arrow: from `From` pointing at `To`. `Size` is a fraction of the picture's height: the font size
/// for text, the line width for shapes.
public sealed record Annotation(AnnotationKind Kind, NormPoint From, NormPoint To, Rgba Color, double Size, string Text = "");

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
            foreach (var r in edit.Redactions) Redact(image, r, w, h);
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
                piece.FilterType = FilterType.Point;
                piece.Resize(new MagickGeometry((uint)px.Width, (uint)px.Height) { IgnoreAspectRatio = true });
                image.Composite(piece, px.X, px.Y, CompositeOperator.Over);
                break;
            }
            case RedactionStyle.Blur:
            {
                using var piece = (MagickImage)image.CloneArea(area);
                var sigma = Math.Max(8, Math.Max(w, h) / 60.0);
                // Shrinking first makes a heavy blur fast and impossible to undo.
                piece.Resize(new Percentage(25));
                piece.Blur(0, sigma / 4);
                piece.Resize(new MagickGeometry((uint)px.Width, (uint)px.Height) { IgnoreAspectRatio = true });
                piece.Blur(0, sigma / 2);
                image.Composite(piece, px.X, px.Y, CompositeOperator.Over);
                break;
            }
        }
    }

    static void Annotate(MagickImage image, Annotation a, int w, int h)
    {
        var size = Math.Max(1, a.Size * h);
        double x0 = a.From.X * w, y0 = a.From.Y * h, x1 = a.To.X * w, y1 = a.To.Y * h;
        var color = a.Color.Magick;
        switch (a.Kind)
        {
            case AnnotationKind.Text:
                if (string.IsNullOrWhiteSpace(a.Text)) return;
                var d = new Drawables().FillColor(color).StrokeColor(MagickColors.Transparent).FontPointSize(size)
                    .Gravity(Gravity.Northwest);
                if (Fonts.BoldSansFile() is { } font) d = d.Font(font);
                // Lines one under the other, the first with its top at the point.
                var lines = a.Text.Replace("\r", "").Split('\n');
                for (var i = 0; i < lines.Length; i++) d = d.Text(x0, y0 + i * size * 1.2, lines[i]);
                d.Draw(image);
                break;
            case AnnotationKind.Rectangle:
            {
                var r = NormRect.Between(a.From, a.To);
                new Drawables().FillColor(MagickColors.Transparent).StrokeColor(color).StrokeWidth(size)
                    .Rectangle(r.X * w, r.Y * h, r.MaxX * w, r.MaxY * h).Draw(image);
                break;
            }
            case AnnotationKind.Highlight:
            {
                var r = NormRect.Between(a.From, a.To);
                new Drawables().FillColor(a.Color.WithAlpha(0.35).Magick).StrokeColor(MagickColors.Transparent)
                    .Rectangle(r.X * w, r.Y * h, r.MaxX * w, r.MaxY * h).Draw(image);
                break;
            }
            case AnnotationKind.Arrow:
            {
                var length = Math.Sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0));
                if (length < 1) return;
                double ux = (x1 - x0) / length, uy = (y1 - y0) / length;
                var head = Math.Min(length * 0.5, size * 4.5);
                // The shaft stops where the head starts so its square end doesn't poke out.
                double bx = x1 - ux * head, by = y1 - uy * head;
                double px = -uy * head * 0.55, py = ux * head * 0.55;
                new Drawables().StrokeColor(color).StrokeWidth(size).StrokeLineCap(LineCap.Round).FillColor(MagickColors.Transparent)
                    .Line(x0, y0, bx, by).Draw(image);
                new Drawables().FillColor(color).StrokeColor(MagickColors.Transparent)
                    .Polygon(new PointD(x1, y1), new PointD(bx + px, by + py), new PointD(bx - px, by - py)).Draw(image);
                break;
            }
        }
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
