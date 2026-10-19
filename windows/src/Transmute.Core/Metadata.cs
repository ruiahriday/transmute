using System.Globalization;
using System.Text.RegularExpressions;
using ImageMagick;

namespace Transmute;

public sealed record MetadataField(string Key, string Label, string Value, string Section, bool Editable = false);

/// Fields to change (an empty value clears the field), and whether to remove the location.
public sealed record MetadataEdit(IReadOnlyDictionary<string, string> Changes, bool RemoveLocation = false);

/// Reads and writes metadata of photos, video, audio and PDFs.
public static class MetadataTool
{
    public static readonly string[] ImageKeys = ["description", "artist", "copyright", "dateTaken"];
    public static readonly string[] MediaKeys = ["title", "artist", "album", "album_artist", "genre", "date", "track", "comment", "copyright"];
    public static readonly string[] PdfKeys = ["title", "author", "subject", "keywords", "creator"];

    public static string Label(string key) => key switch
    {
        "description" => "Description",
        "artist" => "Artist",
        "copyright" => "Copyright",
        "dateTaken" => "Date taken",
        "title" => "Title",
        "album" => "Album",
        "album_artist" => "Album artist",
        "genre" => "Genre",
        "date" => "Year",
        "comment" => "Comment",
        "track" => "Track",
        "author" => "Author",
        "subject" => "Subject",
        "keywords" => "Keywords",
        "creator" => "Creator",
        _ => key,
    };

    public static string? Placeholder(string key) => key switch
    {
        "dateTaken" => "2024:05:31 14:30:00",
        "date" => "2024",
        "track" => "3 or 3/12",
        "keywords" => "holiday, beach",
        _ => null,
    };

    public static async Task<List<MetadataField>> Read(string path, CancellationToken token = default)
    {
        var fields = FileFields(path);
        switch (Kinds.Of(path))
        {
            case FileKind.Image: fields.AddRange(await Task.Run(() => ReadImage(path), token)); break;
            case FileKind.Video or FileKind.Audio: fields.AddRange(await ReadMedia(path, token)); break;
            case FileKind.Pdf: fields.AddRange(await Task.Run(() => ReadPdf(path), token)); break;
        }
        return fields;
    }

    public static async Task<string> Write(MetadataEdit edit, string input, ConversionOptions options, CancellationToken token)
    {
        return Kinds.Of(input) switch
        {
            FileKind.Image => await Task.Run(() => WriteImage(edit, input, options), token),
            FileKind.Video or FileKind.Audio => await WriteMedia(edit, input, options, token),
            FileKind.Pdf => await Task.Run(() => PdfTools.WriteInfo(input, edit.Changes, options), token),
            _ => throw new ConversionException("Transmute can only change the details of photos, video, audio and PDFs."),
        };
    }

    public static string? Value(string key, IEnumerable<MetadataField> fields) => fields.FirstOrDefault(f => f.Key == key)?.Value;

    public static bool HasLocation(IEnumerable<MetadataField> fields) => fields.Any(f => f.Key == "location");

    /// Everything as text, for copying.
    public static string PlainText(IEnumerable<MetadataField> fields, string title)
    {
        var lines = new List<string> { title };
        foreach (var section in fields.GroupBy(f => f.Section))
        {
            lines.Add("");
            lines.Add(section.Key);
            lines.AddRange(section.Where(f => f.Value.Length > 0).Select(f => $"  {f.Label}: {f.Value}"));
        }
        return string.Join("\n", lines);
    }

    static List<MetadataField> FileFields(string path)
    {
        var info = new FileInfo(path);
        var fields = new List<MetadataField>
        {
            new("name", "Name", info.Name, "File"),
            new("kind", "Kind", Kinds.Of(path).Title().TrimEnd('s') + " (" + info.Extension.TrimStart('.').ToUpperInvariant() + ")", "File"),
        };
        if (info.Exists)
        {
            fields.Add(new("size", "Size", $"{OutputPaths.FormatSize(info.Length)} ({info.Length:N0} bytes)", "File"));
            fields.Add(new("created", "Created", info.CreationTime.ToString("d MMM yyyy, HH:mm", CultureInfo.InvariantCulture), "File"));
            fields.Add(new("modified", "Modified", info.LastWriteTime.ToString("d MMM yyyy, HH:mm", CultureInfo.InvariantCulture), "File"));
        }
        return fields;
    }

    // Images

    static bool CanWriteImage(string path) =>
        Path.GetExtension(path).ToLowerInvariant() is ".jpg" or ".jpeg" or ".jfif" or ".png" or ".tif" or ".tiff" or ".webp";

    static List<MetadataField> ReadImage(string path)
    {
        var fields = new List<MetadataField>();
        using var image = new MagickImage();
        try { image.Read(path); }
        catch (MagickException e) { throw new ConversionException($"Couldn't read {Path.GetFileName(path)}: {e.Message.Split('\n')[0]}"); }
        const string pic = "Picture";
        fields.Add(new("dimensions", "Size", $"{image.Width} × {image.Height} pixels", pic));
        fields.Add(new("format", "Format", image.Format.ToString().ToUpperInvariant(), pic));
        fields.Add(new("colorSpace", "Colours", $"{image.ColorSpace}, {image.Depth}-bit{(image.HasAlpha ? ", with transparency" : "")}", pic));
        if (image.Density.X > 0) fields.Add(new("dpi", "Resolution", $"{image.Density.X:0} dpi", pic));

        var exif = image.GetExifProfile();
        string? Get(ExifTag<string> tag) => exif?.GetValue(tag)?.Value?.Trim('\0', ' ');
        const string camera = "Camera";
        void Add(string key, string label, string? value, string section)
        {
            if (!string.IsNullOrWhiteSpace(value)) fields.Add(new(key, label, value!, section));
        }
        Add("make", "Make", Get(ExifTag.Make), camera);
        Add("model", "Model", Get(ExifTag.Model), camera);
        Add("lens", "Lens", Get(ExifTag.LensModel), camera);
        if (exif?.GetValue(ExifTag.ExposureTime)?.Value is { } exposure && exposure.Denominator != 0)
        {
            var seconds = exposure.ToDouble();
            Add("exposure", "Exposure", seconds >= 1 ? $"{seconds:0.#} s" : $"1/{Math.Round(1 / seconds)} s", camera);
        }
        if (exif?.GetValue(ExifTag.FNumber)?.Value is { } f && f.Denominator != 0) Add("aperture", "Aperture", $"f/{f.ToDouble():0.#}", camera);
        if (exif?.GetValue(ExifTag.ISOSpeedRatings)?.Value is { Length: > 0 } iso) Add("iso", "ISO", iso[0].ToString(), camera);
        if (exif?.GetValue(ExifTag.FocalLength)?.Value is { } focal && focal.Denominator != 0) Add("focal", "Focal length", $"{focal.ToDouble():0.#} mm", camera);
        Add("software", "Software", Get(ExifTag.Software), camera);

        var editable = CanWriteImage(path);
        const string details = "Details";
        var values = new Dictionary<string, string?>
        {
            ["description"] = Get(ExifTag.ImageDescription) ?? image.GetAttribute("comment"),
            ["artist"] = Get(ExifTag.Artist),
            ["copyright"] = Get(ExifTag.Copyright),
            ["dateTaken"] = Get(ExifTag.DateTimeOriginal) ?? Get(ExifTag.DateTime),
        };
        foreach (var key in ImageKeys) fields.Add(new(key, Label(key), values[key] ?? "", details, editable));

        if (exif is not null && Location(exif) is { } location)
            fields.Add(new("location", "Location", location, "Location"));
        return fields;
    }

    static string? Location(IExifProfile exif)
    {
        var lat = exif.GetValue(ExifTag.GPSLatitude)?.Value;
        var lon = exif.GetValue(ExifTag.GPSLongitude)?.Value;
        if (lat is not { Length: 3 } || lon is not { Length: 3 }) return null;
        double Degrees(Rational[] r) => r[0].ToDouble() + r[1].ToDouble() / 60 + r[2].ToDouble() / 3600;
        var latRef = exif.GetValue(ExifTag.GPSLatitudeRef)?.Value ?? "N";
        var lonRef = exif.GetValue(ExifTag.GPSLongitudeRef)?.Value ?? "E";
        var la = Degrees(lat) * (latRef.StartsWith('S') ? -1 : 1);
        var lo = Degrees(lon) * (lonRef.StartsWith('W') ? -1 : 1);
        if (double.IsNaN(la) || double.IsNaN(lo)) return null;
        return $"{Math.Abs(la):0.00000}° {(la < 0 ? "S" : "N")}, {Math.Abs(lo):0.00000}° {(lo < 0 ? "W" : "E")}";
    }

    /// "2024:05:31 14:30:00" from that or "2024-05-31 14:30", "31/05/2024" and similar.
    public static string? ExifDate(string text)
    {
        text = text.Trim();
        string[] formats = ["yyyy:MM:dd HH:mm:ss", "yyyy:MM:dd HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-ddTHH:mm:ss",
            "yyyy-MM-dd", "yyyy:MM:dd", "dd/MM/yyyy HH:mm", "dd/MM/yyyy", "d MMM yyyy", "d MMM yyyy HH:mm"];
        return DateTime.TryParseExact(text, formats, CultureInfo.InvariantCulture, DateTimeStyles.None, out var date)
            ? date.ToString("yyyy:MM:dd HH:mm:ss", CultureInfo.InvariantCulture) : null;
    }

    static string WriteImage(MetadataEdit edit, string input, ConversionOptions options)
    {
        if (!CanWriteImage(input))
            throw new ConversionException($"Transmute can show the details of {Path.GetExtension(input).TrimStart('.').ToUpperInvariant()} pictures but not change them. Convert it to JPEG or PNG first.");
        var output = OutputPaths.Destination(input, Path.GetExtension(input).TrimStart('.'), "edited", options.OutputFolder);
        using var image = new MagickImage(input);
        var quality = image.Quality;
        var exif = image.GetExifProfile() ?? new ExifProfile();
        foreach (var (key, raw) in edit.Changes)
        {
            var value = raw.Trim();
            switch (key)
            {
                case "description":
                    if (value.Length == 0) exif.RemoveValue(ExifTag.ImageDescription); else exif.SetValue(ExifTag.ImageDescription, value);
                    break;
                case "artist":
                    if (value.Length == 0) exif.RemoveValue(ExifTag.Artist); else exif.SetValue(ExifTag.Artist, value);
                    break;
                case "copyright":
                    if (value.Length == 0) exif.RemoveValue(ExifTag.Copyright); else exif.SetValue(ExifTag.Copyright, value);
                    break;
                case "dateTaken":
                    if (value.Length == 0)
                    {
                        exif.RemoveValue(ExifTag.DateTimeOriginal);
                        exif.RemoveValue(ExifTag.DateTimeDigitized);
                    }
                    else
                    {
                        var date = ExifDate(value) ?? throw new ConversionException($"\"{value}\" isn't a date Transmute understands. Write it like 2024:05:31 14:30:00.");
                        exif.SetValue(ExifTag.DateTimeOriginal, date);
                        exif.SetValue(ExifTag.DateTimeDigitized, date);
                    }
                    break;
            }
        }
        if (edit.RemoveLocation)
        {
            foreach (var value in exif.Values.Where(v => v.Tag.ToString().StartsWith("GPS", StringComparison.Ordinal)).ToList())
                exif.RemoveValue(value.Tag);
        }
        image.SetProfile(exif);
        if (quality > 0) image.Quality = quality;
        image.Write(output);
        return output;
    }

    // Video and audio

    static readonly string[] LocationKeys = ["location", "location-eng", "com.apple.quicktime.location.ISO6709"];

    static async Task<List<MetadataField>> ReadMedia(string path, CancellationToken token)
    {
        var banner = await MediaInfo.Banner(path, token);
        if (banner.Length == 0) throw new ConversionException("Reading video and audio details needs ffmpeg, which comes with Transmute.");
        var fields = new List<MetadataField>();
        var input = Regex.Match(banner, @"Input #0, ([^\n]+?), from");
        const string media = "Media";
        if (input.Success) fields.Add(new("container", "Container", input.Groups[1].Value.Split(',')[0].ToUpperInvariant(), media));
        if (MediaInfo.ParseDuration(banner) is { } duration) fields.Add(new("duration", "Length", MediaInfo.TimeLabel(duration, true), media));
        var rate = Regex.Match(banner, @"bitrate: (\d+) kb/s");
        if (rate.Success) fields.Add(new("bitrate", "Bit rate", $"{rate.Groups[1].Value} kb/s", media));

        var video = MediaInfo.StreamLines(banner, "Video").FirstOrDefault(l => !l.Contains("attached pic"));
        if (video is not null)
        {
            var details = video[(video.IndexOf("Video:", StringComparison.Ordinal) + 6)..].Trim();
            fields.Add(new("videoCodec", "Codec", details.Split(' ', ',')[0], "Video"));
            if (MediaInfo.ParseFrameSize(banner) is { } size) fields.Add(new("frameSize", "Frame size", $"{size.Width} × {size.Height}", "Video"));
            var fps = Regex.Match(video, @"([\d.]+) fps");
            if (fps.Success) fields.Add(new("frameRate", "Frame rate", $"{fps.Groups[1].Value} fps", "Video"));
        }
        var audio = MediaInfo.StreamLines(banner, "Audio").FirstOrDefault();
        if (audio is not null)
        {
            var details = audio[(audio.IndexOf("Audio:", StringComparison.Ordinal) + 6)..].Trim();
            fields.Add(new("audioCodec", "Codec", details.Split(' ', ',')[0], "Sound"));
            if (MediaInfo.ParseSoundTrack(banner) is { } track)
            {
                if (track.SampleRate is { } hz) fields.Add(new("sampleRate", "Sample rate", $"{hz / 1000.0:0.#} kHz", "Sound"));
                if (track.Channels is { } ch) fields.Add(new("channels", "Channels", ch == 1 ? "Mono" : ch == 2 ? "Stereo" : $"{ch} channels", "Sound"));
            }
        }

        var tags = Tags(banner);
        var ext = Path.GetExtension(path).ToLowerInvariant();
        var editable = ext is not (".mpg" or ".mpeg" or ".ts" or ".mts" or ".m2ts" or ".vob" or ".3gp");
        foreach (var key in MediaKeys)
        {
            var value = key switch
            {
                "album_artist" => Tag(tags, "album_artist", "albumartist", "album artist"),
                "date" => Tag(tags, "date", "year", "creation_time"),
                "track" => Tag(tags, "track", "tracknumber"),
                _ => Tag(tags, key, $"com.apple.quicktime.{key}"),
            } ?? "";
            if (key == "date" && value.Length >= 10 && value.Contains('T')) value = value[..10];
            fields.Add(new(key, Label(key), value, "Tags", editable));
        }
        var location = Tag(tags, LocationKeys);
        if (location is not null) fields.Add(new("location", "Location", location, "Location"));
        return fields;
    }

    static string? Tag(Dictionary<string, string> tags, params string[] names)
    {
        foreach (var name in names)
            if (tags.TryGetValue(name, out var value) && value.Length > 0) return value;
        return null;
    }

    /// The file's own tags and, for Ogg and Opus, the sound track's (where those formats keep them).
    public static Dictionary<string, string> Tags(string banner)
    {
        var tags = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var lines = banner.Replace("\r", "").Split('\n');
        string? block = null;
        foreach (var line in lines)
        {
            var indent = line.Length - line.TrimStart().Length;
            var trimmed = line.Trim();
            if (trimmed.StartsWith("Input #")) { block = "input"; continue; }
            if (trimmed.StartsWith("Duration:")) { block = "after"; continue; }
            if (trimmed.StartsWith("Stream #")) { block = trimmed.Contains("Audio:") ? "audio" : "stream"; continue; }
            if (trimmed.StartsWith("Metadata:")) continue;
            if (trimmed.StartsWith("Output #")) break;
            var colon = trimmed.IndexOf(':');
            if (colon <= 0) continue;
            var key = trimmed[..colon].Trim();
            var value = trimmed[(colon + 1)..].Trim();
            if (block == "input" && indent == 4) tags[key] = value;
            else if (block == "audio" && indent == 6) tags.TryAdd(key, value);
        }
        return tags;
    }

    static async Task<string> WriteMedia(MetadataEdit edit, string input, ConversionOptions options, CancellationToken token)
    {
        var ffmpeg = Tools.RequireFfmpeg("Changing video and audio details");
        var ext = Path.GetExtension(input).TrimStart('.');
        var output = OutputPaths.Destination(input, ext, "edited", options.OutputFolder);
        var oggLike = ext.ToLowerInvariant() is "ogg" or "oga" or "opus";
        var args = new List<string> { "-hide_banner", "-nostdin", "-y", "-i", input, "-map", "0", "-c", "copy" };
        void Set(string key, string value)
        {
            args.AddRange(["-metadata", $"{key}={value}"]);
            // Ogg and Opus keep tags on the sound track itself.
            if (oggLike) args.AddRange(["-metadata:s:a:0", $"{key}={value}"]);
        }
        foreach (var (key, value) in edit.Changes)
        {
            Set(key, value.Trim());
            if (key == "album_artist" && ext.Equals("mp3", StringComparison.OrdinalIgnoreCase)) Set("TPE2", value.Trim());
        }
        if (edit.RemoveLocation) foreach (var key in LocationKeys) Set(key, "");
        if (ext.Equals("mp3", StringComparison.OrdinalIgnoreCase)) args.AddRange(["-id3v2_version", "3"]);
        if (ext.ToLowerInvariant() is "mp4" or "m4a" or "m4v" or "mov") args.AddRange(["-movflags", "+faststart"]);
        args.Add(output);
        try
        {
            await Shell.Check(ffmpeg, args, token);
        }
        catch
        {
            OutputPaths.TryDelete(output);
            throw;
        }
        return output;
    }

    // PDF

    static List<MetadataField> ReadPdf(string path)
    {
        var info = PdfTools.ReadInfo(path);
        var fields = new List<MetadataField>();
        const string doc = "Document";
        fields.Add(new("pages", "Pages", info["pages"], doc));
        if (info.TryGetValue("pageSize", out var size)) fields.Add(new("pageSize", "Page size", size, doc));
        if (info.TryGetValue("producer", out var producer) && producer.Length > 0) fields.Add(new("producer", "Made with", producer, doc));
        if (info.TryGetValue("created", out var created)) fields.Add(new("pdfCreated", "Created", created, doc));
        if (info.TryGetValue("modified", out var modified)) fields.Add(new("pdfModified", "Modified", modified, doc));
        foreach (var key in PdfKeys) fields.Add(new(key, Label(key), info.GetValueOrDefault(key) ?? "", "Details", true));
        return fields;
    }
}
