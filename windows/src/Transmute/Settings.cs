using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32;

namespace Transmute.App;

public enum WheelKey { Shift, Ctrl, Alt, Off }

/// Preferences, kept in %APPDATA%\Transmute\settings.json.
public sealed class Settings
{
    public static Settings Current { get; private set; } = new();

    public static string Folder =>
        Environment.GetEnvironmentVariable("TRANSMUTE_SETTINGS_DIR") is { Length: > 0 } dir ? dir
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Transmute");
    static string FilePath => Path.Combine(Folder, "settings.json");

    public bool SaveInFolder { get; set; }
    public string OutputFolder { get; set; } = "";
    public bool RevealWhenDone { get; set; } = true;
    public double ImageQuality { get; set; } = 0.85;
    public bool StripMetadata { get; set; }
    public bool UseOfficeApps { get; set; } = true;
    public bool WheelEnabled { get; set; } = true;
    public WheelKey ConvertKey { get; set; } = WheelKey.Shift;
    public WheelKey ToolsKey { get; set; } = WheelKey.Ctrl;
    public WheelKey ActionsKey { get; set; } = WheelKey.Alt;
    /// Customized wheels by WheelLayout.Key ("convert.document"); a missing entry means the default.
    public Dictionary<string, List<string>> WheelLayouts { get; set; } = [];
    public bool ShakeToShelf { get; set; } = true;
    public bool TopEdgeToShelf { get; set; } = true;
    public bool OpenWindowAtStart { get; set; } = true;
    public List<string> ShelfFiles { get; set; } = [];
    public double[]? ShelfBounds { get; set; }
    public Dictionary<string, string> Choices { get; set; } = [];

    public static void Load()
    {
        try
        {
            if (File.Exists(FilePath))
                Current = JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath), Json) ?? new();
        }
        catch
        {
            Current = new();
        }
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Folder);
            var temp = FilePath + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(this, Json));
            File.Move(temp, FilePath, true);
        }
        catch { }
    }

    static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    public WheelKey KeyFor(WheelKind kind) => kind switch
    {
        WheelKind.Convert => ConvertKey,
        WheelKind.Tools => ToolsKey,
        _ => ActionsKey,
    };

    public ConversionOptions Options() => new()
    {
        Quality = ImageQuality,
        StripMetadata = StripMetadata,
        UseOfficeApps = UseOfficeApps,
        OutputFolder = SaveInFolder && Directory.Exists(OutputFolder) ? OutputFolder : null,
    };

    // Open at sign-in: a value under the current user's Run key.
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public static bool OpenAtLogin
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue("Transmute") is string;
        }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) key.SetValue("Transmute", $"\"{Environment.ProcessPath}\" --background");
            else key.DeleteValue("Transmute", false);
        }
    }
}

public static class WheelKeys
{
    public static string Label(this WheelKey key) => key switch
    {
        WheelKey.Shift => "Shift",
        WheelKey.Ctrl => "Ctrl",
        WheelKey.Alt => "Alt",
        _ => "Off",
    };

    public static bool IsDown(this WheelKey key) => key switch
    {
        WheelKey.Shift => Native.KeyDown(Native.VK_SHIFT),
        WheelKey.Ctrl => Native.KeyDown(Native.VK_CONTROL),
        WheelKey.Alt => Native.KeyDown(Native.VK_MENU),
        _ => false,
    };

    public static string Title(this WheelKind kind) => kind switch
    {
        WheelKind.Convert => "Convert to",
        WheelKind.Tools => "Tools",
        _ => "Actions",
    };

    public static string Hint(this WheelKind kind) => kind switch
    {
        WheelKind.Convert => "formats",
        WheelKind.Tools => "tools",
        _ => "actions",
    };
}
