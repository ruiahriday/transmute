using System.Diagnostics;
using System.Text;

namespace Transmute;

/// Finds the helper programs Spinform uses.
public static class Tools
{
    static string? cachedFfmpeg;
    static bool searched;

    /// ffmpeg.exe shipped next to Spinform, or one on the PATH.
    public static string? Ffmpeg
    {
        get
        {
            // Lets the self-test check the messages shown without ffmpeg.
            if (Environment.GetEnvironmentVariable("TRANSMUTE_NO_FFMPEG") is not null) return null;
            if (searched) return cachedFfmpeg;
            cachedFfmpeg = Find();
            searched = true;
            return cachedFfmpeg;
        }
    }

    static string? Find()
    {
        var exe = OperatingSystem.IsWindows() ? "ffmpeg.exe" : "ffmpeg";
        var candidates = new List<string>();
        if (Environment.GetEnvironmentVariable("TRANSMUTE_FFMPEG") is { Length: > 0 } custom) candidates.Add(custom);
        var appDir = AppContext.BaseDirectory;
        candidates.Add(Path.Combine(appDir, "ffmpeg", exe));
        candidates.Add(Path.Combine(appDir, exe));
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
            if (dir.Length > 0) candidates.Add(Path.Combine(dir.Trim('"'), exe));
        return candidates.FirstOrDefault(File.Exists);
    }

    static HashSet<string>? encoders;

    /// Whether the bundled ffmpeg has this encoder (builds differ: the ARM one has no libvpx).
    public static bool HasEncoder(string name)
    {
        if (encoders is null)
        {
            var found = new HashSet<string>();
            try
            {
                if (Ffmpeg is { } ffmpeg)
                {
                    using var process = Process.Start(new ProcessStartInfo(ffmpeg, "-hide_banner -encoders")
                        { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true })!;
                    process.ErrorDataReceived += (_, _) => { };
                    process.BeginErrorReadLine();
                    var text = process.StandardOutput.ReadToEnd();
                    process.WaitForExit(10_000);
                    foreach (var line in text.Split('\n'))
                    {
                        var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                        if (parts.Length >= 2 && parts[0].Length == 6) found.Add(parts[1]);
                    }
                }
            }
            catch { }
            encoders = found;
        }
        // Unknown list (ffmpeg didn't answer): assume the usual encoders are there.
        return encoders.Count == 0 || encoders.Contains(name);
    }

    /// Video codec arguments for WebM: VP9, or AV1 when this ffmpeg has no VP9 encoder.
    /// Either `quality` (a CRF on VP9's 0–63 scale) or `bitrate` (bits per second) is given.
    public static string[] WebmVideo(int? quality, string? bitrate)
    {
        string[] rate(string crf) => bitrate is null ? ["-crf", crf, "-b:v", "0"] : ["-b:v", bitrate];
        var q = (quality ?? 32).ToString(System.Globalization.CultureInfo.InvariantCulture);
        if (HasEncoder("libvpx-vp9")) return ["-c:v", "libvpx-vp9", .. rate(q), "-row-mt", "1"];
        string[] plain = bitrate is null ? ["-crf", q] : ["-b:v", bitrate];
        if (HasEncoder("libsvtav1")) return ["-c:v", "libsvtav1", "-preset", "8", .. plain];
        if (HasEncoder("libaom-av1")) return ["-c:v", "libaom-av1", "-cpu-used", "8", "-row-mt", "1", .. rate(q)];
        string[] vp8 = bitrate is null ? ["-crf", "10", "-b:v", "2M"] : ["-b:v", bitrate];
        return ["-c:v", "libvpx", .. vp8];
    }

    public static string RequireFfmpeg(string what) =>
        Ffmpeg ?? throw new ConversionException($"{what} needs ffmpeg, which comes with Spinform. Reinstall Spinform to put it back.");
}

public static class Shell
{
    public sealed record Output(int Status, string Stdout, string Stderr);

    /// Runs a program and waits for it. Cancelling kills the process.
    public static async Task<Output> Run(string exe, IEnumerable<string> args, CancellationToken token = default,
        string? stdoutFile = null, Action<string>? onStdoutLine = null, Action<string>? onStderrLine = null,
        string? workingDirectory = null)
    {
        var info = new ProcessStartInfo(exe)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        if (workingDirectory is not null) info.WorkingDirectory = workingDirectory;
        foreach (var a in args) info.ArgumentList.Add(a);

        using var process = new Process { StartInfo = info };
        var err = new StringBuilder();
        var outText = new StringBuilder();
        try { process.Start(); }
        catch (Exception e) { throw new ConversionException($"Couldn't start {Path.GetFileName(exe)}: {e.Message}"); }
        process.StandardInput.Close();

        Task stdoutTask;
        if (stdoutFile is not null)
        {
            stdoutTask = Task.Run(async () =>
            {
                await using var file = File.Create(stdoutFile);
                await process.StandardOutput.BaseStream.CopyToAsync(file);
            });
        }
        else
        {
            stdoutTask = Pump(process.StandardOutput, outText, onStdoutLine);
        }
        var stderrTask = Pump(process.StandardError, err, onStderrLine);

        await using (token.Register(() => { try { if (!process.HasExited) process.Kill(true); } catch { } }))
        {
            await process.WaitForExitAsync(CancellationToken.None);
            await Task.WhenAll(stdoutTask, stderrTask);
        }
        token.ThrowIfCancellationRequested();
        return new Output(process.ExitCode, outText.ToString(), err.ToString());
    }

    static async Task Pump(StreamReader reader, StringBuilder all, Action<string>? onLine)
    {
        var line = new StringBuilder();
        var buffer = new char[4096];
        int read;
        while ((read = await reader.ReadAsync(buffer, 0, buffer.Length)) > 0)
        {
            lock (all) all.Append(buffer, 0, read);
            if (onLine is null) continue;
            for (var i = 0; i < read; i++)
            {
                var c = buffer[i];
                if (c is '\n' or '\r')
                {
                    if (line.Length > 0) onLine(line.ToString());
                    line.Clear();
                }
                else line.Append(c);
            }
        }
        if (line.Length > 0) onLine?.Invoke(line.ToString());
    }

    /// Like Run, but throws with the end of stderr when the program fails.
    public static async Task<Output> Check(string exe, IEnumerable<string> args, CancellationToken token = default,
        string? stdoutFile = null, Action<string>? onStdoutLine = null, Action<string>? onStderrLine = null,
        string? workingDirectory = null)
    {
        var output = await Run(exe, args, token, stdoutFile, onStdoutLine, onStderrLine, workingDirectory);
        if (output.Status != 0)
        {
            var tail = string.Join("\n", output.Stderr.Split('\n', '\r').Where(l => l.Trim().Length > 0).TakeLast(3));
            throw new ConversionException(tail.Length == 0 ? $"{Path.GetFileName(exe)} failed (exit code {output.Status})" : tail);
        }
        return output;
    }
}
