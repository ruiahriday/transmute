using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using Ellipse = System.Windows.Shapes.Ellipse;

namespace Transmute.App;

/// Settings → Customize wheels: pick which bubbles each wheel shows for each kind of file, and
/// where. Drag a bubble onto another position to swap them, or use the list. Saves as you go.
sealed class WheelEditorWindow : Window
{
    static WheelEditorWindow? open;

    /// True while a bubble is being dragged here, so the drag watcher doesn't open a wheel for it.
    public static bool IsDragging { get; private set; }

    const double PreviewSize = 330, Radius = 118, Largest = 62;
    const string SlotFormat = "TransmuteWheelSlot";

    static Settings Prefs => Settings.Current;

    readonly Dictionary<WheelKind, RadioButton> wheelTabs = [];
    readonly ComboBox kindBox = new() { MinWidth = 170 };
    readonly Canvas preview = new() { Width = PreviewSize, Height = PreviewSize, Background = Brushes.Transparent };
    readonly ListBox list = new() { BorderThickness = new Thickness(1), MinHeight = 200 };
    readonly Button addButton = new() { Content = "＋ Add…", HorizontalAlignment = HorizontalAlignment.Left };
    readonly TextBlock status = new() { Style = (Style)Application.Current.FindResource("Caption"), Margin = new Thickness(0, 6, 0, 0) };

    WheelKind wheel = WheelKind.Convert;
    FileKind kind = FileKind.Document;
    List<string> slots = [];
    int selected = -1;
    Point dragStart;
    int pressed = -1;

    public static WheelEditorWindow Open(Window? owner = null)
    {
        if (open is not null) { open.Activate(); return open; }
        open = new WheelEditorWindow();
        if (owner is { IsVisible: true }) { open.Owner = owner; open.WindowStartupLocation = WindowStartupLocation.CenterOwner; }
        else open.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        open.Closed += (_, _) => open = null;
        open.Show();
        open.Activate();
        return open;
    }

    WheelEditorWindow()
    {
        Title = "Customize Drag Wheels";
        Width = 780;
        Height = 600;
        MinWidth = 640;
        MinHeight = 480;
        Style = (Style)Application.Current.FindResource("BaseWindow");
        ShowInTaskbar = false;
        try { Icon = new System.Windows.Media.Imaging.BitmapImage(new Uri("pack://application:,,,/Assets/app.ico")); } catch { }

        // Wheel tabs and the kind of file.
        var tabs = new StackPanel { Orientation = Orientation.Horizontal };
        var tabBack = new Border { Background = new SolidColorBrush(Color.FromRgb(0xE8, 0xE8, 0xE8)), CornerRadius = new CornerRadius(7), Child = tabs, HorizontalAlignment = HorizontalAlignment.Left };
        foreach (var w in Enum.GetValues<WheelKind>())
        {
            var tab = new RadioButton { Style = (Style)Application.Current.FindResource("Segment"), GroupName = "wheel", IsChecked = w == wheel };
            tab.Checked += (_, _) => { wheel = w; Load(); };
            wheelTabs[w] = tab;
            tabs.Children.Add(tab);
        }
        foreach (var k in Enum.GetValues<FileKind>()) kindBox.Items.Add(new ComboBoxItem { Content = k.Title(), Tag = k });
        kindBox.SelectedIndex = (int)kind;
        kindBox.SelectionChanged += (_, _) =>
        {
            if (kindBox.SelectedItem is ComboBoxItem { Tag: FileKind k }) { kind = k; Load(); }
        };
        var kindRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 10, 0, 0) };
        kindRow.Children.Add(new TextBlock { Text = "When I drag", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) });
        kindRow.Children.Add(kindBox);
        var top = new StackPanel { Margin = new Thickness(20, 16, 20, 4) };
        top.Children.Add(tabBack);
        top.Children.Add(kindRow);
        top.Children.Add(new TextBlock
        {
            Style = (Style)Application.Current.FindResource("Caption"),
            Margin = new Thickness(0, 8, 0, 0),
            Text = "Drag a bubble onto another spot to swap them. Positions go clockwise from the top. Any format, tool or action can go on any wheel, and changes save right away.",
        });

        // The preview on the left, the list on the right.
        var previewCard = new Border
        {
            Background = Brushes.White,
            CornerRadius = new CornerRadius(8),
            BorderBrush = (Brush)Application.Current.FindResource("Line"),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(6),
            Child = preview,
            VerticalAlignment = VerticalAlignment.Top,
        };
        list.SelectionChanged += (_, _) =>
        {
            if (list.SelectedIndex == selected) return;
            selected = list.SelectedIndex;
            DrawPreview();
        };
        addButton.Click += (_, _) => ShowAddMenu();
        // Bubbles are redrawn when one is picked, so the drag is followed on the canvas under them.
        preview.MouseLeftButtonUp += (_, _) => pressed = -1;
        preview.MouseMove += (_, e) =>
        {
            if (pressed < 0 || e.LeftButton != MouseButtonState.Pressed) { pressed = -1; return; }
            var moved = e.GetPosition(preview) - dragStart;
            if (Math.Abs(moved.X) < SystemParameters.MinimumHorizontalDragDistance && Math.Abs(moved.Y) < SystemParameters.MinimumVerticalDragDistance) return;
            var from = pressed;
            pressed = -1;
            IsDragging = true;
            try { DragDrop.DoDragDrop(preview, new DataObject(SlotFormat, from), DragDropEffects.Move); }
            finally { IsDragging = false; }
        };
        var right = new DockPanel { Margin = new Thickness(16, 0, 0, 0) };
        var listTitle = new TextBlock { Text = "On the wheel (clockwise from the top)", FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 6) };
        DockPanel.SetDock(listTitle, Dock.Top);
        var listFooter = new StackPanel();
        listFooter.Children.Add(addButton);
        listFooter.Children.Add(status);
        DockPanel.SetDock(listFooter, Dock.Bottom);
        listFooter.Margin = new Thickness(0, 8, 0, 0);
        right.Children.Add(listTitle);
        right.Children.Add(listFooter);
        right.Children.Add(list);
        var body = new DockPanel { Margin = new Thickness(20, 10, 20, 14) };
        DockPanel.SetDock(previewCard, Dock.Left);
        body.Children.Add(previewCard);
        body.Children.Add(right);

        // Bottom bar.
        var reset = new Button { Content = "Reset to default" };
        reset.Click += (_, _) => { Prefs.WheelLayouts.Remove(WheelLayout.Key(wheel, kind)); Prefs.Save(); Load(); };
        var resetAll = new Button { Content = "Reset all wheels", Margin = new Thickness(8, 0, 0, 0) };
        resetAll.Click += (_, _) =>
        {
            if (MessageBox.Show(this, "Put every wheel back the way Spinform came?", "Spinform", MessageBoxButton.OKCancel) != MessageBoxResult.OK) return;
            Prefs.WheelLayouts.Clear();
            Prefs.Save();
            Load();
        };
        var done = new Button { Content = "Done", Style = (Style)Application.Current.FindResource("Primary"), MinWidth = 90, IsDefault = true, IsCancel = true };
        done.Click += (_, _) => Close();
        var bar = new DockPanel();
        DockPanel.SetDock(done, Dock.Right);
        bar.Children.Add(done);
        var resets = new StackPanel { Orientation = Orientation.Horizontal };
        resets.Children.Add(reset);
        resets.Children.Add(resetAll);
        bar.Children.Add(resets);
        var bottom = new Border
        {
            Background = (Brush)Application.Current.FindResource("Card"),
            BorderBrush = (Brush)Application.Current.FindResource("Line"),
            BorderThickness = new Thickness(0, 1, 0, 0),
            Padding = new Thickness(16, 10, 16, 10),
            Child = bar,
        };

        var root = new DockPanel();
        DockPanel.SetDock(bottom, Dock.Bottom);
        DockPanel.SetDock(top, Dock.Top);
        root.Children.Add(bottom);
        root.Children.Add(top);
        root.Children.Add(body);
        Content = root;
        Load();
    }

    /// Opens on a particular wheel and kind of file.
    public void Select(WheelKind wheel, FileKind kind)
    {
        kindBox.SelectedIndex = (int)kind;
        wheelTabs[wheel].IsChecked = true;
        this.wheel = wheel;
        this.kind = kind;
        Load();
    }

    bool IsCustom => Prefs.WheelLayouts.ContainsKey(WheelLayout.Key(wheel, kind));

    void Load()
    {
        foreach (var (w, tab) in wheelTabs)
        {
            var key = Prefs.KeyFor(w);
            tab.Content = key == WheelKey.Off ? w.Title() : $"{w.Title()}  ({key.Label()})";
        }
        slots = Prefs.WheelLayouts.TryGetValue(WheelLayout.Key(wheel, kind), out var saved)
            ? WheelLayout.Clean(saved, kind)
            : WheelLayout.Default(wheel, kind);
        selected = -1;
        Refresh();
    }

    void Save()
    {
        var key = WheelLayout.Key(wheel, kind);
        if (slots.SequenceEqual(WheelLayout.Default(wheel, kind))) Prefs.WheelLayouts.Remove(key);
        else Prefs.WheelLayouts[key] = [.. slots];
        Prefs.Save();
    }

    void Change(Action edit, int select)
    {
        edit();
        selected = select;
        Save();
        Refresh();
    }

    void Refresh()
    {
        list.Items.Clear();
        for (var i = 0; i < slots.Count; i++) list.Items.Add(Row(i));
        list.SelectedIndex = selected;
        addButton.IsEnabled = slots.Count < WheelLayout.MaxSlots;
        var real = slots.Count(id => id != WheelLayout.Gap);
        status.Text = (real, IsCustom) switch
        {
            (0, _) => $"Nothing on this wheel, so it won't open for {kind.Title().ToLowerInvariant()}.",
            (_, true) => $"Customized. {slots.Count} of {WheelLayout.MaxSlots} spots used.",
            _ => $"The default wheel. {slots.Count} of {WheelLayout.MaxSlots} spots used.",
        };
        DrawPreview();
    }

    FrameworkElement Row(int index)
    {
        var id = slots[index];
        var name = new TextBlock { Text = $"{index + 1}.  {WheelItems.Describe(id)}", VerticalAlignment = VerticalAlignment.Center };
        if (id == WheelLayout.Gap) name.Foreground = (Brush)Application.Current.FindResource("Secondary");
        Button Small(string text, string tip, bool enabled, Action click)
        {
            var b = new Button { Content = text, ToolTip = tip, Style = (Style)Application.Current.FindResource("Flat"), IsEnabled = enabled, MinWidth = 28, Padding = new Thickness(4, 1, 4, 1) };
            b.Click += (_, e) => { e.Handled = true; click(); };
            return b;
        }
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        buttons.Children.Add(Small("▲", "Move up (anticlockwise)", index > 0, () => Change(() => (slots[index - 1], slots[index]) = (slots[index], slots[index - 1]), index - 1)));
        buttons.Children.Add(Small("▼", "Move down (clockwise)", index < slots.Count - 1, () => Change(() => (slots[index + 1], slots[index]) = (slots[index], slots[index + 1]), index + 1)));
        buttons.Children.Add(Small("✕", "Remove from the wheel", true, () => Change(() => slots.RemoveAt(index), -1)));
        var row = new DockPanel { LastChildFill = true, MinWidth = 300 };
        DockPanel.SetDock(buttons, Dock.Right);
        row.Children.Add(buttons);
        row.Children.Add(name);
        return row;
    }

    void ShowAddMenu()
    {
        var menu = new ContextMenu { PlacementTarget = addButton, Placement = PlacementMode.Bottom };
        var unused = WheelLayout.Available(kind).Where(id => !slots.Contains(id)).ToList();
        void Group(string title, string prefix)
        {
            var group = new MenuItem { Header = title };
            foreach (var id in unused.Where(id => id.StartsWith(prefix)))
            {
                var item = new MenuItem { Header = WheelItems.Describe(id) };
                item.Click += (_, _) => Add(id);
                group.Items.Add(item);
            }
            group.IsEnabled = group.Items.Count > 0;
            menu.Items.Add(group);
        }
        Group("Formats", "convert:");
        Group("Tools", "tool:");
        Group("Actions", "action:");
        menu.Items.Add(new Separator());
        var gap = new MenuItem { Header = "Empty space" };
        gap.Click += (_, _) => Add(WheelLayout.Gap);
        menu.Items.Add(gap);
        menu.IsOpen = true;
    }

    void Add(string id)
    {
        if (slots.Count >= WheelLayout.MaxSlots) return;
        // Into the first empty space if there is one, otherwise at the end.
        var at = id == WheelLayout.Gap ? -1 : slots.IndexOf(WheelLayout.Gap);
        Change(() => { if (at >= 0) slots[at] = id; else slots.Add(id); }, at >= 0 ? at : slots.Count);
    }

    void DrawPreview()
    {
        preview.Children.Clear();
        var ringSize = (Radius + Largest / 2 + 10) * 2;
        var ring = new Ellipse
        {
            Width = ringSize,
            Height = ringSize,
            Fill = new SolidColorBrush(Color.FromRgb(0xF4, 0xF4, 0xF4)),
            Stroke = new SolidColorBrush(Color.FromArgb(0x30, 0, 0, 0)),
        };
        Canvas.SetLeft(ring, (PreviewSize - ringSize) / 2);
        Canvas.SetTop(ring, (PreviewSize - ringSize) / 2);
        preview.Children.Add(ring);

        var caption = new TextBlock { Text = wheel.Title(), FontSize = 14, FontWeight = FontWeights.SemiBold, Width = 120, TextAlignment = TextAlignment.Center };
        Canvas.SetLeft(caption, (PreviewSize - 120) / 2);
        Canvas.SetTop(caption, PreviewSize / 2 - 10);
        preview.Children.Add(caption);

        var size = WheelWindow.BubbleSize(slots.Count, Radius, Largest);
        for (var i = 0; i < slots.Count; i++)
        {
            var bubble = Bubble(i, size);
            var (x, y) = WheelWindow.Position(i, slots.Count, Radius);
            Canvas.SetLeft(bubble, PreviewSize / 2 + x - size / 2);
            Canvas.SetTop(bubble, PreviewSize / 2 + y - size / 2);
            preview.Children.Add(bubble);
        }
    }

    Border Bubble(int index, double size)
    {
        var id = slots[index];
        var accent = (Brush)Application.Current.FindResource("Accent");
        var item = WheelItems.Item(id);
        var stack = new StackPanel { VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false };
        if (item is not null)
        {
            stack.Children.Add(new TextBlock { Text = item.Glyph, FontSize = 15, HorizontalAlignment = HorizontalAlignment.Center, FontFamily = new FontFamily("Segoe UI Emoji, Segoe UI Symbol, Segoe UI") });
            stack.Children.Add(new TextBlock { Text = item.Label, FontSize = 10, FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = size - 6 });
        }
        else stack.Children.Add(new TextBlock { Text = "empty", FontSize = 10, Foreground = Brushes.Gray, HorizontalAlignment = HorizontalAlignment.Center });
        var isSelected = index == selected;
        var bubble = new Border
        {
            Width = size,
            Height = size,
            CornerRadius = new CornerRadius(size / 2),
            Background = item is null ? Brushes.Transparent : Brushes.White,
            BorderBrush = isSelected ? accent : new SolidColorBrush(Color.FromArgb(item is null ? (byte)0x60 : (byte)0x30, 0, 0, 0)),
            BorderThickness = new Thickness(isSelected ? 2.5 : 1),
            Child = stack,
            AllowDrop = true,
            Cursor = Cursors.SizeAll,
            ToolTip = WheelItems.Describe(id),
        };
        bubble.MouseLeftButtonDown += (_, e) =>
        {
            dragStart = e.GetPosition(preview);
            pressed = index;
            selected = index;
            list.SelectedIndex = index;
            DrawPreview();
            e.Handled = true;
        };
        bubble.DragOver += (_, e) =>
        {
            e.Effects = e.Data.GetDataPresent(SlotFormat) ? DragDropEffects.Move : DragDropEffects.None;
            e.Handled = true;
        };
        bubble.Drop += (_, e) =>
        {
            e.Handled = true;
            if (e.Data.GetData(SlotFormat) is not int from || from == index || from >= slots.Count) return;
            // Dispatch so the drag finishes before the bubbles are rebuilt.
            Dispatcher.BeginInvoke(() => Move(from, index));
        };
        return bubble;
    }

    /// Swaps two positions, as when one bubble is dropped on another.
    public void Move(int from, int to) =>
        Change(() => (slots[from], slots[to]) = (slots[to], slots[from]), to);
}
