using System.Diagnostics;
using System.Text.Json;

namespace Transmute.Desktop;

/// What a recording shows on top of the screen.
public sealed record RecordingLook
{
    public bool Cursor { get; init; } = true;
    public bool Clicks { get; init; } = true;
    /// RRGGBB
    public int ClickColor { get; init; } = 0xF59E0B;
    /// Ring radius in pixels at 100% scaling.
    public int ClickSize { get; init; } = 22;
    public bool ClickFilled { get; init; }
    public bool ClickAnimated { get; init; } = true;
    public bool Keystrokes { get; init; }
    public bool KeystrokesShortcutsOnly { get; init; }
    /// 0 bottom centre, 1 bottom left, 2 bottom right, 3 top centre.
    public int KeystrokePosition { get; init; }
    public int KeystrokeSize { get; init; } = 22;
    public bool KeystrokesDark { get; init; } = true;
}

/// One moment of pointer activity, for the studio's automatic zooms.
public sealed record PointerSample(double Time, int X, int Y, bool Click);

public sealed record RecordingResult(string Path, double Seconds, int Width, int Height, IReadOnlyList<string> Notes, string EventsPath);

/// Records part of the screen to an MP4. Spinform grabs each frame itself (GDI, physical pixels,
/// any area across any displays), draws the pointer, clicks, keys and camera on it, and pipes it to
/// the bundled ffmpeg, which stamps frames by arrival time so the video keeps real time even when
/// the PC is busy. Sound is recorded alongside and mixed in when the recording stops.
public sealed class ScreenRecorder : IDisposable
{
    readonly PixelRect area;
    readonly RecordingFormat format;
    readonly RecordingLook look;
    readonly string output, work, ffmpeg;
    readonly Stopwatch clock = new();
    readonly List<PointerSample> samples = [];
    readonly List<(double Time, int X, int Y)> clicks = [];
    readonly KeystrokeText keys = new();
    readonly bool microphone, systemSound;
    Process? process;
    Thread? thread;
    volatile bool running;
    InputHooks? hooks;
    AudioCapture? audio;
    double firstFrame = -1;
    string? failure;
    public double Scale { get; init; } = 1;

    /// Called on the recording thread for each frame: the camera picture to draw and where, in
    /// screen pixels, or null.
    public Func<(BgraImage Image, int X, int Y)?>? Camera { get; set; }

    public TimeSpan Elapsed => clock.Elapsed;
    public bool IsRunning => running;
    public int FramesWritten { get; private set; }
    public PixelRect Area => area;

    public ScreenRecorder(PixelRect area, RecordingFormat format, RecordingLook look, string output, bool microphone = false, bool systemSound = false, string? ffmpeg = null)
    {
        this.area = area.Even();
        this.format = format with { Width = this.area.Width, Height = this.area.Height };
        this.look = look;
        this.output = output;
        this.microphone = microphone;
        this.systemSound = systemSound;
        this.ffmpeg = ffmpeg ?? Tools.RequireFfmpeg("Screen recording");
        work = OutputPaths.TempDir();
        keys.ShortcutsOnly = look.KeystrokesShortcutsOnly;
    }

    public List<string> Notes { get; } = [];

    public void Start()
    {
        var video = Path.Combine(work, "video.mp4");
        var info = new ProcessStartInfo(ffmpeg) { UseShellExecute = false, RedirectStandardInput = true, RedirectStandardError = true, CreateNoWindow = true };
        foreach (var a in ScreenRecording.LiveArgs(format, video)) info.ArgumentList.Add(a);
        process = Process.Start(info) ?? throw new ConversionException("Couldn't start ffmpeg.");
        var errors = new System.Text.StringBuilder();
        process.ErrorDataReceived += (_, e) => { if (e.Data is { } line) lock (errors) { if (errors.Length < 4000) errors.AppendLine(line); } };
        process.BeginErrorReadLine();
        stderr = errors;
        if (look.Clicks || look.Keystrokes)
        {
            hooks = new InputHooks(look.Clicks, look.Keystrokes);
            hooks.Clicked += (x, y) => { lock (clicks) clicks.Add((clock.Elapsed.TotalSeconds, x, y)); };
            hooks.KeyPressed += vk => { lock (keys) keys.Press(vk); };
        }
        clock.Start();
        if (microphone || systemSound)
        {
            audio = new AudioCapture(clock, work, microphone, systemSound);
            Notes.AddRange(audio.Problems);
        }
        running = true;
        thread = new Thread(Loop) { IsBackground = true, Name = "Spinform recorder", Priority = ThreadPriority.AboveNormal };
        thread.Start();
    }

    System.Text.StringBuilder? stderr;

    void Loop()
    {
        try
        {
            using var grabber = new ScreenGrabber(area.Width, area.Height);
            var stdin = process!.StandardInput.BaseStream;
            var interval = 1.0 / Math.Clamp(format.Fps, 5, 60);
            var next = clock.Elapsed.TotalSeconds;
            while (running)
            {
                var now = clock.Elapsed.TotalSeconds;
                if (now < next)
                {
                    var wait = (next - now) * 1000;
                    if (wait > 1.5) Thread.Sleep((int)(wait - 1));
                    else Thread.SpinWait(200);
                    continue;
                }
                grabber.Grab(area.X, area.Y, layered: false);
                Decorate(grabber, now);
                if (firstFrame < 0) firstFrame = clock.Elapsed.TotalSeconds;
                stdin.Write(grabber.Pixels);
                FramesWritten++;
                next += interval;
                if (next < clock.Elapsed.TotalSeconds - interval) next = clock.Elapsed.TotalSeconds; // fell behind: catch up
            }
            stdin.Flush();
        }
        catch (Exception e)
        {
            failure = e is IOException ? "ffmpeg stopped taking frames" : e.Message;
            running = false;
        }
    }

    void Decorate(ScreenGrabber grabber, double now)
    {
        var (cx, cy) = Screens.Cursor;
        bool clicked;
        List<(double Time, int X, int Y)> recent;
        lock (clicks)
        {
            clicked = clicks.Count > 0 && clicks[^1].Time > now - 0.05;
            recent = clicks.Where(c => now - c.Time < 0.45).ToList();
            clicks.RemoveAll(c => now - c.Time > 2);
        }
        if (samples.Count == 0 || samples[^1].X != cx - area.X || samples[^1].Y != cy - area.Y || clicked)
            samples.Add(new PointerSample(Math.Round(now, 3), cx - area.X, cy - area.Y, clicked));
        if (look.Clicks)
        {
            foreach (var c in recent)
            {
                var p = (now - c.Time) / 0.45;
                var radius = (int)Math.Round(look.ClickSize * Scale * (look.ClickAnimated ? 0.55 + 0.6 * p : 1));
                grabber.DrawRing(c.X - area.X, c.Y - area.Y, radius, look.ClickColor, (int)Math.Max(2, 3 * Scale), look.ClickFilled);
            }
        }
        if (Camera?.Invoke() is { } cam) grabber.Blend(cam.Image, cam.X - area.X, cam.Y - area.Y);
        if (look.Cursor) grabber.DrawCursor(area.X, area.Y);
        if (look.Keystrokes)
        {
            string text;
            DateTime changed;
            lock (keys) { text = keys.Text; changed = keys.Changed; }
            if (text.Length > 0 && DateTime.Now - changed < TimeSpan.FromSeconds(1.8))
                grabber.DrawLabel(text, (int)Math.Round(look.KeystrokeSize * Scale), look.KeystrokesDark, look.KeystrokePosition);
        }
    }

    /// Finishes the video: stops grabbing, lets ffmpeg write the end of the file, mixes in sound.
    public async Task<RecordingResult> Stop()
    {
        running = false;
        thread?.Join(5000);
        var seconds = clock.Elapsed.TotalSeconds - Math.Max(0, firstFrame);
        clock.Stop();
        hooks?.Dispose();
        var tracks = audio?.Stop() ?? [];
        try { process!.StandardInput.Close(); } catch { }
        if (process is not null && !process.WaitForExit(60_000)) { try { process.Kill(true); } catch { } }
        var video = Path.Combine(work, "video.mp4");
        if (process?.ExitCode != 0 || !File.Exists(video) || new FileInfo(video).Length == 0)
        {
            string detail;
            lock (stderr!) detail = string.Join(" ", stderr.ToString().Trim().Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0).TakeLast(3));
            throw new ConversionException($"The recording couldn't be saved{(failure is null ? "" : $" ({failure})")}. {detail}".Trim());
        }
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(output))!);
        if (tracks.Count > 0)
        {
            var list = tracks.Select(t => new ScreenRecording.AudioTrack(t.Path, t.Start - Math.Max(0, firstFrame))).ToList();
            try { await Shell.Check(ffmpeg, ScreenRecording.MuxArgs(video, list, output)); }
            catch (Exception e)
            {
                Notes.Add($"The sound couldn't be added: {e.Message}");
                File.Copy(video, output, true);
            }
        }
        else File.Copy(video, output, true);
        var events = Path.ChangeExtension(output, null) + ".pointer.json";
        try
        {
            File.WriteAllText(Path.Combine(work, "pointer.json"), JsonSerializer.Serialize(new { area.Width, area.Height, Scale, Samples = samples, CursorDrawn = look.Cursor }));
            events = Path.Combine(work, "pointer.json");
        }
        catch { }
        var (ow, oh) = ScreenRecording.OutputSize(format);
        return new RecordingResult(output, seconds, ow, oh, Notes, events);
    }

    /// Stops and throws everything away.
    public void Cancel()
    {
        running = false;
        thread?.Join(3000);
        hooks?.Dispose();
        audio?.Stop();
        try { process?.Kill(true); } catch { }
        Dispose();
    }

    public void Dispose()
    {
        hooks?.Dispose();
        audio?.Dispose();
        process?.Dispose();
    }

    /// Removes the temporary files (after the result has been moved somewhere safe).
    public void CleanUp() => OutputPaths.TryDelete(work);

    // Encoders

    static string? chosen;

    /// The best H.264 encoder this PC's ffmpeg can actually use: a graphics card's (NVIDIA, Intel,
    /// AMD) when one works, otherwise the software encoder.
    public static async Task<string> PickEncoder(string preference, string? ffmpegPath = null)
    {
        if (preference is "libx264") return "libx264";
        var ffmpeg = ffmpegPath ?? Tools.Ffmpeg;
        if (ffmpeg is null) return "libx264";
        IEnumerable<string> candidates = preference is "auto" ? ScreenRecording.HardwareEncoders.Where(e => e != "h264_mf") : [preference];
        if (preference is "auto" && chosen is not null) return chosen;
        foreach (var encoder in candidates)
        {
            if (!Tools.HasEncoder(encoder)) continue;
            try
            {
                using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(8));
                var result = await Shell.Run(ffmpeg, ["-hide_banner", "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=gray:s=320x240:d=0.3:r=30",
                    "-pix_fmt", "yuv420p", "-c:v", encoder, "-f", "null", "-"], cts.Token);
                if (result.Status == 0) return preference is "auto" ? chosen = encoder : encoder;
            }
            catch { }
        }
        return preference is "auto" ? chosen = "libx264" : "libx264";
    }
}
