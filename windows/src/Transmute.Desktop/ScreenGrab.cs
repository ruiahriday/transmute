using System.Runtime.InteropServices;
using static Transmute.Desktop.Win32;

namespace Transmute.Desktop;

/// Grabs a part of the screen with GDI (BitBlt), again and again into the same buffer. GDI reads
/// the desktop as Windows composes it, so it works on every Windows 10 and 11 PC, x64 or ARM64,
/// with or without a graphics card, and in physical pixels across displays with different scaling.
public sealed unsafe class ScreenGrabber : IDisposable
{
    readonly IntPtr screenDc, memoryDc, bitmap, previous;
    readonly byte* bits;
    public int Width { get; }
    public int Height { get; }
    public int Length => Width * Height * 4;
    public ReadOnlySpan<byte> Pixels => new(bits, Length);

    public ScreenGrabber(int width, int height)
    {
        Width = Math.Max(1, width);
        Height = Math.Max(1, height);
        screenDc = GetDC(IntPtr.Zero);
        memoryDc = CreateCompatibleDC(screenDc);
        var header = new BITMAPINFOHEADER { biSize = Marshal.SizeOf<BITMAPINFOHEADER>(), biWidth = Width, biHeight = -Height, biPlanes = 1, biBitCount = 32 };
        bitmap = CreateDIBSection(screenDc, ref header, 0, out var pointer, IntPtr.Zero, 0);
        if (bitmap == IntPtr.Zero) { Dispose(); throw new InvalidOperationException("Windows couldn't make room for the screen picture."); }
        bits = (byte*)pointer;
        previous = SelectObject(memoryDc, bitmap);
    }

    /// Copies the screen area starting at (x, y). `layered` also takes in see-through windows
    /// (always wanted for still pictures; recordings leave it off because it can make the mouse
    /// pointer flicker).
    public void Grab(int x, int y, bool layered = true)
    {
        if (!BitBlt(memoryDc, 0, 0, Width, Height, screenDc, x, y, SRCCOPY | (layered ? CAPTUREBLT : 0)))
            throw new InvalidOperationException("Windows didn't allow reading the screen.");
        GdiFlush();
    }

    readonly Dictionary<IntPtr, (int X, int Y)> hotspots = [];

    /// Draws the mouse pointer where it is, for a grab taken at (originX, originY).
    public void DrawCursor(int originX, int originY, double scale = 1)
    {
        var info = new CURSORINFO { cbSize = Marshal.SizeOf<CURSORINFO>() };
        if (!GetCursorInfo(ref info) || (info.flags & CURSOR_SHOWING) == 0 || info.hCursor == IntPtr.Zero) return;
        if (!hotspots.TryGetValue(info.hCursor, out var hot))
        {
            if (GetIconInfo(info.hCursor, out var icon))
            {
                hot = (icon.xHotspot, icon.yHotspot);
                if (icon.hbmMask != IntPtr.Zero) DeleteObject(icon.hbmMask);
                if (icon.hbmColor != IntPtr.Zero) DeleteObject(icon.hbmColor);
            }
            hotspots[info.hCursor] = hot;
        }
        var size = scale == 1 ? 0 : (int)Math.Round(GetSystemMetrics(13 /* SM_CXCURSOR */) * scale);
        var hx = (int)Math.Round(hot.X * scale);
        var hy = (int)Math.Round(hot.Y * scale);
        DrawIconEx(memoryDc, info.ptScreenPos.X - originX - hx, info.ptScreenPos.Y - originY - hy, info.hCursor, size, size, 0, IntPtr.Zero, DI_NORMAL);
    }

    /// A ring (or disc) around a point, for showing clicks. Colour is RRGGBB.
    public void DrawRing(int x, int y, int radius, int rgb, int thickness, bool filled)
    {
        var colorref = ((rgb & 0xFF) << 16) | (rgb & 0xFF00) | ((rgb >> 16) & 0xFF);
        var pen = CreatePen(0, Math.Max(1, thickness), colorref);
        var brush = filled ? CreateSolidBrush(colorref) : GetStockObject(5 /* NULL_BRUSH */);
        var oldPen = SelectObject(memoryDc, pen);
        var oldBrush = SelectObject(memoryDc, brush);
        Ellipse(memoryDc, x - radius, y - radius, x + radius, y + radius);
        SelectObject(memoryDc, oldPen);
        SelectObject(memoryDc, oldBrush);
        DeleteObject(pen);
        if (filled) DeleteObject(brush);
        GdiFlush();
    }

    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFont(int height, int width, int escapement, int orientation, int weight, uint italic, uint underline, uint strike,
        uint charset, uint precision, uint clip, uint quality, uint pitch, string face);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)] static extern bool GetTextExtentPoint32(IntPtr hdc, string text, int length, out SIZE size);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)] static extern bool TextOut(IntPtr hdc, int x, int y, string text, int length);
    [DllImport("gdi32.dll")] static extern int SetBkMode(IntPtr hdc, int mode);
    [DllImport("gdi32.dll")] static extern int SetTextColor(IntPtr hdc, int color);
    [DllImport("gdi32.dll")] static extern bool RoundRect(IntPtr hdc, int l, int t, int r, int b, int w, int h);
    [StructLayout(LayoutKind.Sequential)] struct SIZE { public int cx, cy; }

    static int ColorRef(int rgb) => ((rgb & 0xFF) << 16) | (rgb & 0xFF00) | ((rgb >> 16) & 0xFF);

    /// A rounded label with text, placed by `anchor` (0 bottom centre, 1 bottom left, 2 bottom
    /// right, 3 top centre) inside the grab. Dark draws white text on near-black.
    public void DrawLabel(string text, int fontSize, bool dark, int anchor)
    {
        if (string.IsNullOrEmpty(text)) return;
        var font = CreateFont(-fontSize, 0, 0, 0, 600, 0, 0, 0, 1, 0, 0, 5 /* ClearType */, 0, "Segoe UI");
        var oldFont = SelectObject(memoryDc, font);
        GetTextExtentPoint32(memoryDc, text, text.Length, out var size);
        int padX = fontSize * 2 / 3, padY = fontSize / 3, margin = Math.Max(8, fontSize);
        int w = size.cx + 2 * padX, h = size.cy + 2 * padY;
        var x = anchor switch { 1 => margin, 2 => Width - w - margin, _ => (Width - w) / 2 };
        var y = anchor == 3 ? margin : Height - h - margin * 2;
        var back = CreateSolidBrush(ColorRef(dark ? 0x1C1B22 : 0xF8F8FB));
        var pen = CreatePen(0, 1, ColorRef(dark ? 0x3A3946 : 0xD4D4DE));
        var oldBrush = SelectObject(memoryDc, back);
        var oldPen = SelectObject(memoryDc, pen);
        RoundRect(memoryDc, x, y, x + w, y + h, h / 2, h / 2);
        SetBkMode(memoryDc, 1 /* TRANSPARENT */);
        SetTextColor(memoryDc, ColorRef(dark ? 0xFFFFFF : 0x15141C));
        TextOut(memoryDc, x + padX, y + padY, text, text.Length);
        SelectObject(memoryDc, oldBrush);
        SelectObject(memoryDc, oldPen);
        SelectObject(memoryDc, oldFont);
        DeleteObject(back);
        DeleteObject(pen);
        DeleteObject(font);
        GdiFlush();
    }

    /// Blends a picture (BGRA, straight alpha) onto the grab with its top-left at (x, y).
    public void Blend(BgraImage overlay, int x, int y, double opacity = 1)
    {
        var src = overlay.Pixels;
        for (var row = 0; row < overlay.Height; row++)
        {
            var ty = y + row;
            if (ty < 0 || ty >= Height) continue;
            for (var col = 0; col < overlay.Width; col++)
            {
                var tx = x + col;
                if (tx < 0 || tx >= Width) continue;
                var si = (row * overlay.Width + col) * 4;
                var a = src[si + 3] * opacity / 255.0;
                if (a <= 0) continue;
                var d = bits + (ty * Width + tx) * 4;
                d[0] = (byte)(src[si] * a + d[0] * (1 - a));
                d[1] = (byte)(src[si + 1] * a + d[1] * (1 - a));
                d[2] = (byte)(src[si + 2] * a + d[2] * (1 - a));
            }
        }
    }

    /// A copy of the grab, fully opaque.
    public BgraImage ToImage()
    {
        var image = new BgraImage(Width, Height);
        Pixels.CopyTo(image.Pixels);
        var p = image.Pixels;
        for (var i = 3; i < p.Length; i += 4) p[i] = 255;
        return image;
    }

    public void Dispose()
    {
        if (memoryDc != IntPtr.Zero)
        {
            if (previous != IntPtr.Zero) SelectObject(memoryDc, previous);
            DeleteDC(memoryDc);
        }
        if (bitmap != IntPtr.Zero) DeleteObject(bitmap);
        if (screenDc != IntPtr.Zero) ReleaseDC(IntPtr.Zero, screenDc);
    }
}

public static class ScreenGrab
{
    /// A still picture of part of the screen (physical pixels).
    public static BgraImage Area(PixelRect area, bool cursor = false)
    {
        using var grabber = new ScreenGrabber(area.Width, area.Height);
        grabber.Grab(area.X, area.Y, layered: true);
        if (cursor) grabber.DrawCursor(area.X, area.Y);
        return grabber.ToImage();
    }

    /// Every display at once.
    public static BgraImage Everything(bool cursor = false) => Area(Screens.VirtualScreen, cursor);
}
