using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;

namespace Transmute.App;

/// The Capture tab: every kind of screenshot and recording, with its shortcut.
public partial class MainWindow
{
    bool captureBuilt;

    void BuildCapturePanel()
    {
        if (captureBuilt) { RefreshCaptureHints(); return; }
        captureBuilt = true;
        CapturePanel.Children.Clear();

        CapturePanel.Children.Add(new TextBlock { Text = "SCREENSHOTS", Style = (Style)FindResource("Overline") });
        var shots = new WrapPanel();
        shots.Children.Add(CaptureButton("capture", "Capture…", CaptureAction.AllInOne, "Every kind of capture in one place, with an exact size if you like"));
        shots.Children.Add(CaptureButton("area", "Area", CaptureAction.Area, "Drag across part of the screen"));
        shots.Children.Add(CaptureButton("window", "Window", CaptureAction.Window, "Click a window"));
        shots.Children.Add(CaptureButton("screen", "Full Screen", CaptureAction.FullScreen, "The display the pointer is on"));
        shots.Children.Add(CaptureButton("repeat", "Previous Area", CaptureAction.Previous, "The same spot as last time"));
        shots.Children.Add(CaptureButton("scroll", "Scrolling", CaptureAction.Scrolling, "A whole long page, joined into one picture as it scrolls"));
        shots.Children.Add(CaptureButton("text", "Copy Text", CaptureAction.Text, "Reads the words (and QR codes) in an area and copies them. On this PC, nothing is uploaded."));
        CapturePanel.Children.Add(shots);

        CapturePanel.Children.Add(new TextBlock { Text = "RECORDING", Style = (Style)FindResource("Overline"), Margin = new Thickness(0, 4, 0, 6) });
        var records = new WrapPanel();
        records.Children.Add(CaptureButton("record", "Record Area", CaptureAction.RecordArea, "Record part of the screen as an MP4 or GIF"));
        records.Children.Add(Tool("window", "Record Window", "Record one window", () => { Hide(); _ = RunThenShow(Capture.RecordWindow()); }));
        records.Children.Add(CaptureButton("screen", "Record Full Screen", CaptureAction.RecordScreen, "Record the display the pointer is on"));
        CapturePanel.Children.Add(records);

        CapturePanel.Children.Add(new TextBlock { Text = "MORE", Style = (Style)FindResource("Overline"), Margin = new Thickness(0, 4, 0, 6) });
        var more = new WrapPanel();
        more.Children.Add(CaptureButton("history", "History", CaptureAction.History, "Recent screenshots, recordings and copied text"));
        more.Children.Add(Tool("text", "Text from a File…", "Copy the text in a picture, or in a video's first frame", () =>
        {
            if (PickFile("Pictures and videos|*.png;*.jpg;*.jpeg;*.webp;*.heic;*.bmp;*.gif;*.tif;*.tiff;*.mp4;*.mov;*.mkv;*.webm;*.avi|All files|*.*") is { } f) _ = Capture.RecognizeFile(f);
        }));
        more.Children.Add(Tool("pin", "Pin a Picture…", "Keep a picture floating on top of every window", () => { if (PickFile(PictureFilter) is { } f) PinWindow.Show(f); }));
        more.Children.Add(Tool("frame", "Frame a Picture…", "Put a picture on a background", () => { if (PickFile(PictureFilter) is { } f) FrameWindow.Open(f); }));
        more.Children.Add(Tool("edit", "Open Project…", "Open a .spinform mark-up project", () => { if (PickFile("Spinform project|*.spinform") is { } f) Editors.OpenProject(f, this); }));
        CapturePanel.Children.Add(more);

        var options = new DockPanel { Margin = new Thickness(0, 6, 0, 0), LastChildFill = false };
        var timerLabel = new TextBlock { Text = "Timer", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };
        var timer = Ui.Combo([("Off", 0), ("3 seconds", 3), ("5 seconds", 5), ("10 seconds", 10)], Settings.Current.SelfTimer, v => { Settings.Current.SelfTimer = v; Settings.Current.Save(); });
        timer.MinWidth = 110;
        timer.Margin = new Thickness(0, 0, 16, 0);
        var icons = new CheckBox { Content = "Hide desktop icons", IsChecked = Settings.Current.HideDesktopIcons, VerticalAlignment = VerticalAlignment.Center, ToolTip = "Hides the icons on the desktop while capturing or recording" };
        icons.Click += (_, _) => { Settings.Current.HideDesktopIcons = icons.IsChecked == true; Settings.Current.Save(); };
        var settings = new Button { Content = "Capture Settings…", VerticalAlignment = VerticalAlignment.Center };
        settings.Click += (_, _) => SettingsWindow.Open("capture");
        foreach (var e in new UIElement[] { timerLabel, timer, icons }) { DockPanel.SetDock(e, Dock.Left); options.Children.Add(e); }
        DockPanel.SetDock(settings, Dock.Right);
        options.Children.Add(settings);
        CapturePanel.Children.Add(options);
        CapturePanel.Children.Add(new TextBlock { Style = (Style)FindResource("Caption"), Margin = new Thickness(0, 8, 0, 0), Text = "Shortcuts work from anywhere while Spinform is in the tray. Nothing is uploaded." });
    }

    const string PictureFilter = "Pictures|*.png;*.jpg;*.jpeg;*.webp;*.heic;*.bmp;*.gif;*.tif;*.tiff|All files|*.*";

    string? PickFile(string filter)
    {
        var dialog = new OpenFileDialog { Filter = filter };
        return dialog.ShowDialog(this) == true ? dialog.FileName : null;
    }

    readonly Dictionary<CaptureAction, Button> captureButtons = [];

    Button CaptureButton(string glyph, string text, CaptureAction action, string tip)
    {
        var button = Tool(glyph, text, tip, () => _ = Capture.Run(action, fromApp: true));
        button.Tag = tip;
        captureButtons[action] = button;
        Hint(button, action);
        return button;
    }

    Button Tool(string glyph, string text, string tip, Action run)
    {
        var button = new Button { Style = (Style)FindResource("ToolButton"), Content = new Icon { Glyph = glyph, Size = 15, Text = text }, ToolTip = tip };
        button.Click += (_, _) => run();
        return button;
    }

    static void Hint(Button button, CaptureAction action)
    {
        var keys = Hotkeys.Label(action);
        button.ToolTip = (string)button.Tag + (keys.Length > 0 ? $"  ({keys})" : "");
    }

    void RefreshCaptureHints()
    {
        foreach (var (action, button) in captureButtons) Hint(button, action);
    }

    async Task RunThenShow(Task work)
    {
        try { await work; } finally { Show(); }
    }
}
