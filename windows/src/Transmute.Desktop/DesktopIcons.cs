using static Transmute.Desktop.Win32;

namespace Transmute.Desktop;

/// Hides the desktop's icons for a clean screenshot or recording and brings them back after.
public static class DesktopIcons
{
    static IntPtr Find()
    {
        // The icons live in a list view under SHELLDLL_DefView, whose parent is Progman or one
        // of the WorkerW windows behind it.
        var progman = FindWindow("Progman", null);
        var view = FindWindowEx(progman, IntPtr.Zero, "SHELLDLL_DefView", null);
        var worker = IntPtr.Zero;
        while (view == IntPtr.Zero)
        {
            worker = FindWindowEx(IntPtr.Zero, worker, "WorkerW", null);
            if (worker == IntPtr.Zero) break;
            view = FindWindowEx(worker, IntPtr.Zero, "SHELLDLL_DefView", null);
        }
        return view == IntPtr.Zero ? IntPtr.Zero : FindWindowEx(view, IntPtr.Zero, "SysListView32", null);
    }

    /// Hides the icons; dispose the result to show them again. Does nothing if they were already hidden.
    public static IDisposable Hide()
    {
        var list = Find();
        if (list == IntPtr.Zero || !IsWindowVisible(list)) return new Restore(IntPtr.Zero);
        ShowWindow(list, SW_HIDE);
        return new Restore(list);
    }

    sealed class Restore(IntPtr list) : IDisposable
    {
        bool done;
        public void Dispose()
        {
            if (done || list == IntPtr.Zero) return;
            done = true;
            ShowWindow(list, SW_SHOW);
        }
    }
}
