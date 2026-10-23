using System.Diagnostics;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Transmute.Desktop;

/// Records the microphone and/or the computer's own sound (WASAPI loopback) to WAV files while a
/// screen recording runs. Each track remembers when its first sound arrived so the recorder can
/// line it up with the video.
public sealed class AudioCapture : IDisposable
{
    sealed class Track(IWaveIn source, string path) : IDisposable
    {
        public IWaveIn Source { get; } = source;
        public string Path { get; } = path;
        public WaveFileWriter? Writer;
        public double? Start;
        public long Bytes;

        public void Dispose()
        {
            try { Source.StopRecording(); } catch { }
            lock (this) { Writer?.Dispose(); Writer = null; }
            Source.Dispose();
        }
    }

    readonly List<Track> tracks = [];
    readonly Stopwatch clock;
    WasapiOut? silence;
    public List<string> Problems { get; } = [];

    /// `clock` is the recording's clock: offsets are measured on it.
    public AudioCapture(Stopwatch clock, string folder, bool microphone, bool systemSound)
    {
        this.clock = clock;
        if (microphone) Add(() => new WasapiCapture(), System.IO.Path.Combine(folder, "microphone.wav"), "microphone");
        if (systemSound)
        {
            var loopback = Add(() => new WasapiLoopbackCapture(), System.IO.Path.Combine(folder, "computer.wav"), "computer sound");
            // Loopback only delivers sound while something plays; playing silence keeps it going so
            // the track stays in step with the video.
            if (loopback is not null)
            {
                try
                {
                    silence = new WasapiOut(AudioClientShareMode.Shared, 100);
                    silence.Init(new SilenceProvider(loopback.Source.WaveFormat));
                    silence.Play();
                }
                catch { silence?.Dispose(); silence = null; }
            }
        }
    }

    Track? Add(Func<IWaveIn> make, string path, string what)
    {
        try
        {
            var source = make();
            var track = new Track(source, path);
            track.Writer = new WaveFileWriter(path, source.WaveFormat);
            source.DataAvailable += (_, e) =>
            {
                if (e.BytesRecorded == 0) return;
                lock (track)
                {
                    if (track.Writer is null) return;
                    track.Start ??= clock.Elapsed.TotalSeconds - (double)e.BytesRecorded / source.WaveFormat.AverageBytesPerSecond;
                    track.Writer.Write(e.Buffer, 0, e.BytesRecorded);
                    track.Bytes += e.BytesRecorded;
                }
            };
            source.StartRecording();
            tracks.Add(track);
            return track;
        }
        catch (Exception e)
        {
            Problems.Add($"Couldn't record the {what}: {e.Message}");
            return null;
        }
    }

    /// Stops and returns the tracks that got sound, with their start times on the clock.
    public IReadOnlyList<(string Path, double Start)> Stop()
    {
        var done = new List<(string, double)>();
        foreach (var t in tracks)
        {
            t.Dispose();
            if (t.Bytes > 0 && t.Start is { } start) done.Add((t.Path, start));
        }
        tracks.Clear();
        silence?.Stop();
        silence?.Dispose();
        silence = null;
        return done;
    }

    public void Dispose() => Stop();
}
