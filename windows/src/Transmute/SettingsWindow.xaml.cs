using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;

namespace Transmute.App;

public partial class SettingsWindow : Window
{
    static SettingsWindow? open;
    static Settings Prefs => Settings.Current;
    bool loading = true;

    /// Opens Settings scrolled to a section ("capture").
    public static void Open(string section)
    {
        Open();
        if (section == "capture" && open is not null) open.Dispatcher.BeginInvoke(() => open?.CaptureSection.BringIntoView(), System.Windows.Threading.DispatcherPriority.Loaded);
    }

    public static void Open(Window? owner = null)
    {
        if (open is not null) { open.Activate(); return; }
        open = new SettingsWindow();
        if (owner is { IsVisible: true }) open.Owner = owner;
        else open.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        open.Closed += (_, _) => open = null;
        open.Show();
        open.Activate();
    }

    public SettingsWindow()
    {
        InitializeComponent();
        BesideOriginal.IsChecked = !Prefs.SaveInFolder;
        InFolder.IsChecked = Prefs.SaveInFolder;
        RevealBox.IsChecked = Prefs.RevealWhenDone;
        OfficeBox.IsChecked = Prefs.UseOfficeApps;
        WheelBox.IsChecked = Prefs.WheelEnabled;
        ShakeBox.IsChecked = Prefs.ShakeToShelf;
        EdgeBox.IsChecked = Prefs.TopEdgeToShelf;
        try { LoginBox.IsChecked = Settings.OpenAtLogin; } catch { LoginBox.IsEnabled = false; }
        foreach (var (box, key) in new[] { (ConvertKey, Prefs.ConvertKey), (ToolsKey, Prefs.ToolsKey), (ActionsKey, Prefs.ActionsKey) })
        {
            foreach (var option in Enum.GetValues<WheelKey>()) box.Items.Add(new ComboBoxItem { Content = option.Label(), Tag = option });
            box.SelectedIndex = (int)key;
        }
        BuildCaptureSection();
        VersionLabel.Text = $"Spinform {Feedback.Version} (formerly Transmute)";
        FfmpegLabel.Text = Tools.Ffmpeg is { } path
            ? $"Found at {path}"
            : "Not found. It comes with Spinform, so reinstalling should bring it back. Video, audio and some image formats need it.";
        if (Tools.Ffmpeg is null) FfmpegLabel.Foreground = (System.Windows.Media.Brush)FindResource("Danger");
        ModelLabel.Text = Backgrounds.IsAvailable
            ? "Ready. Subjects are found on this PC by the IS-Net segmentation model (Apache License 2.0); pictures are never uploaded."
            : "The background model is missing. Reinstalling Spinform brings it back.";
        var office = new[] { OfficeApps.App.Word, OfficeApps.App.Excel, OfficeApps.App.PowerPoint }.Where(OfficeApps.Has).Select(a => a.ToString()).ToList();
        OfficeStatus.Text = (office.Count, OfficeApps.LibreOffice) switch
        {
            ( > 0, _) => $"Found {string.Join(", ", office)}: Word, Excel and PowerPoint files convert exactly as Office shows them.",
            (_, not null) => "Found LibreOffice: Office files convert exactly as LibreOffice shows them.",
            _ => "Neither is installed, so Spinform uses its own converters. They keep text, headings, lists, tables and pictures, but not every bit of layout.",
        };
        RefreshFolder();
        RefreshKeyNote();
        loading = false;
    }

    void RefreshFolder()
    {
        FolderRow.Visibility = InFolder.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        FolderLabel.Text = Prefs.OutputFolder.Length == 0 ? "No folder chosen" : Prefs.OutputFolder;
    }

    void RefreshKeyNote()
    {
        var keys = new[] { Prefs.ConvertKey, Prefs.ToolsKey, Prefs.ActionsKey }.Where(k => k != WheelKey.Off).ToList();
        KeyNote.Text = keys.Distinct().Count() != keys.Count
            ? "⚠ Two wheels use the same key. The actions wheel wins, then tools."
            : "File Explorer also uses these keys while dragging (Shift moves, Ctrl copies, Alt makes a shortcut), but dropping on the wheel never moves or changes your file.";
    }

    void OnOutputMode(object sender, RoutedEventArgs e)
    {
        Prefs.SaveInFolder = InFolder.IsChecked == true;
        if (Prefs.SaveInFolder && Prefs.OutputFolder.Length == 0) OnChooseFolder(sender, e);
        Prefs.Save();
        RefreshFolder();
    }

    void OnChooseFolder(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = "Save Spinform results in" };
        if (dialog.ShowDialog(this) == true) Prefs.OutputFolder = dialog.FolderName;
        if (Prefs.OutputFolder.Length == 0) { Prefs.SaveInFolder = false; BesideOriginal.IsChecked = true; }
        Prefs.Save();
        RefreshFolder();
    }

    void OnChanged(object sender, RoutedEventArgs e)
    {
        Prefs.RevealWhenDone = RevealBox.IsChecked == true;
        Prefs.UseOfficeApps = OfficeBox.IsChecked == true;
        Prefs.WheelEnabled = WheelBox.IsChecked == true;
        Prefs.ShakeToShelf = ShakeBox.IsChecked == true;
        Prefs.TopEdgeToShelf = EdgeBox.IsChecked == true;
        Prefs.Save();
    }

    void OnKeyChanged(object sender, SelectionChangedEventArgs e)
    {
        if (loading) return;
        static WheelKey Key(ComboBox box) => box.SelectedItem is ComboBoxItem { Tag: WheelKey k } ? k : WheelKey.Off;
        Prefs.ConvertKey = Key(ConvertKey);
        Prefs.ToolsKey = Key(ToolsKey);
        Prefs.ActionsKey = Key(ActionsKey);
        Prefs.Save();
        RefreshKeyNote();
    }

    void OnLogin(object sender, RoutedEventArgs e)
    {
        try { Settings.OpenAtLogin = LoginBox.IsChecked == true; }
        catch { LoginBox.IsChecked = Settings.OpenAtLogin; }
    }

    void OnCustomizeWheels(object sender, RoutedEventArgs e) => WheelEditorWindow.Open(this);
    void OnFeedback(object sender, RoutedEventArgs e) => Feedback.OpenForm();
    void OnCopyDetails(object sender, RoutedEventArgs e) => Feedback.CopyDetails();
    void OnDone(object sender, RoutedEventArgs e) => Close();

    void OnNotices(object sender, RoutedEventArgs e)
    {
        var file = System.IO.Path.Combine(AppContext.BaseDirectory, "THIRD-PARTY-NOTICES.txt");
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(file) { UseShellExecute = true }); }
        catch { MessageBox.Show(this, "The notices file isn't there. Reinstalling Spinform brings it back.", "Spinform"); }
    }
}
