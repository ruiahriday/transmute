namespace Transmute;

/// A rectangle in physical screen pixels (the coordinates Windows uses for a per-monitor DPI
/// aware app; the main display's top-left is 0,0 and others can be negative).
public readonly record struct PixelRect(int X, int Y, int Width, int Height)
{
    public int Right => X + Width;
    public int Bottom => Y + Height;
    public bool IsEmpty => Width <= 0 || Height <= 0;
    public long Area => IsEmpty ? 0 : (long)Width * Height;

    public static PixelRect FromEdges(int left, int top, int right, int bottom) =>
        new(Math.Min(left, right), Math.Min(top, bottom), Math.Abs(right - left), Math.Abs(bottom - top));

    public bool Contains(int x, int y) => x >= X && y >= Y && x < Right && y < Bottom;

    public PixelRect Intersect(PixelRect other)
    {
        int l = Math.Max(X, other.X), t = Math.Max(Y, other.Y), r = Math.Min(Right, other.Right), b = Math.Min(Bottom, other.Bottom);
        return r <= l || b <= t ? default : new(l, t, r - l, b - t);
    }

    public PixelRect Union(PixelRect other)
    {
        if (IsEmpty) return other;
        if (other.IsEmpty) return this;
        int l = Math.Min(X, other.X), t = Math.Min(Y, other.Y), r = Math.Max(Right, other.Right), b = Math.Max(Bottom, other.Bottom);
        return new(l, t, r - l, b - t);
    }

    public PixelRect Offset(int dx, int dy) => this with { X = X + dx, Y = Y + dy };

    public PixelRect Inflate(int by) => new(X - by, Y - by, Width + 2 * by, Height + 2 * by);

    /// Shrinks to even width and height (video encoders need that).
    public PixelRect Even() => this with { Width = Math.Max(2, Width / 2 * 2), Height = Math.Max(2, Height / 2 * 2) };

    /// "120,80,640,480": how the last area is stored.
    public override string ToString() => $"{X},{Y},{Width},{Height}";

    public static PixelRect? Parse(string? text)
    {
        var parts = (text ?? "").Split(',');
        if (parts.Length != 4) return null;
        var n = new int[4];
        for (var i = 0; i < 4; i++) if (!int.TryParse(parts[i].Trim(), out n[i])) return null;
        var r = new PixelRect(n[0], n[1], n[2], n[3]);
        return r.IsEmpty ? null : r;
    }

    /// The rectangle with a size typed in ("1280x720") kept centred on this one.
    public PixelRect Resized(int width, int height) =>
        new(X + (Width - width) / 2, Y + (Height - height) / 2, Math.Max(1, width), Math.Max(1, height));

    /// The largest rectangle of the given shape (width ÷ height) inside this one, anchored at
    /// the corner where a drag started, as when the aspect is locked while dragging.
    public static PixelRect Drag(int startX, int startY, int x, int y, double? aspect)
    {
        if (aspect is not { } a || a <= 0) return FromEdges(startX, startY, x, y);
        int dx = x - startX, dy = y - startY;
        double w = Math.Abs(dx), h = Math.Abs(dy);
        if (w / Math.Max(1, h) > a) w = h * a; else h = w / a;
        var ex = startX + (int)Math.Round(Math.Sign(dx == 0 ? 1 : dx) * w);
        var ey = startY + (int)Math.Round(Math.Sign(dy == 0 ? 1 : dy) * h);
        return FromEdges(startX, startY, ex, ey);
    }
}
