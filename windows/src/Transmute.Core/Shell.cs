using System.Diagnostics;
using System.Text;

namespace Transmute;

/// Finds the helper programs Transmute uses.
public static class Tools
{
    static string? cachedFfmpeg;
    static bool searched;

    /// ffmpeg.exe shipped next to Transmute, or one on the PATH.
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

    public static string RequireFfmpeg(string what) =>
        Ffmpeg ?? throw new ConversionException($"{what} needs ffmpeg, which comes with Transmute. Reinstall Transmute to put it back.");
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
