using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Transmute.Desktop;

namespace Transmute.App;

/// Every recent capture, newest first: screenshots, recordings and copied text. Each can be
/// copied, edited, pinned, shown again as a thumbnail, found in its folder or deleted. Kept in
/// %LOCALAPPDATA%\Spinform\History for as long as Settings says.
sealed class HistoryWindow : Window
{
    static HistoryWindow? current;
    readonly WrapPanel grid = new() { Margin = new Thickness(14, 4, 14, 14) };
    readonly TextBlock empty = new() { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 80, 0, 0), Foreground = CaptureKit.Brush("Tertiary") };
    readonly TextBlock summary = new() { VerticalAlignment = VerticalAlignment.Center, Foreground = CaptureKit.Brush("Secondary"), Margin = new Thickness(12, 0, 0, 0) };
    CaptureKind? filter;

    HistoryWindow()
    {
        Title = "Capture history";
        Width = 900;
        Height = 640;
        MinWidth = 560;
        MinHeight = 400;
        Style = CaptureKit.Style("BaseWindow");
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Icon = new BitmapImage(new Uri("pack://application:,,,/Assets/app.ico"));

        var filters = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var (label, kind) in new (string, CaptureKind?)[] { ("All", null), ("Screenshots", CaptureKind.Screenshot), ("Recordings", CaptureKind.Recording), ("Text", CaptureKind.Text) })
        {
            var button = new RadioButton { Content = label, GroupName = "historyFilter", IsChecked = kind == null, Style = CaptureKit.Style("SegmentPill") };
            button.Checked += (_, _) => { filter = kind; Fill(); };
            filters.Children.Add(button);
        }
        var track = new Border { Style = CaptureKit.Style("SegmentTrack"), Child = filters };
        var open = Ui.Button("Open folder", (_, _) => { Directory.CreateDirectory(CaptureKit.CaptureFolder); Native.Open(CaptureKit.CaptureFolder); }, icon: "folder");
        var clear = Ui.Button("Clear", (_, _) => ClearAll(), icon: "trash");
        clear.Margin = new Thickness(8, 0, 0, 0);
        var bar = new DockPanel { Margin = new Thickness(18, 14, 18, 8) };
        var right = new StackPanel { Orientation = Orientation.Horizontal };
        right.Children.Add(open);
        right.Children.Add(clear);
        DockPanel.SetDock(right, Dock.Right);
        bar.Children.Add(right);
        bar.Children.Add(track);
        bar.Children.Add(summary);
        var body = new Grid();
        body.Children.Add(new ScrollViewer { Content = grid, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        body.Children.Add(empty);
        var root = new DockPanel();
        DockPanel.SetDock(bar, Dock.Top);
        root.Children.Add(bar);
        root.Children.Add(body);
        Content = root;
        KeyDown += (_, e) => { if (e.Key == Key.Escape) Close(); };
        CaptureKit.History.Changed += OnChanged;
        Closed += (_, _) => { CaptureKit.History.Changed -= OnChanged; current = null; };
        Fill();
    }

    void OnChanged() => Dispatcher.BeginInvoke(Fill);

    public static HistoryWindow Open()
    {
        if (current is null)
        {
            CaptureKit.History.Prune(Settings.Current.HistoryDays);
            current = new HistoryWindow();
            current.Show();
        }
        if (current.WindowState == WindowState.Minimized) current.WindowState = WindowState.Normal;
        current.Activate();
        return current;
    }

    void Fill()
    {
        grid.Children.Clear();
        var items = CaptureKit.History.Items.Where(i => filter is null || i.Kind == filter).ToList();
        foreach (var item in items) grid.Children.Add(Tile(item));
        var all = CaptureKit.History.Items;
        summary.Text = all.Count == 0 ? "" : $"{all.Count} item{(all.Count == 1 ? "" : "s")} · kept {Retention(Settings.Current.HistoryDays)}";
        empty.Text = Settings.Current.HistoryDays == 0 ? "History is off. Turn it on in Settings › Capture."
            : filter is null ? "Nothing yet. Screenshots, recordings and copied text show up here." : "Nothing of this kind yet.";
        empty.Visibility = items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    public static string Retention(int days) => days switch
    {
        < 0 => "until you delete them",
        0 => "off",
        1 => "for 1 day",
        7 => "for 1 week",
        14 => "for 2 weeks",
        30 => "for 1 month",
        _ => $"for {days} days",
    };

    FrameworkElement Tile(HistoryItem item)
    {
        var path = CaptureKit.History.PathOf(item);
        FrameworkElement preview;
        if (item.Kind == CaptureKind.Text)
        {
            preview = new Border
            {
                Background = CaptureKit.Brush("Subtle"), Padding = new Thickness(10),
                Child = new TextBlock { Text = item.Preview ?? "", TextWrapping = TextWrapping.Wrap, FontSize = 12, Foreground = CaptureKit.Brush("Ink"), TextTrimming = TextTrimming.CharacterEllipsis },
            };
        }
        else
        {
            var image = new Image { Stretch = Stretch.Uniform };
            RenderOptions.SetBitmapScalingMode(image, BitmapScalingMode.HighQuality);
            _ = LoadThumbnail(item, image);
            var stack = new Grid { Background = BackgroundPanel.Checkerboard(8), Children = { image } };
            if (item.Kind == CaptureKind.Recording)
                stack.Children.Add(new Border
                {
                    Background = new SolidColorBrush(Color.FromArgb(0xD0, 0x20, 0x20, 0x20)), CornerRadius = new CornerRadius(4), Padding = new Thickness(6, 1, 6, 2),
                    HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(6),
                    Child = new TextBlock { Text = CaptureHistory.Duration(item.Seconds), Foreground = Brushes.White, FontSize = 11 },
                });
            preview = stack;
        }
        var box = new Border { Height = 124, CornerRadius = new CornerRadius(6), ClipToBounds = true, Child = preview, Cursor = Cursors.Hand };
        box.MouseLeftButtonDown += (_, e) =>
        {
            if (e.ClickCount == 2) OpenItem(item, path);
            else dragFrom = (e.GetPosition(this), item, path);
        };
        box.MouseMove += (_, e) =>
        {
            if (dragFrom is not { } d || d.Item != item || e.LeftButton != MouseButtonState.Pressed) return;
            var moved = e.GetPosition(this) - d.At;
            if (Math.Abs(moved.X) < 5 && Math.Abs(moved.Y) < 5) return;
            dragFrom = null;
            if (File.Exists(path)) DragDrop.DoDragDrop(box, new DataObject(DataFormats.FileDrop, new[] { path }), DragDropEffects.Copy);
        };
        var title = new TextBlock { Text = CaptureHistory.Describe(item), FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = CaptureKit.Brush("Ink"), TextTrimming = TextTrimming.CharacterEllipsis };
        var when = new TextBlock { Text = CaptureHistory.When(item.Created), FontSize = 11, Foreground = CaptureKit.Brush("Tertiary") };
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(-4, 4, 0, 0) };
        void Action(string glyph, string tip, Action run) => actions.Children.Add(CaptureKit.IconButton(glyph, tip, run, 14));
        Action("copy", item.Kind == CaptureKind.Text ? "Copy the text" : "Copy", () => Copy(item, path));
        if (item.Kind != CaptureKind.Text) Action("edit", item.Kind == CaptureKind.Recording ? "Trim and edit" : "Mark up", () => OpenItem(item, path));
        if (item.Kind == CaptureKind.Screenshot)
        {
            Action("pin", "Pin on top", () => PinWindow.Show(path));
            Action("frame", "Put on a background", () => FrameWindow.Open(path));
        }
        if (item.Kind == CaptureKind.Recording && path.EndsWith(".mp4", StringComparison.OrdinalIgnoreCase)) Action("film", "Open in the video studio", () => StudioWindow.Open(item.SavedPath is { } v && File.Exists(v) ? v : path));
        if (item.Kind != CaptureKind.Text) Action("capture", "Show the thumbnail again", () => QuickAccess.Show(new CaptureItem(item.SavedPath is { } s && File.Exists(s) ? s : path, item.Kind, item.Width, item.Height, item.Seconds, null, item.Id)));
        Action("folder", "Show in folder", () => Native.RevealInExplorer([item.SavedPath is { } saved && File.Exists(saved) ? saved : path]));
        Action("trash", "Delete from history", () => CaptureKit.History.Delete(item.Id));
        var stackPanel = new StackPanel { Width = 196 };
        stackPanel.Children.Add(box);
        stackPanel.Children.Add(new StackPanel { Margin = new Thickness(2, 8, 2, 0), Children = { title, when } });
        stackPanel.Children.Add(actions);
        var card = new Border
        {
            Background = CaptureKit.Brush("Card"), BorderBrush = CaptureKit.Brush("Line"), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10),
            Padding = new Thickness(8), Margin = new Thickness(6), Child = stackPanel, ToolTip = item.SavedPath ?? path,
        };
        return card;
    }

    (Point At, HistoryItem Item, string Path)? dragFrom;

    static async Task LoadThumbnail(HistoryItem item, Image image)
    {
        try
        {
            var thumb = CaptureKit.History.ThumbnailOf(item);
            if (!File.Exists(thumb))
            {
                var source = CaptureKit.History.PathOf(item);
                if (item.Kind == CaptureKind.Recording) await MakeVideoThumbnail(source, thumb);
                else await Task.Run(() =>
                {
                    using var magick = ImageConverter.LoadFirst(source);
                    magick.Thumbnail(392, 248);
                    Directory.CreateDirectory(Path.GetDirectoryName(thumb)!);
                    magick.Write(thumb, ImageMagick.MagickFormat.Png);
                });
            }
            if (File.Exists(thumb)) image.Source = CaptureKit.Load(thumb);
        }
        catch { }
    }

    static async Task MakeVideoThumbnail(string video, string thumb)
    {
        var frame = await VideoEditEngine.PreviewFrame(video, 0.5, 392, default);
        if (frame is null) return;
        Directory.CreateDirectory(Path.GetDirectoryName(thumb)!);
        await File.WriteAllBytesAsync(thumb, frame);
    }

    /// A still for a recording's thumbnail card (made now if needed).
    public static string? ThumbnailFor(CaptureItem item)
    {
        try
        {
            var entry = item.HistoryId is { } id ? CaptureKit.History.Items.FirstOrDefault(i => i.Id == id) : null;
            var thumb = entry is not null ? CaptureKit.History.ThumbnailOf(entry) : Path.Combine(OutputPaths.TempDir(), "thumb.jpg");
            if (!File.Exists(thumb))
            {
                var frame = Task.Run(() => VideoEditEngine.PreviewFrame(item.Path, 0.5, 496, default)).GetAwaiter().GetResult();
                if (frame is null) return null;
                Directory.CreateDirectory(Path.GetDirectoryName(thumb)!);
                File.WriteAllBytes(thumb, frame);
            }
            return thumb;
        }
        catch { return null; }
    }

    static void Copy(HistoryItem item, string path)
    {
        try
        {
            switch (item.Kind)
            {
                case CaptureKind.Text: CaptureKit.CopyText(File.ReadAllText(path)); break;
                case CaptureKind.Screenshot: CaptureKit.CopyImage(path); break;
                default: CaptureKit.CopyFile(path); break;
            }
            Toast.Show("Copied", null);
        }
        catch (Exception e) { Toast.Show("Couldn't copy", e.Message, ok: false); }
    }

    static void OpenItem(HistoryItem item, string path)
    {
        if (!File.Exists(path)) return;
        if (item.Kind == CaptureKind.Text) { Native.Open(path); return; }
        Editors.Open(new Job(path), null);
    }

    void ClearAll()
    {
        if (CaptureKit.History.Items.Count == 0) return;
        if (MessageBox.Show(this, "Delete everything in the capture history? Copies saved in your capture folder stay where they are.", "Clear history",
                MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
        CaptureKit.History.Clear();
    }
}
