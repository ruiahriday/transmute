using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace Transmute.App;

/// Global capture shortcuts (RegisterHotKey), set in Settings › Capture.
static class Hotkeys
{
    [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hwnd, int id);
    const uint NoRepeat = 0x4000;
    const int WM_HOTKEY = 0x0312;
    const int PrintScreenId = 900;

    static HwndSource? window;
    static readonly Dictionary<int, CaptureAction> registered = [];
    /// Shortcuts another app already has, by action.
    public static Dictionary<CaptureAction, string> Problems { get; } = [];
    public static string? PrintScreenProblem { get; private set; }

    public static Hotkey? For(CaptureAction action)
    {
        if (Settings.Current.CaptureHotkeys.TryGetValue(action.ToString(), out var text)) return Hotkey.Parse(text);
        return Hotkey.Default(action);
    }

    public static void Set(CaptureAction action, Hotkey? hotkey)
    {
        Settings.Current.CaptureHotkeys[action.ToString()] = hotkey?.ToString() ?? "";
        Settings.Current.Save();
        Apply();
    }

    public static void Start()
    {
        if (window is not null) return;
        window = new HwndSource(new HwndSourceParameters("Spinform shortcuts") { Width = 0, Height = 0, WindowStyle = 0, ParentWindow = new IntPtr(-3) /* message-only */ });
        window.AddHook(Hook);
        Apply();
    }

    public static void Stop()
    {
        if (window is null) return;
        foreach (var id in registered.Keys.Append(PrintScreenId)) UnregisterHotKey(window.Handle, id);
        registered.Clear();
        window.Dispose();
        window = null;
    }

    /// (Re)registers every shortcut from Settings.
    public static void Apply()
    {
        if (window is null) return;
        foreach (var id in registered.Keys) UnregisterHotKey(window.Handle, id);
        UnregisterHotKey(window.Handle, PrintScreenId);
        registered.Clear();
        Problems.Clear();
        PrintScreenProblem = null;
        var id2 = 1;
        foreach (var action in Enum.GetValues<CaptureAction>())
        {
            var id = id2++;
            if (For(action) is not { } key) continue;
            if (key.Problem is { } problem) { Problems[action] = problem; continue; }
            if (RegisterHotKey(window.Handle, id, (uint)key.Modifiers | NoRepeat, (uint)key.Key)) registered[id] = action;
            else Problems[action] = $"{key} is already used by another app.";
        }
        if (Settings.Current.PrintScreenTakeover && !RegisterHotKey(window.Handle, PrintScreenId, NoRepeat, Hotkey.PrintScreen))
            PrintScreenProblem = "Windows or another app is using the Print Screen key. In Windows Settings › Accessibility › Keyboard, turn off \"Use the Print screen key to open screen capture\".";
    }

    static IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg != WM_HOTKEY) return IntPtr.Zero;
        handled = true;
        var id = wParam.ToInt32();
        if (id == PrintScreenId) _ = Capture.Run(CaptureAction.Area);
        else if (registered.TryGetValue(id, out var action)) _ = Capture.Run(action);
        return IntPtr.Zero;
    }

    /// "Ctrl+Shift+4" for menus and tooltips, or "".
    public static string Label(CaptureAction action) => For(action)?.ToString() ?? "";
}
