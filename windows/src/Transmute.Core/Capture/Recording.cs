using System.Globalization;

namespace Transmute;

public enum RecordingQuality { High, Standard }

/// How a screen recording is encoded. The frames come from Spinform itself (grabbed from the
/// screen and piped into ffmpeg as raw pixels), so this only covers ffmpeg's side.
public sealed record RecordingFormat
{
    public int Width { get; init; }
    public int Height { get; init; }
    public int Fps { get; init; } = 30;
    public RecordingQuality Quality { get; init; } = RecordingQuality.High;
    /// The longest side of the video; 0 keeps the screen's own size.
    public int MaxSide { get; init; }
    /// An ffmpeg H.264 encoder (libx264, h264_nvenc, h264_qsv, h264_amf, h264_mf).
    public string Encoder { get; init; } = "libx264";
}

public static class ScreenRecording
{
    static string N(double v) => v.ToString("0.###", CultureInfo.InvariantCulture);

    /// Video size after the longest-side limit, always even (H.264 needs that).
    public static (int Width, int Height) OutputSize(RecordingFormat f)
    {
        double w = f.Width, h = f.Height;
        if (f.MaxSide > 0 && Math.Max(w, h) > f.MaxSide)
        {
            var scale = f.MaxSide / Math.Max(w, h);
            w *= scale;
            h *= scale;
        }
        return (Math.Max(2, (int)Math.Round(w) / 2 * 2), Math.Max(2, (int)Math.Round(h) / 2 * 2));
    }

    static IEnumerable<string> EncoderArgs(string encoder, RecordingQuality quality) => encoder switch
    {
        "h264_nvenc" => ["-c:v", "h264_nvenc", "-preset", "p4", "-cq", quality == RecordingQuality.High ? "21" : "27"],
        "h264_qsv" => ["-c:v", "h264_qsv", "-global_quality", quality == RecordingQuality.High ? "22" : "28"],
        "h264_amf" => ["-c:v", "h264_amf", "-quality", "balanced", "-rc", "cqp", "-qp_i", quality == RecordingQuality.High ? "20" : "26", "-qp_p", quality == RecordingQuality.High ? "22" : "28"],
        "h264_mf" => ["-c:v", "h264_mf", "-b:v", quality == RecordingQuality.High ? "12M" : "5M"],
        _ => ["-c:v", "libx264", "-preset", quality == RecordingQuality.High ? "veryfast" : "ultrafast", "-crf", quality == RecordingQuality.High ? "20" : "26", "-tune", "zerolatency"],
    };

    /// ffmpeg's arguments while recording: raw BGRA frames on stdin, each stamped with the time it
    /// arrives, so a slow moment repeats a frame instead of making the video run fast.
    public static List<string> LiveArgs(RecordingFormat f, string output)
    {
        var (ow, oh) = OutputSize(f);
        var filters = new List<string>();
        if (ow != f.Width || oh != f.Height) filters.Add($"scale={ow}:{oh}:flags=bicubic");
        filters.Add("format=yuv420p");
        var args = new List<string>
        {
            "-hide_banner", "-nostdin", "-y", "-loglevel", "error",
            "-f", "rawvideo", "-pix_fmt", "bgra", "-video_size", $"{f.Width}x{f.Height}", "-framerate", f.Fps.ToString(CultureInfo.InvariantCulture),
            "-use_wallclock_as_timestamps", "1", "-thread_queue_size", "16", "-i", "pipe:0",
            "-vf", string.Join(",", filters), "-fps_mode", "cfr", "-r", f.Fps.ToString(CultureInfo.InvariantCulture),
        };
        args.AddRange(EncoderArgs(f.Encoder, f.Quality));
        args.AddRange(["-pix_fmt", "yuv420p", "-movflags", "+faststart", output]);
        return args;
    }

    /// One recorded sound track and when it started, in seconds after the first video frame
    /// (negative when it started before).
    public sealed record AudioTrack(string Path, double Offset);

    /// Puts the sound tracks (microphone, computer sound) under the video. The video is copied
    /// as it is; tracks are lined up by their start times and mixed.
    public static List<string> MuxArgs(string video, IReadOnlyList<AudioTrack> tracks, string output)
    {
        var args = new List<string> { "-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-i", video };
        foreach (var t in tracks)
        {
            if (t.Offset < 0) args.AddRange(["-ss", N(-t.Offset)]);
            else if (t.Offset > 0) args.AddRange(["-itsoffset", N(t.Offset)]);
            args.AddRange(["-i", t.Path]);
        }
        args.AddRange(["-map", "0:v"]);
        if (tracks.Count == 1) args.AddRange(["-map", "1:a"]);
        else if (tracks.Count > 1)
        {
            var inputs = string.Concat(Enumerable.Range(1, tracks.Count).Select(i => $"[{i}:a]"));
            args.AddRange(["-filter_complex", $"{inputs}amix=inputs={tracks.Count}:duration=longest:normalize=0[a]", "-map", "[a]"]);
        }
        args.AddRange(["-c:v", "copy"]);
        if (tracks.Count > 0) args.AddRange(["-c:a", "aac", "-b:a", "160k", "-shortest"]);
        args.AddRange(["-movflags", "+faststart", output]);
        return args;
    }

    /// The hardware H.264 encoders to try, best first; libx264 always works.
    public static readonly string[] HardwareEncoders = ["h264_nvenc", "h264_qsv", "h264_amf", "h264_mf"];
}
