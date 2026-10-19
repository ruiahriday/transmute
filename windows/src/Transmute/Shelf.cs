using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;

namespace Transmute.App;

/// Floating files: a small always-on-top shelf to park files on while you switch windows,
/// then drag them out again. The list survives restarts.
public sealed class Shelf
{
    public static Shelf Shared { get; } = new();

    public ObservableCollection<string> Files { get; } = [];
    ShelfWindow? window;

    Shelf()
    {
        foreach (var path in Settings.Current.ShelfFiles.Where(p => File.Exists(p) || Directory.Exists(p))) Files.Add(path);
    }

    public bool IsVisible => window?.IsVisible == true;

    public void Add(IEnumerable<string> paths)
    {
        foreach (var path in paths)
            if (!Files.Contains(path, StringComparer.OrdinalIgnoreCase)) Files.Add(path);
        Save();
        Show();
    }

    public void Remove(string path)
    {
        Files.Remove(path);
        Save();
    }

    public void Clear()
    {
        Files.Clear();
        Save();
    }

    public void Toggle()
    {
        if (IsVisible) window!.Hide();
        else Show();
    }

    /// Shows the shelf. With a point (in screen pixels), the shelf's top centre goes there, kept
    /// on screen, which puts it under the files being dragged.
    public void Show(Point? at = null)
    {
        window ??= new ShelfWindow(this);
        foreach (var gone in Files.Where(p => !File.Exists(p) && !Directory.Exists(p)).ToList()) Files.Remove(gone);
        Save();
        if (at is { } point) window.PlaceTopCentre(point);
        window.Show();
    }

    void Save()
    {
        Settings.Current.ShelfFiles = Files.ToList();
        Settings.Current.Save();
    }
}

sealed class ShelfWindow : Window
{
    readonly Shelf shelf;
    readonly ListBox list;
    readonly TextBlock count;
    readonly FrameworkElement empty;
    readonly Border highlight;
    Point dragStart;

    public ShelfWindow(Shelf shelf)
    {
        this.shelf = shelf;
        Title = "Floating Files";
        Width = 270;
        Height = 360;
        MinWidth = 220;
        MinHeight = 240;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        WindowStyle = WindowStyle.ToolWindow;
        AllowDrop = true;
        Style = (Style)Application.Current.FindResource("BaseWindow");

        list = new ListBox { ItemsSource = shelf.Files, BorderThickness = new Thickness(0), Background = Brushes.Transparent, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        ScrollViewer.SetHorizontalScrollBarVisibility(list, ScrollBarVisibility.Disabled);
        list.ItemTemplate = RowTemplate();
        list.PreviewMouseLeftButtonDown += (_, e) => dragStart = e.GetPosition(null);
        list.PreviewMouseMove += OnMouseMove;
        list.MouseDoubleClick += (_, _) => { if (list.SelectedItem is string path) Native.Open(path); };
        list.ContextMenu = Menu();

        empty = new TextBlock
        {
            Text = "Drop files here to keep them handy, then drag them out wherever you need them.",
            TextWrapping = TextWrapping.Wrap,
            TextAlignment = TextAlignment.Center,
            Foreground = (Brush)Application.Current.FindResource("Secondary"),
            Margin = new Thickness(24),
            VerticalAlignment = VerticalAlignment.Center,
            IsHitTestVisible = false,
        };
        count = new TextBlock { VerticalAlignment = VerticalAlignment.Center, Style = (Style)Application.Current.FindResource("Caption") };
        var clear = new Button { Content = "Clear", Padding = new Thickness(10, 2, 10, 2), MinHeight = 24 };
        clear.Click += (_, _) => shelf.Clear();
        var footer = new DockPanel { Margin = new Thickness(8) };
        DockPanel.SetDock(clear, Dock.Right);
        footer.Children.Add(clear);
        footer.Children.Add(count);
        var footerBorder = new Border { Child = footer, BorderBrush = (Brush)Application.Current.FindResource("Line"), BorderThickness = new Thickness(0, 1, 0, 0), Background = (Brush)Application.Current.FindResource("Card") };

        highlight = new Border { BorderBrush = (Brush)Application.Current.FindResource("Accent"), BorderThickness = new Thickness(3), CornerRadius = new CornerRadius(8), Margin = new Thickness(3), Visibility = Visibility.Collapsed, IsHitTestVisible = false };
        var body = new Grid();
        body.Children.Add(list);
        body.Children.Add(empty);
        body.Children.Add(highlight);
        var root = new DockPanel();
        DockPanel.SetDock(footerBorder, Dock.Bottom);
        root.Children.Add(footerBorder);
        root.Children.Add(body);
        Content = root;

        DragEnter += OnDragOver;
        DragOver += OnDragOver;
        DragLeave += (_, _) => highlight.Visibility = Visibility.Collapsed;
        Drop += (_, e) =>
        {
            highlight.Visibility = Visibility.Collapsed;
            if (e.Data.GetData(DataFormats.FileDrop) is string[] paths) shelf.Add(paths);
        };
        shelf.Files.CollectionChanged += (_, _) => Refresh();
        Closing += (_, e) => { e.Cancel = true; Hide(); };
        LocationChanged += (_, _) => SaveBounds();
        SizeChanged += (_, _) => SaveBounds();
        RestoreBounds();
        Refresh();
    }

    void Refresh()
    {
        var n = shelf.Files.Count;
        count.Text = n == 1 ? "1 file" : $"{n} files";
        empty.Visibility = n == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    void OnDragOver(object sender, DragEventArgs e)
    {
        // Our own items being dragged out shouldn't light up the shelf.
        var files = e.Data.GetDataPresent(DataFormats.FileDrop) && !e.Data.GetDataPresent("TransmuteShelf");
        e.Effects = files ? DragDropEffects.Copy : DragDropEffects.None;
        highlight.Visibility = files ? Visibility.Visible : Visibility.Collapsed;
        e.Handled = true;
    }

    void OnMouseMove(object sender, MouseEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed) return;
        var moved = e.GetPosition(null) - dragStart;
        if (Math.Abs(moved.X) < SystemParameters.MinimumHorizontalDragDistance && Math.Abs(moved.Y) < SystemParameters.MinimumVerticalDragDistance) return;
        var item = (e.OriginalSource as DependencyObject)?.FindAncestor<ListBoxItem>();
        if (item?.DataContext is not string path) return;
        var selected = list.SelectedItems.Cast<string>().ToList();
        var paths = selected.Contains(path) ? selected : [path];
        var data = new DataObject(DataFormats.FileDrop, paths.ToArray());
        data.SetData("TransmuteShelf", true);
        DragDrop.DoDragDrop(item, data, DragDropEffects.Copy | DragDropEffects.Move | DragDropEffects.Link);
    }

    ContextMenu Menu()
    {
        var menu = new ContextMenu();
        void Add(string title, Action<string> action)
        {
            var item = new MenuItem { Header = title };
            item.Click += (_, _) => { if (list.SelectedItem is string path) action(path); };
            menu.Items.Add(item);
        }
        Add("Open", Native.Open);
        Add("Show in folder", p => Native.RevealInExplorer([p]));
        Add("Remove", shelf.Remove);
        return menu;
    }

    DataTemplate RowTemplate()
    {
        var template = new DataTemplate(typeof(string));
        var row = new FrameworkElementFactory(typeof(DockPanel));
        row.SetValue(MarginProperty, new Thickness(2, 3, 2, 3));
        var remove = new FrameworkElementFactory(typeof(Button));
        remove.SetValue(DockPanel.DockProperty, Dock.Right);
        remove.SetValue(ContentProperty, "✕");
        remove.SetValue(StyleProperty, Application.Current.FindResource("Flat"));
        remove.SetValue(ToolTipProperty, "Remove from shelf");
        remove.AddHandler(Button.ClickEvent, new RoutedEventHandler((s, _) => { if (((FrameworkElement)s).DataContext is string p) shelf.Remove(p); }));
        var icon = new FrameworkElementFactory(typeof(Image));
        icon.SetValue(WidthProperty, 26.0);
        icon.SetValue(HeightProperty, 26.0);
        icon.SetValue(MarginProperty, new Thickness(0, 0, 8, 0));
        icon.SetBinding(Image.SourceProperty, new System.Windows.Data.Binding { Converter = new IconConverter() });
        var name = new FrameworkElementFactory(typeof(TextBlock));
        name.SetBinding(TextBlock.TextProperty, new System.Windows.Data.Binding { Converter = new NameConverter() });
        name.SetBinding(ToolTipProperty, new System.Windows.Data.Binding());
        name.SetValue(TextBlock.TextTrimmingProperty, TextTrimming.CharacterEllipsis);
        name.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center);
        row.AppendChild(remove);
        row.AppendChild(icon);
        row.AppendChild(name);
        template.VisualTree = row;
        return template;
    }

    public void PlaceTopCentre(Point screenPixels)
    {
        var dpi = VisualTreeHelper.GetDpi(this);
        var x = screenPixels.X / dpi.DpiScaleX;
        var y = screenPixels.Y / dpi.DpiScaleY;
        var area = SystemParameters.WorkArea;
        Left = Math.Clamp(x - Width / 2, area.Left + 8, Math.Max(area.Left + 8, area.Right - Width - 8));
        Top = Math.Clamp(y, area.Top + 4, Math.Max(area.Top + 4, area.Bottom - Height - 8));
    }

    void RestoreBounds()
    {
        var area = SystemParameters.WorkArea;
        if (Settings.Current.ShelfBounds is [var l, var t, var w, var h] && w >= MinWidth && h >= MinHeight
            && l < SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - 40 && t < SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight - 40
            && l + w > SystemParameters.VirtualScreenLeft + 40 && t > SystemParameters.VirtualScreenTop - 10)
        {
            (Left, Top, Width, Height) = (l, t, w, h);
            return;
        }
        Left = area.Right - Width - 20;
        Top = area.Top + (area.Height - Height) / 2;
    }

    void SaveBounds()
    {
        if (!IsLoaded || WindowState != WindowState.Normal) return;
        Settings.Current.ShelfBounds = [Left, Top, Width, Height];
        Settings.Current.Save();
    }

    sealed class IconConverter : System.Windows.Data.IValueConverter
    {
        public object? Convert(object value, Type t, object p, System.Globalization.CultureInfo c) => value is string s ? FileIcons.For(s) : null;
        public object ConvertBack(object value, Type t, object p, System.Globalization.CultureInfo c) => throw new NotSupportedException();
    }

    sealed class NameConverter : System.Windows.Data.IValueConverter
    {
        public object? Convert(object value, Type t, object p, System.Globalization.CultureInfo c) => value is string s ? Path.GetFileName(s.TrimEnd('\\')) : "";
        public object ConvertBack(object value, Type t, object p, System.Globalization.CultureInfo c) => throw new NotSupportedException();
    }
}

static class VisualTreeExtensions
{
    public static T? FindAncestor<T>(this DependencyObject start) where T : DependencyObject
    {
        for (var node = start; node is not null; node = node is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(node) : LogicalTreeHelper.GetParent(node))
            if (node is T match) return match;
        return null;
    }
}
