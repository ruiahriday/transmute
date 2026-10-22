using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using Path = System.Windows.Shapes.Path;
using System.Windows.Threading;
using ImageMagick;
using Microsoft.Win32;

namespace Transmute.App;

/// The photo editor: mark up screenshots (arrows, lines, boxes, ovals, highlights, text, numbered
/// steps, spotlight, pencil, blur and pixelate), crop to a shape, turn, flip, resize, adjust colour,
/// remove or replace the background and place other pictures on top. Saves an edited copy; the
/// original is never changed. Projects (.spinform) keep every mark editable.
sealed class ImageEditorWindow : Window
{
    public enum Tool { Arrow, Line, Box, Filled, Oval, Highlight, Text, Step, Spotlight, Pencil, Hide, Crop }

    static readonly (Tool Tool, string Glyph, string Name, Key Key)[] Tools =
    [
        (Tool.Arrow, "arrow", "Arrow", Key.A), (Tool.Line, "line", "Line", Key.L), (Tool.Box, "rect", "Box", Key.R),
        (Tool.Filled, "filled", "Filled box", Key.F), (Tool.Oval, "ellipse", "Oval", Key.O), (Tool.Highlight, "highlighter", "Highlighter", Key.H),
        (Tool.Text, "text", "Text", Key.T), (Tool.Step, "step", "Numbered step", Key.N), (Tool.Spotlight, "spotlight", "Spotlight", Key.S),
        (Tool.Pencil, "edit", "Pencil", Key.P), (Tool.Hide, "pixelate", "Blur or pixelate", Key.B), (Tool.Crop, "crop", "Crop", Key.C),
    ];

    readonly Job job;
    readonly string? projectPath;
    ImageEdit edit = new();
    string? previewSource;
    BgraImage? previewPixels;
    Tool tool = Tool.Arrow;
    RedactionStyle redactionStyle = RedactionStyle.Pixelate;
    ArrowStyle arrowStyle = ArrowStyle.Filled;
    int textPreset;
    int cropShape;
    Rgba color = Rgba.Red;
    double sizeLevel = 4; // 1…10: text 1.2% of the picture's height per step, lines 0.2%
    readonly List<object> history = []; // redactions, annotations and placed pictures, newest last

    // Preview: the picture with marks and colours applied; crop, turns and flips are shown with
    // WPF transforms so the marks keep the original's coordinates.
    readonly Image picture = new() { Stretch = Stretch.Fill };
    readonly Border checker = new() { Visibility = Visibility.Collapsed };
    readonly Canvas overlay = new() { Background = Brushes.Transparent, ClipToBounds = true };
    readonly Grid stage = new();
    readonly Viewbox viewbox = new() { Stretch = Stretch.Uniform, Margin = new Thickness(20) };
    readonly TextBlock status = new() { Foreground = Brushes.White, Margin = new Thickness(12), VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Left };
    readonly Rectangle rubber = new() { Stroke = Brushes.White, StrokeDashArray = [4, 3], StrokeThickness = 1.5, Visibility = Visibility.Collapsed, Fill = new SolidColorBrush(Color.FromArgb(0x30, 0xFF, 0xFF, 0xFF)) };
    readonly Line liveLine = new() { StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, Visibility = Visibility.Collapsed, IsHitTestVisible = false };
    readonly Ellipse liveOval = new() { Visibility = Visibility.Collapsed, IsHitTestVisible = false };
    readonly Polyline livePencil = new() { StrokeLineJoin = PenLineJoin.Round, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, Visibility = Visibility.Collapsed, IsHitTestVisible = false };
    readonly Path cropShade = new() { Fill = new SolidColorBrush(Color.FromArgb(0x99, 0, 0, 0)), IsHitTestVisible = false };
    readonly DispatcherTimer renderTimer = new() { Interval = TimeSpan.FromMilliseconds(120) };
    readonly List<NormPoint> stroke = [];
    TextBox? typing;
    Point? dragFrom;
    int pixelWidth = 1, pixelHeight = 1;
    int renderGeneration;
    /// Whether the last preview had the background changed (for the smoke test).
    public bool RenderedBackground { get; private set; }
    public int RenderCount { get; private set; }

    public void BringIntoViewBackground() => backgroundPanel.BringIntoView();
    readonly StackPanel toolOptions = new();
    readonly WrapPanel palette = new();
    readonly ComboBox formatBox;
    readonly BackgroundPanel backgroundPanel;
    readonly Button undoButton;
    readonly TextBlock sizeLabel = new() { Style = (Style)Application.Current.FindResource("Caption") };

    public ImageEditorWindow(Job job, ImageEdit? initial = null, string? project = null)
    {
        this.job = job;
        projectPath = project;
        if (initial is not null) edit = initial;
        Ui.SetUpEditorWindow(this, project is null ? $"Edit {job.Name}" : $"Edit {System.IO.Path.GetFileName(project)}");

        stage.Children.Add(checker);
        stage.Children.Add(picture);
        stage.Children.Add(overlay);
        overlay.Children.Add(cropShade);
        overlay.Children.Add(rubber);
        overlay.Children.Add(liveLine);
        overlay.Children.Add(liveOval);
        overlay.Children.Add(livePencil);
        viewbox.Child = stage;
        var previewArea = new Grid { AllowDrop = true };
        previewArea.Children.Add(viewbox);
        previewArea.Children.Add(status);
        previewArea.Drop += OnDrop;
        previewArea.DragOver += (_, e) => { e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None; e.Handled = true; };
        overlay.MouseLeftButtonDown += OnDown;
        overlay.MouseMove += OnMove;
        overlay.MouseLeftButtonUp += OnUp;
        overlay.Cursor = Cursors.Cross;

        var controls = new StackPanel();
        controls.Children.Add(Ui.Heading("Mark up"));
        controls.Children.Add(palette);
        BuildPalette();
        controls.Children.Add(toolOptions);
        undoButton = Ui.Button("Undo", (_, _) => Undo());
        controls.Children.Add(Ui.Row(undoButton, Ui.Button("Clear marks", (_, _) => { history.Clear(); Update(edit with { Redactions = [], Annotations = [], Overlays = [] }); }),
            Ui.Button("Add picture…", (_, _) => AddPicture(), tip: "Place another picture on this one (or drop it on the preview)")));

        controls.Children.Add(Ui.Heading("Turn, flip and size"));
        controls.Children.Add(Ui.Row(
            Ui.Button("Left", (_, _) => Update(edit with { QuarterTurns = edit.QuarterTurns - 1 }), icon: "rotateleft", tip: "Turn left"),
            Ui.Button("Right", (_, _) => Update(edit with { QuarterTurns = edit.QuarterTurns + 1 }), icon: "rotateright", tip: "Turn right"),
            Ui.Button("", (_, _) => Update(edit with { FlipHorizontal = !edit.FlipHorizontal }), tip: "Flip left to right", contentOverride: Icons.Make("fliph", 15)),
            Ui.Button("", (_, _) => Update(edit with { FlipVertical = !edit.FlipVertical }), tip: "Flip upside down", contentOverride: Icons.Make("flipv", 15))));
        controls.Children.Add(Ui.Slider("Size", 0.05, 1, edit.Scale, Ui.Percent, v => Update(edit with { Scale = Math.Round(v, 2) }), 0.05).View);
        controls.Children.Add(sizeLabel);

        controls.Children.Add(Ui.Heading("Colour"));
        var sliders = new List<Slider>();
        void AddSlider(string title, double min, double max, double value, Func<double, string> format, Func<double, ImageEdit> apply)
        {
            var (view, s) = Ui.Slider(title, min, max, value, format, v => Update(apply(v)));
            sliders.Add(s);
            controls.Children.Add(view);
        }
        AddSlider("Exposure", -2, 2, edit.Exposure, v => Ui.Signed(v), v => edit with { Exposure = Math.Round(v, 2) });
        AddSlider("Brightness", -0.5, 0.5, edit.Brightness, v => Ui.Signed(v * 100, "%").Replace(".0", ""), v => edit with { Brightness = Math.Round(v, 3) });
        AddSlider("Contrast", 0.5, 2, edit.Contrast, Ui.Percent, v => edit with { Contrast = Math.Round(v, 3) });
        AddSlider("Saturation", 0, 2, edit.Saturation, Ui.Percent, v => edit with { Saturation = Math.Round(v, 3) });
        controls.Children.Add(Ui.Row(Ui.Button("Reset colours", (_, _) =>
        {
            sliders[0].Value = 0; sliders[1].Value = 0; sliders[2].Value = 1; sliders[3].Value = 1;
        })));

        controls.Children.Add(Ui.Heading("Background"));
        backgroundPanel = new BackgroundPanel(BackgroundMode.Keep, true, background =>
        {
            Update(edit with { Background = background });
            // A see-through background needs a format that keeps it.
            if (background is { KeepsTransparency: true } && formatBox?.SelectedItem is ComboBoxItem { Tag: OutputFormat f } && !Backgrounds.HoldsTransparency(f))
                SelectFormat(OutputFormat.Png);
        });
        controls.Children.Add(backgroundPanel);

        controls.Children.Add(Ui.Heading("Save as"));
        var current = ImageEditEngine.FormatFor(edit, job.Path);
        var formats = ImageEditEngine.Formats.Where(f => f != OutputFormat.Heic || ImageConverter.CanWriteHeic).ToList();
        formatBox = Ui.Combo(formats.Select(f => (f.Label(), f)), current, f => edit = edit with { OutputFormat = f });
        controls.Children.Add(formatBox);
        controls.Children.Add(Ui.Caption(InCaptureStore ? "The edited copy is saved in your screenshots folder." : "The edited copy is saved next to the original with “edited” in its name."));
        controls.Children.Add(Ui.Row(Ui.Button("Save project…", (_, _) => SaveProject(), tip: "Keep every mark editable in a .spinform file")));

        var cancel = Ui.Button("Cancel", (_, _) => Close());
        var save = Ui.Button("Save Copy", (_, _) => _ = Save(), primary: true);
        save.IsDefault = true;
        var copy = Ui.Button("Copy", (_, _) => _ = CopyResult(), tip: "Copy the edited picture");
        var drag = new Border
        {
            Child = Icons.WithText("drag", "Drag out"), Cursor = Cursors.Hand, VerticalAlignment = VerticalAlignment.Center, Padding = new Thickness(8, 4, 8, 4),
            ToolTip = "Drag the edited picture into another app", Margin = new Thickness(6, 0, 0, 0), Background = Brushes.Transparent,
        };
        drag.MouseLeftButtonDown += async (_, _) =>
        {
            try
            {
                var file = await RenderToFile(OutputPaths.TempDir());
                DragDrop.DoDragDrop(drag, new DataObject(DataFormats.FileDrop, new[] { file }), DragDropEffects.Copy);
            }
            catch (Exception e) { status.Text = JobQueue.Describe(e); }
        };
        var footerLeft = new StackPanel { Orientation = Orientation.Horizontal };
        footerLeft.Children.Add(copy);
        footerLeft.Children.Add(drag);
        Content = Ui.EditorLayout(previewArea, controls, cancel, save, footerLeft);
        BuildToolOptions();
        renderTimer.Tick += (_, _) => { renderTimer.Stop(); _ = Render(); };
        Loaded += async (_, _) => await LoadPreview();
        Closed += (_, _) => OutputPaths.TryDelete(previewSource);
        PreviewKeyDown += OnKey;
    }

    bool InCaptureStore => job.Path.StartsWith(CaptureKit.HistoryFolder, StringComparison.OrdinalIgnoreCase)
        || job.Path.StartsWith(System.IO.Path.GetTempPath(), StringComparison.OrdinalIgnoreCase);

    void OnKey(object sender, KeyEventArgs e)
    {
        if (typing is not null || e.OriginalSource is TextBox) return;
        if (e.Key == Key.Z && Keyboard.Modifiers == ModifierKeys.Control) { Undo(); e.Handled = true; return; }
        if (e.Key == Key.C && Keyboard.Modifiers == ModifierKeys.Control) { _ = CopyResult(); e.Handled = true; return; }
        if (e.Key == Key.S && Keyboard.Modifiers == ModifierKeys.Control) { _ = Save(); e.Handled = true; return; }
        if (e.Key == Key.Escape) { Close(); return; }
        if (Keyboard.Modifiers != ModifierKeys.None) return;
        foreach (var t in Tools)
            if (t.Key == e.Key) { SelectTool(t.Tool); e.Handled = true; return; }
    }

    void SelectFormat(OutputFormat format)
    {
        foreach (ComboBoxItem item in formatBox.Items)
            if (item.Tag is OutputFormat f && f == format) { formatBox.SelectedItem = item; break; }
    }

    /// Shows the Background section with a choice made (for the smoke test).
    public BackgroundPanel BackgroundControls => backgroundPanel;

    public void SelectTool(Tool next)
    {
        tool = next;
        foreach (RadioButton b in palette.Children) b.IsChecked = (Tool)b.Tag == next;
        BuildToolOptions();
    }

    void BuildPalette()
    {
        foreach (var (t, glyph, name, key) in Tools)
        {
            var button = new RadioButton
            {
                Style = (Style)FindResource("Tile"), GroupName = "markupTool", Tag = t, IsChecked = t == tool, Width = 38, Height = 34, Margin = new Thickness(0, 0, 4, 4),
                Content = Icons.Make(glyph, 16), ToolTip = $"{name} ({key})",
            };
            button.Checked += (_, _) => { tool = t; BuildToolOptions(); };
            palette.Children.Add(button);
        }
    }

    void BuildToolOptions()
    {
        toolOptions.Children.Clear();
        toolOptions.Margin = new Thickness(0, 4, 0, 6);
        switch (tool)
        {
            case Tool.Crop:
                toolOptions.Children.Add(Ui.Labelled("Shape", Ui.Combo(Markup.CropShapes.Select((s, i) => (s.Label, i)), cropShape, i => cropShape = i)));
                toolOptions.Children.Add(Ui.Caption("Drag across the picture to choose what to keep. Edges snap to the sides and the middle."));
                toolOptions.Children.Add(Ui.Row(Ui.Button("Reset crop", (_, _) => Update(edit with { Crop = null }))));
                return;
            case Tool.Hide:
                toolOptions.Children.Add(Ui.Labelled("Style", Ui.Combo([("Pixelate", RedactionStyle.Pixelate), ("Smooth blur", RedactionStyle.Blur), ("Secure blur", RedactionStyle.SecureBlur), ("Black box", RedactionStyle.Blackout)], redactionStyle, s => redactionStyle = s)));
                toolOptions.Children.Add(Ui.Caption("Drag across faces, names or numbers. Pixelate and secure blur are scrambled so they can't be undone."));
                return;
            case Tool.Spotlight:
                toolOptions.Children.Add(Ui.Caption("Drag around what matters; everything else is dimmed."));
                return;
        }
        if (tool == Tool.Arrow)
            toolOptions.Children.Add(Ui.Labelled("Style", Ui.Combo([("Filled head", ArrowStyle.Filled), ("Open head", ArrowStyle.Open), ("Both ends", ArrowStyle.Double), ("Curved", ArrowStyle.Curved)], arrowStyle, s => arrowStyle = s)));
        if (tool == Tool.Text)
            toolOptions.Children.Add(Ui.Labelled("Style", Ui.Combo(Markup.TextPresets.Select((p, i) => (p.Name, i)), textPreset, i =>
            {
                textPreset = i;
                var preset = Markup.TextPresets[i];
                sizeLevel = preset.SizeLevel;
                if (preset.Color is { } c) color = c;
                BuildToolOptions();
            })));
        toolOptions.Children.Add(Ui.Labelled("Colour", Swatches()));
        toolOptions.Children.Add(Ui.Slider("Size", 1, 10, sizeLevel, v => $"{v:0}", v => sizeLevel = v, 1).View);
        toolOptions.Children.Add(Ui.Caption(tool switch
        {
            Tool.Text => "Click where the text goes and type. Enter to finish, Shift+Enter for a new line.",
            Tool.Step => "Click to drop the next number.",
            Tool.Highlight => "Drag over text; the highlight fits itself to the line.",
            Tool.Pencil => "Draw freehand; the line is smoothed when you let go.",
            Tool.Arrow or Tool.Line => "Drag to draw. Hold Shift to keep it straight.",
            _ => "Drag on the picture to draw.",
        }));
    }

    FrameworkElement Swatches()
    {
        var panel = new WrapPanel { Margin = new Thickness(0, 2, 0, 2) };
        void Chip(Rgba swatch, bool custom)
        {
            var chip = new Border
            {
                Width = 20, Height = 20, CornerRadius = new CornerRadius(10), Margin = new Thickness(0, 0, 5, 5), Cursor = Cursors.Hand,
                Background = new SolidColorBrush(Color.FromRgb((byte)(swatch.R * 255), (byte)(swatch.G * 255), (byte)(swatch.B * 255))),
                BorderBrush = swatch.Hex == color.Hex ? Ui.Brush("Accent") : Brushes.Gray,
                BorderThickness = new Thickness(swatch.Hex == color.Hex ? 3 : 1),
                ToolTip = "#" + swatch.Hex + (custom ? " (right-click to remove)" : ""),
            };
            chip.MouseLeftButtonUp += (_, _) => { color = swatch; BuildToolOptions(); };
            if (custom) chip.MouseRightButtonUp += (_, _) => { Settings.Current.CustomColors.Remove(swatch.Hex); Settings.Current.Save(); BuildToolOptions(); };
            panel.Children.Add(chip);
        }
        foreach (var s in Rgba.Swatches) Chip(s, false);
        foreach (var hex in Settings.Current.CustomColors) if (Parse(hex) is { } c) Chip(c, true);
        var pick = CaptureKit.IconButton("eyedropper", "Pick a colour from the screen or the picture", async () =>
        {
            if (await SelectionOverlay.PickColor() is { } hex && Parse(hex) is { } picked)
            {
                color = picked;
                Remember(hex);
                BuildToolOptions();
            }
        }, 14);
        pick.Padding = new Thickness(3);
        panel.Children.Add(pick);
        var add = CaptureKit.IconButton("add", "Save this colour to your palette", () => { Remember(color.Hex); BuildToolOptions(); }, 14);
        add.Padding = new Thickness(3);
        panel.Children.Add(add);
        return panel;
    }

    static void Remember(string hex)
    {
        var list = Settings.Current.CustomColors;
        if (Rgba.Swatches.Any(s => s.Hex == hex) || list.Contains(hex)) return;
        list.Add(hex);
        while (list.Count > 10) list.RemoveAt(0);
        Settings.Current.Save();
    }

    static Rgba? Parse(string hex)
    {
        hex = hex.Trim().TrimStart('#');
        if (hex.Length != 6 || !int.TryParse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var v)) return null;
        return new Rgba((v >> 16 & 0xFF) / 255.0, (v >> 8 & 0xFF) / 255.0, (v & 0xFF) / 255.0);
    }

    async Task LoadPreview()
    {
        status.Text = "Loading…";
        try
        {
            // Edit a smaller copy for the preview so sliders stay quick on big photos.
            var (path, width, height) = await Task.Run(() =>
            {
                using var image = ImageConverter.LoadFirst(job.Path);
                var (w, h) = ((int)image.Width, (int)image.Height);
                if (Math.Max(w, h) > 1600) image.Resize(new MagickGeometry(1600, 1600) { Greater = true });
                var temp = OutputPaths.TempFile("png");
                image.Write(temp, MagickFormat.Png);
                return (temp, w, h);
            });
            previewSource = path;
            (pixelWidth, pixelHeight) = (width, height);
            stage.Width = width > height ? 1600 : 1600.0 * width / height;
            stage.Height = width > height ? 1600.0 * height / width : 1600;
            checker.Background = BackgroundPanel.Checkerboard(32);
            try { previewPixels = await Task.Run(() => { using var m = ImageConverter.LoadFirst(path); return BgraImage.FromMagick(m); }); } catch { }
            history.AddRange(edit.Redactions);
            history.AddRange(edit.Annotations);
            history.AddRange(edit.Overlays);
            Update(edit);
            await Render();
        }
        catch (Exception e)
        {
            status.Text = $"Couldn't open the picture: {JobQueue.Describe(e)}";
        }
    }

    void Update(ImageEdit next)
    {
        edit = next;
        ApplyTransforms();
        DrawCrop();
        undoButton.IsEnabled = history.Count > 0;
        var crop = edit.Crop?.Pixels(pixelWidth, pixelHeight) ?? (0, 0, pixelWidth, pixelHeight);
        var (w, h) = edit.Turns % 2 == 1 ? (crop.Height, crop.Width) : (crop.Width, crop.Height);
        sizeLabel.Text = $"Saved at {Math.Max(1, (int)Math.Round(w * edit.Scale))} × {Math.Max(1, (int)Math.Round(h * edit.Scale))} pixels";
        renderTimer.Stop();
        renderTimer.Start();
    }

    void Undo()
    {
        if (history.Count == 0) return;
        var last = history[^1];
        history.RemoveAt(history.Count - 1);
        Update(last switch
        {
            Redaction r => edit with { Redactions = edit.Redactions.Where(x => !ReferenceEquals(x, r)).ToList() },
            Annotation a => edit with { Annotations = edit.Annotations.Where(x => !ReferenceEquals(x, a)).ToList() },
            PlacedImage p => edit with { Overlays = edit.Overlays.Where(x => !ReferenceEquals(x, p)).ToList() },
            _ => edit,
        });
    }

    async Task Render()
    {
        if (previewSource is null) return;
        var generation = ++renderGeneration;
        // Marks and colours only; the crop, turns and size are shown by the preview itself.
        var previewEdit = edit with { Crop = null, QuarterTurns = 0, FlipHorizontal = false, FlipVertical = false, Scale = 1 };
        var source = previewSource;
        var background = previewEdit.Background is { Mode: not BackgroundMode.Keep };
        if (background) status.Text = "Finding the subject…";
        try
        {
            var bitmap = await Task.Run(() =>
            {
                using var image = ImageEditEngine.Render(source, previewEdit);
                return Editors.Pixels(image);
            });
            if (generation != renderGeneration) return;
            picture.Source = bitmap;
            checker.Visibility = previewEdit.Background is { KeepsTransparency: true } ? Visibility.Visible : Visibility.Collapsed;
            status.Text = $"{pixelWidth} × {pixelHeight}";
            RenderedBackground = background;
            RenderCount++;
        }
        catch (Exception e)
        {
            status.Text = JobQueue.Describe(e);
        }
    }

    void ApplyTransforms()
    {
        var group = new TransformGroup();
        group.Children.Add(new ScaleTransform(edit.FlipHorizontal ? -1 : 1, edit.FlipVertical ? -1 : 1));
        group.Children.Add(new RotateTransform(edit.Turns * 90));
        stage.LayoutTransform = group;
        stage.RenderTransformOrigin = new Point(0.5, 0.5);
    }

    void DrawCrop()
    {
        if (edit.Crop is not { } crop || crop.IsFull) { cropShade.Data = null; return; }
        double w = stage.Width, h = stage.Height;
        var outside = new RectangleGeometry(new Rect(0, 0, w, h));
        var inside = new RectangleGeometry(new Rect(crop.X * w, crop.Y * h, crop.Width * w, crop.Height * h));
        cropShade.Data = new CombinedGeometry(GeometryCombineMode.Exclude, outside, inside);
    }

    NormPoint Norm(Point p) => new NormPoint(p.X / stage.Width, p.Y / stage.Height).Clamped;
    Brush Ink => new SolidColorBrush(Color.FromArgb((byte)(color.A * 255), (byte)(color.R * 255), (byte)(color.G * 255), (byte)(color.B * 255)));
    double LineWidth => Math.Max(1, sizeLevel * 0.002 * stage.Height);

    void OnDown(object sender, MouseButtonEventArgs e)
    {
        var p = e.GetPosition(overlay);
        if (typing is not null) { CommitText(); return; }
        switch (tool)
        {
            case Tool.Text: StartTyping(p); e.Handled = true; return;
            case Tool.Step:
                var number = edit.Annotations.Count(a => a.Kind == AnnotationKind.Step) + 1;
                AddMark(new Annotation(AnnotationKind.Step, Norm(p), Norm(p), color, sizeLevel * 0.012, number.ToString(CultureInfo.InvariantCulture)));
                return;
        }
        dragFrom = p;
        overlay.CaptureMouse();
        stroke.Clear();
        if (tool == Tool.Pencil)
        {
            stroke.Add(Norm(p));
            livePencil.Points = [p];
            livePencil.Stroke = Ink;
            livePencil.StrokeThickness = LineWidth;
            livePencil.Visibility = Visibility.Visible;
        }
        else if (tool is Tool.Arrow or Tool.Line)
        {
            (liveLine.X1, liveLine.Y1, liveLine.X2, liveLine.Y2) = (p.X, p.Y, p.X, p.Y);
            liveLine.Stroke = Ink;
            liveLine.StrokeThickness = LineWidth;
            liveLine.Visibility = Visibility.Visible;
        }
        else if (tool == Tool.Oval)
        {
            liveOval.Stroke = Ink;
            liveOval.StrokeThickness = LineWidth;
            liveOval.Width = liveOval.Height = 0;
            Canvas.SetLeft(liveOval, p.X);
            Canvas.SetTop(liveOval, p.Y);
            liveOval.Visibility = Visibility.Visible;
        }
        else
        {
            Canvas.SetLeft(rubber, p.X);
            Canvas.SetTop(rubber, p.Y);
            rubber.Width = rubber.Height = 0;
            rubber.Visibility = Visibility.Visible;
        }
    }

    void OnMove(object sender, MouseEventArgs e)
    {
        if (dragFrom is not { } from) return;
        var p = e.GetPosition(overlay);
        p = new Point(Math.Clamp(p.X, 0, stage.Width), Math.Clamp(p.Y, 0, stage.Height));
        // Shift keeps lines straight across, down or diagonal.
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift) && tool is Tool.Arrow or Tool.Line)
        {
            var dx = p.X - from.X; var dy = p.Y - from.Y;
            var angle = Math.Round(Math.Atan2(dy, dx) / (Math.PI / 4)) * (Math.PI / 4);
            var length = Math.Sqrt(dx * dx + dy * dy);
            p = new Point(from.X + Math.Cos(angle) * length, from.Y + Math.Sin(angle) * length);
        }
        switch (tool)
        {
            case Tool.Pencil:
                stroke.Add(Norm(p));
                livePencil.Points.Add(p);
                return;
            case Tool.Arrow or Tool.Line:
                (liveLine.X2, liveLine.Y2) = (p.X, p.Y);
                return;
            case Tool.Oval:
                Canvas.SetLeft(liveOval, Math.Min(from.X, p.X));
                Canvas.SetTop(liveOval, Math.Min(from.Y, p.Y));
                liveOval.Width = Math.Abs(p.X - from.X);
                liveOval.Height = Math.Abs(p.Y - from.Y);
                return;
            case Tool.Crop:
                var r = Markup.Crop(Norm(from), Norm(p), pixelWidth, pixelHeight, Markup.CropShapes[cropShape].Ratio);
                Canvas.SetLeft(rubber, r.X * stage.Width);
                Canvas.SetTop(rubber, r.Y * stage.Height);
                rubber.Width = r.Width * stage.Width;
                rubber.Height = r.Height * stage.Height;
                return;
        }
        Canvas.SetLeft(rubber, Math.Min(from.X, p.X));
        Canvas.SetTop(rubber, Math.Min(from.Y, p.Y));
        rubber.Width = Math.Abs(p.X - from.X);
        rubber.Height = Math.Abs(p.Y - from.Y);
    }

    void OnUp(object sender, MouseButtonEventArgs e)
    {
        if (dragFrom is not { } from) return;
        dragFrom = null;
        overlay.ReleaseMouseCapture();
        rubber.Visibility = liveLine.Visibility = liveOval.Visibility = livePencil.Visibility = Visibility.Collapsed;
        var a = Norm(from);
        var b = tool is Tool.Arrow or Tool.Line ? Norm(new Point(liveLine.X2, liveLine.Y2)) : Norm(e.GetPosition(overlay));
        var rect = NormRect.Between(a, b);
        var tiny = rect.Width < 0.01 && rect.Height < 0.01;
        var line = sizeLevel * 0.002;
        switch (tool)
        {
            case Tool.Crop:
                var crop = Markup.Crop(a, b, pixelWidth, pixelHeight, Markup.CropShapes[cropShape].Ratio);
                if (crop.Width < 0.02 || crop.Height < 0.02) return;
                Update(edit with { Crop = crop });
                break;
            case Tool.Hide:
                if (tiny) return;
                AddMark(new Redaction(rect, redactionStyle));
                break;
            case Tool.Pencil:
                if (stroke.Count == 0) return;
                var smooth = Markup.Smooth(stroke);
                AddMark(new Annotation(AnnotationKind.Pencil, smooth[0], smooth[^1], color, line, Points: smooth));
                break;
            case Tool.Highlight:
                if (tiny) return;
                var fitted = previewPixels is null ? rect : Markup.FitHighlight(previewPixels, rect);
                AddMark(new Annotation(AnnotationKind.Highlight, new NormPoint(fitted.X, fitted.Y), new NormPoint(fitted.MaxX, fitted.MaxY), color, line));
                break;
            default:
                if (tiny) return;
                var kind = tool switch
                {
                    Tool.Arrow => AnnotationKind.Arrow, Tool.Line => AnnotationKind.Line, Tool.Box => AnnotationKind.Rectangle, Tool.Filled => AnnotationKind.FilledRectangle,
                    Tool.Oval => AnnotationKind.Ellipse, Tool.Spotlight => AnnotationKind.Spotlight, _ => AnnotationKind.Rectangle,
                };
                AddMark(new Annotation(kind, a, b, color, line, Style: tool == Tool.Arrow ? (int)arrowStyle : 0));
                break;
        }
    }

    // Text typed right on the picture.

    NormPoint typingAt;

    void StartTyping(Point p)
    {
        typingAt = Norm(p);
        typing = new TextBox
        {
            FontSize = Math.Max(10, sizeLevel * 0.012 * stage.Height), FontWeight = FontWeights.Bold, Foreground = Ink, Background = new SolidColorBrush(Color.FromArgb(0x40, 0xFF, 0xFF, 0xFF)),
            BorderBrush = Brushes.White, BorderThickness = new Thickness(1), MinWidth = 60, AcceptsReturn = true, Padding = new Thickness(0),
        };
        Canvas.SetLeft(typing, p.X);
        Canvas.SetTop(typing, p.Y);
        typing.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter && !Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) { CommitText(); e.Handled = true; }
            else if (e.Key == Key.Escape) { CancelTyping(); e.Handled = true; }
        };
        typing.LostKeyboardFocus += (_, _) => CommitText();
        overlay.Children.Add(typing);
        Dispatcher.BeginInvoke(() => typing?.Focus(), DispatcherPriority.Input);
    }

    void CommitText()
    {
        if (typing is not { } box) return;
        typing = null;
        overlay.Children.Remove(box);
        var text = box.Text.TrimEnd();
        if (text.Trim().Length == 0) return;
        var preset = Markup.TextPresets[textPreset];
        AddMark(new Annotation(AnnotationKind.Text, typingAt, typingAt, color, sizeLevel * 0.012, text, (int)preset.Style));
    }

    void CancelTyping()
    {
        if (typing is not { } box) return;
        typing = null;
        overlay.Children.Remove(box);
    }

    void AddMark(object mark)
    {
        history.Add(mark);
        Update(mark switch
        {
            Redaction r => edit with { Redactions = [.. edit.Redactions, r] },
            Annotation a => edit with { Annotations = [.. edit.Annotations, a] },
            PlacedImage p => edit with { Overlays = [.. edit.Overlays, p] },
            _ => edit,
        });
    }

    // Other pictures placed on this one.

    void OnDrop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] files) return;
        var at = Norm(e.GetPosition(overlay));
        foreach (var file in files.Where(f => Kinds.Of(f) == FileKind.Image))
        {
            Place(file, at);
            at = new NormPoint(Math.Min(0.9, at.X + 0.04), Math.Min(0.9, at.Y + 0.04));
        }
    }

    void AddPicture()
    {
        var dialog = new OpenFileDialog { Filter = "Pictures|*.png;*.jpg;*.jpeg;*.webp;*.heic;*.bmp;*.gif;*.tif;*.tiff|All files|*.*", Multiselect = true, Title = "Place a picture" };
        if (dialog.ShowDialog(this) != true) return;
        foreach (var file in dialog.FileNames) Place(file, new NormPoint(0.5, 0.5));
    }

    void Place(string file, NormPoint centre)
    {
        try
        {
            var info = new MagickImageInfo(file);
            // About 40% of the width (or 60% of the height, for tall pictures), keeping its shape.
            var aspect = (double)info.Height / Math.Max(1, info.Width) * pixelWidth / Math.Max(1, pixelHeight);
            double w = 0.4, h = w * aspect;
            if (h > 0.6) { h = 0.6; w = h / aspect; }
            var rect = new NormRect(Math.Clamp(centre.X - w / 2, 0, Math.Max(0, 1 - w)), Math.Clamp(centre.Y - h / 2, 0, Math.Max(0, 1 - h)), w, h);
            AddMark(new PlacedImage(file, rect));
        }
        catch (Exception e) { status.Text = $"Couldn't place {System.IO.Path.GetFileName(file)}: {e.Message}"; }
    }

    // Results

    async Task<string> RenderToFile(string folder)
    {
        var current = edit;
        var input = job.Path;
        return await Task.Run(() =>
        {
            using var image = ImageEditEngine.Render(input, current);
            var format = ImageEditEngine.FormatFor(current, input);
            var output = OutputPaths.Destination(input, format.Extension(), "edited", folder);
            image.Write(output, ImageConverter.MagickFormatFor(format));
            return output;
        });
    }

    async Task CopyResult()
    {
        try
        {
            var file = await RenderToFile(OutputPaths.TempDir());
            CaptureKit.CopyImage(file);
            status.Text = "Copied";
        }
        catch (Exception e) { status.Text = JobQueue.Describe(e); }
    }

    async Task Save()
    {
        if (!InCaptureStore)
        {
            Editors.Run(job, new JobOperation.EditImage(edit));
            Close();
            return;
        }
        // Captures that only live in the history are saved to the screenshots folder.
        try
        {
            Directory.CreateDirectory(CaptureKit.CaptureFolder);
            var file = await RenderToFile(CaptureKit.CaptureFolder);
            if (Settings.Current.CaptureCopy) { try { CaptureKit.CopyImage(file); } catch { } }
            Toast.Show("Saved", System.IO.Path.GetFileName(file), action: ("Show in folder", () => Native.RevealInExplorer([file])));
            Close();
        }
        catch (Exception e) { status.Text = JobQueue.Describe(e); }
    }

    void SaveProject()
    {
        var dialog = new SaveFileDialog
        {
            Filter = "Spinform project|*" + ImageProject.Extension, Title = "Save project",
            FileName = projectPath is not null ? System.IO.Path.GetFileName(projectPath) : System.IO.Path.GetFileNameWithoutExtension(job.Path) + ImageProject.Extension,
            InitialDirectory = projectPath is not null ? System.IO.Path.GetDirectoryName(projectPath) : InCaptureStore ? CaptureKit.CaptureFolder : System.IO.Path.GetDirectoryName(job.Path),
        };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            ImageProject.Save(dialog.FileName, job.Path, edit);
            status.Text = "Project saved";
        }
        catch (Exception e) { status.Text = $"Couldn't save the project: {e.Message}"; }
    }

    /// For the smoke test: a set of marks showing every kind.
    public void ShowSampleMarks()
    {
        var marks = new object[]
        {
            new Annotation(AnnotationKind.Arrow, new(0.08, 0.15), new(0.3, 0.34), Rgba.Red, 0.008),
            new Annotation(AnnotationKind.Arrow, new(0.72, 0.12), new(0.55, 0.3), Rgba.Blue, 0.008, Style: (int)ArrowStyle.Curved),
            new Annotation(AnnotationKind.Rectangle, new(0.34, 0.36), new(0.62, 0.6), Rgba.Red, 0.006),
            new Annotation(AnnotationKind.Ellipse, new(0.66, 0.6), new(0.92, 0.86), Rgba.Green, 0.006),
            new Annotation(AnnotationKind.Step, new(0.36, 0.38), new(0.36, 0.38), Rgba.Red, 0.04, "1"),
            new Annotation(AnnotationKind.Step, new(0.68, 0.62), new(0.68, 0.62), Rgba.Green, 0.04, "2"),
            new Annotation(AnnotationKind.Text, new(0.06, 0.72), new(0.06, 0.72), Rgba.Blue, 0.05, "Click here", (int)TextStyle.Label),
            new Annotation(AnnotationKind.Highlight, new(0.06, 0.06), new(0.4, 0.11), Rgba.Yellow, 0.006),
            new Annotation(AnnotationKind.Pencil, new(0.1, 0.9), new(0.4, 0.92), Rgba.Orange, 0.006,
                Points: Markup.Smooth([new(0.1, 0.9), new(0.15, 0.86), new(0.2, 0.93), new(0.27, 0.87), new(0.33, 0.94), new(0.4, 0.9)])),
            new Redaction(new NormRect(0.7, 0.36, 0.22, 0.12), RedactionStyle.Pixelate),
        };
        foreach (var m in marks) AddMark(m);
        SelectTool(Tool.Arrow);
    }
}
