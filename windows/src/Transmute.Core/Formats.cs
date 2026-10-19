using System.Globalization;

namespace Transmute;

/// What kind of file something is, decided by its extension.
public enum FileKind { Image, Video, Audio, Pdf, Document, Ebook, Presentation, Spreadsheet, Subtitle, Archive, Other }

public enum OutputFormat
{
    Jpeg, Png, Webp, Heic, Avif, Tiff, Bmp, Gif, Ico, Svg, Pdf,
    Mp4, Mov, Mkv, Avi, Wmv, Webm,
    Mp3, M4a, Wav, Flac, Ogg, Opus, Aiff, Wma,
    Txt, Rtf, Docx, Html, Odt, Epub, Md,
    Pptx,
    Xlsx, Csv,
    Srt, Vtt,
    Zip, Tgz, Extract,
}

public static class Kinds
{
    public static readonly FileKind[] All = Enum.GetValues<FileKind>();

    static readonly string[] CompoundArchive = [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz"];

    public static FileKind Of(string path)
    {
        var name = Path.GetFileName(path).ToLowerInvariant();
        if (CompoundArchive.Any(name.EndsWith)) return FileKind.Archive;
        return Path.GetExtension(name).TrimStart('.') switch
        {
            "jpg" or "jpeg" or "jfif" or "png" or "heic" or "heif" or "webp" or "tiff" or "tif" or "bmp" or "gif" or "svg"
                or "ico" or "jp2" or "psd" or "avif" or "dng" or "cr2" or "cr3" or "nef" or "arw" or "raf" or "orf"
                or "rw2" or "tga" => FileKind.Image,
            "mp4" or "mov" or "m4v" or "mkv" or "avi" or "wmv" or "webm" or "flv" or "mpg" or "mpeg" or "3gp" or "ts"
                or "mts" or "m2ts" or "vob" => FileKind.Video,
            "mp3" or "m4a" or "wav" or "flac" or "ogg" or "oga" or "opus" or "aiff" or "aif" or "aac" or "wma"
                or "caf" or "amr" => FileKind.Audio,
            "pdf" => FileKind.Pdf,
            "txt" or "md" or "markdown" or "rtf" or "doc" or "docx" or "odt" or "html" or "htm" or "pages" => FileKind.Document,
            "epub" => FileKind.Ebook,
            "pptx" or "ppt" or "key" or "odp" => FileKind.Presentation,
            "xlsx" or "xls" or "numbers" or "csv" or "tsv" or "ods" => FileKind.Spreadsheet,
            "srt" or "vtt" => FileKind.Subtitle,
            "zip" or "tar" or "gz" or "tgz" or "bz2" or "xz" or "rar" or "7z" => FileKind.Archive,
            _ => FileKind.Other,
        };
    }

    public static string Title(this FileKind kind) => kind switch
    {
        FileKind.Image => "Images",
        FileKind.Video => "Videos",
        FileKind.Audio => "Audio",
        FileKind.Pdf => "PDFs",
        FileKind.Document => "Documents",
        FileKind.Ebook => "E-books",
        FileKind.Presentation => "Presentations",
        FileKind.Spreadsheet => "Spreadsheets",
        FileKind.Subtitle => "Subtitles",
        FileKind.Archive => "Archives",
        _ => "Other files",
    };

    /// Formats this kind of file can be converted to, most useful first.
    public static OutputFormat[] ConvertTargets(this FileKind kind) => kind switch
    {
        FileKind.Image => [OutputFormat.Jpeg, OutputFormat.Png, OutputFormat.Webp, OutputFormat.Heic, OutputFormat.Avif,
            OutputFormat.Tiff, OutputFormat.Bmp, OutputFormat.Gif, OutputFormat.Ico, OutputFormat.Pdf, OutputFormat.Svg],
        FileKind.Video => [OutputFormat.Mp4, OutputFormat.Mov, OutputFormat.Mkv, OutputFormat.Webm, OutputFormat.Avi,
            OutputFormat.Wmv, OutputFormat.Gif, OutputFormat.Mp3, OutputFormat.M4a, OutputFormat.Wav],
        FileKind.Audio => [OutputFormat.Mp3, OutputFormat.M4a, OutputFormat.Wav, OutputFormat.Flac, OutputFormat.Ogg,
            OutputFormat.Opus, OutputFormat.Aiff, OutputFormat.Wma],
        FileKind.Pdf => [OutputFormat.Png, OutputFormat.Jpeg, OutputFormat.Txt, OutputFormat.Docx, OutputFormat.Html, OutputFormat.Rtf],
        FileKind.Document => [OutputFormat.Pdf, OutputFormat.Docx, OutputFormat.Rtf, OutputFormat.Txt, OutputFormat.Html,
            OutputFormat.Odt, OutputFormat.Epub, OutputFormat.Md],
        FileKind.Ebook => [OutputFormat.Pdf, OutputFormat.Txt, OutputFormat.Html, OutputFormat.Docx, OutputFormat.Rtf],
        FileKind.Presentation => [OutputFormat.Pdf, OutputFormat.Png, OutputFormat.Jpeg, OutputFormat.Pptx],
        FileKind.Spreadsheet => [OutputFormat.Csv, OutputFormat.Xlsx, OutputFormat.Pdf, OutputFormat.Html],
        FileKind.Subtitle => [OutputFormat.Srt, OutputFormat.Vtt],
        FileKind.Archive => [OutputFormat.Extract, OutputFormat.Zip, OutputFormat.Tgz],
        _ => [OutputFormat.Zip, OutputFormat.Tgz],
    };

    public static bool CanCompress(this FileKind kind) => kind is FileKind.Image or FileKind.Video or FileKind.Audio or FileKind.Pdf;
    public static bool CanStripMetadata(this FileKind kind) => kind.CanCompress();

    public static string Extension(this OutputFormat format) => format switch
    {
        OutputFormat.Jpeg => "jpg",
        OutputFormat.Tgz => "tar.gz",
        OutputFormat.Extract => "",
        _ => format.ToString().ToLowerInvariant(),
    };

    public static string Label(this OutputFormat format) => format switch
    {
        OutputFormat.Extract => "Extract",
        OutputFormat.Tgz => "TAR.GZ",
        OutputFormat.Md => "Markdown",
        _ => format.ToString().ToUpperInvariant(),
    };

    /// The format whose extension is `ext` ("jpg", "tif"…), if any.
    public static OutputFormat? FormatFor(string ext)
    {
        ext = ext.TrimStart('.').ToLowerInvariant();
        ext = ext switch { "jpeg" or "jfif" => "jpg", "tif" => "tiff", "aif" => "aiff", "oga" => "ogg", "htm" => "html", "markdown" => "md", _ => ext };
        foreach (var f in Enum.GetValues<OutputFormat>())
            if (f != OutputFormat.Extract && f.Extension() == ext) return f;
        return null;
    }
}

public abstract record CompressionTarget
{
    public sealed record Percent(double Fraction) : CompressionTarget;
    public sealed record Bytes(long Count) : CompressionTarget;

    public long Goal(long originalSize) => this switch
    {
        Percent p => Math.Max(1, (long)(originalSize * p.Fraction)),
        Bytes b => b.Count,
        _ => originalSize,
    };
}

/// One thing to do to one file.
public abstract record JobOperation
{
    public sealed record Convert(OutputFormat Format) : JobOperation;
    public sealed record Compress(CompressionTarget Target) : JobOperation;
    public sealed record StripMetadata : JobOperation;
    public sealed record SplitPdf : JobOperation;
    public sealed record ReadQr : JobOperation;
    public sealed record Resize(double Scale) : JobOperation;
    public sealed record EditImage(ImageEdit Edit) : JobOperation;
    public sealed record EditVideo(VideoEdit Edit) : JobOperation;
    public sealed record EditAudio(AudioEdit Edit) : JobOperation;
    public sealed record WriteMetadata(MetadataEdit Edit) : JobOperation;
    public sealed record Snapshot(double Seconds) : JobOperation;
}

/// Tools that take several files and produce one output.
public abstract record BatchTool
{
    public sealed record MergePdfs : BatchTool;
    public sealed record ImagesToPdf : BatchTool;
    public sealed record Archive(OutputFormat Format) : BatchTool;
    public sealed record JoinVideos : BatchTool;
}

public sealed record JobResult(IReadOnlyList<string> Outputs, string? Message = null)
{
    public static JobResult Of(params string[] outputs) => new(outputs);
    public static JobResult Note(string message) => new([], message);
}

public sealed record ConversionOptions
{
    public double Quality { get; init; } = 0.85;
    /// null means "next to the original file".
    public string? OutputFolder { get; init; }
    public bool StripMetadata { get; init; }
    /// Lets the built-in converters run even when Microsoft Office or LibreOffice is installed.
    public bool UseOfficeApps { get; init; } = true;
}

public sealed class ConversionException(string message) : Exception(message);

public delegate void ProgressHandler(double fraction);

public static class OutputPaths
{
    static readonly object Gate = new();
    static readonly HashSet<string> Reserved = new(StringComparer.OrdinalIgnoreCase);
    static readonly string[] CompoundArchive = [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz"];

    /// File name without extension, treating ".tar.gz" and friends as one extension.
    public static string BaseName(string path)
    {
        var name = Path.GetFileName(path.TrimEnd('\\', '/'));
        foreach (var suffix in CompoundArchive)
            if (name.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)) return name[..^suffix.Length];
        return Path.GetFileNameWithoutExtension(name);
    }

    public static string Destination(string input, string ext, string? suffix, string? folder)
    {
        var name = BaseName(input) + (suffix is null ? "" : $" ({suffix})");
        var dir = folder ?? Path.GetDirectoryName(Path.GetFullPath(input))!;
        return Unique(dir, name, ext);
    }

    /// A path in `dir` that doesn't exist yet and hasn't been handed to another running job.
    public static string Unique(string dir, string baseName, string ext)
    {
        string Make(string b) => Path.Combine(dir, ext.Length == 0 ? b : $"{b}.{ext}");
        lock (Gate)
        {
            var candidate = Make(baseName);
            for (var n = 2; File.Exists(candidate) || Directory.Exists(candidate) || Reserved.Contains(candidate); n++)
                candidate = Make($"{baseName} {n}");
            Reserved.Add(candidate);
            return candidate;
        }
    }

    public static long FileSize(string path)
    {
        try { return new FileInfo(path).Length; } catch { return 0; }
    }

    public static string TempFile(string ext) =>
        Path.Combine(Path.GetTempPath(), $"transmute-{Guid.NewGuid():N}.{ext}");

    public static string TempDir()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"transmute-{Guid.NewGuid():N}");
        Directory.CreateDirectory(dir);
        return dir;
    }

    public static void TryDelete(string? path)
    {
        if (path is null) return;
        try
        {
            if (Directory.Exists(path)) Directory.Delete(path, true);
            else if (File.Exists(path)) File.Delete(path);
        }
        catch { }
    }

    /// "1.2 MB", like Explorer.
    public static string FormatSize(long bytes)
    {
        string[] units = ["bytes", "KB", "MB", "GB", "TB"];
        double value = bytes;
        var unit = 0;
        while (value >= 1000 && unit < units.Length - 1) { value /= 1000; unit++; }
        return unit == 0 ? $"{bytes} bytes" : value.ToString(value < 10 ? "0.0" : "0", CultureInfo.InvariantCulture) + " " + units[unit];
    }
}

static class Num
{
    /// A number for an ffmpeg argument, always with a dot.
    public static string D(double value, int digits = 4) => value.ToString("F" + digits, CultureInfo.InvariantCulture);

    /// "12.5", "3", "0.25": no trailing zeros.
    public static string Compact(double value) =>
        value.ToString("0.##", CultureInfo.InvariantCulture);

    public static string Clamp01(double v) => D(Math.Clamp(v, 0, 1));
}
