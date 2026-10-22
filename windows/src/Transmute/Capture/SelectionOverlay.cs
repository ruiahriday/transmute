using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using Transmute.Desktop;
using Path = System.Windows.Shapes.Path;

namespace Transmute.App;

/// The screen, frozen and dimmed, across every display: drag to choose an area, or point at a
/// window. A crosshair and a magnifier help line up the edge pixel by pixel. Everything inside is
/// laid out in physical pixels, so it lines up exactly on displays with different scaling.
sealed class SelectionOverlay : Window
{
    public enum Mode { Area, Window, Color }

    public sealed record Result(PixelRect Rect, IntPtr Window, CaptureAction Action);

    /// Whether the overlay shows the screen as it was (so the capture is that picture) or the
    /// live screen under a see-through layer (so the capture is taken after it closes).
    public bool Frozen { get; }

    readonly BgraImage snapshot;
    readonly BitmapSource picture;
    readonly PixelRect virt;
    readonly IReadOnlyList<WindowInfo> windows;
    readonly IReadOnlyList<MonitorInfo> monitors;
    readonly string purpose;
    readonly bool allInOne;
    readonly TaskCompletionSource<Result?> done = new();
    Mode mode;
    CaptureAction action;

    readonly Canvas root = new() { Background = Brushes.Black, ClipToBounds = true };
    readonly Path dim = new() { Fill = new SolidColorBrush(Color.FromArgb(0x8C, 0x0B, 0x0A, 0x14)), IsHitTestVisible = false };
    readonly Rectangle outline = new() { Stroke = Brushes.White, IsHitTestVisible = false, Visibility = Visibility.Collapsed };
    readonly Rectangle outlineDark = new() { Stroke = new SolidColorBrush(Color.FromArgb(0xB0, 0x43, 0x38, 0xCA)), IsHitTestVisible = false, Visibility = Visibility.Collapsed };
    readonly Line hLight = new() { Stroke = new SolidColorBrush(Color.FromArgb(0xD8, 0xFF, 0xFF, 0xFF)), IsHitTestVisible = false };
    readonly Line vLight = new() { Stroke = new SolidColorBrush(Color.FromArgb(0xD8, 0xFF, 0xFF, 0xFF)), IsHitTestVisible = false };
    readonly Line hDark = new() { Stroke = new SolidColorBrush(Color.FromArgb(0x90, 0, 0, 0)), IsHitTestVisible = false };
    readonly Line vDark = new() { Stroke = new SolidColorBrush(Color.FromArgb(0x90, 0, 0, 0)), IsHitTestVisible = false };
    readonly Border sizeLabel;
    readonly TextBlock sizeText = new() { Foreground = Brushes.White, FontSize = 12, FontWeight = FontWeights.SemiBold };
    readonly Border magnifier;
    readonly Image magImage = new() { Width = 120, Height = 120, Stretch = Stretch.Fill };
    readonly TextBlock magText = new() { Foreground = Brushes.White, FontSize = 11, FontFamily = new FontFamily("Cascadia Mono, Consolas"), HorizontalAlignment = HorizontalAlignment.Center };
    readonly Border hint;
    readonly TextBlock hintText = new() { Foreground = Brushes.White, FontSize = 13 };
    Border? toolbar;
    TextBox? widthBox, heightBox;
    ToggleButton? lockButton;
    readonly Dictionary<CaptureAction, ToggleButton> actionButtons = [];

    double scale = 1; // WPF units per physical pixel, inverted
    Point? dragStart;
    PixelRect? selection; // relative to the virtual screen's top-left
    WindowInfo? hovered;
    (int X, int Y) cursor;
    double? lockedAspect;

    SelectionOverlay(BgraImage snapshot, PixelRect virt, Mode mode, string purpose, bool allInOne, CaptureAction action)
    {
        this.snapshot = snapshot;
        this.virt = virt;
        this.mode = mode;
        this.purpose = purpose;
        this.allInOne = allInOne;
        this.action = action;
        picture = CaptureKit.ToBitmap(snapshot);
        windows = Screens.Windows();
        monitors = Screens.Monitors();
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        Topmost = true;
        ShowInTaskbar = false;
        Background = Brushes.Black;
        Cursor = Cursors.Cross;
        FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI");
        Title = "Spinform capture";

        var shot = new Image { Source = picture, Width = virt.Width, Height = virt.Height, Stretch = Stretch.Fill };
        // Without freezing, the overlay is see-through and the live screen shows under it.
        Frozen = Settings.Current.FreezeScreen || mode == Mode.Color;
        if (!Frozen)
        {
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            root.Background = new SolidColorBrush(Color.FromArgb(1, 0, 0, 0));
            shot.Visibility = Visibility.Collapsed;
            dim.Fill = new SolidColorBrush(Color.FromArgb(0x60, 0x0B, 0x0A, 0x14));
        }
        RenderOptions.SetBitmapScalingMode(shot, BitmapScalingMode.NearestNeighbor);
        RenderOptions.SetBitmapScalingMode(magImage, BitmapScalingMode.NearestNeighbor);
        root.Width = virt.Width;
        root.Height = virt.Height;
        root.Children.Add(shot);
        root.Children.Add(dim);
        foreach (var line in new[] { hDark, vDark, hLight, vLight }) root.Children.Add(line);
        root.Children.Add(outlineDark);
        root.Children.Add(outline);

        sizeLabel = Pill(sizeText);
        sizeLabel.Visibility = Visibility.Collapsed;
        root.Children.Add(sizeLabel);

        var magGrid = new Grid { Width = 120, Height = 120, ClipToBounds = true };
        magGrid.Children.Add(magImage);
        // The pixel under the pointer.
        magGrid.Children.Add(new Rectangle { Width = 8, Height = 8, Stroke = Brushes.White, StrokeThickness = 1, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
        magGrid.Children.Add(new Rectangle { Width = 10, Height = 10, Stroke = Brushes.Black, StrokeThickness = 1, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
        var magStack = new StackPanel();
        magStack.Children.Add(new Border { Child = magGrid, BorderBrush = Brushes.White, BorderThickness = new Thickness(2), CornerRadius = new CornerRadius(4), ClipToBounds = true });
        magStack.Children.Add(new Border { Child = magText, Margin = new Thickness(0, 4, 0, 0) });
        magnifier = new Border { Child = magStack, Background = new SolidColorBrush(Color.FromArgb(0xE6, 0x16, 0x15, 0x1F)), CornerRadius = new CornerRadius(8), Padding = new Thickness(5), IsHitTestVisible = false, Visibility = Settings.Current.ShowMagnifier || mode == Mode.Color ? Visibility.Visible : Visibility.Collapsed };
        root.Children.Add(magnifier);
        if (!Settings.Current.ShowCrosshair) foreach (var line in new[] { hDark, vDark, hLight, vLight }) line.Visibility = Visibility.Collapsed;

        hint = Pill(hintText);
        hint.IsHitTestVisible = false;
        root.Children.Add(hint);
        if (allInOne) BuildToolbar();
        UpdateHint();

        Content = root;
        SourceInitialized += (_, _) =>
        {
            var source = (HwndSource)PresentationSource.FromVisual(this)!;
            // Stay exactly where we're put: no rescaling when the window spans displays.
            source.AddHook((IntPtr _, int msg, IntPtr _, IntPtr _, ref bool handled) => { if (msg == 0x02E0) handled = true; return IntPtr.Zero; });
            SetWindowPos(source.Handle, new IntPtr(-1), virt.X, virt.Y, virt.Width, virt.Height, 0x0040);
        };
        Loaded += (_, _) =>
        {
            scale = PresentationSource.FromVisual(this)!.CompositionTarget.TransformToDevice.M11;
            root.RenderTransform = new ScaleTransform(1 / scale, 1 / scale);
            var (x, y) = Screens.Cursor;
            Track(x - virt.X, y - virt.Y);
            Activate();
            Native.SetForegroundWindow(CaptureKit.Handle(this));
            Keyboard.Focus(this);
            if (allInOne && PixelRect.Parse(Settings.Current.LastArea) is { } last && !virt.Intersect(last).IsEmpty)
                SetSelection(last.Offset(-virt.X, -virt.Y));
        };
        MouseLeftButtonDown += OnDown;
        MouseMove += (_, e) => { var p = e.GetPosition(root); OnMove(p); };
        MouseLeftButtonUp += OnUp;
        MouseRightButtonUp += (_, _) => Finish(null);
        KeyDown += OnKey;
        Deactivated += (_, _) => { if (!done.Task.IsCompleted && !allInOne) Activate(); };
        Closed += (_, _) => done.TrySetResult(null);
    }

    [DllImport("user32.dll")]
    static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int w, int h, uint flags);

    public static Task<Result?> Pick(BgraImage snapshot, PixelRect virt, Mode mode, string purpose, bool allInOne = false, CaptureAction action = CaptureAction.Area)
    {
        var overlay = new SelectionOverlay(snapshot, virt, mode, purpose, allInOne, action);
        Current = overlay;
        overlay.Closed += (_, _) => { if (Current == overlay) Current = null; };
        LastFrozen = overlay.Frozen;
        overlay.Show();
        return overlay.done.Task;
    }

    public static SelectionOverlay? Current { get; private set; }

    /// Whether the last overlay was frozen (read once it has closed).
    public static bool LastFrozen { get; private set; } = true;

    /// A screen colour picker: returns "RRGGBB" for the pixel clicked, or null.
    public static async Task<string?> PickColor()
    {
        var virt = Screens.VirtualScreen;
        var snapshot = await Task.Run(() => ScreenGrab.Area(virt));
        var result = await Pick(snapshot, virt, Mode.Color, "Pick a colour");
        return result is null ? null : snapshot.HexAt(result.Rect.X - virt.X, result.Rect.Y - virt.Y);
    }

    static Border Pill(UIElement content) => new()
    {
        Child = content,
        Background = new SolidColorBrush(Color.FromArgb(0xE6, 0x16, 0x15, 0x1F)),
        CornerRadius = new CornerRadius(6),
        Padding = new Thickness(9, 4, 9, 5),
        RenderTransformOrigin = new Point(0, 0),
    };

    MonitorInfo MonitorAtRelative(int x, int y) =>
        monitors.FirstOrDefault(m => m.Bounds.Contains(x + virt.X, y + virt.Y)) ?? monitors[0];

    double Ui(MonitorInfo m) => m.Scale;

    void UpdateHint()
    {
        hintText.Text = mode == Mode.Color ? "Click to pick a colour · Esc to cancel" : allInOne
            ? "Drag to choose an area, or type its size · Enter to go · Esc to cancel"
            : mode == Mode.Window
                ? $"{purpose}: click a window · Space for an area · Esc to cancel"
                : $"{purpose}: drag across it · click a window · Space for windows · Esc to cancel";
    }

    void Place(FrameworkElement element, double x, double y, MonitorInfo m, bool keepInside = true)
    {
        var ui = Ui(m);
        element.RenderTransform = new ScaleTransform(ui, ui);
        element.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        double w = element.DesiredSize.Width * ui, h = element.DesiredSize.Height * ui;
        if (keepInside)
        {
            var b = m.Bounds.Offset(-virt.X, -virt.Y);
            if (x + w > b.Right - 4) x = b.Right - 4 - w;
            if (y + h > b.Bottom - 4) y = b.Bottom - 4 - h;
            x = Math.Max(b.X + 4, x);
            y = Math.Max(b.Y + 4, y);
        }
        Canvas.SetLeft(element, Math.Round(x));
        Canvas.SetTop(element, Math.Round(y));
    }

    void Track(double x, double y)
    {
        cursor = ((int)Math.Floor(x), (int)Math.Floor(y));
        var m = MonitorAtRelative(cursor.X, cursor.Y);
        var ui = Ui(m);
        // Crosshair across the whole screen.
        foreach (var (light, dark, horizontal) in new[] { (hLight, hDark, true), (vLight, vDark, false) })
        {
            if (horizontal)
            {
                (light.X1, light.X2, light.Y1, light.Y2) = (0, virt.Width, cursor.Y + 0.5, cursor.Y + 0.5);
                (dark.X1, dark.X2, dark.Y1, dark.Y2) = (0, virt.Width, cursor.Y + 1.5, cursor.Y + 1.5);
            }
            else
            {
                (light.X1, light.X2, light.Y1, light.Y2) = (cursor.X + 0.5, cursor.X + 0.5, 0, virt.Height);
                (dark.X1, dark.X2, dark.Y1, dark.Y2) = (cursor.X + 1.5, cursor.X + 1.5, 0, virt.Height);
            }
        }
        // Magnifier: 15 × 15 pixels around the pointer, 8 times bigger.
        var px = Math.Clamp(cursor.X - 7, 0, Math.Max(0, snapshot.Width - 15));
        var py = Math.Clamp(cursor.Y - 7, 0, Math.Max(0, snapshot.Height - 15));
        try { magImage.Source = new CroppedBitmap(picture, new Int32Rect(px, py, Math.Min(15, snapshot.Width), Math.Min(15, snapshot.Height))); } catch { }
        magText.Text = $"{cursor.X + virt.X - m.Bounds.X}, {cursor.Y + virt.Y - m.Bounds.Y}  #{snapshot.HexAt(cursor.X, cursor.Y)}";
        Place(magnifier, cursor.X + 22 * ui, cursor.Y + 22 * ui, m);
        if (Canvas.GetLeft(magnifier) < cursor.X && Canvas.GetTop(magnifier) < cursor.Y)
            Place(magnifier, cursor.X - (magnifier.DesiredSize.Width + 22) * ui, cursor.Y - (magnifier.DesiredSize.Height + 22) * ui, m);
        // The hint sits at the top of the display the pointer is on.
        hint.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var mb = m.Bounds.Offset(-virt.X, -virt.Y);
        Place(hint, mb.X + (mb.Width - hint.DesiredSize.Width * ui) / 2, mb.Y + (allInOne ? 74 : 18) * ui, m);
        if (toolbar is not null && dragStart is null)
        {
            toolbar.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            Place(toolbar, mb.X + (mb.Width - toolbar.DesiredSize.Width * ui) / 2, mb.Y + 14 * ui, m);
        }

        if (mode == Mode.Window && dragStart is null)
        {
            hovered = Screens.WindowAt(windows, cursor.X + virt.X, cursor.Y + virt.Y);
            ShowRect(hovered?.Bounds.Offset(-virt.X, -virt.Y), m);
        }
    }

    void ShowRect(PixelRect? r, MonitorInfo m)
    {
        var full = new RectangleGeometry(new Rect(0, 0, virt.Width, virt.Height));
        if (r is not { } rect || rect.IsEmpty)
        {
            dim.Data = full;
            outline.Visibility = outlineDark.Visibility = sizeLabel.Visibility = Visibility.Collapsed;
            return;
        }
        dim.Data = new CombinedGeometry(GeometryCombineMode.Exclude, full, new RectangleGeometry(new Rect(rect.X, rect.Y, rect.Width, rect.Height)));
        var ui = Ui(m);
        var t = Math.Max(1, Math.Round(ui));
        outline.StrokeThickness = t;
        outlineDark.StrokeThickness = t;
        Canvas.SetLeft(outline, rect.X - t); Canvas.SetTop(outline, rect.Y - t);
        outline.Width = rect.Width + 2 * t; outline.Height = rect.Height + 2 * t;
        Canvas.SetLeft(outlineDark, rect.X - 2 * t); Canvas.SetTop(outlineDark, rect.Y - 2 * t);
        outlineDark.Width = rect.Width + 4 * t; outlineDark.Height = rect.Height + 4 * t;
        outline.Visibility = outlineDark.Visibility = Visibility.Visible;
        sizeText.Text = $"{rect.Width} × {rect.Height}";
        sizeLabel.Visibility = Visibility.Visible;
        sizeLabel.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var below = rect.Bottom + 8 * ui;
        Place(sizeLabel, rect.X, below + sizeLabel.DesiredSize.Height * ui > m.Bounds.Bottom - virt.Y ? rect.Y - (sizeLabel.DesiredSize.Height + 8) * ui : below, m);
        if (widthBox is not null && !widthBox.IsKeyboardFocused) widthBox.Text = rect.Width.ToString();
        if (heightBox is not null && !heightBox.IsKeyboardFocused) heightBox.Text = rect.Height.ToString();
    }

    void SetSelection(PixelRect r)
    {
        r = r.Intersect(new PixelRect(0, 0, virt.Width, virt.Height));
        if (r.IsEmpty) return;
        selection = r;
        ShowRect(r, MonitorAtRelative(r.X + r.Width / 2, r.Y + r.Height / 2));
    }

    void OnDown(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is DependencyObject d && toolbar is not null && IsInside(d, toolbar)) return;
        if (mode == Mode.Window) return;
        if (mode == Mode.Color) { Finish(new Result(new PixelRect(cursor.X + virt.X, cursor.Y + virt.Y, 1, 1), IntPtr.Zero, action)); return; }
        dragStart = e.GetPosition(root);
        CaptureMouse();
    }

    static bool IsInside(DependencyObject d, DependencyObject container)
    {
        for (var node = d; node is not null; node = node is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(node) : LogicalTreeHelper.GetParent(node))
            if (node == container) return true;
        return false;
    }

    void OnMove(Point p)
    {
        Track(p.X, p.Y);
        if (dragStart is not { } start) return;
        var aspect = lockButton?.IsChecked == true ? lockedAspect : null;
        var r = PixelRect.Drag((int)Math.Floor(start.X), (int)Math.Floor(start.Y), cursor.X + 1, cursor.Y + 1, aspect);
        SetSelection(r);
    }

    void OnUp(object sender, MouseButtonEventArgs e)
    {
        if (mode == Mode.Window)
        {
            if (e.OriginalSource is DependencyObject d && toolbar is not null && IsInside(d, toolbar)) return;
            if (hovered is { } w) Finish(new Result(w.Bounds, w.Handle, allInOne ? (action is CaptureAction.Area ? CaptureAction.Window : action) : action));
            return;
        }
        if (dragStart is not { } start) return;
        dragStart = null;
        ReleaseMouseCapture();
        var p = e.GetPosition(root);
        var dragged = Math.Abs(p.X - start.X) > 3 || Math.Abs(p.Y - start.Y) > 3;
        if (!dragged)
        {
            // A click picks the window under the pointer.
            if (Screens.WindowAt(windows, cursor.X + virt.X, cursor.Y + virt.Y) is { } w)
            {
                if (allInOne) SetSelection(w.Bounds.Offset(-virt.X, -virt.Y));
                else Finish(new Result(w.Bounds, action == CaptureAction.Area ? w.Handle : IntPtr.Zero, action));
            }
            return;
        }
        if (selection is { Width: >= 2, Height: >= 2 } s && !allInOne) Finish(new Result(s.Offset(virt.X, virt.Y), IntPtr.Zero, action));
    }

    void OnKey(object sender, KeyEventArgs e)
    {
        if (e.OriginalSource is TextBox) return;
        switch (e.Key)
        {
            case Key.Escape:
                Finish(null);
                break;
            case Key.Space when !allInOne && mode != Mode.Color:
                mode = mode == Mode.Area ? Mode.Window : Mode.Area;
                selection = null;
                ShowRect(null, monitors[0]);
                UpdateHint();
                Track(cursor.X, cursor.Y);
                break;
            case Key.Enter:
                Confirm();
                break;
            case Key.Left or Key.Right or Key.Up or Key.Down when selection is { } s:
                var step = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift) ? 10 : 1;
                var (dx, dy) = e.Key switch { Key.Left => (-step, 0), Key.Right => (step, 0), Key.Up => (0, -step), _ => (0, step) };
                SetSelection(s.Offset(dx, dy));
                break;
        }
        e.Handled = true;
    }

    void Confirm()
    {
        if (action == CaptureAction.FullScreen)
        {
            var m = MonitorAtRelative(cursor.X, cursor.Y);
            Finish(new Result(m.Bounds, IntPtr.Zero, CaptureAction.FullScreen));
            return;
        }
        if (mode == Mode.Window && hovered is { } w) { Finish(new Result(w.Bounds, w.Handle, CaptureAction.Window)); return; }
        if (selection is { Width: >= 2, Height: >= 2 } s) Finish(new Result(s.Offset(virt.X, virt.Y), IntPtr.Zero, action));
    }

    void Finish(Result? result)
    {
        if (done.Task.IsCompleted) return;
        if (result is not null && mode != Mode.Color && result.Action is not CaptureAction.Window and not CaptureAction.FullScreen)
            Settings.Current.LastArea = result.Rect.ToString();
        done.TrySetResult(result);
        Close();
    }

    // All-in-one: a bar of every capture kind, and a typed size.

    void BuildToolbar()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        void Add(CaptureAction a, string glyph, string label)
        {
            var b = new ToggleButton { Content = Icons.WithText(glyph, label, 14), Margin = new Thickness(0, 0, 4, 0), Padding = new Thickness(9, 4, 9, 4), Focusable = false, Foreground = Brushes.White, Background = Brushes.Transparent, BorderThickness = new Thickness(0), Cursor = Cursors.Hand };
            b.Style = ToolbarToggle();
            b.Checked += (_, _) =>
            {
                action = a;
                foreach (var other in actionButtons.Values) if (other != b) other.IsChecked = false;
                mode = a == CaptureAction.Window ? Mode.Window : Mode.Area;
                if (a == CaptureAction.FullScreen) Confirm();
            };
            b.Unchecked += (_, _) => { if (actionButtons.Values.All(x => x.IsChecked != true)) b.IsChecked = true; };
            actionButtons[a] = b;
            row.Children.Add(b);
        }
        Add(CaptureAction.Area, "area", "Area");
        Add(CaptureAction.Window, "window", "Window");
        Add(CaptureAction.FullScreen, "screen", "Full screen");
        Add(CaptureAction.Scrolling, "scroll", "Scrolling");
        Add(CaptureAction.Text, "text", "Text");
        Add(CaptureAction.RecordArea, "record", "Record");
        row.Children.Add(new Rectangle { Width = 1, Fill = new SolidColorBrush(Color.FromArgb(0x50, 0xFF, 0xFF, 0xFF)), Margin = new Thickness(6, 3, 10, 3) });
        TextBox Box()
        {
            var box = new TextBox { Width = 54, Padding = new Thickness(4, 2, 4, 2), MinHeight = 0, VerticalContentAlignment = VerticalAlignment.Center };
            box.KeyDown += (_, e) => { if (e.Key == Key.Enter) { ApplyTypedSize(); e.Handled = true; } };
            box.LostKeyboardFocus += (_, _) => ApplyTypedSize();
            return box;
        }
        widthBox = Box();
        heightBox = Box();
        row.Children.Add(widthBox);
        row.Children.Add(new TextBlock { Text = "×", Foreground = Brushes.White, Margin = new Thickness(5, 0, 5, 0), VerticalAlignment = VerticalAlignment.Center });
        row.Children.Add(heightBox);
        lockButton = new ToggleButton { Content = Icons.Make("lock", 14), ToolTip = "Keep this shape while dragging", Margin = new Thickness(6, 0, 0, 0), Padding = new Thickness(6, 4, 6, 4), Focusable = false, Foreground = Brushes.White, Style = ToolbarToggle() };
        lockButton.Checked += (_, _) => { lockedAspect = selection is { } s ? (double)s.Width / s.Height : null; Settings.Current.LockedAspect = lockedAspect?.ToString(System.Globalization.CultureInfo.InvariantCulture); };
        lockButton.Unchecked += (_, _) => { lockedAspect = null; Settings.Current.LockedAspect = null; };
        if (double.TryParse(Settings.Current.LockedAspect, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var saved) && saved > 0)
        {
            lockedAspect = saved;
            lockButton.IsChecked = true;
            lockedAspect = saved;
        }
        row.Children.Add(lockButton);
        var go = new Button { Content = "Capture", Style = CaptureKit.Style("Primary"), Margin = new Thickness(10, 0, 0, 0), Padding = new Thickness(14, 4, 14, 4), Focusable = false };
        go.Click += (_, _) => Confirm();
        row.Children.Add(go);
        var close = new Button { Content = Icons.Make("close", 12), Style = CaptureKit.Style("Flat"), Foreground = Brushes.White, Margin = new Thickness(6, 0, 0, 0), Focusable = false, ToolTip = "Cancel (Esc)" };
        close.Click += (_, _) => Finish(null);
        row.Children.Add(close);
        toolbar = Pill(row);
        toolbar.Padding = new Thickness(8, 6, 8, 6);
        toolbar.CornerRadius = new CornerRadius(10);
        toolbar.Cursor = Cursors.Arrow;
        root.Children.Add(toolbar);
        actionButtons[action is CaptureAction.Area or CaptureAction.Window or CaptureAction.Scrolling or CaptureAction.Text or CaptureAction.RecordArea ? action : CaptureAction.Area].IsChecked = true;
    }

    static Style ToolbarToggle()
    {
        var style = new Style(typeof(ToggleButton));
        var template = new ControlTemplate(typeof(ToggleButton));
        var border = new FrameworkElementFactory(typeof(Border)) { Name = "Back" };
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(6));
        border.SetValue(Border.BackgroundProperty, Brushes.Transparent);
        border.SetValue(Border.PaddingProperty, new TemplateBindingExtension(PaddingProperty));
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center);
        border.AppendChild(presenter);
        template.VisualTree = border;
        var hover = new Trigger { Property = IsMouseOverProperty, Value = true };
        hover.Setters.Add(new Setter(Border.BackgroundProperty, new SolidColorBrush(Color.FromArgb(0x30, 0xFF, 0xFF, 0xFF)), "Back"));
        var on = new Trigger { Property = ToggleButton.IsCheckedProperty, Value = true };
        on.Setters.Add(new Setter(Border.BackgroundProperty, Theme.Brand, "Back"));
        template.Triggers.Add(hover);
        template.Triggers.Add(on);
        style.Setters.Add(new Setter(TemplateProperty, template));
        style.Setters.Add(new Setter(ForegroundProperty, Brushes.White));
        return style;
    }

    void ApplyTypedSize()
    {
        if (widthBox is null || heightBox is null) return;
        if (!int.TryParse(widthBox.Text.Trim(), out var w) || !int.TryParse(heightBox.Text.Trim(), out var h) || w < 2 || h < 2) return;
        var current = selection ?? MonitorAtRelative(cursor.X, cursor.Y).Bounds.Offset(-virt.X, -virt.Y);
        SetSelection(current.Resized(w, h));
    }

    /// For the smoke test: shows a chosen area as if dragged.
    public void Preview(PixelRect area)
    {
        SetSelection(area.Offset(-virt.X, -virt.Y));
        Track(area.Right - virt.X, area.Bottom - virt.Y);
        ShowRect(selection, MonitorAtRelative(area.X - virt.X, area.Y - virt.Y));
    }
}
