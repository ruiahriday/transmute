using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Threading;

namespace Transmute.App;

/// "Create link": the card in the bottom-right corner while files upload, then "Link copied".
/// The upload itself is in Transmute.Core (ShareLinks.cs).
sealed class LinkCard : Window
{
    public static LinkCard Shared => shared ??= new LinkCard();
    static LinkCard? shared;

    readonly ContentControl icon = new() { Width = 34, VerticalAlignment = VerticalAlignment.Center, Focusable = false };
    readonly TextBlock title = new() { FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
    readonly TextBlock detail = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap, MaxHeight = 34 };
    readonly ProgressBar bar = new() { Maximum = 1, Margin = new Thickness(0, 6, 0, 2) };
    readonly Button button = new() { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 0, 0), Padding = new Thickness(10, 3, 10, 3) };
    readonly DispatcherTimer hide = new();
    CancellationTokenSource? cancel;
    SharedLink? last;

    LinkCard()
    {
        Width = 360;
        Height = 100;
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
        text.Children.Add(bar);
        text.Children.Add(detail);
        var row = new DockPanel();
        DockPanel.SetDock(icon, Dock.Left);
        DockPanel.SetDock(button, Dock.Right);
        row.Children.Add(icon);
        row.Children.Add(button);
        row.Children.Add(text);
        // The shadow is its own layer under the card, so the card's text stays crisp (as in Hud).
        var shadow = new Border
        {
            Background = Ui.Brush("Card"),
            CornerRadius = new CornerRadius(8),
            Margin = new Thickness(8),
            Effect = new DropShadowEffect { BlurRadius = 16, ShadowDepth = 3, Direction = 270, Opacity = 0.18 },
        };
        var card = new Border
        {
            Background = Ui.Brush("Card"),
            CornerRadius = new CornerRadius(8),
            BorderBrush = Ui.Brush("Line"),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(14, 10, 14, 10),
            Margin = new Thickness(8),
            Child = row,
            SnapsToDevicePixels = true,
        };
        title.Foreground = Ui.Brush("Ink");
        detail.Foreground = Ui.Brush("Secondary");
        Content = new Grid { Children = { shadow, card } };
        button.Click += (_, _) => OnButton();
        hide.Tick += (_, _) =>
        {
            hide.Stop();
            if (IsMouseOver) { hide.Interval = TimeSpan.FromSeconds(2); hide.Start(); }
            else Hide();
        };
    }

    public async void Create(IReadOnlyList<string> paths)
    {
        if (LinkService.Endpoint is not { } service || LinkService.Token is not { } appToken || paths.Count == 0) return;
        cancel?.Cancel();
        var mine = cancel = new CancellationTokenSource();
        hide.Stop();
        last = null;
        Working(paths.Count == 1 && File.Exists(paths[0]) ? Path.GetFileName(paths[0]) : $"{paths.Count} files", null, 0, 0);
        PlaceAndShow();
        string? cleanup = null;
        try
        {
            if (paths.Count > 1 || !File.Exists(paths[0])) title.Text = $"Zipping {(paths.Count == 1 ? Path.GetFileName(paths[0].TrimEnd('\\')) : $"{paths.Count} files")}…";
            var (file, folder) = await LinkUploader.Prepare(paths, mine.Token);
            cleanup = folder;
            var name = Path.GetFileName(file);
            var link = await Task.Run(() => LinkUploader.Upload(file, service, appToken,
                (sent, total) => Dispatcher.BeginInvoke(() => { if (cancel == mine) Working(name, null, sent, total); }), mine.Token));
            if (cancel != mine) return;
            SharedLinks.Add(link);
            Copy(link);
            last = link;
            Finished("check", "Success", "Link copied", $"{link.Name} · works for {LinkService.Days} days. Paste it anywhere.", "Copy", 8);
        }
        catch (OperationCanceledException)
        {
            if (cancel == mine) Hide();
        }
        catch (Exception e)
        {
            if (cancel == mine) Finished("warning", "Warning", "Couldn't create the link", e.Message, "Close", 10);
        }
        finally
        {
            if (cleanup is not null) try { Directory.Delete(cleanup, true); } catch { }
        }
    }

    void Working(string name, string? note, long sent, long total)
    {
        icon.Content = Icons.Make("working", 22, Ui.Brush("Accent"), 1.8);
        title.Text = total == 0 ? $"Preparing {name}…" : $"Uploading {name}";
        bar.Visibility = Visibility.Visible;
        bar.IsIndeterminate = total == 0;
        bar.Value = total == 0 ? 0 : (double)sent / total;
        detail.Text = note ?? (total == 0 ? "" : $"{(int)(100.0 * sent / total)}% of {OutputPaths.FormatSize(total)} · encrypted");
        button.Content = "Cancel";
    }

    void Finished(string glyph, string color, string heading, string message, string action, double seconds)
    {
        icon.Content = Icons.Make(glyph, 22, Ui.Brush(color), 2);
        title.Text = heading;
        bar.Visibility = Visibility.Collapsed;
        detail.Text = message;
        button.Content = action;
        hide.Interval = TimeSpan.FromSeconds(seconds);
        hide.Start();
    }

    void OnButton()
    {
        if (last is not null) { Copy(last); return; }
        cancel?.Cancel();
        cancel = null;
        Hide();
    }

    void PlaceAndShow()
    {
        var area = SystemParameters.WorkArea;
        Left = area.Right - Width - 8;
        Top = area.Bottom - Height - 8;
        Show();
    }

    public static void Copy(SharedLink link)
    {
        try { Clipboard.SetText(link.Url); } catch { }
    }

    /// For the smoke test's pictures: the card as it looks mid-upload or when done.
    public void Showcase(bool done)
    {
        hide.Stop();
        if (done)
        {
            last = new SharedLink("x7k2Qm9aPz", "Holiday video.mp4", 1_840_000_000, "https://links.spinform.app/l/x7k2Qm9aPz#key", "", DateTimeOffset.Now.AddDays(7), "");
            Finished("check", "Success", "Link copied", $"{last.Name} · works for {LinkService.Days} days. Paste it anywhere.", "Copy", 600);
            hide.Stop();
        }
        else
        {
            last = null;
            Working("Holiday video.mp4", null, 773_000_000, 1_840_000_000);
        }
        PlaceAndShow();
    }
}
