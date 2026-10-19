using System.Formats.Tar;
using System.Globalization;
using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;
using SharpCompress.Archives;
using SharpCompress.Compressors.BZip2;
using SharpCompress.Compressors.Xz;

namespace Transmute;

/// ZIP and TAR.GZ archives, and extracting ZIP, RAR, 7Z, TAR, GZ, BZ2 and XZ.
public static class Archives
{
    public static async Task<string> Compress(IReadOnlyList<string> inputs, OutputFormat format, string? name, ConversionOptions options, CancellationToken token)
    {
        if (inputs.Count == 0) throw new ConversionException("Nothing to compress.");
        var first = Path.GetFullPath(inputs[0].TrimEnd('\\', '/'));
        var dir = options.OutputFolder ?? Path.GetDirectoryName(first)!;
        var baseName = name ?? (Directory.Exists(first) ? Path.GetFileName(first) : OutputPaths.BaseName(first));
        var output = OutputPaths.Unique(dir, baseName, format == OutputFormat.Tgz ? "tar.gz" : "zip");
        try
        {
            await Task.Run(() =>
            {
                var entries = Entries(inputs, token).ToList();
                if (format == OutputFormat.Tgz)
                {
                    using var file = File.Create(output);
                    using var gzip = new GZipStream(file, CompressionLevel.Optimal);
                    using var tar = new TarWriter(gzip, TarEntryFormat.Pax);
                    foreach (var (path, entryName) in entries)
                    {
                        token.ThrowIfCancellationRequested();
                        tar.WriteEntry(path, entryName);
                    }
                }
                else
                {
                    using var zip = ZipFile.Open(output, ZipArchiveMode.Create, Encoding.UTF8);
                    foreach (var (path, entryName) in entries)
                    {
                        token.ThrowIfCancellationRequested();
                        if (Directory.Exists(path)) zip.CreateEntry(entryName + "/");
                        else zip.CreateEntryFromFile(path, entryName, CompressionLevel.Optimal);
                    }
                }
            }, token);
        }
        catch
        {
            OutputPaths.TryDelete(output);
            throw;
        }
        return output;
    }

    /// Every file and folder to store, with its name inside the archive.
    static IEnumerable<(string Path, string Name)> Entries(IReadOnlyList<string> inputs, CancellationToken token)
    {
        foreach (var input in inputs)
        {
            var full = Path.GetFullPath(input.TrimEnd('\\', '/'));
            var root = Path.GetDirectoryName(full)!;
            if (File.Exists(full))
            {
                yield return (full, Path.GetFileName(full));
                continue;
            }
            if (!Directory.Exists(full)) continue;
            yield return (full, Path.GetFileName(full));
            foreach (var item in Directory.EnumerateFileSystemEntries(full, "*", SearchOption.AllDirectories))
            {
                token.ThrowIfCancellationRequested();
                yield return (item, Path.GetRelativePath(root, item).Replace('\\', '/'));
            }
        }
    }

    /// Unpacks into a new folder next to the archive.
    public static async Task<string> Extract(string input, ConversionOptions options, CancellationToken token)
    {
        var folder = OutputPaths.Destination(input, "", null, options.OutputFolder);
        Directory.CreateDirectory(folder);
        try
        {
            await Task.Run(() => ExtractTo(input, folder, token), token);
            // One folder inside with the same name: lift its contents up a level.
            var items = Directory.GetFileSystemEntries(folder);
            if (items.Length == 1 && Directory.Exists(items[0]) && Path.GetFileName(items[0]) == Path.GetFileName(folder))
            {
                var temp = folder + "-" + Guid.NewGuid().ToString("N")[..6];
                Directory.Move(items[0], temp);
                Directory.Delete(folder);
                Directory.Move(temp, folder);
            }
        }
        catch
        {
            OutputPaths.TryDelete(folder);
            throw;
        }
        return folder;
    }

    static void ExtractTo(string input, string folder, CancellationToken token)
    {
        var name = Path.GetFileName(input).ToLowerInvariant();
        var single = Regex.Match(name, @"^(.*)\.(gz|bz2|xz)$");
        if (single.Success && !single.Groups[1].Value.EndsWith(".tar"))
        {
            // A single compressed file, not a folder.
            using var source = File.OpenRead(input);
            using Stream stream = single.Groups[2].Value switch
            {
                "gz" => new GZipStream(source, CompressionMode.Decompress),
                "bz2" => BZip2Stream.Create(source, SharpCompress.Compressors.CompressionMode.Decompress, true, false, false),
                _ => new XZStream(source),
            };
            var outName = Path.GetFileName(input)[..^(single.Groups[2].Value.Length + 1)];
            using var target = File.Create(Path.Combine(folder, outName));
            stream.CopyTo(target);
            return;
        }
        IArchive archive;
        try { archive = ArchiveFactory.OpenArchive(input, new SharpCompress.Readers.ReaderOptions()); }
        catch (Exception e) { throw new ConversionException($"Couldn't open {Path.GetFileName(input)} as an archive: {e.Message}"); }
        using (archive)
        {
            var root = Path.GetFullPath(folder) + Path.DirectorySeparatorChar;
            foreach (var entry in archive.Entries)
            {
                token.ThrowIfCancellationRequested();
                if (entry.Key is null) continue;
                var target = Path.GetFullPath(Path.Combine(folder, entry.Key.Replace('\\', '/').TrimStart('/')));
                // Never write outside the folder ("../" tricks).
                if (!target.StartsWith(root, StringComparison.OrdinalIgnoreCase)) continue;
                if (entry.IsDirectory) { Directory.CreateDirectory(target); continue; }
                if (entry.IsEncrypted) throw new ConversionException($"{Path.GetFileName(input)} is protected with a password.");
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                using var source = entry.OpenEntryStream();
                using var file = File.Create(target);
                source.CopyTo(file);
                if (entry.LastModifiedTime is { } time) { file.Close(); File.SetLastWriteTime(target, time); }
            }
        }
    }

    /// An archive in another archive format.
    public static async Task<string> Repack(string input, OutputFormat format, ConversionOptions options, CancellationToken token)
    {
        var temp = OutputPaths.TempDir();
        try
        {
            var folder = Path.Combine(temp, OutputPaths.BaseName(input));
            Directory.CreateDirectory(folder);
            await Task.Run(() => ExtractTo(input, folder, token), token);
            var dir = options.OutputFolder ?? Path.GetDirectoryName(Path.GetFullPath(input))!;
            return await Compress(Directory.GetFileSystemEntries(folder), format, OutputPaths.BaseName(input), options with { OutputFolder = dir }, token);
        }
        finally
        {
            OutputPaths.TryDelete(temp);
        }
    }
}

/// SRT and WebVTT subtitles.
public static class Subtitles
{
    public sealed record Cue(TimeSpan Start, TimeSpan End, string Text);

    public static string Convert(string input, OutputFormat format, ConversionOptions options)
    {
        var cues = Parse(DocReaders.ReadAllText(input));
        if (cues.Count == 0) throw new ConversionException($"No subtitles found in {Path.GetFileName(input)}.");
        var output = OutputPaths.Destination(input, format.Extension(), null, options.OutputFolder);
        var text = format switch
        {
            OutputFormat.Srt => ToSrt(cues),
            OutputFormat.Vtt => ToVtt(cues),
            _ => throw new ConversionException($"Subtitles can't be saved as {format.Label()}."),
        };
        File.WriteAllText(output, text, new UTF8Encoding(false));
        return output;
    }

    static readonly Regex Timing = new(@"((?:\d+:)?\d{1,2}:\d{2}[.,]\d{1,3})\s*-->\s*((?:\d+:)?\d{1,2}:\d{2}[.,]\d{1,3})");

    public static List<Cue> Parse(string text)
    {
        var cues = new List<Cue>();
        var blocks = Regex.Split(text.Replace("\r\n", "\n").Replace('\r', '\n').TrimStart('﻿'), @"\n\s*\n");
        foreach (var block in blocks)
        {
            var lines = block.Split('\n').ToList();
            var index = lines.FindIndex(l => Timing.IsMatch(l));
            if (index < 0) continue; // headers, NOTE and STYLE blocks
            var m = Timing.Match(lines[index]);
            var body = string.Join("\n", lines.Skip(index + 1)).Trim('\n');
            cues.Add(new Cue(ParseTime(m.Groups[1].Value), ParseTime(m.Groups[2].Value), body));
        }
        return cues;
    }

    static TimeSpan ParseTime(string stamp)
    {
        var parts = stamp.Replace(',', '.').Split(':');
        double seconds = 0;
        foreach (var p in parts) seconds = seconds * 60 + double.Parse(p, CultureInfo.InvariantCulture);
        return TimeSpan.FromSeconds(seconds);
    }

    static string Stamp(TimeSpan t, char separator) =>
        $"{(int)t.TotalHours:00}:{t.Minutes:00}:{t.Seconds:00}{separator}{t.Milliseconds:000}";

    static string ToSrt(List<Cue> cues)
    {
        var sb = new StringBuilder();
        for (var i = 0; i < cues.Count; i++)
        {
            // SRT has no voice tags or cue settings; keep <i>, <b> and <u>.
            var text = Regex.Replace(cues[i].Text, @"</?(v|c|lang|ruby|rt)(\.[^ >]*)?( [^>]*)?>", "");
            sb.Append(i + 1).Append('\n').Append(Stamp(cues[i].Start, ',')).Append(" --> ").Append(Stamp(cues[i].End, ',')).Append('\n')
              .Append(text).Append("\n\n");
        }
        return sb.ToString();
    }

    static string ToVtt(List<Cue> cues)
    {
        var sb = new StringBuilder("WEBVTT\n\n");
        foreach (var cue in cues)
        {
            var text = Regex.Replace(cue.Text, @"</?font[^>]*>", "").Replace("-->", "→");
            sb.Append(Stamp(cue.Start, '.')).Append(" --> ").Append(Stamp(cue.End, '.')).Append('\n').Append(text).Append("\n\n");
        }
        return sb.ToString();
    }
}
