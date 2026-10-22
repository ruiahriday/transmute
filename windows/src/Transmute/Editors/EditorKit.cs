using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Transmute.App;

/// Opens the right editor for a file. Editors save a copy; the original is never changed.
static class Editors
{
    public static void Open(Job job, Window? owner)
    {
        Window window = job.Kind switch
        {
            FileKind.Image => new ImageEditorWindow(job),
            FileKind.Video => new VideoEditorWindow(job),
            FileKind.Audio => new AudioEditorWindow(job),
            _ => throw new InvalidOperationException(),
        };
        if (owner is not null) window.Owner = owner;
        else window.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        window.Show();
        window.Activate();
    }

    public static bool CanEdit(FileKind kind) => kind is FileKind.Image or FileKind.Video or FileKind.Audio;

    public static void Run(Job job, JobOperation operation) =>
        _ = JobQueue.Shared.Start([(job, operation)], Settings.Current.RevealWhenDone);

    /// A picture's pixels for the screen, keeping transparency.
    public static BitmapSource Pixels(ImageMagick.MagickImage image)
    {
        int w = (int)image.Width, h = (int)image.Height;
        var bytes = image.GetPixels().ToByteArray(ImageMagick.PixelMapping.BGRA)!;
        var bitmap = BitmapSource.Create(w, h, 96, 96, PixelFormats.Bgra32, null, bytes, w * 4);
        bitmap.Freeze();
        return bitmap;
    }

    public static BitmapSource Bitmap(byte[] encoded)
    {
        var image = new BitmapImage();
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.StreamSource = new MemoryStream(encoded);
        image.EndInit();
        image.Freeze();
        return image;
    }

    public static string Time(double seconds)
    {
        if (!double.IsFinite(seconds) || seconds < 0) seconds = 0;
        var t = TimeSpan.FromSeconds(seconds);
        return t.TotalHours >= 1 ? $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}.{t.Milliseconds / 100}" : $"{t.Minutes}:{t.Seconds:00}.{t.Milliseconds / 100}";
    }
}

/// Small builders so the editor windows read as layouts rather than property soup.
static class Ui
{
    public static Style Res(string key) => (Style)Application.Current.FindResource(key);
    public static Brush Brush(string key) => (Brush)Application.Current.FindResource(key);

    public static TextBlock Heading(string text) => new() { Text = text, Style = Res("SectionTitle") };
    public static TextBlock Caption(string text) => new() { Text = text, Style = Res("Caption") };
    public static TextBlock Label(string text) => new() { Text = text, VerticalAlignment = VerticalAlignment.Center };

    public static Button Button(string text, RoutedEventHandler click, bool primary = false, string? tip = null, object? contentOverride = null, string? icon = null)
    {
        object content = contentOverride ?? (icon is not null ? Icons.WithText(icon, text, 14) : text);
        var button = new Button { Content = content, Margin = new Thickness(0, 0, 6, 6), ToolTip = tip };
        if (primary) button.Style = Res("Primary");
        button.Click += click;
        return button;
    }

    public static WrapPanel Row(params UIElement[] children)
    {
        var panel = new WrapPanel();
        foreach (var child in children) panel.Children.Add(child);
        return panel;
    }

    /// A labelled slider with its value shown on the right.
    public static (FrameworkElement View, Slider Slider) Slider(string title, double min, double max, double value, Func<double, string> format, Action<double> changed, double step = 0)
    {
        var slider = new Slider { Minimum = min, Maximum = max, Value = value, VerticalAlignment = VerticalAlignment.Center };
        if (step > 0) { slider.TickFrequency = step; slider.IsSnapToTickEnabled = true; }
        var shown = new TextBlock { Text = format(value), Width = 58, TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center, Foreground = Brush("Secondary") };
        slider.ValueChanged += (_, e) => { shown.Text = format(e.NewValue); changed(e.NewValue); };
        var grid = new DockPanel { Margin = new Thickness(0, 3, 0, 3) };
        var label = new TextBlock { Text = title, Width = 86, VerticalAlignment = VerticalAlignment.Center };
        DockPanel.SetDock(label, Dock.Left);
        DockPanel.SetDock(shown, Dock.Right);
        grid.Children.Add(label);
        grid.Children.Add(shown);
        grid.Children.Add(slider);
        return (grid, slider);
    }

    public static ComboBox Combo<T>(IEnumerable<(string Label, T Value)> options, T selected, Action<T> changed)
    {
        var box = new ComboBox { MinWidth = 150, HorizontalAlignment = HorizontalAlignment.Left };
        var index = 0;
        foreach (var (label, value) in options)
        {
            box.Items.Add(new ComboBoxItem { Content = label, Tag = value });
            if (EqualityComparer<T>.Default.Equals(value, selected)) box.SelectedIndex = index;
            index++;
        }
        if (box.SelectedIndex < 0) box.SelectedIndex = 0;
        box.SelectionChanged += (_, _) => { if (box.SelectedItem is ComboBoxItem { Tag: T v }) changed(v); };
        return box;
    }

    public static DockPanel Labelled(string title, FrameworkElement control)
    {
        var row = new DockPanel { Margin = new Thickness(0, 3, 0, 3) };
        var label = new TextBlock { Text = title, Width = 86, VerticalAlignment = VerticalAlignment.Center };
        DockPanel.SetDock(label, Dock.Left);
        row.Children.Add(label);
        row.Children.Add(control);
        return row;
    }

    public static string Percent(double v) => $"{Math.Round(v * 100):0}%";
    public static string Signed(double v, string unit = "") => (v > 0 ? "+" : "") + v.ToString("0.0", CultureInfo.CurrentCulture) + unit;

    /// The standard editor layout: preview on the left, controls in a scrolling column on the
    /// right, Cancel and Save at the bottom.
    public static DockPanel EditorLayout(UIElement preview, UIElement controls, Button cancel, Button save, UIElement? footerLeft = null)
    {
        var footer = new DockPanel { Margin = new Thickness(16, 11, 16, 11), LastChildFill = false };
        save.Margin = new Thickness(0);
        cancel.Margin = new Thickness(0, 0, 8, 0);
        DockPanel.SetDock(save, Dock.Right);
        DockPanel.SetDock(cancel, Dock.Right);
        footer.Children.Add(save);
        footer.Children.Add(cancel);
        if (footerLeft is not null) footer.Children.Add(footerLeft);
        var footerBorder = new Border { Child = footer, Background = Brush("Card"), BorderBrush = Brush("Line"), BorderThickness = new Thickness(0, 1, 0, 0) };
        var side = new Border
        {
            Width = 330,
            Background = Brush("Card"),
            BorderBrush = Brush("Line"),
            BorderThickness = new Thickness(1, 0, 0, 0),
            Child = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = new Border { Padding = new Thickness(18, 2, 18, 18), Child = controls } },
        };
        var root = new DockPanel();
        DockPanel.SetDock(footerBorder, Dock.Bottom);
        DockPanel.SetDock(side, Dock.Right);
        root.Children.Add(footerBorder);
        root.Children.Add(side);
        root.Children.Add(new Border { Background = Brush("Stage"), Child = preview });
        return root;
    }

    public static void SetUpEditorWindow(Window window, string title)
    {
        window.Title = title;
        window.Width = 1080;
        window.Height = 720;
        window.MinWidth = 820;
        window.MinHeight = 540;
        window.Style = Res("BaseWindow");
        window.WindowStartupLocation = WindowStartupLocation.CenterOwner;
        window.Icon = new BitmapImage(new Uri("pack://application:,,,/Assets/app.ico"));
    }
}
