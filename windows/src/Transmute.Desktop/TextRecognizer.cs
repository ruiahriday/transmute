using ImageMagick;
using Windows.Globalization;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Security.Cryptography;

namespace Transmute.Desktop;

public sealed record OcrOutcome(string Text, int Lines, string Language);

/// Thrown when Windows has no text recognition for any installed language.
public sealed class OcrUnavailableException() : Exception(
    "Text recognition needs a Windows language with its optical character recognition (OCR) part installed. " +
    "Open Settings › Time & language › Language & region, choose your language's ⋯ › Language options, and add Optical character recognition. " +
    "It's a small download from Microsoft; after that everything runs on this PC.");

/// Text recognition with Windows' own on-device engine (Windows.Media.Ocr). Nothing is uploaded.
public static class TextRecognizer
{
    /// Languages Windows can read text in, as (tag, name).
    public static IReadOnlyList<(string Tag, string Name)> Languages
    {
        get
        {
            try { return OcrEngine.AvailableRecognizerLanguages.Select(l => (l.LanguageTag, l.DisplayName)).ToList(); }
            catch { return []; }
        }
    }

    public static bool IsAvailable => Languages.Count > 0;

    static OcrEngine? Engine(string? tag)
    {
        if (!string.IsNullOrEmpty(tag))
        {
            try
            {
                var language = new Language(tag);
                if (OcrEngine.IsLanguageSupported(language)) return OcrEngine.TryCreateFromLanguage(language);
            }
            catch { }
        }
        return OcrEngine.TryCreateFromUserProfileLanguages()
            ?? OcrEngine.AvailableRecognizerLanguages.Select(OcrEngine.TryCreateFromLanguage).FirstOrDefault(e => e is not null);
    }

    public static async Task<OcrOutcome> Recognize(BgraImage image, string? language = null, bool keepLineBreaks = true)
    {
        var engine = Engine(language) ?? throw new OcrUnavailableException();
        // Small text reads better a little bigger; the engine has a size limit too.
        using var magick = image.ToMagick();
        magick.Alpha(AlphaOption.Remove);
        var longest = Math.Max(magick.Width, magick.Height);
        var limit = OcrEngine.MaxImageDimension;
        if (magick.Height < 300 && longest * 3 <= limit) magick.Resize(new Percentage(300));
        else if (magick.Height < 600 && longest * 2 <= limit) magick.Resize(new Percentage(200));
        else if (longest > limit) magick.Resize(new MagickGeometry(limit, limit));
        var bytes = magick.GetPixels().ToByteArray(PixelMapping.BGRA)!;
        for (var i = 3; i < bytes.Length; i += 4) bytes[i] = 255;
        using var bitmap = SoftwareBitmap.CreateCopyFromBuffer(CryptographicBuffer.CreateFromByteArray(bytes), BitmapPixelFormat.Bgra8,
            (int)magick.Width, (int)magick.Height, BitmapAlphaMode.Premultiplied);
        var result = await engine.RecognizeAsync(bitmap);
        var lines = result.Lines.Select(l => l.Text.Trim()).Where(l => l.Length > 0).ToList();
        var text = keepLineBreaks ? string.Join(Environment.NewLine, lines) : string.Join(" ", lines);
        return new OcrOutcome(text, lines.Count, engine.RecognizerLanguage.DisplayName);
    }

    /// QR codes in the picture, using the reader the QR tool uses.
    public static IReadOnlyList<string> ReadQrCodes(BgraImage image)
    {
        var temp = OutputPaths.TempFile("png");
        try
        {
            image.Save(temp);
            return ImageConverter.ReadQr(temp).Split('\n', StringSplitOptions.RemoveEmptyEntries);
        }
        catch { return []; }
        finally { OutputPaths.TryDelete(temp); }
    }
}
