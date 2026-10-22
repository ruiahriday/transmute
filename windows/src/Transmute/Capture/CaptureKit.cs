using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Transmute.Desktop;

namespace Transmute.App;

/// Small shared pieces for the capture windows: pictures to and from WPF, the clipboard, where
/// files go, and putting windows at exact physical-pixel spots on any display.
static class CaptureKit
{
    static Settings Prefs => Settings.Current;

    public static string CaptureFolder => Prefs.CaptureFolder is { Length: > 0 } f ? f
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "Spinform");

    public static string RecordingFolder => Prefs.RecordingFolder is { Length: > 0 } f ? f
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyVideos), "Spinform");

    public static string HistoryFolder => Environment.GetEnvironmentVariable("TRANSMUTE_HISTORY_DIR") is { Length: > 0 } dir ? dir
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Spinform", "History");

    static CaptureHistory? history;
    public static CaptureHistory History => history ??= new CaptureHistory(HistoryFolder);

    /// "Spinform 2026-10-22 at 14.32.10"
    public static string NewName(string what = "Spinform") => $"{what} {DateTime.Now:yyyy-MM-dd} at {DateTime.Now:HH.mm.ss}";

    public static BitmapSource ToBitmap(BgraImage image)
    {
        var bitmap = BitmapSource.Create(image.Width, image.Height, 96, 96, PixelFormats.Bgra32, null, image.Pixels, image.Stride);
        bitmap.Freeze();
        return bitmap;
    }

    public static BgraImage FromBitmap(BitmapSource source)
    {
        var converted = source.Format == PixelFormats.Bgra32 ? source : new FormatConvertedBitmap(source, PixelFormats.Bgra32, null, 0);
        var image = new BgraImage(converted.PixelWidth, converted.PixelHeight);
        converted.CopyPixels(image.Pixels, image.Stride, 0);
        return image;
    }

    public static BitmapSource Load(string path, int decodeWidth = 0)
    {
        var image = new BitmapImage();
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.CreateOptions = BitmapCreateOptions.IgnoreColorProfile;
        if (decodeWidth > 0) image.DecodePixelWidth = decodeWidth;
        using (var stream = File.OpenRead(path))
        {
            image.StreamSource = stream;
            image.EndInit();
        }
        image.Freeze();
        return image;
    }

    /// Puts a picture on the clipboard, as a bitmap and as PNG (which keeps transparency).
    public static void CopyImage(string path)
    {
        var bitmap = Load(path);
        var data = new DataObject();
        data.SetImage(bitmap);
        var png = new MemoryStream();
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        encoder.Save(png);
        data.SetData("PNG", png);
        SetClipboard(data);
    }

    public static void CopyFile(string path)
    {
        var data = new DataObject();
        data.SetFileDropList([path]);
        SetClipboard(data);
    }

    public static void CopyText(string text) => SetClipboard(new DataObject(DataFormats.UnicodeText, text));

    /// The clipboard can be busy for a moment when another app is reading it.
    static void SetClipboard(DataObject data)
    {
        for (var i = 0; i < 10; i++)
        {
            try { Clipboard.SetDataObject(data, true); return; }
            catch (COMException) { Thread.Sleep(60); }
        }
    }

    // Placing windows in physical pixels

    [DllImport("user32.dll")]
    static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int w, int h, uint flags);
    public static readonly IntPtr Topmost = new(-1);
    const uint NoSize = 0x1, NoZOrder = 0x4, NoActivate = 0x10;

    public static IntPtr Handle(Window window) => new WindowInteropHelper(window).EnsureHandle();

    public static void MoveTo(Window window, int x, int y) => SetWindowPos(Handle(window), IntPtr.Zero, x, y, 0, 0, NoSize | NoZOrder | NoActivate);

    public static void SetBounds(Window window, PixelRect r) => SetWindowPos(Handle(window), Topmost, r.X, r.Y, r.Width, r.Height, NoActivate);

    /// The window's size in physical pixels on the display it's on now.
    public static (int Width, int Height) PhysicalSize(Window window)
    {
        var dpi = VisualTreeHelper.GetDpi(window);
        return ((int)Math.Round(window.ActualWidth * dpi.DpiScaleX), (int)Math.Round(window.ActualHeight * dpi.DpiScaleY));
    }

    /// Moves a (shown) window onto a display so it takes that display's scaling, then puts it at
    /// a point given by `place` from its physical size.
    public static void Place(Window window, MonitorInfo monitor, Func<int, int, (int X, int Y)> place)
    {
        MoveTo(window, monitor.WorkArea.X + 10, monitor.WorkArea.Y + 10);
        window.UpdateLayout();
        void Finish()
        {
            var (w, h) = PhysicalSize(window);
            var (x, y) = place(w, h);
            MoveTo(window, x, y);
        }
        Finish();
        // The scaling change arrives as a message; place it again once it has been handled.
        window.Dispatcher.BeginInvoke(Finish, System.Windows.Threading.DispatcherPriority.Background);
    }

    public static void PlaceAtCorner(Window window, MonitorInfo monitor, bool right, int margin = 16, int lift = 0)
    {
        var scaled = (int)Math.Round(margin * monitor.Scale);
        Place(window, monitor, (w, h) => (right ? monitor.WorkArea.Right - w - scaled : monitor.WorkArea.X + scaled, monitor.WorkArea.Bottom - h - scaled - lift));
    }

    /// Keeps a helper window (bars, borders, countdowns) out of screenshots and recordings.
    public static void KeepOutOfCaptures(Window window)
    {
        if (window.IsLoaded) Screens.ExcludeFromCapture(Handle(window));
        else window.SourceInitialized += (_, _) => Screens.ExcludeFromCapture(Handle(window));
    }

    /// A window that never takes focus or shows in Alt+Tab.
    public static void MakeToolWindow(Window window, bool clickThrough = false)
    {
        void Apply()
        {
            var hwnd = Handle(window);
            var ex = Native.GetWindowLong(hwnd, Native.GWL_EXSTYLE) | Native.WS_EX_TOOLWINDOW;
            if (clickThrough) ex |= 0x20 | 0x80000;
            Native.SetWindowLong(hwnd, Native.GWL_EXSTYLE, ex);
        }
        if (window.IsLoaded || new WindowInteropHelper(window).Handle != IntPtr.Zero) Apply();
        else window.SourceInitialized += (_, _) => Apply();
    }

    public static void SetClickThrough(Window window, bool on)
    {
        var hwnd = Handle(window);
        var ex = Native.GetWindowLong(hwnd, Native.GWL_EXSTYLE);
        ex = on ? ex | 0x20 | 0x80000 : ex & ~0x20;
        Native.SetWindowLong(hwnd, Native.GWL_EXSTYLE, ex);
    }

    public static Style Style(string key) => (Style)Application.Current.FindResource(key);
    public static Brush Brush(string key) => (Brush)Application.Current.FindResource(key);

    /// A shadowed white card, the look of Spinform's floating panels.
    public static FrameworkElement Card(UIElement content, Thickness padding, double radius = 10)
    {
        var shadow = new System.Windows.Controls.Border
        {
            Background = Brushes.White,
            CornerRadius = new CornerRadius(radius),
            Margin = new Thickness(10),
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 18, ShadowDepth = 3, Direction = 270, Opacity = 0.2 },
        };
        var card = new System.Windows.Controls.Border
        {
            Background = Brushes.White,
            CornerRadius = new CornerRadius(radius),
            BorderBrush = Brush("Line"),
            BorderThickness = new Thickness(1),
            Padding = padding,
            Margin = new Thickness(10),
            Child = content,
            SnapsToDevicePixels = true,
        };
        return new System.Windows.Controls.Grid { Children = { shadow, card } };
    }

    /// Sets up a borderless, see-through, always-on-top floating window.
    public static void Floating(Window window)
    {
        window.WindowStyle = WindowStyle.None;
        window.AllowsTransparency = true;
        window.Background = Brushes.Transparent;
        window.Topmost = true;
        window.ShowInTaskbar = false;
        window.ResizeMode = ResizeMode.NoResize;
        window.SizeToContent = SizeToContent.WidthAndHeight;
        window.FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI");
        window.UseLayoutRounding = true;
        TextOptions.SetTextFormattingMode(window, TextFormattingMode.Display);
    }

    /// An icon-only flat button with a tooltip.
    public static System.Windows.Controls.Button IconButton(string glyph, string tip, Action click, double size = 16, Brush? color = null)
    {
        var button = new System.Windows.Controls.Button { Style = Style("Flat"), ToolTip = tip, Content = Icons.Make(glyph, size), Padding = new Thickness(6), Focusable = false };
        if (color is not null) button.Foreground = color;
        else button.Foreground = Brush("Ink");
        button.Click += (_, _) => click();
        return button;
    }

    /// The wallpaper's file, for putting window captures on it.
    public static string? WallpaperPath()
    {
        try
        {
            var buffer = new System.Text.StringBuilder(520);
            return SystemParametersInfo(0x73 /* SPI_GETDESKWALLPAPER */, (uint)buffer.Capacity, buffer, 0) && File.Exists(buffer.ToString()) ? buffer.ToString() : null;
        }
        catch { return null; }
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool SystemParametersInfo(uint action, uint param, System.Text.StringBuilder value, uint winIni);
}
