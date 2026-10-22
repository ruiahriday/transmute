using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using Microsoft.Win32;
using Transmute.Desktop;

namespace Transmute.App;

/// The floating thumbnail after a capture: copy, save, mark up, pin, read text, frame or share
/// it, or drag it straight into another app. Several stack up; each tucks itself away after a
/// while unless the pointer is on it.
sealed class QuickAccess : Window
{
    static readonly List<QuickAccess> open = [];
    static CaptureItem? lastClosed;
    static bool hiddenAll;

    public static IReadOnlyList<QuickAccess> Open => open;
    public static bool CanRestore => lastClosed is not null && File.Exists(lastClosed.Path);
    public static bool AllHidden => hiddenAll;

    public CaptureItem Item { get; }
    readonly DispatcherTimer timer = new();
    readonly MonitorInfo monitor;
    readonly Button closeButton;
    Point? pressAt;
    bool closing;

    QuickAccess(CaptureItem item)
    {
        Item = item;
        CaptureKit.Floating(this);
        ShowActivated = false;
        Title = "Spinform capture";
        var prefs = Settings.Current;
        monitor = item.Where is { } w ? Screens.MonitorAt(w.X + w.Width / 2, w.Y + w.Height / 2) : Screens.MonitorUnderCursor();

        // The thumbnail, which can be dragged into other apps as a file.
        var thumbnail = new Image { Stretch = Stretch.Uniform, MaxWidth = 248, MaxHeight = 156, Cursor = Cursors.Hand, ToolTip = "Drag into any app, or double-click to mark up" };
        RenderOptions.SetBitmapScalingMode(thumbnail, BitmapScalingMode.HighQuality);
        try
        {
            if (item.Kind == CaptureKind.Recording)
            {
                var thumb = HistoryWindow.ThumbnailFor(item);
                if (thumb is not null) thumbnail.Source = CaptureKit.Load(thumb, 496);
            }
            else thumbnail.Source = CaptureKit.Load(item.Path, 496);
        }
        catch { }
        thumbnail.MouseLeftButtonDown += (_, e) =>
        {
            if (e.ClickCount == 2) { MarkUp(); return; }
            pressAt = e.GetPosition(this);
        };
        thumbnail.MouseMove += (_, e) =>
        {
            if (pressAt is not { } start || e.LeftButton != MouseButtonState.Pressed) return;
            var moved = e.GetPosition(this) - start;
            if (Math.Abs(moved.X) < 5 && Math.Abs(moved.Y) < 5) return;
            pressAt = null;
            timer.Stop();
            var data = new DataObject(DataFormats.FileDrop, new[] { item.Path });
            if (item.Kind == CaptureKind.Screenshot) try { data.SetImage(CaptureKit.Load(item.Path)); } catch { }
            DragDrop.DoDragDrop(thumbnail, data, DragDropEffects.Copy);
            StartTimer();
        };
        var picture = new Border { CornerRadius = new CornerRadius(6), ClipToBounds = true, Background = BackgroundPanel.Checkerboard(8), Child = thumbnail, HorizontalAlignment = HorizontalAlignment.Center, MinWidth = 120, MinHeight = 60 };
        var badge = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(0xD0, 0x16, 0x15, 0x1F)), CornerRadius = new CornerRadius(4), Padding = new Thickness(6, 1, 6, 2),
            HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(6),
            Child = new TextBlock { Text = CaptureHistory.Duration(item.Seconds), Foreground = Brushes.White, FontSize = 11 },
            Visibility = item.Kind == CaptureKind.Recording ? Visibility.Visible : Visibility.Collapsed,
        };
        closeButton = CaptureKit.IconButton("close", "Close", () => Dismiss(0), 10, Brushes.White);
        closeButton.Background = new SolidColorBrush(Color.FromArgb(0xC0, 0x16, 0x15, 0x1F));
        closeButton.Padding = new Thickness(5);
        closeButton.HorizontalAlignment = HorizontalAlignment.Right;
        closeButton.VerticalAlignment = VerticalAlignment.Top;
        closeButton.Margin = new Thickness(5);
        closeButton.Visibility = Visibility.Hidden;
        var top = new Grid { Children = { picture, badge, closeButton } };

        var actions = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 8, 0, 0) };
        void Action(string glyph, string tip, Action run) => actions.Children.Add(CaptureKit.IconButton(glyph, tip, run, 16));
        Action("copy", item.Kind == CaptureKind.Recording ? "Copy the file" : "Copy", Copy);
        Action("save", "Save as…", SaveAs);
        Action("edit", item.Kind == CaptureKind.Recording ? "Trim and edit" : "Mark up", MarkUp);
        if (item.Kind == CaptureKind.Screenshot)
        {
            Action("pin", "Pin on top of everything", () => { PinWindow.Show(item.Path, item.Where); Dismiss(0); });
            Action("text", "Copy the text in it", () => _ = ReadText());
            Action("frame", "Put on a background", () => FrameWindow.Open(item.Path));
        }
        if (item.Kind == CaptureKind.Recording && item.Path.EndsWith(".mp4", StringComparison.OrdinalIgnoreCase))
            Action("film", "Open in the video studio: zooms, background, shapes", () => { StudioWindow.Open(item.Path); Dismiss(0); });
        if (ShareSheet.IsAvailable) Action("share", "Share…", () => { try { ShareSheet.Show(CaptureKit.Handle(this), item.Path); } catch (Exception e) { Toast.Show("Couldn't open Share", e.Message, ok: false); } });
        Action("folder", "Show in folder", () => Native.RevealInExplorer([item.Path]));

        var info = new TextBlock
        {
            Text = Describe(item), FontSize = 11, Foreground = CaptureKit.Brush("Tertiary"), HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 2, 0, 0),
            ToolTip = "Flick the card sideways to put it away",
        };
        var stack = new StackPanel { Width = 260 };
        stack.Children.Add(top);
        stack.Children.Add(actions);
        stack.Children.Add(info);
        var card = CaptureKit.Card(stack, new Thickness(6, 6, 6, 6));
        card.LayoutTransform = new ScaleTransform(prefs.OverlaySize, prefs.OverlaySize);
        Content = card;
        CaptureKit.MakeToolWindow(this);

        MouseEnter += (_, _) => { timer.Stop(); closeButton.Visibility = Visibility.Visible; };
        MouseLeave += (_, _) => { StartTimer(); closeButton.Visibility = Visibility.Hidden; };
        // Flick sideways to dismiss.
        PreviewMouseLeftButtonDown += (_, e) => { if (e.OriginalSource is not Image) flickFrom = PointToScreen(e.GetPosition(this)); };
        PreviewMouseMove += (_, e) =>
        {
            if (flickFrom is not { } from || e.LeftButton != MouseButtonState.Pressed) return;
            var now = PointToScreen(e.GetPosition(this));
            if (Math.Abs(now.X - from.X) > 70 * monitor.Scale && Math.Abs(now.Y - from.Y) < 60 * monitor.Scale) { flickFrom = null; Dismiss(now.X > from.X ? 1 : -1); }
        };
        PreviewMouseLeftButtonUp += (_, _) => flickFrom = null;
        timer.Tick += (_, _) => Dismiss(0);
    }

    Point? flickFrom;

    static string Describe(CaptureItem item)
    {
        var size = OutputPaths.FormatSize(OutputPaths.FileSize(item.Path));
        var ext = Path.GetExtension(item.Path).TrimStart('.').ToUpperInvariant();
        return item.Kind == CaptureKind.Recording
            ? $"{ext} · {item.Width} × {item.Height} · {CaptureHistory.Duration(item.Seconds)} · {size}"
            : $"{ext} · {item.Width} × {item.Height} · {size}";
    }

    void StartTimer()
    {
        var seconds = Settings.Current.OverlaySeconds;
        if (seconds <= 0 || closing) return;
        timer.Interval = TimeSpan.FromSeconds(seconds);
        timer.Start();
    }

    public static QuickAccess Show(CaptureItem item)
    {
        while (open.Count >= 4) open[0].Dismiss(0, animate: false);
        var card = new QuickAccess(item);
        open.Add(card);
        if (!hiddenAll)
        {
            card.Show();
            Arrange();
            Theme.To(card, OpacityProperty, 1, 0.25, from: 0);
        }
        card.StartTimer();
        return card;
    }

    /// Stacks the cards from the corner upwards, newest nearest the corner.
    static void Arrange()
    {
        var corner = Settings.Current.OverlayCorner ?? "right";
        var right = corner.Contains("right");
        var atTop = corner.StartsWith("top");
        var offsets = new Dictionary<MonitorInfo, int>();
        foreach (var card in Enumerable.Reverse(open).Where(c => c.IsVisible))
        {
            var m = card.monitor;
            var lift = offsets.GetValueOrDefault(m);
            var margin = (int)Math.Round(4 * m.Scale);
            card.UpdateLayout();
            CaptureKit.Place(card, m, (w, h) =>
            {
                var x = right ? m.WorkArea.Right - w - margin : m.WorkArea.X + margin;
                var y = atTop ? m.WorkArea.Y + margin + lift : m.WorkArea.Bottom - h - margin - lift;
                return (x, y);
            });
            offsets[m] = lift + CaptureKit.PhysicalSize(card).Height - (int)Math.Round(14 * m.Scale);
        }
    }

    public void Dismiss(int direction, bool animate = true)
    {
        if (closing) return;
        closing = true;
        timer.Stop();
        lastClosed = Item;
        open.Remove(this);
        if (!animate || !IsVisible) { Close(); Arrange(); return; }
        var shift = new TranslateTransform();
        ((FrameworkElement)Content).RenderTransform = shift;
        var to = direction == 0 ? (Settings.Current.OverlayCorner?.Contains("right") != false ? 1 : -1) * 300 : direction * 300;
        var slide = new DoubleAnimation(to, TimeSpan.FromSeconds(0.25)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseIn } };
        slide.Completed += (_, _) => { Close(); Arrange(); };
        shift.BeginAnimation(TranslateTransform.XProperty, slide);
        BeginAnimation(OpacityProperty, new DoubleAnimation(0, TimeSpan.FromSeconds(0.25)));
    }

    /// Brings back the card closed last.
    public static void Restore()
    {
        if (lastClosed is { } item && File.Exists(item.Path)) { lastClosed = null; Show(item); }
    }

    /// Hides every card for now (or shows them again).
    public static void ToggleHidden()
    {
        hiddenAll = !hiddenAll;
        foreach (var card in open)
        {
            if (hiddenAll) { card.timer.Stop(); card.Hide(); }
            else { card.Show(); card.StartTimer(); }
        }
        if (!hiddenAll) Arrange();
    }

    void Copy()
    {
        try
        {
            if (Item.Kind == CaptureKind.Screenshot) CaptureKit.CopyImage(Item.Path); else CaptureKit.CopyFile(Item.Path);
            Toast.Show("Copied", Item.Kind == CaptureKind.Screenshot ? "Paste it anywhere." : "Paste the file into a folder, chat or email.");
        }
        catch (Exception e) { Toast.Show("Couldn't copy", e.Message, ok: false); }
    }

    void SaveAs()
    {
        timer.Stop();
        var ext = Path.GetExtension(Item.Path);
        var dialog = new SaveFileDialog
        {
            FileName = Path.GetFileName(Item.Path),
            InitialDirectory = Item.Kind == CaptureKind.Recording ? CaptureKit.RecordingFolder : CaptureKit.CaptureFolder,
            Filter = $"{ext.TrimStart('.').ToUpperInvariant()} file|*{ext}|All files|*.*",
            Title = "Save capture as",
        };
        if (dialog.ShowDialog() == true)
        {
            try
            {
                File.Copy(Item.Path, dialog.FileName, true);
                Toast.Show("Saved", Path.GetFileName(dialog.FileName), action: ("Show in folder", () => Native.RevealInExplorer([dialog.FileName])));
            }
            catch (Exception e) { Toast.Show("Couldn't save", e.Message, ok: false); }
        }
        StartTimer();
    }

    void MarkUp()
    {
        Dismiss(0);
        Editors.Open(new Job(Item.Path), null);
    }

    async Task ReadText()
    {
        try
        {
            using var magick = ImageConverter.LoadFirst(Item.Path);
            await Capture.Recognize(BgraImage.FromMagick(magick));
        }
        catch (Exception e) { Toast.Show("Couldn't read the text", e.Message, ok: false); }
    }
}
