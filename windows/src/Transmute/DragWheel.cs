using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Effects;
using Ellipse = System.Windows.Shapes.Ellipse;

using System.Windows.Threading;
using Microsoft.Win32;

namespace Transmute.App;

/// Watches the mouse while files are dragged anywhere (File Explorer, the desktop, a browser…):
///   holding a key opens the drag wheel (Shift: formats, Ctrl: tools, Alt: actions; changeable
///   in Settings), and shaking the files or dragging them to the middle of the top edge of the
///   screen opens the floating files shelf.
/// It polls the mouse and keyboard, so it needs no special permission and can't slow typing.
sealed class DragWatcher
{
    readonly DispatcherTimer timer = new(DispatcherPriority.Input) { Interval = TimeSpan.FromMilliseconds(30) };
    bool wasDown, isDrag, shelfOpened;
    Native.POINT start;
    WheelKind? shown;
    ShakeDetector shake = new();
    readonly Stopwatch clock = Stopwatch.StartNew();

    public void Start()
    {
        timer.Tick += (_, _) => Tick();
        timer.Start();
    }

    public void Stop() => timer.Stop();

    static int LeftButton => Native.GetSystemMetrics(23 /* SM_SWAPBUTTON */) != 0 ? 0x02 : Native.VK_LBUTTON;

    void Tick()
    {
        var down = Native.KeyDown(LeftButton);
        if (!down)
        {
            if (wasDown && shown is not null) WheelWindow.Shared.HideSoon();
            wasDown = isDrag = shelfOpened = false;
            shown = null;
            shake = new ShakeDetector();
            return;
        }
        // Bubbles being rearranged in Settings aren't files.
        if (WheelEditorWindow.IsDragging) return;
        Native.GetCursorPos(out var point);
        if (!wasDown)
        {
            wasDown = true;
            start = point;
            return;
        }
        if (!isDrag)
        {
            var far = Math.Abs(point.X - start.X) > Native.GetSystemMetrics(Native.SM_CXDRAG)
                || Math.Abs(point.Y - start.Y) > Native.GetSystemMetrics(Native.SM_CYDRAG);
            // Our own windows (the shelf, the main window) start drags too; those count as well.
            if (!far || !Native.OleDragInProgress()) return;
            isDrag = true;
        }

        var prefs = Settings.Current;
        if (!shelfOpened)
        {
            if (prefs.TopEdgeToShelf && AtTopMiddle(point, out var below))
            {
                shelfOpened = true;
                Shelf.Shared.Show(below);
            }
            else if (prefs.ShakeToShelf && shake.Add(point.X, clock.Elapsed.TotalSeconds))
            {
                shelfOpened = true;
                Shelf.Shared.Show(new Point(point.X, point.Y + 40));
            }
        }

        if (!prefs.WheelEnabled) return;
        // Actions and tools win over formats when several keys are held.
        WheelKind? wanted = null;
        foreach (var kind in new[] { WheelKind.Actions, WheelKind.Tools, WheelKind.Convert })
            if (prefs.KeyFor(kind) is var key && key != WheelKey.Off && key.IsDown()) { wanted = kind; break; }
        // Once open, the wheel stays until the drop; pressing another key switches wheels.
        if (wanted is null || wanted == shown) return;
        WheelWindow.Shared.ShowKind(wanted.Value, shown is null ? new Point(point.X, point.Y) : null);
        shown = wanted;
    }

    /// The middle of the top edge of the screen the pointer is on.
    static bool AtTopMiddle(Native.POINT point, out Point below)
    {
        below = default;
        var screen = System.Windows.Forms.Screen.FromPoint(new System.Drawing.Point(point.X, point.Y)).Bounds;
        var middle = screen.Left + screen.Width / 2;
        if (point.Y > screen.Top + 3 || Math.Abs(point.X - middle) > 160) return false;
        below = new Point(middle, screen.Top + 8);
        return true;
    }
}

/// Spots a quick left-right shake in a stream of pointer positions.
sealed class ShakeDetector
{
    const double Distance = 40;
    const int TurnsNeeded = 4;
    const double Window = 0.9;

    double? turnX;
    double heading;
    readonly List<double> turns = [];

    public bool Add(double x, double time)
    {
        if (turnX is not { } start) { turnX = x; return false; }
        var moved = x - start;
        if (heading == 0)
        {
            if (Math.Abs(moved) >= Distance) { heading = Math.Sign(moved); turnX = x; }
        }
        else if (moved * heading > 0) turnX = x; // still going the same way: follow the furthest point
        else if (Math.Abs(moved) >= Distance)
        {
            heading = -heading;
            turnX = x;
            turns.Add(time);
        }
        turns.RemoveAll(t => time - t > Window);
        return turns.Count >= TurnsNeeded;
    }
}

enum FileAction { Float, Copy, CopyPath, Terminal, Move, ShowInFolder }

/// Glyph is the name of one of Spinform's icons (Icons.cs).
sealed record WheelItem(string Label, string Glyph, JobOperation? Operation = null, BatchTool? Batch = null, FileAction? Action = null, bool Edit = false);

static class WheelItems
{
    /// The wheel's positions clockwise from the top, as set in Settings; null is an empty position.
    public static List<WheelItem?> For(WheelKind kind, IReadOnlyList<string> paths) =>
        WheelLayout.Resolve(kind, paths.Select(Kinds.Of).ToList(), Settings.Current.WheelLayouts).Select(Item).ToList();

    public static WheelItem? Item(string id)
    {
        if (WheelLayout.Format(id) is { } format) return new(format.Label(), Glyph(format), new JobOperation.Convert(format));
        return id switch
        {
            "tool:edit" => new("Edit", "edit", Edit: true),
            "tool:half" => new("Half size", "compress", new JobOperation.Compress(new CompressionTarget.Percent(0.5))),
            "tool:quarter" => new("Quarter", "compress", new JobOperation.Compress(new CompressionTarget.Percent(0.25))),
            "tool:clean" => new("Clean", "eraser", new JobOperation.StripMetadata()),
            "tool:split" => new("Split", "split", new JobOperation.SplitPdf()),
            "tool:merge" => new("Merge", "merge", Batch: new BatchTool.MergePdfs()),
            "tool:topdf" => new("To PDF", "document", Batch: new BatchTool.ImagesToPdf()),
            "tool:qr" => new("QR", "qr", new JobOperation.ReadQr()),
            "tool:zip" => new("Zip", "zip", Batch: new BatchTool.Archive(OutputFormat.Zip)),
            "tool:nobg" => new("No BG", "cutout", new JobOperation.Background(new BackgroundEdit { Mode = BackgroundMode.Remove })),
            "action:float" => new("Float", "pin", Action: FileAction.Float),
            "action:copy" => new("Copy", "copy", Action: FileAction.Copy),
            "action:copypath" => new("Copy Path", "link", Action: FileAction.CopyPath),
            "action:terminal" => new("Terminal", "terminal", Action: FileAction.Terminal),
            "action:move" => new("Move…", "move", Action: FileAction.Move),
            "action:show" => new("Show", "search", Action: FileAction.ShowInFolder),
            _ => null,
        };
    }

    /// A longer name for the list in Settings: "Convert to PDF", "Compress to half size"…
    public static string Describe(string id)
    {
        if (id == WheelLayout.Gap) return "Empty space";
        if (WheelLayout.Format(id) is { } format) return format == OutputFormat.Extract ? "Extract" : $"Convert to {format.Label()}";
        return id switch
        {
            "tool:edit" => "Edit (opens the photo, video or audio editor)",
            "tool:half" => "Compress to half size",
            "tool:quarter" => "Compress to a quarter",
            "tool:clean" => "Remove metadata",
            "tool:split" => "Split into pages",
            "tool:merge" => "Merge PDFs (2 or more)",
            "tool:topdf" => "Images to one PDF",
            "tool:qr" => "Read QR code",
            "tool:zip" => "Zip",
            "tool:nobg" => "Remove background (PNG with a see-through background)",
            "action:float" => "Float (floating files)",
            "action:copy" => "Copy",
            "action:copypath" => "Copy path",
            "action:terminal" => "Open Terminal here",
            "action:move" => "Move to a folder",
            "action:show" => "Show in File Explorer",
            _ => id,
        };
    }

    public static string Glyph(OutputFormat format) => format switch
    {
        OutputFormat.Mp3 or OutputFormat.M4a or OutputFormat.Wav or OutputFormat.Flac or OutputFormat.Ogg or OutputFormat.Opus
            or OutputFormat.Aiff or OutputFormat.Wma => "audio",
        OutputFormat.Mp4 or OutputFormat.Mov or OutputFormat.Mkv or OutputFormat.Avi or OutputFormat.Wmv or OutputFormat.Webm => "video",
        OutputFormat.Zip or OutputFormat.Tgz or OutputFormat.Extract => "zip",
        OutputFormat.Jpeg or OutputFormat.Png or OutputFormat.Webp or OutputFormat.Heic or OutputFormat.Avif or OutputFormat.Tiff
            or OutputFormat.Bmp or OutputFormat.Gif or OutputFormat.Ico or OutputFormat.Svg => "image",
        _ => "document",
    };

    public static void Run(WheelItem item, IReadOnlyList<string> paths)
    {
        var queue = JobQueue.Shared;
        var reveal = Settings.Current.RevealWhenDone;
        if (item.Operation is { } operation)
        {
            var jobs = queue.Add(paths);
            Hud.Shared.Track(jobs);
            _ = queue.Start(jobs.Select(j => (j, operation)).ToList(), reveal && operation is not JobOperation.ReadQr);
        }
        else if (item.Batch is { } tool)
        {
            var jobs = queue.Add(paths);
            Hud.Shared.Track(jobs);
            _ = queue.RunBatch(tool, jobs, reveal);
        }
        else if (item.Action is { } action) Perform(action, paths);
        else if (item.Edit && paths.FirstOrDefault(p => Editors.CanEdit(Kinds.Of(p))) is { } path)
        {
            // Straight into the editor, without opening Spinform and adding the file first.
            var job = queue.Add([path]).FirstOrDefault();
            if (job is not null) Editors.Open(job, null);
        }
    }

    static void Perform(FileAction action, IReadOnlyList<string> paths)
    {
        switch (action)
        {
            case FileAction.Float:
                Shelf.Shared.Add(paths);
                break;
            case FileAction.Copy:
                var list = new System.Collections.Specialized.StringCollection();
                list.AddRange(paths.ToArray());
                try { Clipboard.SetFileDropList(list); } catch { }
                break;
            case FileAction.CopyPath:
                try { Clipboard.SetText(string.Join(Environment.NewLine, paths.Select(p => p.Contains(' ') ? $"\"{p}\"" : p))); } catch { }
                break;
            case FileAction.Terminal:
                var folder = Directory.Exists(paths[0]) ? paths[0] : Path.GetDirectoryName(paths[0])!;
                OpenTerminal(folder);
                break;
            case FileAction.ShowInFolder:
                Native.RevealInExplorer(paths);
                break;
            case FileAction.Move:
                var dialog = new OpenFolderDialog { Title = "Move to" };
                if (dialog.ShowDialog() != true) return;
                var moved = new List<string>();
                foreach (var path in paths)
                {
                    try
                    {
                        var name = Path.GetFileName(path.TrimEnd('\\'));
                        var target = Directory.Exists(path)
                            ? OutputPaths.Unique(dialog.FolderName, name, "").TrimEnd('.')
                            : OutputPaths.Unique(dialog.FolderName, Path.GetFileNameWithoutExtension(name), Path.GetExtension(name).TrimStart('.'));
                        if (Directory.Exists(path)) Directory.Move(path, target); else File.Move(path, target);
                        moved.Add(target);
                    }
                    catch (Exception e)
                    {
                        MessageBox.Show($"Couldn't move {Path.GetFileName(path)}: {e.Message}", "Spinform", MessageBoxButton.OK, MessageBoxImage.Warning);
                    }
                }
                if (moved.Count > 0) Native.RevealInExplorer(moved);
                break;
        }
    }

    static void OpenTerminal(string folder)
    {
        // Windows Terminal when it's there, otherwise PowerShell.
        try
        {
            Process.Start(new ProcessStartInfo("wt.exe") { ArgumentList = { "-d", folder }, UseShellExecute = true });
        }
        catch
        {
            try { Process.Start(new ProcessStartInfo("powershell.exe") { WorkingDirectory = folder, UseShellExecute = true }); } catch { }
        }
    }
}

/// The ring of bubbles shown under the pointer during a drag. Drop the files on a bubble to run it.
sealed class WheelWindow : Window
{
    public static WheelWindow Shared => shared ??= new WheelWindow();
    static WheelWindow? shared;

    const double Size = 380, Radius = 132, Bubble = 70;

    readonly Canvas canvas = new() { Width = Size, Height = Size };
    WheelKind kind;
    string[]? paths;
    readonly DispatcherTimer hideTimer = new() { Interval = TimeSpan.FromMilliseconds(350) };

    WheelWindow()
    {
        Width = Height = Size;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        ResizeMode = ResizeMode.NoResize;
        AllowDrop = true;
        FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI");
        UseLayoutRounding = true;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);
        Content = canvas;
        DragEnter += OnDragOver;
        DragOver += OnDragOver;
        Drop += (_, e) => { e.Handled = true; Hide(); };
        hideTimer.Tick += (_, _) => { hideTimer.Stop(); if (!Native.KeyDown(0x01) && !Native.KeyDown(0x02)) Hide(); };
        SourceInitialized += (_, _) =>
        {
            var handle = new WindowInteropHelper(this).Handle;
            Native.SetWindowLong(handle, Native.GWL_EXSTYLE, Native.GetWindowLong(handle, Native.GWL_EXSTYLE) | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOOLWINDOW);
        };
    }

    /// Opens the wheel; with a point (screen pixels) it's centred there.
    public void ShowKind(WheelKind kind, Point? at)
    {
        hideTimer.Stop();
        this.kind = kind;
        if (at is { } point)
        {
            paths = null;
            var dpi = VisualTreeHelper.GetDpi(Application.Current.MainWindow ?? this);
            var source = PresentationSource.FromVisual(this);
            var scaleX = source?.CompositionTarget?.TransformFromDevice.M11 ?? 1 / dpi.DpiScaleX;
            var scaleY = source?.CompositionTarget?.TransformFromDevice.M22 ?? 1 / dpi.DpiScaleY;
            Left = point.X * scaleX - Size / 2;
            Top = point.Y * scaleY - Size / 2;
        }
        Build();
        Show();
    }

    /// Shows the wheel for these files in the middle of the screen (for the smoke test).
    public void Preview(WheelKind kind, string[] files)
    {
        this.kind = kind;
        paths = files;
        var area = SystemParameters.WorkArea;
        Left = area.Left + (area.Width - Size) / 2;
        Top = area.Top + (area.Height - Size) / 2;
        Build();
        Show();
    }

    public void HideSoon()
    {
        hideTimer.Stop();
        hideTimer.Start();
    }

    void OnDragOver(object sender, DragEventArgs e)
    {
        if (paths is null && e.Data.GetData(DataFormats.FileDrop) is string[] dropped && dropped.Length > 0)
        {
            paths = dropped;
            Build();
        }
        e.Effects = DragDropEffects.None;
        e.Handled = true;
    }

    void Build()
    {
        canvas.Children.Clear();
        var ringSize = (Radius + Bubble / 2 + 12) * 2;
        var ring = new Ellipse
        {
            Width = ringSize,
            Height = ringSize,
            // Nearly clear but not fully: fully transparent pixels don't receive the drag.
            Fill = new SolidColorBrush(Color.FromArgb(0xF4, 0xF8, 0xF7, 0xFC)),
            Stroke = Theme.Brand,
            StrokeThickness = 1.5,
            Effect = new DropShadowEffect { BlurRadius = 18, ShadowDepth = 3, Direction = 270, Opacity = 0.22, Color = Color.FromRgb(0x15, 0x13, 0x2B) },
            RenderTransformOrigin = new Point(0.5, 0.5),
            RenderTransform = new ScaleTransform(0.7, 0.7),
            Opacity = 0,
        };
        var ringScale = (ScaleTransform)ring.RenderTransform;
        Theme.To(ringScale, ScaleTransform.ScaleXProperty, 1, 0.3, Theme.Spring);
        Theme.To(ringScale, ScaleTransform.ScaleYProperty, 1, 0.3, Theme.Spring);
        Theme.To(ring, OpacityProperty, 1, 0.2);
        Canvas.SetLeft(ring, (Size - ringSize) / 2);
        Canvas.SetTop(ring, (Size - ringSize) / 2);
        canvas.Children.Add(ring);

        var title = new TextBlock { Text = kind.Title(), FontSize = 15, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, Foreground = Ui.Brush("Ink") };
        var subtitle = new TextBlock { FontSize = 11, Foreground = Ui.Brush("Secondary"), HorizontalAlignment = HorizontalAlignment.Center };
        var items = paths is null ? [] : WheelItems.For(kind, paths);
        subtitle.Text = paths is null ? "Move onto the wheel" : items.Count == 0 ? "Nothing for these files" : "Drop on a bubble";
        var caption = new StackPanel { Width = 140 };
        caption.Children.Add(title);
        caption.Children.Add(subtitle);
        caption.Measure(new Size(140, 100));
        Canvas.SetLeft(caption, (Size - 140) / 2);
        Canvas.SetTop(caption, (Size - caption.DesiredSize.Height) / 2);
        canvas.Children.Add(caption);

        var size = BubbleSize(items.Count, Radius, Bubble);
        for (var i = 0; i < items.Count; i++)
        {
            if (items[i] is not { } item) continue;
            var bubble = MakeBubble(item, size);
            var (x, y) = Position(i, items.Count, Radius);
            Canvas.SetLeft(bubble, Size / 2 + x - size / 2);
            Canvas.SetTop(bubble, Size / 2 + y - size / 2);
            canvas.Children.Add(bubble);
            // Bubbles spring out from the middle one after another.
            var pop = (ScaleTransform)bubble.RenderTransform;
            var delay = i * 0.025;
            bubble.Opacity = 0;
            Theme.To(bubble, OpacityProperty, 1, 0.2, delay: delay);
            Theme.To(pop, ScaleTransform.ScaleXProperty, 1, 0.38, Theme.Spring, delay, from: 0.3);
            Theme.To(pop, ScaleTransform.ScaleYProperty, 1, 0.38, Theme.Spring, delay, from: 0.3);
        }
    }

    /// Where position `index` of `count` sits, from the centre: the first at the top, then clockwise.
    public static (double X, double Y) Position(int index, int count, double radius)
    {
        var angle = (double)index / Math.Max(count, 1) * 2 * Math.PI - Math.PI / 2;
        return (Math.Cos(angle) * radius, Math.Sin(angle) * radius);
    }

    /// Bubbles shrink a little when there are so many that they would touch.
    public static double BubbleSize(int count, double radius, double largest) =>
        Math.Min(largest, 2 * Math.PI * radius / Math.Max(count, 1) - 4);

    Border MakeBubble(WheelItem item, double diameter)
    {
        var ink = Ui.Brush("Ink");
        var glyphPath = new System.Windows.Shapes.Path { Data = Icons.Geometry(item.Glyph), Stroke = Ui.Brush("Accent"), StrokeThickness = 1.7, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round };
        var glyph = new Viewbox { Width = 20, Height = 20, Child = new Canvas { Width = 24, Height = 24, Children = { glyphPath } }, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 2) };
        var label = new TextBlock { Text = item.Label, FontSize = 10.5, FontWeight = FontWeights.SemiBold, Foreground = ink, HorizontalAlignment = HorizontalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = diameter - 6 };
        var stack = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        stack.Children.Add(glyph);
        stack.Children.Add(label);
        var bubble = new Border
        {
            Width = diameter,
            Height = diameter,
            CornerRadius = new CornerRadius(diameter / 2),
            Background = Brushes.White,
            BorderBrush = Ui.Brush("LineStrong"),
            BorderThickness = new Thickness(1),
            Child = stack,
            AllowDrop = true,
            SnapsToDevicePixels = true,
            RenderTransformOrigin = new Point(0.5, 0.5),
            RenderTransform = new ScaleTransform(1, 1),
        };
        void Highlight(bool on)
        {
            bubble.Background = on ? Theme.Brand : Brushes.White;
            bubble.BorderBrush = on ? Brushes.Transparent : Ui.Brush("LineStrong");
            label.Foreground = on ? Brushes.White : ink;
            glyphPath.Stroke = on ? Brushes.White : Ui.Brush("Accent");
            var scale = (ScaleTransform)bubble.RenderTransform;
            Theme.To(scale, ScaleTransform.ScaleXProperty, on ? 1.18 : 1, 0.2, Theme.Spring);
            Theme.To(scale, ScaleTransform.ScaleYProperty, on ? 1.18 : 1, 0.2, Theme.Spring);
        }
        bubble.DragEnter += (_, e) => { Highlight(true); e.Effects = DragDropEffects.Copy; e.Handled = true; };
        bubble.DragOver += (_, e) => { e.Effects = DragDropEffects.Copy; e.Handled = true; };
        bubble.DragLeave += (_, _) => Highlight(false);
        bubble.Drop += (_, e) =>
        {
            e.Handled = true;
            var dropped = e.Data.GetData(DataFormats.FileDrop) as string[] ?? paths ?? [];
            Hide();
            Highlight(false);
            if (dropped.Length > 0)
                Dispatcher.BeginInvoke(() => WheelItems.Run(item, dropped)); // after the drag has finished
        };
        return bubble;
    }
}

/// A small progress card in the bottom-right corner for drops on the wheel.
sealed class Hud : Window
{
    public static Hud Shared => shared ??= new Hud();
    static Hud? shared;

    readonly ContentControl icon = new() { Width = 34, VerticalAlignment = VerticalAlignment.Center, Focusable = false };
    readonly TextBlock title = new() { FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
    readonly TextBox detail = new() { FontSize = 12, IsReadOnly = true, BorderThickness = new Thickness(0), Background = Brushes.Transparent, TextWrapping = TextWrapping.Wrap, MaxHeight = 34, Padding = new Thickness(0), MinHeight = 0 };
    readonly ProgressBar bar = new() { Maximum = 1, Margin = new Thickness(0, 6, 0, 0) };
    readonly DispatcherTimer poll = new() { Interval = TimeSpan.FromMilliseconds(200) };
    readonly DispatcherTimer hide = new() { Interval = TimeSpan.FromSeconds(3.5) };
    List<Job> jobs = [];

    Hud()
    {
        Width = 340;
        Height = 92;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        ResizeMode = ResizeMode.NoResize;
        FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI");
        UseLayoutRounding = true;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(title);
        text.Children.Add(detail);
        text.Children.Add(bar);
        var row = new DockPanel();
        DockPanel.SetDock(icon, Dock.Left);
        row.Children.Add(icon);
        row.Children.Add(text);
        // The shadow is its own layer under the card, so the card's text stays crisp.
        var shadow = new Border
        {
            Background = Brushes.White,
            CornerRadius = new CornerRadius(10),
            Margin = new Thickness(8),
            Effect = new DropShadowEffect { BlurRadius = 16, ShadowDepth = 3, Direction = 270, Opacity = 0.18 },
        };
        var card = new Border
        {
            Background = Brushes.White,
            CornerRadius = new CornerRadius(10),
            BorderBrush = Ui.Brush("Line"),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(14, 10, 14, 10),
            Margin = new Thickness(8),
            Child = row,
            SnapsToDevicePixels = true,
        };
        UseLayoutRounding = true;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);
        title.Foreground = Ui.Brush("Ink");
        detail.Foreground = Ui.Brush("Secondary");
        Content = new Grid { Children = { shadow, card } };
        MouseLeftButtonUp += (_, _) => { Hide(); App.Current.ShowMain(); };
        poll.Tick += (_, _) => Update();
        hide.Tick += (_, _) => { hide.Stop(); Hide(); };
    }

    public void Track(List<Job> jobs)
    {
        this.jobs = jobs;
        hide.Stop();
        var area = SystemParameters.WorkArea;
        Left = area.Right - Width - 8;
        Top = area.Bottom - Height - 8;
        Update();
        Show();
        poll.Start();
    }

    void Update()
    {
        var finished = jobs.Count(j => j.IsFinished);
        var failed = jobs.Where(j => j.Status == JobStatus.Failed).ToList();
        var allDone = finished == jobs.Count;
        var noun = jobs.Count == 1 ? jobs[0].Name : $"{jobs.Count} files";
        bar.Value = jobs.Count == 0 ? 1 : jobs.Average(j => j.IsFinished ? 1 : j.Fraction);
        if (!allDone)
        {
            icon.Content = Icons.Make("working", 22, Ui.Brush("Accent"), 1.8);
            title.Text = $"Working on {noun}…";
            detail.Visibility = Visibility.Collapsed;
            bar.Visibility = Visibility.Visible;
            return;
        }
        poll.Stop();
        bar.Visibility = Visibility.Collapsed;
        icon.Content = Icons.Make(failed.Count == 0 ? "check" : "warning", 22, Ui.Brush(failed.Count == 0 ? "Success" : "Warning"), 2);
        title.Text = failed.Count == 0 ? $"Done: {noun}" : failed.Count == jobs.Count ? $"Couldn't process {noun}" : $"Done, {failed.Count} failed";
        var message = failed.FirstOrDefault()?.Error ?? jobs.Select(j => j.Message).FirstOrDefault(m => m is not null);
        detail.Text = message ?? "";
        detail.Visibility = message is null ? Visibility.Collapsed : Visibility.Visible;
        // QR results and errors stay up a little longer so they can be read.
        hide.Interval = TimeSpan.FromSeconds(message is null ? 3.5 : 8);
        hide.Start();
    }
}
