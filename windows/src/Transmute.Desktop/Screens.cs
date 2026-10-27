using System.Runtime.InteropServices;
using static Transmute.Desktop.Win32;

namespace Transmute.Desktop;

public sealed record MonitorInfo(int Index, IntPtr Handle, PixelRect Bounds, PixelRect WorkArea, double Scale, bool IsPrimary)
{
    public string Label => $"Display {Index + 1}{(IsPrimary ? " (main)" : "")} · {Bounds.Width} × {Bounds.Height}";
}

public sealed record WindowInfo(IntPtr Handle, PixelRect Bounds, string Title, uint ProcessId);

/// Displays and windows, in physical pixels. The app is per-monitor DPI aware, so these are the
/// real pixel positions even when displays use different scaling.
public static class Screens
{
    public static PixelRect VirtualScreen => new(GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN),
        GetSystemMetrics(SM_CXVIRTUALSCREEN), GetSystemMetrics(SM_CYVIRTUALSCREEN));

    public static IReadOnlyList<MonitorInfo> Monitors()
    {
        var list = new List<MonitorInfo>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr monitor, IntPtr _, ref RECT _, IntPtr _) =>
        {
            var info = new MONITORINFOEX { cbSize = Marshal.SizeOf<MONITORINFOEX>() };
            if (GetMonitorInfo(monitor, ref info))
            {
                double scale = 1;
                try { if (GetDpiForMonitor(monitor, 0, out var dx, out _) == 0) scale = dx / 96.0; } catch { }
                list.Add(new MonitorInfo(0, monitor, Rect(info.rcMonitor), Rect(info.rcWork), scale, (info.dwFlags & 1) != 0));
            }
            return true;
        }, IntPtr.Zero);
        // Main display first, then left to right.
        return list.OrderByDescending(m => m.IsPrimary).ThenBy(m => m.Bounds.X).ThenBy(m => m.Bounds.Y)
            .Select((m, i) => m with { Index = i }).ToList();
    }

    static PixelRect Rect(RECT r) => PixelRect.FromEdges(r.Left, r.Top, r.Right, r.Bottom);

    public static (int X, int Y) Cursor
    {
        get { GetCursorPos(out var p); return (p.X, p.Y); }
    }

    public static MonitorInfo MonitorAt(int x, int y)
    {
        var all = Monitors();
        return all.FirstOrDefault(m => m.Bounds.Contains(x, y))
            ?? all.OrderBy(m => Distance(m.Bounds, x, y)).First();
    }

    public static MonitorInfo MonitorUnderCursor()
    {
        var (x, y) = Cursor;
        return MonitorAt(x, y);
    }

    static double Distance(PixelRect r, int x, int y)
    {
        var dx = Math.Max(0, Math.Max(r.X - x, x - r.Right));
        var dy = Math.Max(0, Math.Max(r.Y - y, y - r.Bottom));
        return Math.Sqrt(dx * dx + dy * dy);
    }

    /// The window's visible bounds: without the invisible resize borders Windows 10 and 11 add.
    public static PixelRect WindowBounds(IntPtr hwnd)
    {
        if (DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, out RECT r, Marshal.SizeOf<RECT>()) == 0 && r.Width > 0)
            return Rect(r);
        GetWindowRect(hwnd, out r);
        return Rect(r);
    }

    /// Visible top-level windows, front to back, leaving out this app's own (unless asked),
    /// hidden UWP shells and the desktop.
    public static IReadOnlyList<WindowInfo> Windows(bool includeOwn = false)
    {
        var own = GetCurrentProcessId();
        var shell = GetShellWindow();
        var list = new List<WindowInfo>();
        EnumWindows((hwnd, _) =>
        {
            if (!IsWindowVisible(hwnd) || IsIconic(hwnd) || hwnd == shell) return true;
            var ex = GetWindowLong(hwnd, GWL_EXSTYLE);
            if ((ex & WS_EX_TRANSPARENT) != 0 && (ex & WS_EX_LAYERED) != 0) return true;
            if (DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, out int cloaked, 4) == 0 && cloaked != 0) return true;
            GetWindowThreadProcessId(hwnd, out var pid);
            if (pid == own && !includeOwn) return true;
            var cls = ClassName(hwnd);
            if (cls is "Progman" or "WorkerW" or "Shell_TrayWnd" or "Shell_SecondaryTrayWnd") return true;
            var bounds = WindowBounds(hwnd);
            if (bounds.Width < 24 || bounds.Height < 24) return true;
            list.Add(new WindowInfo(hwnd, bounds, WindowText(hwnd), pid));
            return true;
        }, IntPtr.Zero);
        return list;
    }

    /// The frontmost window under a point.
    public static WindowInfo? WindowAt(IReadOnlyList<WindowInfo> windows, int x, int y) => windows.FirstOrDefault(w => w.Bounds.Contains(x, y));

    /// Keeps a window out of screenshots and recordings (Windows 10 2004 and later; earlier
    /// versions ignore it).
    public static void ExcludeFromCapture(IntPtr hwnd, bool exclude = true)
    {
        try { SetWindowDisplayAffinity(hwnd, exclude ? WDA_EXCLUDEFROMCAPTURE : WDA_NONE); } catch { }
    }
}
