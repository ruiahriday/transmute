using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace Transmute.App;

/// The Windows calls WPF doesn't wrap.
static partial class Native
{
    public const int WH_MOUSE_LL = 14;
    public const int WM_MOUSEMOVE = 0x0200, WM_LBUTTONDOWN = 0x0201, WM_LBUTTONUP = 0x0202;
    public const int VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12, VK_LWIN = 0x5B, VK_RWIN = 0x5C, VK_LBUTTON = 0x01;
    public const int SM_CXDRAG = 68, SM_CYDRAG = 69;
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_NOACTIVATE = 0x08000000, WS_EX_TOOLWINDOW = 0x00000080;

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MSLLHOOKSTRUCT
    {
        public POINT pt;
        public uint mouseData, flags, time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct GUITHREADINFO
    {
        public int cbSize, flags;
        public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
        public RECT rcCaret;
    }

    public delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetWindowsHookEx(int idHook, HookProc proc, IntPtr hMod, uint threadId);

    [DllImport("user32.dll")]
    public static extern bool UnhookWindowsHookEx(IntPtr hook);

    [DllImport("user32.dll")]
    public static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr GetModuleHandle(string? name);

    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int key);

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT point);

    [DllImport("user32.dll")]
    public static extern bool GetGUIThreadInfo(uint threadId, ref GUITHREADINFO info);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);

    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hwnd, int index);

    [DllImport("user32.dll")]
    public static extern int SetWindowLong(IntPtr hwnd, int index, int value);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hwnd);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SHParseDisplayName(string name, IntPtr bindingContext, out IntPtr pidl, uint sfgaoIn, out uint sfgaoOut);

    [DllImport("shell32.dll")]
    static extern int SHOpenFolderAndSelectItems(IntPtr folder, uint count, IntPtr[] items, uint flags);

    [DllImport("ole32.dll")]
    static extern void CoTaskMemFree(IntPtr pv);

    public static bool KeyDown(int key) => (GetAsyncKeyState(key) & 0x8000) != 0;

    public static string ClassName(IntPtr hwnd)
    {
        var sb = new StringBuilder(256);
        GetClassName(hwnd, sb, sb.Capacity);
        return sb.ToString();
    }

    public static string WindowText(IntPtr hwnd)
    {
        var sb = new StringBuilder(256);
        GetWindowText(hwnd, sb, sb.Capacity);
        return sb.ToString();
    }

    /// True while some app is dragging something with OLE drag and drop (how Explorer, the
    /// desktop, browsers and Office drag files). OLE captures the mouse with a hidden window of
    /// its own while the drag lasts.
    public static bool OleDragInProgress()
    {
        var info = new GUITHREADINFO { cbSize = Marshal.SizeOf<GUITHREADINFO>() };
        if (!GetGUIThreadInfo(0, ref info) || info.hwndCapture == IntPtr.Zero) return false;
        var name = ClassName(info.hwndCapture);
        return name == "CLIPBRDWNDCLASS" || name.Contains("DragDrop", StringComparison.OrdinalIgnoreCase)
            || WindowText(info.hwndCapture).Contains("DragDrop", StringComparison.OrdinalIgnoreCase);
    }

    [DllImport("kernel32.dll")]
    static extern uint GetCurrentThreadId();

    public static string CaptureClassOfThisThread()
    {
        var info = new GUITHREADINFO { cbSize = Marshal.SizeOf<GUITHREADINFO>() };
        return GetGUIThreadInfo(GetCurrentThreadId(), ref info) && info.hwndCapture != IntPtr.Zero
            ? $"{ClassName(info.hwndCapture)} \"{WindowText(info.hwndCapture)}\"" : "";
    }

    /// Opens Explorer with the files selected (all must be in one folder for a multi-select).
    public static void RevealInExplorer(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0) return;
        try
        {
            foreach (var group in paths.GroupBy(p => Path.GetDirectoryName(Path.GetFullPath(p)) ?? ""))
            {
                if (SHParseDisplayName(group.Key, IntPtr.Zero, out var folder, 0, out _) != 0) throw new IOException();
                var items = new List<IntPtr>();
                try
                {
                    foreach (var path in group)
                        if (SHParseDisplayName(Path.GetFullPath(path), IntPtr.Zero, out var item, 0, out _) == 0) items.Add(item);
                    SHOpenFolderAndSelectItems(folder, (uint)items.Count, items.ToArray(), 0);
                }
                finally
                {
                    items.ForEach(CoTaskMemFree);
                    CoTaskMemFree(folder);
                }
            }
        }
        catch
        {
            var first = paths[0];
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{first}\"") { UseShellExecute = true });
        }
    }

    public static void Open(string pathOrUrl)
    {
        try { Process.Start(new ProcessStartInfo(pathOrUrl) { UseShellExecute = true }); }
        catch { }
    }
}
