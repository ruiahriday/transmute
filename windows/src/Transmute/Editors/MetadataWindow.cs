using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace Transmute.App;

/// Shows a file's details (camera, place, dates, tags…) and edits the ones that can be changed.
/// Saving writes a copy with the changes; the original is never touched.
sealed class MetadataWindow : Window
{
    readonly Job job;
    List<MetadataField> fields = [];
    readonly Dictionary<string, TextBox> editors = [];
    readonly StackPanel body = new() { Margin = new Thickness(20, 6, 20, 20) };
    readonly CheckBox removeLocation = new() { Content = "Remove the location", Margin = new Thickness(0, 10, 0, 0) };
    readonly Button saveButton;

    public MetadataWindow(Job job)
    {
        this.job = job;
        Title = $"Info: {job.Name}";
        Width = 560;
        Height = 640;
        MinWidth = 420;
        MinHeight = 360;
        Style = Ui.Res("BaseWindow");
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;

        var copy = Ui.Button("Copy All", (_, _) => { try { Clipboard.SetText(MetadataTool.PlainText(fields, job.Name)); } catch { } });
        var cancel = Ui.Button("Close", (_, _) => Close());
        saveButton = Ui.Button("Save Copy", (_, _) => Save(), primary: true);
        saveButton.IsEnabled = false;
        var footer = new DockPanel { Margin = new Thickness(16, 10, 16, 10), LastChildFill = false };
        saveButton.Margin = new Thickness(0);
        cancel.Margin = new Thickness(0, 0, 8, 0);
        copy.Margin = new Thickness(0);
        DockPanel.SetDock(saveButton, Dock.Right);
        DockPanel.SetDock(cancel, Dock.Right);
        footer.Children.Add(saveButton);
        footer.Children.Add(cancel);
        footer.Children.Add(copy);
        var footerBorder = new Border { Child = footer, Background = Ui.Brush("Card"), BorderBrush = Ui.Brush("Line"), BorderThickness = new Thickness(0, 1, 0, 0) };
        var root = new DockPanel();
        DockPanel.SetDock(footerBorder, Dock.Bottom);
        root.Children.Add(footerBorder);
        root.Children.Add(new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = body });
        Content = root;
        body.Children.Add(Ui.Caption("Reading…"));
        removeLocation.Click += (_, _) => RefreshSave();
        Loaded += async (_, _) => await Load();
        KeyDown += (_, e) => { if (e.Key == Key.Escape) Close(); };
    }

    async Task Load()
    {
        try
        {
            fields = await MetadataTool.Read(job.Path);
        }
        catch (Exception e)
        {
            body.Children.Clear();
            body.Children.Add(Ui.Caption($"Couldn't read this file's details: {JobQueue.Describe(e)}"));
            return;
        }
        body.Children.Clear();
        foreach (var section in fields.GroupBy(f => f.Section))
        {
            body.Children.Add(Ui.Heading(section.Key));
            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(140) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            foreach (var field in section)
            {
                grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                var row = grid.RowDefinitions.Count - 1;
                var label = new TextBlock { Text = field.Label, Foreground = Ui.Brush("Secondary"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 3, 8, 3), TextWrapping = TextWrapping.Wrap };
                FrameworkElement value;
                if (field.Editable)
                {
                    var box = new TextBox { Text = field.Value, Margin = new Thickness(0, 2, 0, 2), ToolTip = MetadataTool.Placeholder(field.Key) is { } hint ? $"For example {hint}" : null };
                    box.TextChanged += (_, _) => RefreshSave();
                    editors[field.Key] = box;
                    value = box;
                }
                else
                {
                    value = new TextBox { Text = field.Value, IsReadOnly = true, BorderThickness = new Thickness(0), Background = Brushes.Transparent, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 2) };
                }
                Grid.SetRow(label, row);
                Grid.SetRow(value, row);
                Grid.SetColumn(value, 1);
                grid.Children.Add(label);
                grid.Children.Add(value);
            }
            body.Children.Add(grid);
        }
        if (MetadataTool.HasLocation(fields)) body.Children.Add(removeLocation);
        body.Children.Add(Ui.Caption(editors.Count > 0
            ? "Change the boxes, then Save Copy. Leave a box empty to remove that detail. The copy is saved next to the original."
            : "This kind of file's details can be read but not changed."));
        RefreshSave();
    }

    Dictionary<string, string> Changes()
    {
        var changes = new Dictionary<string, string>();
        foreach (var (key, box) in editors)
        {
            var before = MetadataTool.Value(key, fields) ?? "";
            if (box.Text.Trim() != before.Trim()) changes[key] = box.Text.Trim();
        }
        return changes;
    }

    void RefreshSave() => saveButton.IsEnabled = Changes().Count > 0 || removeLocation.IsChecked == true;

    void Save()
    {
        Editors.Run(job, new JobOperation.WriteMetadata(new MetadataEdit(Changes(), removeLocation.IsChecked == true)));
        Close();
    }
}
