using System.Runtime.InteropServices;

namespace Transmute.Desktop;

/// Low-level mouse and keyboard hooks for recordings: clicks to highlight and keys to show.
/// They run on a thread of their own and only exist while a recording that asked for them is
/// going; nothing is stored or sent anywhere.
public sealed class InputHooks : IDisposable
{
    delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr module, uint thread);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string? name);
    [DllImport("user32.dll")] static extern int GetMessage(out MSG msg, IntPtr hwnd, uint min, uint max);
    [DllImport("user32.dll")] static extern bool PostThreadMessage(uint thread, uint msg, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();

    [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int x, y; }
    [StructLayout(LayoutKind.Sequential)] struct MouseData { public int X, Y; public uint Data, Flags, Time; public IntPtr Extra; }
    [StructLayout(LayoutKind.Sequential)] struct KeyData { public uint Vk, Scan, Flags, Time; public IntPtr Extra; }

    public event Action<int, int>? Clicked;
    /// A key went down: its virtual-key code.
    public event Action<int>? KeyPressed;

    readonly HookProc mouseProc, keyProc;
    readonly Thread thread;
    uint threadId;
    IntPtr mouseHook, keyHook;

    public InputHooks(bool mouse, bool keyboard)
    {
        mouseProc = OnMouse;
        keyProc = OnKey;
        using var ready = new ManualResetEventSlim();
        thread = new Thread(() =>
        {
            threadId = GetCurrentThreadId();
            var module = GetModuleHandle(null);
            if (mouse) mouseHook = SetWindowsHookEx(14, mouseProc, module, 0);
            if (keyboard) keyHook = SetWindowsHookEx(13, keyProc, module, 0);
            ready.Set();
            while (GetMessage(out _, IntPtr.Zero, 0, 0) > 0) { }
            if (mouseHook != IntPtr.Zero) UnhookWindowsHookEx(mouseHook);
            if (keyHook != IntPtr.Zero) UnhookWindowsHookEx(keyHook);
        }) { IsBackground = true, Name = "Spinform input hooks" };
        thread.Start();
        ready.Wait(3000);
    }

    IntPtr OnMouse(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0 && (wParam == 0x0201 || wParam == 0x0204 || wParam == 0x0207)) // left, right, middle down
        {
            var data = Marshal.PtrToStructure<MouseData>(lParam);
            try { Clicked?.Invoke(data.X, data.Y); } catch { }
        }
        return CallNextHookEx(mouseHook, code, wParam, lParam);
    }

    IntPtr OnKey(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0 && (wParam == 0x0100 || wParam == 0x0104)) // key down, system key down
        {
            var data = Marshal.PtrToStructure<KeyData>(lParam);
            try { KeyPressed?.Invoke((int)data.Vk); } catch { }
        }
        return CallNextHookEx(keyHook, code, wParam, lParam);
    }

    public void Dispose()
    {
        if (threadId != 0) PostThreadMessage(threadId, 0x0012 /* WM_QUIT */, IntPtr.Zero, IntPtr.Zero);
    }
}

/// Turns key presses into what a recording shows: "Ctrl + C", "⇧ Shift + Tab", "Hello".
public sealed class KeystrokeText
{
    [DllImport("user32.dll")] static extern short GetKeyState(int key);
    [DllImport("user32.dll")] static extern int ToUnicode(uint vk, uint scan, byte[] state, [Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder buffer, int size, uint flags);
    [DllImport("user32.dll")] static extern bool GetKeyboardState(byte[] state);

    public bool ShortcutsOnly { get; set; }
    public string Text { get; private set; } = "";
    public DateTime Changed { get; private set; } = DateTime.MinValue;
    bool typing;

    static bool Down(int vk) => (GetKeyState(vk) & 0x8000) != 0;

    public void Press(int vk)
    {
        if (vk is 0x10 or 0x11 or 0x12 or 0xA0 or 0xA1 or 0xA2 or 0xA3 or 0xA4 or 0xA5 or 0x5B or 0x5C) return; // modifiers alone
        bool ctrl = Down(0x11), alt = Down(0x12), win = Down(0x5B) || Down(0x5C), shift = Down(0x10);
        var name = Name(vk);
        var shortcut = ctrl || alt || win || (name.Length > 1 && vk != 0x20);
        var now = DateTime.Now;
        if (!shortcut)
        {
            if (ShortcutsOnly) return;
            // Plain typing collects into one line.
            var ch = Typed(vk) ?? name;
            Text = typing && now - Changed < TimeSpan.FromSeconds(1.6) ? (Text + ch)[Math.Max(0, Text.Length + ch.Length - 40)..] : ch;
            typing = true;
            Changed = now;
            return;
        }
        var parts = new List<string>();
        if (ctrl) parts.Add("Ctrl");
        if (alt) parts.Add("Alt");
        if (shift) parts.Add("Shift");
        if (win) parts.Add("Win");
        parts.Add(name);
        Text = string.Join(" + ", parts);
        typing = false;
        Changed = now;
    }

    static string? Typed(int vk)
    {
        try
        {
            var state = new byte[256];
            if (!GetKeyboardState(state)) return null;
            var sb = new System.Text.StringBuilder(8);
            return ToUnicode((uint)vk, 0, state, sb, sb.Capacity, 4) > 0 ? sb.ToString() : null;
        }
        catch { return null; }
    }

    public static string Name(int vk) => vk switch
    {
        0x08 => "Backspace", 0x09 => "Tab", 0x0D => "Enter", 0x1B => "Esc", 0x20 => "Space",
        0x21 => "Page Up", 0x22 => "Page Down", 0x23 => "End", 0x24 => "Home",
        0x25 => "←", 0x26 => "↑", 0x27 => "→", 0x28 => "↓", 0x2C => "Print Screen", 0x2D => "Insert", 0x2E => "Delete",
        0x14 => "Caps Lock",
        _ => Hotkey.KeyName(vk) ?? $"Key {vk}",
    };
}
