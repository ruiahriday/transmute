using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;
using Transmute.Desktop;

namespace Transmute.App;

/// Settings › Capture: shortcuts, what happens after a capture, how windows and recordings look.
public partial class SettingsWindow
{
    readonly Dictionary<CaptureAction, (TextBox Box, TextBlock Problem)> shortcutRows = [];
    TextBlock? printScreenNote;

    void BuildCaptureSection()
    {
        var s = CaptureSection.Children;
        s.Add(new TextBlock { Text = "Capture", Style = (Style)FindResource("SectionTitle") });

        // Shortcuts
        s.Add(Sub("Shortcuts"));
        var grid = new Grid { Margin = new Thickness(0, 2, 0, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(232) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(150) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var row = 0;
        foreach (var action in Enum.GetValues<CaptureAction>())
        {
            grid.RowDefinitions.Add(new RowDefinition());
            grid.RowDefinitions.Add(new RowDefinition());
            var label = new TextBlock { Text = Hotkey.Title(action), VerticalAlignment = VerticalAlignment.Center };
            var box = ShortcutBox(action);
            var reset = new Button { Content = Icons.Make("repeat", 12), ToolTip = "Back to " + (Hotkey.Default(action)?.ToString() ?? "none"), Style = (Style)FindResource("Flat"), Margin = new Thickness(4, 0, 0, 0), Padding = new Thickness(6, 4, 6, 4) };
            reset.Click += (_, _) => { Hotkeys.Set(action, Hotkey.Default(action)); RefreshShortcuts(); };
            var problem = new TextBlock { Foreground = (Brush)FindResource("Warning"), FontSize = 11.5, TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed, Margin = new Thickness(0, 0, 0, 4) };
            Grid.SetRow(label, row); Grid.SetRow(box, row); Grid.SetColumn(box, 1); Grid.SetRow(reset, row); Grid.SetColumn(reset, 2);
            Grid.SetRow(problem, row + 1); Grid.SetColumnSpan(problem, 3);
            grid.Children.Add(label); grid.Children.Add(box); grid.Children.Add(reset); grid.Children.Add(problem);
            shortcutRows[action] = (box, problem);
            row += 2;
        }
        s.Add(grid);
        s.Add(Note("Click a box and press the keys. Backspace removes a shortcut. Win+Shift+S and Print Screen stay with Windows unless you choose below."));
        s.Add(Check("Use the Print Screen key to capture an area", Prefs.PrintScreenTakeover, v => { Prefs.PrintScreenTakeover = v; Hotkeys.Apply(); RefreshShortcuts(); }));
        printScreenNote = Note("");
        printScreenNote.Margin = new Thickness(22, 0, 0, 4);
        s.Add(printScreenNote);
        RefreshShortcuts();

        // After capturing
        s.Add(Sub("After a screenshot"));
        s.Add(Check("Copy it to the clipboard", Prefs.CaptureCopy, v => Prefs.CaptureCopy = v));
        s.Add(Check("Save it in the capture folder", Prefs.CaptureAutoSave, v => Prefs.CaptureAutoSave = v));
        s.Add(CaptureFolderRow("Screenshots", () => CaptureKit.CaptureFolder, v => Prefs.CaptureFolder = v));
        s.Add(CaptureFolderRow("Recordings", () => CaptureKit.RecordingFolder, v => Prefs.RecordingFolder = v));
        s.Add(Pick("Format", [("PNG", "png"), ("JPEG", "jpg")], Prefs.CaptureFormat, v => Prefs.CaptureFormat = v));
        s.Add(Check("Show a thumbnail to copy, save, mark up or drag", Prefs.CaptureOverlay, v => Prefs.CaptureOverlay = v));
        s.Add(Pick("Thumbnail at", [("Bottom right", "right"), ("Bottom left", "left"), ("Top right", "top-right"), ("Top left", "top-left")], Prefs.OverlayCorner, v => Prefs.OverlayCorner = v));
        s.Add(Pick("Put away after", [("5 seconds", 5), ("10 seconds", 10), ("20 seconds", 20), ("1 minute", 60), ("Never", 0)], Prefs.OverlaySeconds, v => Prefs.OverlaySeconds = v));
        s.Add(Pick("Thumbnail size", [("Small", 0.85), ("Medium", 1.0), ("Large", 1.2)], Prefs.OverlaySize, v => Prefs.OverlaySize = v));

        // Choosing
        s.Add(Sub("While choosing"));
        s.Add(Check("Freeze the screen", Prefs.FreezeScreen, v => Prefs.FreezeScreen = v, "Menus and videos hold still while you choose"));
        s.Add(Check("Show the magnifier", Prefs.ShowMagnifier, v => Prefs.ShowMagnifier = v));
        s.Add(Check("Show the crosshair", Prefs.ShowCrosshair, v => Prefs.ShowCrosshair = v));
        s.Add(Pick("Self-timer", [("Off", 0), ("3 seconds", 3), ("5 seconds", 5), ("10 seconds", 10)], Prefs.SelfTimer, v => Prefs.SelfTimer = v));
        s.Add(Check("Hide desktop icons while capturing and recording", Prefs.HideDesktopIcons, v => Prefs.HideDesktopIcons = v));

        // Windows
        s.Add(Sub("Window captures"));
        s.Add(Check("Keep rounded corners see-through (Windows 11)", Prefs.WindowTransparentCorners, v => Prefs.WindowTransparentCorners = v));
        s.Add(Check("Add a shadow", Prefs.WindowShadow, v => Prefs.WindowShadow = v));
        var kind = Prefs.WindowBackground.StartsWith("color:") ? "color" : Prefs.WindowBackground.StartsWith("picture:") ? "picture" : Prefs.WindowBackground;
        s.Add(Pick("Background", [("None", "none"), ("Wallpaper", "wallpaper"), ("Colour…", "color"), ("Picture…", "picture")], kind, v =>
        {
            if (v == "color") Prefs.WindowBackground = "color:" + (Prefs.WindowBackground.StartsWith("color:") ? Prefs.WindowBackground[6..] : "EDE9FE");
            else if (v == "picture")
            {
                var dialog = new OpenFileDialog { Filter = "Pictures|*.png;*.jpg;*.jpeg;*.webp;*.bmp|All files|*.*", Title = "Background for window captures" };
                if (dialog.ShowDialog(this) == true) Prefs.WindowBackground = "picture:" + dialog.FileName;
            }
            else Prefs.WindowBackground = v;
        }));
        var colour = new TextBox { Text = Prefs.WindowBackground.StartsWith("color:") ? Prefs.WindowBackground[6..] : "EDE9FE", Width = 80, MaxLength = 7 };
        colour.TextChanged += (_, _) =>
        {
            var t = colour.Text.Trim().TrimStart('#');
            if (t.Length == 6 && int.TryParse(t, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out _) && Prefs.WindowBackground.StartsWith("color:")) { Prefs.WindowBackground = "color:" + t.ToUpperInvariant(); Prefs.Save(); }
        };
        s.Add(Labelled("Colour", colour));
        s.Add(Pick("Padding", [("Small", 0.04), ("Medium", 0.07), ("Large", 0.12)], Prefs.WindowPadding, v => Prefs.WindowPadding = v));

        // History
        s.Add(Sub("History"));
        s.Add(Pick("Keep captures", [("Off", 0), ("1 day", 1), ("1 week", 7), ("2 weeks", 14), ("1 month", 30), ("Until I delete them", -1)], Prefs.HistoryDays, v =>
        {
            Prefs.HistoryDays = v;
            try { CaptureKit.History.Prune(v); } catch { }
        }));
        s.Add(Note($"Kept in {CaptureKit.HistoryFolder}, on this PC only."));

        // Text
        s.Add(Sub("Copy text"));
        var languages = new List<(string, string)> { ("Automatic", "") };
        try { languages.AddRange(TextRecognizer.Languages.Select(l => (l.Name, l.Tag))); } catch { }
        s.Add(Pick("Language", languages, Prefs.OcrLanguage, v => Prefs.OcrLanguage = v));
        if (languages.Count == 1) s.Add(Note("No text recognition languages are installed. Add one in Windows Settings › Time & language › Language & region."));
        s.Add(Check("Keep line breaks", Prefs.OcrKeepLineBreaks, v => Prefs.OcrKeepLineBreaks = v));

        // Recording
        s.Add(Sub("Recording"));
        s.Add(Pick("Save as", [("MP4 video", "mp4"), ("Animated GIF", "gif")], Prefs.RecordFormat, v => Prefs.RecordFormat = v));
        s.Add(Pick("Frame rate", [("15 fps", 15), ("24 fps", 24), ("30 fps", 30), ("60 fps", 60)], Prefs.RecordFps, v => Prefs.RecordFps = v));
        s.Add(Pick("Quality", [("High", "High"), ("Standard (smaller files)", "Standard")], Prefs.RecordQuality, v => Prefs.RecordQuality = v));
        s.Add(Pick("Size", [("Full size", 0), ("Up to 1080p", 1920), ("Up to 720p", 1280), ("Up to 480p", 854)], Prefs.RecordMaxSide, v => Prefs.RecordMaxSide = v));
        s.Add(Pick("Encoder", [("Automatic (graphics card when possible)", "auto"), ("Software", "libx264"), ("NVIDIA", "h264_nvenc"), ("Intel", "h264_qsv"), ("AMD", "h264_amf"), ("Windows Media Foundation", "h264_mf")], Prefs.RecordEncoder, v => Prefs.RecordEncoder = v));
        s.Add(Pick("Countdown", [("Off", 0), ("3 seconds", 3), ("5 seconds", 5)], Prefs.RecordCountdown, v => Prefs.RecordCountdown = v));
        s.Add(Check("Show the pointer", Prefs.RecordCursor, v => Prefs.RecordCursor = v));
        s.Add(Check("Record the microphone", Prefs.RecordMicrophone, v => Prefs.RecordMicrophone = v));
        s.Add(Check("Record the sound the PC plays", Prefs.RecordSystemAudio, v => Prefs.RecordSystemAudio = v));
        s.Add(Check("Show clicks", Prefs.RecordClicks, v => Prefs.RecordClicks = v));
        s.Add(Pick("Click colour", [("Amber", "F59E0B"), ("Indigo", "4338CA"), ("Pink", "EC4899"), ("Red", "EF4444"), ("Green", "22C55E"), ("White", "FFFFFF")], Prefs.ClickColor, v => Prefs.ClickColor = v));
        s.Add(Pick("Click size", [("Small", 16), ("Medium", 22), ("Large", 32)], Prefs.ClickSize, v => Prefs.ClickSize = v));
        s.Add(Pick("Click style", [("Ring", false), ("Filled", true)], Prefs.ClickFilled, v => Prefs.ClickFilled = v));
        s.Add(Check("Animate clicks", Prefs.ClickAnimated, v => Prefs.ClickAnimated = v));
        s.Add(Check("Show the keys pressed", Prefs.RecordKeystrokes, v => Prefs.RecordKeystrokes = v, "Only while recording, and only in the video"));
        s.Add(Pick("Keys shown", [("All keys", false), ("Shortcuts only", true)], Prefs.KeystrokesShortcutsOnly, v => Prefs.KeystrokesShortcutsOnly = v));
        s.Add(Pick("Keys at", [("Bottom centre", 0), ("Bottom left", 1), ("Bottom right", 2), ("Top centre", 3)], Prefs.KeystrokePosition, v => Prefs.KeystrokePosition = v));
        s.Add(Pick("Key size", [("Small", 16), ("Medium", 22), ("Large", 30)], Prefs.KeystrokeSize, v => Prefs.KeystrokeSize = v));
        s.Add(Pick("Key style", [("Dark", true), ("Light", false)], Prefs.KeystrokesDark, v => Prefs.KeystrokesDark = v));
        s.Add(Check("Show the camera", Prefs.RecordCamera, v => Prefs.RecordCamera = v));
        s.Add(Pick("Camera shape", [("Circle", "Circle"), ("Rounded", "Rounded"), ("Whole area", "Full")], Prefs.CameraShape, v => Prefs.CameraShape = v));
        s.Add(Pick("Camera size", [("Small", 140), ("Medium", 180), ("Large", 260)], Prefs.CameraSize, v => Prefs.CameraSize = v));
        s.Add(Pick("Camera at", [("Bottom right", "bottom-right"), ("Bottom left", "bottom-left"), ("Top right", "top-right"), ("Top left", "top-left")], Prefs.CameraPosition ?? "bottom-right", v => Prefs.CameraPosition = v));
        s.Add(Check("Open the video editor after recording", Prefs.OpenEditorAfterRecording, v => Prefs.OpenEditorAfterRecording = v));
        s.Add(Note("Windows asks once before Spinform can use the microphone or camera."));
    }

    static TextBlock Sub(string text) => new() { Text = text, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 12, 0, 4) };

    TextBlock Note(string text) => new() { Text = text, Style = (Style)FindResource("Caption"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 4) };

    CheckBox Check(string text, bool value, Action<bool> changed, string? tip = null)
    {
        var box = new CheckBox { Content = text, IsChecked = value, ToolTip = tip };
        box.Click += (_, _) => { changed(box.IsChecked == true); Prefs.Save(); };
        return box;
    }

    static DockPanel Labelled(string title, FrameworkElement control)
    {
        var row = new DockPanel { Margin = new Thickness(0, 3, 0, 3) };
        var label = new TextBlock { Text = title, Width = 130, VerticalAlignment = VerticalAlignment.Center };
        DockPanel.SetDock(label, Dock.Left);
        row.Children.Add(label);
        control.HorizontalAlignment = HorizontalAlignment.Left;
        row.Children.Add(control);
        return row;
    }

    DockPanel Pick<T>(string title, IEnumerable<(string Label, T Value)> options, T selected, Action<T> changed)
    {
        var box = Ui.Combo(options, selected, v => { if (!loading) { changed(v); Prefs.Save(); } });
        box.MinWidth = 200;
        return Labelled(title, box);
    }

    DockPanel CaptureFolderRow(string title, Func<string> current, Action<string> set)
    {
        var label = new TextBlock { Text = current(), VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, Foreground = (Brush)FindResource("Secondary"), MaxWidth = 250 };
        var choose = new Button { Content = "Choose…", Margin = new Thickness(8, 0, 0, 0) };
        choose.Click += (_, _) =>
        {
            var dialog = new OpenFolderDialog { Title = $"Save {title.ToLowerInvariant()} in" };
            if (dialog.ShowDialog(this) == true) { set(dialog.FolderName); Prefs.Save(); label.Text = current(); }
        };
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        panel.Children.Add(label);
        panel.Children.Add(choose);
        return Labelled(title, panel);
    }

    TextBox ShortcutBox(CaptureAction action)
    {
        var box = new TextBox { IsReadOnly = true, IsReadOnlyCaretVisible = false, Cursor = Cursors.Hand, Text = Hotkeys.Label(action), Margin = new Thickness(0, 2, 0, 2), ToolTip = "Click, then press the shortcut" };
        box.GotKeyboardFocus += (_, _) => box.Text = "Press keys…";
        box.LostKeyboardFocus += (_, _) => box.Text = Hotkeys.Label(action) is { Length: > 0 } t ? t : "None";
        box.PreviewKeyDown += (_, e) =>
        {
            e.Handled = true;
            var key = e.Key == Key.System ? e.SystemKey : e.Key;
            if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftShift or Key.RightShift or Key.LeftAlt or Key.RightAlt or Key.LWin or Key.RWin) return;
            if (key == Key.Escape) { Keyboard.ClearFocus(); FocusManager.SetFocusedElement(this, this); return; }
            if (key is Key.Back or Key.Delete) { Hotkeys.Set(action, null); RefreshShortcuts(); Keyboard.ClearFocus(); return; }
            var mods = HotkeyModifiers.None;
            if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) mods |= HotkeyModifiers.Ctrl;
            if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) mods |= HotkeyModifiers.Shift;
            if (Keyboard.Modifiers.HasFlag(ModifierKeys.Alt)) mods |= HotkeyModifiers.Alt;
            if (Keyboard.IsKeyDown(Key.LWin) || Keyboard.IsKeyDown(Key.RWin)) mods |= HotkeyModifiers.Win;
            var hotkey = new Hotkey(mods, KeyInterop.VirtualKeyFromKey(key));
            if (hotkey.Problem is { } problem) { shortcutRows[action].Problem.Text = problem; shortcutRows[action].Problem.Visibility = Visibility.Visible; return; }
            // A shortcut can belong to one action only.
            foreach (var other in Enum.GetValues<CaptureAction>())
                if (other != action && Hotkeys.For(other) == hotkey) Hotkeys.Set(other, null);
            Hotkeys.Set(action, hotkey);
            RefreshShortcuts();
            Keyboard.ClearFocus();
        };
        return box;
    }

    void RefreshShortcuts()
    {
        foreach (var (action, (box, problem)) in shortcutRows)
        {
            if (!box.IsKeyboardFocused) box.Text = Hotkeys.Label(action) is { Length: > 0 } t ? t : "None";
            var text = Hotkeys.Problems.GetValueOrDefault(action);
            problem.Text = text ?? "";
            problem.Visibility = text is null ? Visibility.Collapsed : Visibility.Visible;
        }
        if (printScreenNote is not null)
        {
            printScreenNote.Text = Hotkeys.PrintScreenProblem ?? (Prefs.PrintScreenTakeover ? "Print Screen now captures an area." : "Print Screen opens Windows' own screen capture.");
            printScreenNote.Foreground = Hotkeys.PrintScreenProblem is null ? (Brush)FindResource("Tertiary") : (Brush)FindResource("Warning");
        }
    }
}
