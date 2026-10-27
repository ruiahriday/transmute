using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using Microsoft.Win32;

namespace Transmute.App;

/// Follows Windows: light or dark app mode, the user's accent colour, a dark title bar in dark
/// mode, and Mica behind the main windows on Windows 11. Every colour in App.xaml is a brush that
/// this swaps, so the app changes along with Windows' settings while it runs.
static class ThemeManager
{
    public static bool Dark { get; private set; }
    /// Set by the smoke test to force a mode.
    public static bool? Forced { get; set; }
    public static event Action? Changed;
    /// The accent for the always-dark capture bars (white text sits on it), in either mode.
    public static Brush OverlayAccent { get; private set; } = Solid(Color.FromRgb(0x00, 0x5F, 0xB8));

    static readonly Dictionary<string, string> Light = new()
    {
        ["Surface"] = "#F3F3F3", ["Card"] = "#FFFFFF", ["Subtle"] = "#F6F6F6", ["Pressed"] = "#EDEDED",
        ["Glass"] = "#FFFFFF", ["GlassEdge"] = "#E5E5E5", ["Line"] = "#E5E5E5", ["LineStrong"] = "#D0D0D0", ["HoverLine"] = "#BDBDBD",
        ["Ink"] = "#1B1B1B", ["Secondary"] = "#5C5C5C", ["Tertiary"] = "#737373", ["DisabledInk"] = "#A3A3A3", ["DisabledFill"] = "#F7F7F7",
        ["PrimaryDisabled"] = "#C8C8C8", ["Track"] = "#EBEBEB", ["Rail"] = "#D4D4D4", ["TooltipBg"] = "#FFFFFF", ["TooltipInk"] = "#1B1B1B",
        ["DashLine"] = "#C4C4C4", ["Danger"] = "#C42B1C", ["Success"] = "#0F7B0F", ["Warning"] = "#9D5D00", ["Stage"] = "#1C1C1C",
        ["RowHover"] = "#FAFAFA", ["SelectedPill"] = "#FFFFFF",
    };

    static readonly Dictionary<string, string> DarkPalette = new()
    {
        ["Surface"] = "#202020", ["Card"] = "#2B2B2B", ["Subtle"] = "#323232", ["Pressed"] = "#3A3A3A",
        ["Glass"] = "#2B2B2B", ["GlassEdge"] = "#3A3A3A", ["Line"] = "#383838", ["LineStrong"] = "#4A4A4A", ["HoverLine"] = "#5C5C5C",
        ["Ink"] = "#FFFFFF", ["Secondary"] = "#CFCFCF", ["Tertiary"] = "#9E9E9E", ["DisabledInk"] = "#6B6B6B", ["DisabledFill"] = "#262626",
        ["PrimaryDisabled"] = "#4A4A4A", ["Track"] = "#1C1C1C", ["Rail"] = "#4A4A4A", ["TooltipBg"] = "#2C2C2C", ["TooltipInk"] = "#FFFFFF",
        ["DashLine"] = "#555555", ["Danger"] = "#FF99A4", ["Success"] = "#6CCB5F", ["Warning"] = "#FCE100", ["Stage"] = "#141414",
        ["RowHover"] = "#303030", ["SelectedPill"] = "#3A3A3A",
    };

    /// Applies the current Windows settings and keeps following them.
    public static void Start()
    {
        Apply();
        EventManager.RegisterClassHandler(typeof(Window), FrameworkElement.LoadedEvent, new RoutedEventHandler((s, _) => Decorate((Window)s)));
        SystemEvents.UserPreferenceChanged += (_, e) =>
        {
            if (e.Category is UserPreferenceCategory.General or UserPreferenceCategory.Color or UserPreferenceCategory.VisualStyle)
                Application.Current?.Dispatcher.BeginInvoke(Apply);
        };
    }

    public static void Apply()
    {
        var app = Application.Current;
        if (app is null) return;
        Dark = Forced ?? SystemIsDark();
        foreach (var (key, hex) in Dark ? DarkPalette : Light) app.Resources[key] = Solid(Parse(hex));

        var (light, dark) = AccentColors();
        var accent = Dark ? dark : light;
        OverlayAccent = Solid(light);
        app.Resources["Accent"] = Solid(accent);
        app.Resources["Brand"] = Solid(accent);
        app.Resources["CoreGlow"] = Solid(accent);
        var hover = Mix(accent, Dark ? Colors.Black : Colors.White, 0.1);
        app.Resources["AccentHover"] = Solid(hover);
        app.Resources["BrandHover"] = Solid(hover);
        app.Resources["AccentPressed"] = Solid(Mix(accent, Dark ? Colors.Black : Colors.White, 0.2));
        app.Resources["AccentSoft"] = Solid(Mix(accent, Parse(Dark ? "#2B2B2B" : "#FFFFFF"), Dark ? 0.78 : 0.88));
        app.Resources["DropTint"] = Solid(Color.FromArgb(0x14, accent.R, accent.G, accent.B));
        app.Resources["OnAccent"] = Solid(Dark ? Colors.Black : Colors.White);

        foreach (Window w in app.Windows) Decorate(w);
        Changed?.Invoke();
    }

    static bool SystemIsDark()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is int v && v == 0;
        }
        catch { return false; }
    }

    /// The accent for light mode (a darker shade) and for dark mode (a lighter one), as Windows'
    /// own apps use them; Windows blue when the settings can't be read.
    static (Color Light, Color Dark) AccentColors()
    {
        try
        {
            var ui = new Windows.UI.ViewManagement.UISettings();
            Color C(Windows.UI.ViewManagement.UIColorType t) { var c = ui.GetColorValue(t); return Color.FromRgb(c.R, c.G, c.B); }
            return (C(Windows.UI.ViewManagement.UIColorType.AccentDark1), C(Windows.UI.ViewManagement.UIColorType.AccentLight2));
        }
        catch { }
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\DWM");
            if (key?.GetValue("AccentColor") is int abgr)
            {
                var c = Color.FromRgb((byte)abgr, (byte)(abgr >> 8), (byte)(abgr >> 16));
                return (Mix(c, Colors.Black, 0.15), Mix(c, Colors.White, 0.45));
            }
        }
        catch { }
        return (Parse("#005FB8"), Parse("#60CDFF"));
    }

    /// Dark title bar in dark mode; Mica behind standard windows on Windows 11 22H2 and later.
    static void Decorate(Window window)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero) return;
        int dark = Dark ? 1 : 0;
        if (DwmSetWindowAttribute(hwnd, 20, ref dark, 4) != 0) DwmSetWindowAttribute(hwnd, 19, ref dark, 4);
        if (!MicaSupported || window.AllowsTransparency || window.WindowStyle == WindowStyle.None) return;
        if (window.Style != window.TryFindResource("BaseWindow") as Style) return;
        // Only windows showing the plain surface colour get Mica; editors keep their dark stage.
        if (window.ReadLocalValue(Window.BackgroundProperty) != DependencyProperty.UnsetValue) return;
        if (HwndSource.FromHwnd(hwnd) is not { CompositionTarget: { } target }) return;
        var margins = new MARGINS { Left = -1, Right = -1, Top = -1, Bottom = -1 };
        if (DwmExtendFrameIntoClientArea(hwnd, ref margins) != 0) return;
        int mica = 2;
        if (DwmSetWindowAttribute(hwnd, 38, ref mica, 4) != 0) return;
        target.BackgroundColor = Colors.Transparent;
        window.Background = Brushes.Transparent;
    }

    static bool MicaSupported => Environment.OSVersion.Version.Build >= 22621;

    /// The brush a window shows behind its content (for screenshots of a Mica window).
    public static Brush SurfaceBrush => Application.Current.TryFindResource("Surface") as Brush ?? Brushes.White;

    static SolidColorBrush Solid(Color c) { var b = new SolidColorBrush(c); b.Freeze(); return b; }
    static Color Parse(string hex) => (Color)ColorConverter.ConvertFromString(hex);
    static Color Mix(Color a, Color b, double t) => Color.FromRgb((byte)(a.R + (b.R - a.R) * t), (byte)(a.G + (b.G - a.G) * t), (byte)(a.B + (b.B - a.B) * t));

    [StructLayout(LayoutKind.Sequential)] struct MARGINS { public int Left, Right, Top, Bottom; }
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
    [DllImport("dwmapi.dll")] static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref MARGINS margins);
}
