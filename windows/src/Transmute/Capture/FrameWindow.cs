using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using ImageMagick;
using Microsoft.Win32;

namespace Transmute.App;

/// Puts a screenshot on a background: gradients, colours or a picture, with padding, rounded
/// corners, a shadow, a fixed shape for social posts and where it sits. Looks can be saved as
/// presets. The result is a new PNG; the screenshot itself is never changed.
sealed class FrameWindow : Window
{
    readonly string input;
    readonly MagickImage small;
    readonly Image preview = new() { Stretch = Stretch.Uniform, Margin = new Thickness(28) };
    readonly DispatcherTimer debounce = new() { Interval = TimeSpan.FromMilliseconds(90) };
    readonly WrapPanel presetPanel = new();
    readonly StackPanel colorRows = new();
    readonly UniformGrid alignGrid = new() { Rows = 3, Columns = 3, Width = 96, Height = 72, HorizontalAlignment = HorizontalAlignment.Left };
    FrameStyle style;
    Slider? padding, corners, shadow, angle;
    ComboBox? kind, aspect;
    CheckBox? balance;
    bool loading;

    FrameWindow(string path)
    {
        input = path;
        Ui.SetUpEditorWindow(this, "Frame · " + Path.GetFileName(path));
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        style = Settings.Current.LastFrame ?? Frames.BuiltIn[0].Style;
        small = (MagickImage)ImageConverter.LoadFirst(path);
        var limit = 1100u;
        if (small.Width > limit || small.Height > limit) small.Resize(new MagickGeometry(limit, limit));
        RenderOptions.SetBitmapScalingMode(preview, BitmapScalingMode.HighQuality);

        var controls = new StackPanel();
        controls.Children.Add(Ui.Heading("Presets"));
        controls.Children.Add(presetPanel);
        var savePreset = Ui.Button("Save as preset", (_, _) => SavePreset(), icon: "add");
        savePreset.HorizontalAlignment = HorizontalAlignment.Left;
        savePreset.Margin = new Thickness(0, 4, 0, 0);
        controls.Children.Add(savePreset);

        controls.Children.Add(Ui.Heading("Background"));
        kind = Ui.Combo([("Gradient", FrameBackground.Gradient), ("Colour", FrameBackground.Solid), ("Picture", FrameBackground.Picture), ("None (see-through)", FrameBackground.Transparent)],
            style.Background, v => Change(style with { Background = v }, rebuild: true));
        controls.Children.Add(Ui.Labelled("Kind", kind));
        controls.Children.Add(colorRows);

        controls.Children.Add(Ui.Heading("Layout"));
        aspect = Ui.Combo(Enum.GetValues<FrameAspect>().Select(a => (a.Label() + (a.Help() is { Length: > 0 } h ? " · " + h : ""), a)), style.Aspect, v => Change(style with { Aspect = v }));
        controls.Children.Add(Ui.Labelled("Shape", aspect));
        var (padView, padSlider) = Ui.Slider("Padding", 0, 0.3, style.Padding, Ui.Percent, v => Change(style with { Padding = v }), 0.01);
        var (cornerView, cornerSlider) = Ui.Slider("Corners", 0, 0.1, style.Corners, v => Ui.Percent(v * 10), v => Change(style with { Corners = v }), 0.005);
        var (shadowView, shadowSlider) = Ui.Slider("Shadow", 0, 1, style.Shadow, Ui.Percent, v => Change(style with { Shadow = v }), 0.05);
        padding = padSlider; corners = cornerSlider; shadow = shadowSlider;
        controls.Children.Add(padView);
        controls.Children.Add(cornerView);
        controls.Children.Add(shadowView);
        foreach (var align in new[] { FrameAlign.TopLeft, FrameAlign.Top, FrameAlign.TopRight, FrameAlign.Left, FrameAlign.Center, FrameAlign.Right, FrameAlign.BottomLeft, FrameAlign.Bottom, FrameAlign.BottomRight })
        {
            var dot = new RadioButton { GroupName = "frameAlign", Style = CaptureKit.Style("Tile"), Margin = new Thickness(0, 0, 3, 3), Tag = align, ToolTip = align.ToString(), Content = new System.Windows.Shapes.Ellipse { Width = 6, Height = 6, Fill = CaptureKit.Brush("Secondary") } };
            dot.Checked += (_, _) => { if (!loading) Change(style with { Align = align }); };
            alignGrid.Children.Add(dot);
        }
        controls.Children.Add(Ui.Labelled("Position", alignGrid));
        balance = new CheckBox { Content = "Auto balance", ToolTip = "Centres what's actually in the picture, ignoring empty edges", IsChecked = style.AutoBalance };
        balance.Click += (_, _) => Change(style with { AutoBalance = balance.IsChecked == true });
        controls.Children.Add(balance);
        controls.Children.Add(Ui.Caption("Position matters when a shape is chosen and leaves room around the picture."));

        var copy = Ui.Button("Copy", (_, _) => _ = Finish(copy: true), icon: "copy");
        var save = Ui.Button("Save copy", (_, _) => _ = Finish(copy: false), primary: true);
        var cancel = Ui.Button("Close", (_, _) => Close());
        var drag = new Border
        {
            Child = Icons.WithText("drag", "Drag out"), Cursor = Cursors.Hand, VerticalAlignment = VerticalAlignment.Center, Padding = new Thickness(6, 4, 6, 4),
            ToolTip = "Drag the framed picture into another app",
        };
        drag.MouseLeftButtonDown += async (_, _) =>
        {
            try
            {
                var file = await Render(OutputPaths.TempDir());
                DragDrop.DoDragDrop(drag, new DataObject(DataFormats.FileDrop, new[] { file }), DragDropEffects.Copy);
            }
            catch (Exception e) { Toast.Show("Couldn't frame it", e.Message, ok: false); }
        };
        var footerLeft = new StackPanel { Orientation = Orientation.Horizontal };
        footerLeft.Children.Add(copy);
        footerLeft.Children.Add(drag);
        Content = Ui.EditorLayout(new Grid { Background = BackgroundPanel.Checkerboard(10), Children = { preview } }, controls, cancel, save, footerLeft);
        debounce.Tick += (_, _) => { debounce.Stop(); Redraw(); };
        Closed += (_, _) => small.Dispose();
        KeyDown += (_, e) => { if (e.Key == Key.Escape) Close(); };
        FillPresets();
        Load(style);
    }

    public static FrameWindow? Open(string path)
    {
        try
        {
            var window = new FrameWindow(path);
            window.Show();
            window.Activate();
            return window;
        }
        catch (Exception e)
        {
            Toast.Show("Couldn't open that picture", e.Message, ok: false);
            return null;
        }
    }

    IEnumerable<FramePreset> AllPresets => Frames.BuiltIn.Concat(Settings.Current.FramePresets);

    void FillPresets()
    {
        presetPanel.Children.Clear();
        foreach (var preset in AllPresets)
        {
            var s = preset.Style;
            Brush fill = s.Background switch
            {
                FrameBackground.Gradient => new LinearGradientBrush(Hex(s.From), Hex(s.To), s.Angle),
                FrameBackground.Solid => new SolidColorBrush(Hex(s.From)),
                FrameBackground.Transparent => BackgroundPanel.Checkerboard(4),
                _ => CaptureKit.Brush("Subtle"),
            };
            var swatch = new Border
            {
                Width = 38, Height = 28, CornerRadius = new CornerRadius(6), Background = fill, Margin = new Thickness(0, 0, 6, 6), Cursor = Cursors.Hand,
                BorderBrush = CaptureKit.Brush("LineStrong"), BorderThickness = new Thickness(1), ToolTip = preset.Name + (preset.Custom ? " (right-click to remove)" : ""),
                Child = s.Background == FrameBackground.Picture ? Icons.Make("image", 14, CaptureKit.Brush("Secondary")) : null,
            };
            swatch.MouseLeftButtonUp += (_, _) => Load(preset.Style with { PicturePath = preset.Style.PicturePath ?? style.PicturePath });
            if (preset.Custom)
            {
                var menu = new ContextMenu();
                var remove = new MenuItem { Header = "Remove preset" };
                remove.Click += (_, _) =>
                {
                    Settings.Current.FramePresets.RemoveAll(p => p.Id == preset.Id);
                    Settings.Current.Save();
                    FillPresets();
                };
                menu.Items.Add(remove);
                swatch.ContextMenu = menu;
            }
            presetPanel.Children.Add(swatch);
        }
    }

    void SavePreset()
    {
        var count = Settings.Current.FramePresets.Count + 1;
        Settings.Current.FramePresets.Add(new FramePreset(Guid.NewGuid().ToString("N")[..8], $"My preset {count}", style, Custom: true));
        Settings.Current.Save();
        FillPresets();
        Toast.Show("Preset saved", "It's at the end of the presets. Right-click it to remove it.");
    }

    static Color Hex(string hex)
    {
        try { return (Color)ColorConverter.ConvertFromString("#" + hex.TrimStart('#')); } catch { return Colors.Gray; }
    }

    /// Puts a whole look into the controls.
    void Load(FrameStyle next)
    {
        loading = true;
        style = next;
        kind!.SelectedIndex = (int)next.Background;
        aspect!.SelectedIndex = (int)next.Aspect;
        padding!.Value = next.Padding;
        corners!.Value = next.Corners;
        shadow!.Value = next.Shadow;
        balance!.IsChecked = next.AutoBalance;
        foreach (RadioButton dot in alignGrid.Children) dot.IsChecked = (FrameAlign)dot.Tag == next.Align;
        loading = false;
        BuildColorRows();
        Schedule();
    }

    void Change(FrameStyle next, bool rebuild = false)
    {
        if (loading) return;
        style = next;
        if (rebuild) BuildColorRows();
        Schedule();
    }

    /// The controls that depend on the kind of background.
    void BuildColorRows()
    {
        colorRows.Children.Clear();
        switch (style.Background)
        {
            case FrameBackground.Gradient:
                colorRows.Children.Add(ColorRow("From", style.From, v => Change(style with { From = v })));
                colorRows.Children.Add(ColorRow("To", style.To, v => Change(style with { To = v })));
                var (view, slider) = Ui.Slider("Angle", 0, 360, style.Angle, v => $"{v:0}°", v => Change(style with { Angle = v }), 15);
                angle = slider;
                colorRows.Children.Add(view);
                break;
            case FrameBackground.Solid:
                colorRows.Children.Add(ColorRow("Colour", style.From, v => Change(style with { From = v })));
                break;
            case FrameBackground.Picture:
                var name = new TextBlock { Text = style.PicturePath is { } p ? Path.GetFileName(p) : "No picture chosen", VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(8, 0, 0, 0) };
                var choose = Ui.Button("Choose…", (_, _) =>
                {
                    var dialog = new OpenFileDialog { Filter = "Pictures|*.png;*.jpg;*.jpeg;*.webp;*.heic;*.bmp;*.gif;*.tif;*.tiff|All files|*.*", Title = "Choose a background picture" };
                    if (dialog.ShowDialog(this) == true) { Change(style with { PicturePath = dialog.FileName }); name.Text = Path.GetFileName(dialog.FileName); }
                });
                var wallpaper = Ui.Button("Use wallpaper", (_, _) =>
                {
                    if (CaptureKit.WallpaperPath() is { } w) { Change(style with { PicturePath = w }); name.Text = Path.GetFileName(w); }
                    else Toast.Show("No wallpaper picture found", "Windows is using a solid colour or a slideshow.", ok: false);
                });
                wallpaper.Margin = new Thickness(6, 0, 0, 0);
                var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 4) };
                row.Children.Add(choose);
                row.Children.Add(wallpaper);
                colorRows.Children.Add(row);
                colorRows.Children.Add(name);
                break;
        }
    }

    FrameworkElement ColorRow(string label, string hex, Action<string> changed)
    {
        var swatch = new Border { Width = 22, Height = 22, CornerRadius = new CornerRadius(4), Background = new SolidColorBrush(Hex(hex)), BorderBrush = CaptureKit.Brush("LineStrong"), BorderThickness = new Thickness(1), Margin = new Thickness(0, 0, 8, 0) };
        var box = new TextBox { Text = hex.ToUpperInvariant(), Width = 78, VerticalContentAlignment = VerticalAlignment.Center, MaxLength = 7 };
        box.TextChanged += (_, _) =>
        {
            var text = box.Text.Trim().TrimStart('#');
            if (text.Length == 6 && int.TryParse(text, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out _))
            {
                swatch.Background = new SolidColorBrush(Hex(text));
                changed(text.ToUpperInvariant());
            }
        };
        var pick = CaptureKit.IconButton("eyedropper", "Pick a colour from the screen", async () =>
        {
            if (await SelectionOverlay.PickColor() is { } picked) box.Text = picked;
        }, 14);
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(swatch);
        row.Children.Add(box);
        row.Children.Add(pick);
        return Ui.Labelled(label, row);
    }

    void Schedule()
    {
        debounce.Stop();
        debounce.Start();
    }

    int renderId;

    async void Redraw()
    {
        var id = ++renderId;
        var s = style;
        try
        {
            var bitmap = await Task.Run(() =>
            {
                lock (small)
                {
                    using var framed = Frames.Render(small, s);
                    return Editors.Pixels(framed);
                }
            });
            if (id == renderId) preview.Source = bitmap;
        }
        catch { }
        Settings.Current.LastFrame = s;
    }

    async Task<string> Render(string? folder)
    {
        var s = style;
        return await Task.Run(() => Frames.Save(input, s, folder));
    }

    async Task Finish(bool copy)
    {
        try
        {
            Settings.Current.LastFrame = style;
            Settings.Current.Save();
            if (copy)
            {
                var file = await Render(OutputPaths.TempDir());
                CaptureKit.CopyImage(file);
                Toast.Show("Copied", "The framed picture is on the clipboard.", glyph: "frame");
                return;
            }
            var folder = input.StartsWith(CaptureKit.HistoryFolder, StringComparison.OrdinalIgnoreCase) || input.StartsWith(Path.GetTempPath(), StringComparison.OrdinalIgnoreCase)
                ? CaptureKit.CaptureFolder : null;
            if (folder is not null) Directory.CreateDirectory(folder);
            var saved = await Render(folder);
            Toast.Show("Framed picture saved", Path.GetFileName(saved), action: ("Show in folder", () => Native.RevealInExplorer([saved])), glyph: "frame");
        }
        catch (Exception e) { Toast.Show("Couldn't frame it", JobQueue.Describe(e), ok: false); }
    }
}
