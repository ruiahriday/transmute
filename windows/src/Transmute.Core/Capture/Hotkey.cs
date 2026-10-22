namespace Transmute;

/// The modifier keys of a shortcut. The values are the ones RegisterHotKey takes.
[Flags]
public enum HotkeyModifiers { None = 0, Alt = 1, Ctrl = 2, Shift = 4, Win = 8 }

/// Everything a capture shortcut can start.
public enum CaptureAction { AllInOne, Area, Window, FullScreen, Previous, Scrolling, Text, RecordArea, RecordScreen, History }

/// A global shortcut: modifiers plus one key (a Windows virtual-key code). Written as text like
/// "Ctrl+Shift+4", which is how Settings stores it.
public readonly record struct Hotkey(HotkeyModifiers Modifiers, int Key)
{
    public const int PrintScreen = 0x2C;

    static readonly (string Name, int Code)[] Named =
    [
        ("Space", 0x20), ("PageUp", 0x21), ("PageDown", 0x22), ("End", 0x23), ("Home", 0x24),
        ("Left", 0x25), ("Up", 0x26), ("Right", 0x27), ("Down", 0x28), ("PrintScreen", 0x2C), ("Insert", 0x2D), ("Delete", 0x2E),
        ("Pause", 0x13), ("Tab", 0x09), ("Enter", 0x0D), ("Backspace", 0x08),
        (";", 0xBA), ("=", 0xBB), (",", 0xBC), ("-", 0xBD), (".", 0xBE), ("/", 0xBF), ("`", 0xC0), ("[", 0xDB), ("\\", 0xDC), ("]", 0xDD), ("'", 0xDE),
    ];

    static readonly Dictionary<string, int> Aliases = new(StringComparer.OrdinalIgnoreCase)
    {
        ["PrtScn"] = 0x2C, ["PrtSc"] = 0x2C, ["Print"] = 0x2C, ["Snapshot"] = 0x2C, ["Del"] = 0x2E, ["Ins"] = 0x2D,
        ["PgUp"] = 0x21, ["PgDn"] = 0x22, ["Return"] = 0x0D, ["Plus"] = 0xBB, ["Minus"] = 0xBD, ["Comma"] = 0xBC, ["Period"] = 0xBE,
    };

    /// The key's name as shown and stored, or null for keys a shortcut can't use.
    public static string? KeyName(int code)
    {
        if (code is >= 0x30 and <= 0x39 or >= 0x41 and <= 0x5A) return ((char)code).ToString();
        if (code is >= 0x70 and <= 0x87) return $"F{code - 0x6F}";
        if (code is >= 0x60 and <= 0x69) return $"Num{code - 0x60}";
        foreach (var (name, c) in Named) if (c == code) return name;
        return null;
    }

    public static int? KeyCode(string name)
    {
        name = name.Trim();
        if (name.Length == 1 && char.IsAsciiLetterOrDigit(name[0])) return char.ToUpperInvariant(name[0]);
        if (name.Length is >= 2 and <= 3 && (name[0] is 'F' or 'f') && int.TryParse(name[1..], out var f) && f is >= 1 and <= 24) return 0x6F + f;
        if (name.StartsWith("Num", StringComparison.OrdinalIgnoreCase) && name.Length == 4 && char.IsAsciiDigit(name[3])) return 0x60 + (name[3] - '0');
        foreach (var (n, c) in Named) if (string.Equals(n, name, StringComparison.OrdinalIgnoreCase)) return c;
        return Aliases.TryGetValue(name, out var alias) ? alias : null;
    }

    /// "Ctrl+Shift+4", "Win+Alt+F9", "PrintScreen"; case and spaces don't matter. Null when it
    /// isn't a shortcut (no key, an unknown key, or two keys).
    public static Hotkey? Parse(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var mods = HotkeyModifiers.None;
        int? key = null;
        // "+" is a key too ("Ctrl+Shift+="), so split carefully: an empty part after a "+" means the "+" key.
        var parts = text.Replace(" ", "").Split('+');
        for (var i = 0; i < parts.Length; i++)
        {
            var part = parts[i];
            if (part.Length == 0) { if (i == parts.Length - 1 && key is null) key = 0xBB; continue; }
            switch (part.ToLowerInvariant())
            {
                case "ctrl" or "control" or "ctl": mods |= HotkeyModifiers.Ctrl; continue;
                case "shift": mods |= HotkeyModifiers.Shift; continue;
                case "alt": mods |= HotkeyModifiers.Alt; continue;
                case "win" or "windows" or "meta": mods |= HotkeyModifiers.Win; continue;
            }
            if (key is not null) return null;
            key = KeyCode(part);
            if (key is null) return null;
        }
        return key is { } k ? new Hotkey(mods, k) : null;
    }

    public override string ToString()
    {
        var parts = new List<string>();
        if (Modifiers.HasFlag(HotkeyModifiers.Ctrl)) parts.Add("Ctrl");
        if (Modifiers.HasFlag(HotkeyModifiers.Alt)) parts.Add("Alt");
        if (Modifiers.HasFlag(HotkeyModifiers.Shift)) parts.Add("Shift");
        if (Modifiers.HasFlag(HotkeyModifiers.Win)) parts.Add("Win");
        parts.Add(KeyName(Key) ?? $"0x{Key:X2}");
        return string.Join("+", parts);
    }

    public bool IsFunctionKey => Key is >= 0x70 and <= 0x87;

    /// Why this can't be a global shortcut, or null when it can.
    public string? Problem
    {
        get
        {
            if (KeyName(Key) is null) return "That key can't be used in a shortcut.";
            if (Modifiers == (HotkeyModifiers.Win | HotkeyModifiers.Shift) && Key == 'S') return "Windows uses Win+Shift+S for its own screenshot tool.";
            if (Key == PrintScreen && Modifiers == HotkeyModifiers.None) return "Use the Print Screen setting below to take over the Print Screen key.";
            if (Key == PrintScreen && Modifiers is HotkeyModifiers.Win or (HotkeyModifiers.Win | HotkeyModifiers.Alt) or HotkeyModifiers.Alt)
                return "Windows uses that Print Screen combination itself.";
            if (Modifiers.HasFlag(HotkeyModifiers.Win) && (Modifiers & ~HotkeyModifiers.Win) == HotkeyModifiers.None)
                return "Windows keeps most Win+key shortcuts for itself; add Ctrl, Alt or Shift.";
            if ((Modifiers & (HotkeyModifiers.Ctrl | HotkeyModifiers.Alt | HotkeyModifiers.Win)) == 0 && !IsFunctionKey && Key != PrintScreen)
                return "Add Ctrl, Alt or Win so the shortcut doesn't get in the way of typing.";
            return null;
        }
    }

    /// The shortcut each action has until it's changed: Ctrl+Shift and a number, clear of
    /// Windows' own Win+Shift+S and Print Screen.
    public static Hotkey? Default(CaptureAction action) => action switch
    {
        CaptureAction.FullScreen => new(HotkeyModifiers.Ctrl | HotkeyModifiers.Shift, '3'),
        CaptureAction.Area => new(HotkeyModifiers.Ctrl | HotkeyModifiers.Shift, '4'),
        CaptureAction.RecordArea => new(HotkeyModifiers.Ctrl | HotkeyModifiers.Shift, '5'),
        CaptureAction.Window => new(HotkeyModifiers.Ctrl | HotkeyModifiers.Shift, '6'),
        CaptureAction.Previous => new(HotkeyModifiers.Ctrl | HotkeyModifiers.Shift, '7'),
        CaptureAction.Scrolling => new(HotkeyModifiers.Ctrl | HotkeyModifiers.Shift, '8'),
        CaptureAction.Text => new(HotkeyModifiers.Ctrl | HotkeyModifiers.Shift, '9'),
        CaptureAction.History => new(HotkeyModifiers.Ctrl | HotkeyModifiers.Shift, '0'),
        CaptureAction.AllInOne => new(HotkeyModifiers.Ctrl | HotkeyModifiers.Shift, '2'),
        _ => null,
    };

    public static string Title(CaptureAction action) => action switch
    {
        CaptureAction.AllInOne => "All-in-one",
        CaptureAction.Area => "Capture an area",
        CaptureAction.Window => "Capture a window",
        CaptureAction.FullScreen => "Capture the full screen",
        CaptureAction.Previous => "Capture the previous area again",
        CaptureAction.Scrolling => "Scrolling capture",
        CaptureAction.Text => "Copy text from the screen",
        CaptureAction.RecordArea => "Record an area (again to stop)",
        CaptureAction.RecordScreen => "Record the screen (again to stop)",
        CaptureAction.History => "Open capture history",
        _ => action.ToString(),
    };
}
