using System.Globalization;
using System.Text.RegularExpressions;

namespace Transmute;

/// Video and audio, through the ffmpeg that ships with Transmute.
public static class MediaConverter
{
    public static async Task<string> Convert(string input, OutputFormat format, ConversionOptions options,
        ProgressHandler progress, CancellationToken token)
    {
        var ffmpeg = Tools.RequireFfmpeg("Converting video and audio");
        var args = FfmpegArgs(format) ?? throw new ConversionException($"Can't convert media to {format.Label()}.");
        var output = OutputPaths.Destination(input, format.Extension(), null, options.OutputFolder);
        if (options.StripMetadata) args = [.. args, "-map_metadata", "-1"];
        var streams = MediaStreams.Parse(await MediaInfo.Banner(input, token));
        try
        {
            try
            {
                await RunFfmpeg(ffmpeg, input, [.. streams.Maps(args), .. args], output, progress, token);
            }
            catch (ConversionException) when (!token.IsCancellationRequested && !args.Contains("-an"))
            {
                // A second go with plain stereo sound, which most failures on odd camera files come down to.
                OutputPaths.TryDelete(output);
                await RunFfmpeg(ffmpeg, input, [.. streams.Maps(args), .. args, "-ac", "2"], output, progress, token);
            }
        }
        catch
        {
            OutputPaths.TryDelete(output);
            throw;
        }
        return output;
    }

    static readonly string[] EvenSize = ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2"];

    public static string[]? FfmpegArgs(OutputFormat format)
    {
        string[] h264 = ["-c:v", "libx264", "-preset", "medium", "-crf", "23", "-pix_fmt", "yuv420p", .. EvenSize];
        return format switch
        {
            OutputFormat.Mp4 => [.. h264, "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"],
            OutputFormat.Mov => [.. h264, "-c:a", "aac", "-b:a", "160k"],
            OutputFormat.Mkv => [.. h264, "-c:a", "aac", "-b:a", "160k"],
            OutputFormat.Avi => ["-c:v", "mpeg4", "-q:v", "4", "-c:a", "libmp3lame", "-q:a", "4"],
            OutputFormat.Wmv => ["-c:v", "wmv2", "-b:v", "2M", "-c:a", "wmav2", "-b:a", "160k"],
            OutputFormat.Webm => [.. Tools.WebmVideo(32, null), "-c:a", "libopus", "-b:a", "128k"],
            OutputFormat.Gif => ["-an", "-vf", "fps=12,scale=480:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop", "0"],
            OutputFormat.Mp3 => ["-vn", "-c:a", "libmp3lame", "-q:a", "2"],
            OutputFormat.M4a => ["-vn", "-c:a", "aac", "-b:a", "192k"],
            OutputFormat.Wav => ["-vn", "-c:a", "pcm_s16le"],
            OutputFormat.Flac => ["-vn", "-c:a", "flac"],
            OutputFormat.Ogg => ["-vn", "-c:a", "libvorbis", "-q:a", "5"],
            OutputFormat.Opus => ["-vn", "-c:a", "libopus", "-b:a", "128k"],
            OutputFormat.Aiff => ["-vn", "-c:a", "pcm_s16be"],
            OutputFormat.Wma => ["-vn", "-c:a", "wmav2", "-b:a", "192k"],
            _ => null,
        };
    }

    public static async Task RunFfmpeg(string ffmpeg, string input, IEnumerable<string> args, string output,
        ProgressHandler progress, CancellationToken token)
    {
        var tracker = new FfmpegProgress(progress);
        string[] full = ["-hide_banner", "-nostdin", "-y", "-progress", "pipe:1", "-nostats", "-i", input, .. args, output];
        await Shell.Check(ffmpeg, full, token, onStdoutLine: tracker.Stdout, onStderrLine: tracker.Stderr);
        progress(1);
    }

    // Compression

    public static async Task<JobResult> Compress(string input, FileKind kind, long goal, ConversionOptions options,
        ProgressHandler progress, CancellationToken token)
    {
        var ffmpeg = Tools.RequireFfmpeg("Compressing video and audio");
        var duration = await MediaInfo.Duration(input, token);
        if (duration <= 0) throw new ConversionException($"Couldn't read the length of {Path.GetFileName(input)}.");
        var ext = Path.GetExtension(input).TrimStart('.').ToLowerInvariant();
        var totalBitsPerSecond = goal * 8 * 0.95 / duration;

        string outExt;
        List<string> args;
        if (kind == FileKind.Video)
        {
            outExt = ext is "mp4" or "mov" or "mkv" or "webm" ? ext : "mp4";
            const double audio = 96_000;
            var video = Math.Min(500_000_000, Math.Max(80_000, totalBitsPerSecond - audio));
            var filters = "scale=trunc(iw/2)*2:trunc(ih/2)*2";
            if (video < 500_000) filters = "scale=w='min(854,iw)':h=-2";
            else if (video < 1_500_000) filters = "scale=w='min(1280,iw)':h=-2";
            var v = ((long)video).ToString(CultureInfo.InvariantCulture);
            if (outExt == "webm")
            {
                args = [.. Tools.WebmVideo(null, v), "-vf", filters, "-c:a", "libopus", "-b:a", "96k"];
            }
            else
            {
                args = ["-c:v", "libx264", "-preset", "medium", "-b:v", v, "-maxrate", ((long)(video * 1.4)).ToString(CultureInfo.InvariantCulture),
                    "-bufsize", ((long)(video * 2)).ToString(CultureInfo.InvariantCulture), "-pix_fmt", "yuv420p", "-vf", filters,
                    "-c:a", "aac", "-b:a", "96k"];
                if (outExt != "mkv") args.AddRange(["-movflags", "+faststart"]);
            }
        }
        else
        {
            outExt = ext is "mp3" or "m4a" or "ogg" or "opus" ? ext : "m4a";
            var bitrate = ((long)Math.Min(320_000, Math.Max(32_000, totalBitsPerSecond))).ToString(CultureInfo.InvariantCulture);
            var codec = outExt switch { "mp3" => "libmp3lame", "ogg" => "libvorbis", "opus" => "libopus", _ => "aac" };
            args = ["-vn", "-c:a", codec, "-b:a", bitrate];
        }
        if (options.StripMetadata) args.AddRange(["-map_metadata", "-1"]);

        var output = OutputPaths.Destination(input, outExt, "compressed", options.OutputFolder);
        try
        {
            var streams = MediaStreams.Parse(await MediaInfo.Banner(input, token));
            await RunFfmpeg(ffmpeg, input, [.. streams.Maps(args), .. args], output, progress, token);
        }
        catch
        {
            OutputPaths.TryDelete(output);
            throw;
        }
        return SizeResult(input, output, goal);
    }

    public static JobResult SizeResult(string input, string output, long goal)
    {
        long before = OutputPaths.FileSize(input), after = OutputPaths.FileSize(output);
        var message = $"{OutputPaths.FormatSize(before)} → {OutputPaths.FormatSize(after)}";
        if (after > goal + goal / 10) message += $" (target {OutputPaths.FormatSize(goal)} was too small to hit exactly)";
        return new JobResult([output], message);
    }

    public static async Task<string> StripMetadata(string input, ConversionOptions options, CancellationToken token)
    {
        var ffmpeg = Tools.RequireFfmpeg("Removing metadata from video and audio");
        var output = OutputPaths.Destination(input, Path.GetExtension(input).TrimStart('.'), "clean", options.OutputFolder);
        try
        {
            var maps = MediaStreams.Parse(await MediaInfo.Banner(input, token)).CopyMaps();
            await Shell.Check(ffmpeg, ["-hide_banner", "-nostdin", "-y", "-i", input, .. maps, "-map_metadata", "-1",
                "-map_chapters", "-1", "-c", "copy", output], token);
        }
        catch
        {
            OutputPaths.TryDelete(output);
            throw;
        }
        return output;
    }
}

/// The tracks in a media file as ffmpeg lists them, so a conversion can pick ones ffmpeg can decode.
/// Recent iPhones add a spatial-audio track (APAC) next to the normal one, which ffmpeg can't decode.
public sealed class MediaStreams
{
    public sealed record Track(string Type, string Codec, int? Channels, bool IsDefault, bool AttachedPicture);

    public IReadOnlyList<Track> Tracks { get; init; } = [];

    /// Codecs ffmpeg lists but can't decode.
    public static readonly HashSet<string> Undecodable = ["none", "apac"];

    static readonly Regex StreamLine = new(@"Stream #0:\d+(?:\[0x[0-9a-fA-F]+\])?(?:\([^)]*\))?: (\w+): (.*)");

    /// Reads lines like "Stream #0:1[0x2](und): Audio: aac (LC) (mp4a / 0x6134706D), 48000 Hz, stereo, fltp (default)".
    public static MediaStreams Parse(string banner)
    {
        var tracks = new List<Track>();
        foreach (var line in banner.Split('\n', '\r'))
        {
            var m = StreamLine.Match(line);
            if (!m.Success) continue;
            var type = m.Groups[1].Value;
            var details = m.Groups[2].Value.Trim();
            var codec = new string(details.TakeWhile(c => c != ' ' && c != ',').ToArray()).ToLowerInvariant();
            int? channels = null;
            if (type == "Audio") channels = MediaInfo.ParseSoundTrack(line)?.Channels;
            tracks.Add(new Track(type, codec, channels, line.Contains("(default)"), line.Contains("attached pic")));
        }
        return new MediaStreams { Tracks = tracks };
    }

    Track? BestAudio
    {
        get
        {
            var audio = Tracks.Where(t => t.Type == "Audio" && !Undecodable.Contains(t.Codec)).ToList();
            return audio.FirstOrDefault(t => t.IsDefault) ?? audio.FirstOrDefault();
        }
    }

    /// "0:a:1": the default sound track if ffmpeg can decode it, otherwise the first one it can.
    public string? AudioSpec
    {
        get
        {
            if (BestAudio is not { } best) return null;
            var index = Tracks.Where(t => t.Type == "Audio").ToList().IndexOf(best);
            return index < 0 ? null : $"0:a:{index}";
        }
    }

    /// "0:V:0": the first real video track (not cover art).
    public string? VideoSpec
    {
        get
        {
            var videos = Tracks.Where(t => t.Type == "Video" && !t.AttachedPicture).ToList();
            var index = videos.FindIndex(t => !Undecodable.Contains(t.Codec));
            return index < 0 ? null : $"0:V:{index}";
        }
    }

    public int? AudioChannels => BestAudio?.Channels;

    /// "-map 0" without the tracks ffmpeg can't read, for copying a file's tracks as they are.
    public string[] CopyMaps()
    {
        var maps = new List<string> { "-map", "0" };
        foreach (var (type, prefix) in new[] { ("Video", "v"), ("Audio", "a"), ("Subtitle", "s"), ("Data", "d"), ("Attachment", "t") })
        {
            var same = Tracks.Where(t => t.Type == type).ToList();
            for (var i = 0; i < same.Count; i++)
                if (Undecodable.Contains(same[i].Codec)) maps.AddRange(["-map", $"-0:{prefix}:{i}"]);
        }
        return [.. maps];
    }

    static readonly HashSet<string> TwoChannelCodecs = ["libmp3lame", "wmav2", "libopus"];

    /// -map arguments for these encoder arguments (which say "-vn" for sound only, "-an" for no sound).
    /// Empty when the file couldn't be read, which leaves the choice to ffmpeg.
    public string[] Maps(IReadOnlyList<string> args)
    {
        if (Tracks.Count == 0) return [];
        var maps = new List<string>();
        if (!args.Contains("-vn") && VideoSpec is { } v) maps.AddRange(["-map", v]);
        if (!args.Contains("-an") && AudioSpec is { } a) maps.AddRange(["-map", a]);
        if (maps.Count == 0) return [];
        // MP3 and WMA hold at most two channels, and Opus refuses camera surround layouts like
        // 5.1(side): surround and spatial sound is mixed down to stereo for those.
        var codecAt = args.ToList().IndexOf("-c:a");
        if (AudioChannels > 2 && codecAt >= 0 && codecAt + 1 < args.Count && TwoChannelCodecs.Contains(args[codecAt + 1]))
            maps.AddRange(["-ac", "2"]);
        // Files with sparse tracks otherwise stop with "Too many packets buffered for output stream".
        maps.AddRange(["-max_muxing_queue_size", "4096"]);
        return [.. maps];
    }
}

/// Turns ffmpeg's `-progress` output into a 0…1 fraction.
public sealed class FfmpegProgress(ProgressHandler handler, double knownSeconds = 0)
{
    double duration = knownSeconds;

    public void Stderr(string line)
    {
        if (duration > 0) return;
        if (MediaInfo.ParseDuration(line) is { } seconds) duration = seconds;
    }

    public void Stdout(string line)
    {
        if (!line.StartsWith("out_time_us=") && !line.StartsWith("out_time_ms=")) return;
        if (!double.TryParse(line[(line.IndexOf('=') + 1)..], NumberStyles.Float, CultureInfo.InvariantCulture, out var micro)) return;
        if (duration > 0) handler(Math.Clamp(micro / 1_000_000 / duration, 0, 1));
    }

    /// A progress reader for an output of a known length.
    public static Action<string> ForSeconds(double total, ProgressHandler report) =>
        new FfmpegProgress(report, total).Stdout;
}

/// Facts about a media file, read from ffmpeg's banner.
public static class MediaInfo
{
    public sealed record SoundTrack(int? SampleRate, int? Channels);

    public static async Task<string> Banner(string path, CancellationToken token = default)
    {
        var ffmpeg = Tools.Ffmpeg;
        if (ffmpeg is null) return "";
        var output = await Shell.Run(ffmpeg, ["-hide_banner", "-nostdin", "-i", path], token);
        return output.Stderr;
    }

    public static async Task<double> Duration(string path, CancellationToken token = default) =>
        ParseDuration(await Banner(path, token)) ?? 0;

    /// Finds "Duration: 00:01:02.50" in ffmpeg's banner.
    public static double? ParseDuration(string text)
    {
        var at = text.IndexOf("Duration: ", StringComparison.Ordinal);
        if (at < 0) return null;
        var stamp = text[(at + 10)..].Split(',')[0];
        var parts = stamp.Split(':');
        if (parts.Length != 3) return null;
        double total = 0;
        foreach (var p in parts)
        {
            if (!double.TryParse(p.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var v)) return null;
            total = total * 60 + v;
        }
        return total;
    }

    public static IEnumerable<string> StreamLines(string banner, string type) =>
        banner.Split('\n', '\r').Where(l => l.Contains("Stream #") && l.Contains(type + ":"));

    public static async Task<bool> HasAudio(string path, CancellationToken token = default) =>
        StreamLines(await Banner(path, token), "Audio").Any();

    public static async Task<bool> HasVideo(string path, CancellationToken token = default) =>
        StreamLines(await Banner(path, token), "Video").Any(l => !l.Contains("attached pic"));

    public static async Task<(int Width, int Height)?> FrameSize(string path, CancellationToken token = default) =>
        ParseFrameSize(await Banner(path, token));

    /// Reads "320x240" from the first video stream line, swapped for phone video stored sideways.
    public static (int Width, int Height)? ParseFrameSize(string banner)
    {
        var line = StreamLines(banner, "Video").FirstOrDefault();
        if (line is null) return null;
        var m = Regex.Match(line, @"(?<![0-9x])([0-9]{2,5})x([0-9]{2,5})(?![0-9])");
        if (!m.Success) return null;
        int w = int.Parse(m.Groups[1].Value), h = int.Parse(m.Groups[2].Value);
        if (w <= 0 || h <= 0) return null;
        foreach (var pattern in new[] { @"rotation of (-?[0-9]+(?:\.[0-9]+)?) degrees", @"rotate\s*:\s*(-?[0-9]+)" })
        {
            var r = Regex.Match(banner, pattern);
            if (!r.Success) continue;
            var degrees = (int)Math.Round(double.Parse(r.Groups[1].Value, CultureInfo.InvariantCulture));
            if (Math.Abs(degrees) % 180 == 90) (w, h) = (h, w);
            break;
        }
        return (w, h);
    }

    public static async Task<SoundTrack?> Sound(string path, CancellationToken token = default) =>
        ParseSoundTrack(await Banner(path, token));

    /// Reads "Audio: aac (LC), 44100 Hz, stereo, fltp".
    public static SoundTrack? ParseSoundTrack(string banner)
    {
        var line = StreamLines(banner, "Audio").FirstOrDefault();
        if (line is null) return null;
        var fields = line[(line.IndexOf("Audio:", StringComparison.Ordinal) + 6)..].Split(',').Select(f => f.Trim()).ToList();
        int? rate = null, channels = null;
        var index = fields.FindIndex(f => f.EndsWith(" Hz"));
        if (index >= 0)
        {
            if (int.TryParse(fields[index][..^3], out var r)) rate = r;
            if (index + 1 < fields.Count) channels = ChannelCount(fields[index + 1]);
        }
        return new SoundTrack(rate, channels);
    }

    static int? ChannelCount(string layout)
    {
        var name = layout.ToLowerInvariant();
        if (name == "mono") return 1;
        if (name is "stereo" or "downmix") return 2;
        if (name.EndsWith(" channels") || name.EndsWith(" channel"))
            return int.TryParse(new string(name.TakeWhile(char.IsDigit).ToArray()), out var n) ? n : null;
        var named = new Dictionary<string, int>
        {
            ["2.1"] = 3, ["3.0"] = 3, ["4.0"] = 4, ["quad"] = 4, ["5.0"] = 5, ["5.0(side)"] = 5, ["4.1"] = 5,
            ["5.1"] = 6, ["5.1(side)"] = 6, ["6.0"] = 6, ["6.1"] = 7, ["7.0"] = 7, ["7.1"] = 8, ["7.1(wide)"] = 8,
        };
        return named.TryGetValue(name, out var c) ? c : null;
    }

    /// "1:05", "1:02:03", or with tenths "1:05.3".
    public static string TimeLabel(double seconds, bool tenths = false)
    {
        var value = double.IsFinite(seconds) ? Math.Clamp(seconds, 0, 1_000_000) : 0;
        var units = tenths ? (int)Math.Round(value * 10) : (int)Math.Round(value);
        var whole = tenths ? units / 10 : units;
        int h = whole / 3600, m = whole / 60 % 60, s = whole % 60;
        var text = h > 0 ? $"{h}:{m:00}:{s:00}" : $"{m}:{s:00}";
        if (tenths) text += $".{units % 10}";
        return text;
    }
}
