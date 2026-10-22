using ImageMagick;

namespace Transmute;

/// Pixels in memory: 4 bytes a pixel in blue, green, red, alpha order, rows top to bottom, no
/// padding. Screen grabs, scrolling capture and the recorder all pass these around.
public sealed class BgraImage
{
    public int Width { get; }
    public int Height { get; }
    public byte[] Pixels { get; }
    public int Stride => Width * 4;

    public BgraImage(int width, int height, byte[]? pixels = null)
    {
        if (width < 1 || height < 1) throw new ArgumentException("An image needs at least one pixel.");
        Width = width;
        Height = height;
        Pixels = pixels ?? new byte[(long)width * height * 4];
        if (Pixels.Length < (long)width * height * 4) throw new ArgumentException("Not enough pixels for that size.");
    }

    public BgraImage Crop(int x, int y, int width, int height)
    {
        x = Math.Clamp(x, 0, Width - 1);
        y = Math.Clamp(y, 0, Height - 1);
        width = Math.Clamp(width, 1, Width - x);
        height = Math.Clamp(height, 1, Height - y);
        var result = new BgraImage(width, height);
        for (var row = 0; row < height; row++)
            Buffer.BlockCopy(Pixels, ((y + row) * Width + x) * 4, result.Pixels, row * width * 4, width * 4);
        return result;
    }

    /// Rows become columns (used to stitch sideways scrolling with the same code).
    public BgraImage Transposed()
    {
        var result = new BgraImage(Height, Width);
        var src = Pixels;
        var dst = result.Pixels;
        for (var y = 0; y < Height; y++)
            for (var x = 0; x < Width; x++)
                Buffer.BlockCopy(src, (y * Width + x) * 4, dst, (x * Height + y) * 4, 4);
        return result;
    }

    public MagickImage ToMagick()
    {
        var image = new MagickImage(Pixels, new PixelReadSettings((uint)Width, (uint)Height, StorageType.Char, PixelMapping.BGRA));
        return image;
    }

    public static BgraImage FromMagick(IMagickImage<byte> image)
    {
        var bytes = image.GetPixels().ToByteArray(PixelMapping.BGRA)!;
        return new BgraImage((int)image.Width, (int)image.Height, bytes);
    }

    /// Writes a PNG (or JPEG for .jpg) of the pixels.
    public void Save(string path, double jpegQuality = 0.9)
    {
        using var image = ToMagick();
        var jpeg = path.EndsWith(".jpg", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".jpeg", StringComparison.OrdinalIgnoreCase);
        if (jpeg)
        {
            image.Alpha(AlphaOption.Off);
            image.Quality = (uint)Math.Clamp(Math.Round(jpegQuality * 100), 1, 100);
            image.Write(path, MagickFormat.Jpeg);
        }
        else
        {
            image.Quality = 75; // zlib 7, adaptive filters: quick and small enough for screenshots
            image.Write(path, MagickFormat.Png);
        }
    }

    /// The colour at a pixel, as RRGGBB.
    public string HexAt(int x, int y)
    {
        var i = (Math.Clamp(y, 0, Height - 1) * Width + Math.Clamp(x, 0, Width - 1)) * 4;
        return $"{Pixels[i + 2]:X2}{Pixels[i + 1]:X2}{Pixels[i]:X2}";
    }
}

public enum StitchStep { First, Added, Unchanged, Lost, Full }

public enum ScrollDirection { Vertical, Horizontal }

/// Scrolling capture: frames of the same area, taken while its content scrolls, joined into one
/// long picture. Each new frame is matched against the previous one row by row to find how far the
/// content moved; only the rows that scrolled into view are added. Rows that stay put (a page's
/// sticky header or footer) are recognised and kept once.
public sealed class ScrollStitcher
{
    readonly ScrollDirection direction;
    readonly int maxLength;
    BgraImage? last;
    readonly List<byte[]> rows = [];
    int footer = -1;
    int width;

    public ScrollStitcher(ScrollDirection direction = ScrollDirection.Vertical, int maxLength = 24_000)
    {
        this.direction = direction;
        this.maxLength = maxLength;
    }

    public int Frames { get; private set; }
    /// How long the result is so far, in pixels (height, or width when sideways).
    public int Length => rows.Count + Math.Max(0, footer);

    /// The frame the next one is matched against (the last one joined on).
    public BgraImage? Last => last;
    /// How well the best offset fitted on the last Add, from 0 to 1 (for diagnostics).
    public double LastScore { get; private set; }

    /// Joins a frame on. Relaxed accepts a weaker fit; use it only when the page has stopped
    /// moving and a strict match keeps failing.
    public StitchStep Add(BgraImage frame, bool relaxed = false)
    {
        if (direction == ScrollDirection.Horizontal) frame = frame.Transposed();
        if (last is null)
        {
            width = frame.Width;
            for (var y = 0; y < frame.Height; y++) rows.Add(Row(frame, y));
            last = frame;
            Frames = 1;
            return StitchStep.First;
        }
        if (frame.Width != width || frame.Height != last.Height) throw new ArgumentException("Every frame must be the same size.");
        if (rows.Count >= maxLength) return StitchStep.Full;
        var offset = FindOffset(last, frame, out _, out var bottom, out var score, relaxed ? 0.6 : 0.8);
        LastScore = score;
        if (offset is null) return StitchStep.Lost;
        if (offset == 0) return StitchStep.Unchanged;
        if (footer < 0)
        {
            // The first move shows which rows at the bottom stay put: take them off for now and
            // put the latest copy back at the end.
            footer = bottom;
            rows.RemoveRange(rows.Count - footer, footer);
        }
        var d = offset.Value;
        var end = frame.Height - footer;
        for (var y = Math.Max(0, end - d); y < end && rows.Count < maxLength; y++) rows.Add(Row(frame, y));
        last = frame;
        Frames++;
        return StitchStep.Added;
    }

    static byte[] Row(BgraImage image, int y)
    {
        var row = new byte[image.Stride];
        Buffer.BlockCopy(image.Pixels, y * image.Stride, row, 0, image.Stride);
        return row;
    }

    public BgraImage Result()
    {
        if (last is null) throw new InvalidOperationException("No frames yet.");
        var foot = Math.Max(0, footer);
        var height = rows.Count + foot;
        var result = new BgraImage(width, height);
        var stride = width * 4;
        for (var y = 0; y < rows.Count; y++) Buffer.BlockCopy(rows[y], 0, result.Pixels, y * stride, stride);
        for (var y = 0; y < foot; y++)
            Buffer.BlockCopy(last.Pixels, (last.Height - foot + y) * stride, result.Pixels, (rows.Count + y) * stride, stride);
        return direction == ScrollDirection.Horizontal ? result.Transposed() : result;
    }

    // Matching

    /// A hash of each row, leaving out a strip on the right where a scroll bar usually is (its
    /// thumb moves while the content scrolls). Also whether the row is one flat colour, which
    /// matches anywhere and so says nothing about the offset.
    static (ulong[] Hash, bool[] Flat) Hashes(BgraImage image)
    {
        var w = image.Width;
        var skip = w > 200 ? Math.Min(32, w / 10) : 0;
        var used = w - skip;
        var hashes = new ulong[image.Height];
        var flat = new bool[image.Height];
        var p = image.Pixels;
        for (var y = 0; y < image.Height; y++)
        {
            var start = y * image.Stride;
            ulong h = 14695981039346656037UL;
            var first = BitConverter.ToUInt32(p, start) & 0xFFFFFF;
            var same = true;
            for (var x = 0; x < used; x++)
            {
                var px = BitConverter.ToUInt32(p, start + x * 4) & 0xFFFFFF; // ignore alpha
                same &= px == first;
                h = (h ^ px) * 1099511628211UL;
            }
            hashes[y] = h;
            flat[y] = same;
        }
        return (hashes, flat);
    }

    /// How many pixels the content moved up between two frames: 0 when it didn't move, null when
    /// no offset fits (scrolled too far between frames, or the content changed). Also the number
    /// of rows at the top and bottom that didn't move at all.
    public static int? FindOffset(BgraImage previous, BgraImage next, out int staticTop, out int staticBottom) =>
        FindOffset(previous, next, out staticTop, out staticBottom, out _);

    public static int? FindOffset(BgraImage previous, BgraImage next, out int staticTop, out int staticBottom, out double bestScore, double threshold = 0.8)
    {
        var h = previous.Height;
        var (hp, fp) = Hashes(previous);
        var (hn, fn) = Hashes(next);
        staticTop = staticBottom = 0;
        bestScore = 0;
        var equal = 0;
        for (var y = 0; y < h; y++) if (hp[y] == hn[y]) equal++;
        // All (or all but a few flickering) rows in place: nothing scrolled.
        if (equal >= h - Math.Max(1, h / 30)) { bestScore = 1; return 0; }
        while (staticTop < h && hp[staticTop] == hn[staticTop]) staticTop++;
        while (staticBottom < h - staticTop && hp[h - 1 - staticBottom] == hn[h - 1 - staticBottom]) staticBottom++;
        // Never let "still" edges take more than 40% each: in a long blank stretch everything matches.
        staticTop = Math.Min(staticTop, h * 2 / 5);
        staticBottom = Math.Min(staticBottom, h * 2 / 5);
        var moving = h - staticTop - staticBottom;
        var minOverlap = Math.Max(6, moving / 12);
        int? best = null;
        for (var d = 1; d <= moving - minOverlap; d++)
        {
            int matched = 0, considered = 0;
            for (var y = staticTop; y < h - staticBottom - d; y++)
            {
                var a = y + d;
                if (fp[a] && fn[y] && hp[a] == hn[y]) continue; // two blank rows say nothing
                considered++;
                if (hp[a] == hn[y]) matched++;
            }
            if (considered < 3) continue;
            var score = (double)matched / considered;
            if (score > bestScore + 1e-9) { bestScore = score; best = d; }
            if (score == 1 && considered >= minOverlap) break; // a perfect fit: the smallest move wins
        }
        // Apps re-draw a few rows differently as they scroll (text at the edge, a blinking caret),
        // so a strong majority is enough; a wrong offset matches almost nothing.
        return bestScore >= threshold ? best : null;
    }
}
