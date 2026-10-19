using System.Collections.Specialized;
using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Win32;

namespace Transmute.App;

public partial class MainWindow : Window
{
    static JobQueue Queue => JobQueue.Shared;
    static Settings Prefs => Settings.Current;

    public MainWindow()
    {
        InitializeComponent();
        FileList.ItemsSource = Queue.Jobs;
        QualitySlider.Value = Prefs.ImageQuality;
        StripBox.IsChecked = Prefs.StripMetadata;
        Queue.Jobs.CollectionChanged += OnJobsChanged;
        Queue.PropertyChanged += OnQueueChanged;
        Closed += (_, _) =>
        {
            Queue.Jobs.CollectionChanged -= OnJobsChanged;
            Queue.PropertyChanged -= OnQueueChanged;
        };
        DragEnter += OnDragOver;
        DragOver += OnDragOver;
        DragLeave += (_, _) => DropHighlight.Visibility = Visibility.Collapsed;
        Drop += OnDrop;
        Activated += (_, _) => RefreshTip();
        Refresh();
    }

    void OnJobsChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        // Job states change while converting; watch them so the buttons stay right.
        if (e.NewItems is not null) foreach (Job job in e.NewItems) job.PropertyChanged += OnJobChanged;
        if (e.OldItems is not null) foreach (Job job in e.OldItems) job.PropertyChanged -= OnJobChanged;
        Refresh();
    }

    void OnJobChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(Job.Status)) RefreshButtons();
    }

    void OnQueueChanged(object? sender, PropertyChangedEventArgs e) => RefreshButtons();

    void Refresh()
    {
        var any = Queue.Jobs.Count > 0;
        EmptyState.Visibility = any ? Visibility.Collapsed : Visibility.Visible;
        FileList.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
        BuildFormatPickers();
        RefreshTip();
        RefreshButtons();
    }

    void RefreshTip()
    {
        var key = Prefs.ConvertKey;
        WheelTip.Text = Prefs.WheelEnabled && key != WheelKey.Off
            ? $"Tip: hold {key.Label()} while dragging files anywhere to convert them on the spot. You can also right-click files in File Explorer and choose Send to › Transmute."
            : "Tip: right-click files in File Explorer and choose Send to › Transmute.";
    }

    void RefreshButtons()
    {
        var jobs = Queue.Jobs;
        var busy = Queue.IsRunning;
        var pdfs = jobs.Count(j => j.Kind == FileKind.Pdf);
        var images = jobs.Count(j => j.Kind == FileKind.Image);
        var videos = jobs.Count(j => j.Kind == FileKind.Video);
        ClearButton.IsEnabled = jobs.Count > 0;
        ConvertButton.IsEnabled = CompressButton.IsEnabled = jobs.Count > 0 && !busy;
        foreach (var cancel in new[] { CancelConvert, CancelCompress, CancelTools })
            cancel.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        MergeButton.IsEnabled = pdfs >= 2 && !busy;
        ImagesPdfButton.IsEnabled = images > 0 && !busy;
        SplitButton.IsEnabled = pdfs > 0 && !busy;
        JoinButton.IsEnabled = videos >= 2 && !busy;
        ZipButton.IsEnabled = jobs.Count > 0 && !busy;
        CleanButton.IsEnabled = jobs.Any(j => j.Kind.CanStripMetadata()) && !busy;
        QrButton.IsEnabled = images > 0 && !busy;
        FloatButton.IsEnabled = jobs.Count > 0;
        var kinds = Queue.KindsPresent.ToList();
        QualityRow.Visibility = kinds.Contains(FileKind.Image) || kinds.Contains(FileKind.Pdf) ? Visibility.Visible : Visibility.Collapsed;
    }

    // Format pickers: one per kind of file in the list.

    readonly Dictionary<FileKind, ComboBox> pickers = [];

    void BuildFormatPickers()
    {
        var kinds = Queue.KindsPresent.ToList();
        NoFormats.Visibility = kinds.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (kinds.SequenceEqual(pickers.Keys)) return;
        FormatPickers.Children.Clear();
        pickers.Clear();
        foreach (var kind in kinds)
        {
            var targets = kind.ConvertTargets();
            if (targets.Length == 0) continue;
            var row = new DockPanel { Margin = new Thickness(0, 0, 0, 6) };
            row.Children.Add(new TextBlock { Text = kind.Title(), Width = 120, VerticalAlignment = VerticalAlignment.Center });
            var box = new ComboBox { Width = 200, HorizontalAlignment = HorizontalAlignment.Left };
            foreach (var format in targets) box.Items.Add(new ComboBoxItem { Content = format.Label(), Tag = format });
            var saved = Prefs.Choices.GetValueOrDefault(kind.ToString());
            var index = Array.FindIndex(targets, f => f.ToString() == saved);
            box.SelectedIndex = Math.Max(0, index);
            box.SelectionChanged += (_, _) =>
            {
                if (box.SelectedItem is ComboBoxItem { Tag: OutputFormat f }) { Prefs.Choices[kind.ToString()] = f.ToString(); Prefs.Save(); }
            };
            row.Children.Add(box);
            FormatPickers.Children.Add(row);
            pickers[kind] = box;
        }
    }

    OutputFormat FormatFor(FileKind kind) =>
        pickers.TryGetValue(kind, out var box) && box.SelectedItem is ComboBoxItem { Tag: OutputFormat f } ? f : kind.ConvertTargets().FirstOrDefault();

    // Adding files

    void OnDragOver(object sender, DragEventArgs e)
    {
        var files = e.Data.GetDataPresent(DataFormats.FileDrop);
        e.Effects = files ? DragDropEffects.Copy : DragDropEffects.None;
        DropHighlight.Visibility = files ? Visibility.Visible : Visibility.Collapsed;
        e.Handled = true;
    }

    void OnDrop(object sender, DragEventArgs e)
    {
        DropHighlight.Visibility = Visibility.Collapsed;
        if (e.Data.GetData(DataFormats.FileDrop) is string[] paths) Queue.Add(paths);
    }

    void OnAddFiles(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Multiselect = true, Title = "Add files to Transmute" };
        if (dialog.ShowDialog(this) == true) Queue.Add(dialog.FileNames);
    }

    void OnAddFolder(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Multiselect = true, Title = "Add folders to Transmute" };
        if (dialog.ShowDialog(this) == true) Queue.Add(dialog.FolderNames);
    }

    void OnClear(object sender, RoutedEventArgs e) => Queue.Clear();
    void OnSettings(object sender, RoutedEventArgs e) => SettingsWindow.Open(this);
    void OnFeedback(object sender, RoutedEventArgs e) => Feedback.OpenForm();

    void OnListKey(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Delete) return;
        foreach (var job in FileList.SelectedItems.Cast<Job>().ToList()) Queue.Remove(job);
    }

    // Row buttons

    static Job JobOf(object sender) => (Job)((FrameworkElement)sender).DataContext;

    void OnRemove(object sender, RoutedEventArgs e) => Queue.Remove(JobOf(sender));

    void OnShow(object sender, RoutedEventArgs e)
    {
        if (JobOf(sender).Result is { } result) Native.RevealInExplorer(result.Outputs);
    }

    void OnEdit(object sender, RoutedEventArgs e)
    {
        var job = JobOf(sender);
        if (job.IsRunning) return;
        Editors.Open(job, this);
    }

    void OnInfo(object sender, RoutedEventArgs e)
    {
        var job = JobOf(sender);
        if (job.IsRunning) return;
        new MetadataWindow(job) { Owner = this }.Show();
    }

    // Mode tabs

    void OnMode(object sender, RoutedEventArgs e)
    {
        if (ConvertPanel is null) return;
        ConvertPanel.Visibility = ConvertTab.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        CompressPanel.Visibility = CompressTab.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        ToolsPanel.Visibility = ToolsTab.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
    }

    void OnQuality(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        QualityLabel.Text = $"{(int)Math.Round(e.NewValue * 100)}%";
        if (!IsLoaded) return;
        Prefs.ImageQuality = Math.Round(e.NewValue, 2);
        Prefs.Save();
    }

    void OnStripToggle(object sender, RoutedEventArgs e)
    {
        Prefs.StripMetadata = StripBox.IsChecked == true;
        Prefs.Save();
    }

    void OnCompressBy(object sender, RoutedEventArgs e)
    {
        if (PercentRow is null) return;
        PercentRow.Visibility = ByPercent.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        SizeRow.Visibility = BySize.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
    }

    void OnPercent(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (PercentLabel is not null) PercentLabel.Text = $"to {(int)e.NewValue}% of original";
    }

    // Actions

    static bool Reveal => Prefs.RevealWhenDone;

    void OnConvert(object sender, RoutedEventArgs e)
    {
        var plan = Queue.Jobs.Where(j => j.Kind.ConvertTargets().Length > 0)
            .Select(j => (j, (JobOperation)new JobOperation.Convert(FormatFor(j.Kind)))).ToList();
        _ = Queue.Start(plan, Reveal);
    }

    void OnCompress(object sender, RoutedEventArgs e)
    {
        CompressionTarget target;
        if (ByPercent.IsChecked == true) target = new CompressionTarget.Percent(PercentSlider.Value / 100);
        else
        {
            var text = TargetMB.Text.Trim().Replace(',', '.');
            var mb = double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) && double.IsFinite(v) ? v : 5;
            target = new CompressionTarget.Bytes((long)(Math.Clamp(mb, 0.01, 1_000_000) * 1_000_000));
        }
        var plan = Queue.Jobs.Where(j => j.Kind.CanCompress()).Select(j => (j, (JobOperation)new JobOperation.Compress(target))).ToList();
        _ = Queue.Start(plan, Reveal);
    }

    void OnCancel(object sender, RoutedEventArgs e) => Queue.CancelAll();

    List<Job> Of(FileKind kind) => Queue.Jobs.Where(j => j.Kind == kind).ToList();

    void OnMerge(object sender, RoutedEventArgs e) => _ = Queue.RunBatch(new BatchTool.MergePdfs(), Of(FileKind.Pdf), Reveal);
    void OnImagesToPdf(object sender, RoutedEventArgs e) => _ = Queue.RunBatch(new BatchTool.ImagesToPdf(), Of(FileKind.Image), Reveal);
    void OnJoin(object sender, RoutedEventArgs e) => _ = Queue.RunBatch(new BatchTool.JoinVideos(), Of(FileKind.Video), Reveal);
    void OnZip(object sender, RoutedEventArgs e) => _ = Queue.RunBatch(new BatchTool.Archive(OutputFormat.Zip), Queue.Jobs.ToList(), Reveal);

    void OnSplit(object sender, RoutedEventArgs e) =>
        _ = Queue.Start(Of(FileKind.Pdf).Select(j => (j, (JobOperation)new JobOperation.SplitPdf())).ToList(), Reveal);

    void OnClean(object sender, RoutedEventArgs e) =>
        _ = Queue.Start(Queue.Jobs.Where(j => j.Kind.CanStripMetadata()).Select(j => (j, (JobOperation)new JobOperation.StripMetadata())).ToList(), Reveal);

    void OnQr(object sender, RoutedEventArgs e) =>
        _ = Queue.Start(Of(FileKind.Image).Select(j => (j, (JobOperation)new JobOperation.ReadQr())).ToList(), false);

    void OnFloat(object sender, RoutedEventArgs e) => Shelf.Shared.Add(Queue.Jobs.Select(j => j.Path));
}
