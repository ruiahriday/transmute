using System.Windows;
using System.Windows.Controls;

namespace Transmute.App;

/// Settings → Links: links made on this PC that still work, with Copy and Delete.
public partial class SettingsWindow
{
    void BuildLinksSection()
    {
        var s = LinksSection.Children;
        s.Clear();
        if (!LinkService.IsAvailable) return;
        s.Add(new TextBlock { Text = "Links", Style = (Style)FindResource("SectionTitle") });
        var links = SharedLinks.Load();
        if (links.Count == 0)
            s.Add(Note($"Hold the actions key while dragging files and drop them on Link. Links last {LinkService.Days} days."));
        foreach (var link in links)
        {
            var row = new DockPanel { Margin = new Thickness(0, 3, 0, 3) };
            var delete = new Button { Content = "Delete", Margin = new Thickness(6, 0, 0, 0), Padding = new Thickness(10, 3, 10, 3), VerticalAlignment = VerticalAlignment.Center };
            var copy = new Button { Content = "Copy", Margin = new Thickness(6, 0, 0, 0), Padding = new Thickness(10, 3, 10, 3), VerticalAlignment = VerticalAlignment.Center };
            DockPanel.SetDock(delete, Dock.Right);
            DockPanel.SetDock(copy, Dock.Right);
            copy.Click += (_, _) => LinkCard.Copy(link);
            delete.Click += async (_, _) =>
            {
                delete.IsEnabled = false;
                try { await SharedLinks.Delete(link); BuildLinksSection(); }
                catch (Exception e) { delete.IsEnabled = true; MessageBox.Show(e.Message, "Spinform", MessageBoxButton.OK, MessageBoxImage.Warning); }
            };
            var text = new StackPanel();
            text.Children.Add(new TextBlock { Text = link.Name, TextTrimming = TextTrimming.CharacterEllipsis });
            text.Children.Add(new TextBlock { Text = $"{OutputPaths.FormatSize(link.Size)} · until {link.Expires.LocalDateTime:d MMM, HH:mm}", Style = (Style)FindResource("Caption") });
            row.Children.Add(delete);
            row.Children.Add(copy);
            row.Children.Add(text);
            s.Add(row);
        }
    }
}
