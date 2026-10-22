using System.Windows;
using Transmute.Desktop;

namespace Transmute.App;

/// A capture or recording that has been made: the file people act on (the saved copy, or the
/// history copy when saving is off) and what it is.
sealed record CaptureItem(string Path, CaptureKind Kind, int Width, int Height, double Seconds = 0, PixelRect? Where = null, string? HistoryId = null);

/// Runs every capture: from a shortcut, the tray, the Capture tab or the command line.
static class Capture
{
    static Settings Prefs => Settings.Current;
    static bool busy;

    public static bool IsBusy => busy;

    public static async Task Run(CaptureAction action, bool fromApp = false)
    {
        if (RecordingSession.Current is { } recording && action is CaptureAction.RecordArea or CaptureAction.RecordScreen)
        {
            await recording.StopFromShortcut();
            return;
        }
        if (action == CaptureAction.History) { HistoryWindow.Open(); return; }
        if (busy || ScrollCapture.Current is not null || RecordingSession.Current is not null) return;
        busy = true;
        var hidden = fromApp ? HideAppWindows() : [];
        IDisposable? icons = null;
        try
        {
            if (Prefs.HideDesktopIcons && action is not CaptureAction.Text)
            {
                icons = DesktopIcons.Hide();
                await Task.Delay(250);
            }
            else if (hidden.Count > 0) await Task.Delay(220);
            switch (action)
            {
                case CaptureAction.Area: await Area(); break;
                case CaptureAction.AllInOne: await AllInOne(); break;
                case CaptureAction.Window: await Window(); break;
                case CaptureAction.FullScreen: await Screen(Screens.MonitorUnderCursor()); break;
                case CaptureAction.Previous: await Previous(); break;
                case CaptureAction.Text: await Text(); break;
                case CaptureAction.Scrolling: await Scrolling(); break;
                case CaptureAction.RecordArea: await Record(SelectionOverlay.Mode.Area); break;
                case CaptureAction.RecordScreen: await RecordScreen(Screens.MonitorUnderCursor()); break;
            }
        }
        catch (Exception e)
        {
            Toast.Show("Couldn't capture", JobQueue.Describe(e), ok: false, seconds: 8);
        }
        finally
        {
            icons?.Dispose();
            foreach (var w in hidden) { w.Show(); }
            busy = false;
        }
    }

    /// Hides Spinform's own windows while the user picks something on screen.
    static List<Window> HideAppWindows()
    {
        var list = Application.Current.Windows.OfType<Window>().Where(w => w.IsVisible && (w is MainWindow or HistoryWindow)).ToList();
        foreach (var w in list) w.Hide();
        return list;
    }

    // Choosing

    static async Task<(SelectionOverlay.Result? Result, BgraImage Snapshot, PixelRect Virt)> Select(SelectionOverlay.Mode mode, string purpose,
        bool allInOne = false, CaptureAction action = CaptureAction.Area)
    {
        var virt = Screens.VirtualScreen;
        var snapshot = await Task.Run(() => ScreenGrab.Area(virt));
        var result = await SelectionOverlay.Pick(snapshot, virt, mode, purpose, allInOne, action);
        Prefs.Save();
        return (result, snapshot, virt);
    }

    static async Task<bool> Timer(PixelRect where)
    {
        if (Prefs.SelfTimer <= 0) return true;
        return await Countdown.Run(Prefs.SelfTimer, Screens.MonitorAt(where.X + where.Width / 2, where.Y + where.Height / 2));
    }

    static async Task Area(CaptureAction action = CaptureAction.Area)
    {
        var (result, snapshot, virt) = await Select(SelectionOverlay.Mode.Area, "Capture an area");
        if (result is null) return;
        await Finish(result, snapshot, virt);
    }

    static async Task AllInOne()
    {
        var (result, snapshot, virt) = await Select(SelectionOverlay.Mode.Area, "Capture", allInOne: true);
        if (result is null) return;
        switch (result.Action)
        {
            case CaptureAction.Text: await RecognizeArea(result.Rect, snapshot, virt); break;
            case CaptureAction.Scrolling: await ScrollCapture.Start(result.Rect); break;
            case CaptureAction.RecordArea: await RecordingSession.Prepare(result.Rect, IntPtr.Zero); break;
            default: await Finish(result, snapshot, virt); break;
        }
    }

    static async Task Finish(SelectionOverlay.Result result, BgraImage snapshot, PixelRect virt)
    {
        if (result.Window != IntPtr.Zero) { await WindowShot(result.Window, result.Rect); return; }
        BgraImage image;
        if (Prefs.SelfTimer > 0 || !SelectionOverlay.LastFrozen)
        {
            if (!await Timer(result.Rect)) return;
            await Task.Delay(150); // let the overlay disappear
            image = await Task.Run(() => ScreenGrab.Area(result.Rect));
        }
        else image = snapshot.Crop(result.Rect.X - virt.X, result.Rect.Y - virt.Y, result.Rect.Width, result.Rect.Height);
        await Deliver(image, result.Rect);
    }

    static async Task Window()
    {
        var (result, _, _) = await Select(SelectionOverlay.Mode.Window, "Capture a window");
        if (result is null) return;
        if (result.Window == IntPtr.Zero) { await Deliver(await Task.Run(() => ScreenGrab.Area(result.Rect)), result.Rect); return; }
        await WindowShot(result.Window, result.Rect);
    }

    static async Task WindowShot(IntPtr hwnd, PixelRect bounds)
    {
        if (!await Timer(bounds)) return;
        await Task.Delay(120); // let the overlay disappear
        var image = await Task.Run(() => WindowCapture.Capture(hwnd));
        image = await Task.Run(() => WindowLook.Apply(image, Screens.MonitorAt(bounds.X, bounds.Y).Scale));
        await Deliver(image, bounds);
    }

    public static async Task Screen(MonitorInfo? monitor)
    {
        var area = monitor?.Bounds ?? Screens.VirtualScreen;
        if (!await Timer(area)) return;
        await Task.Delay(80);
        await Deliver(await Task.Run(() => ScreenGrab.Area(area)), area);
    }

    static async Task Previous()
    {
        if (PixelRect.Parse(Prefs.LastArea) is not { } area || Screens.VirtualScreen.Intersect(area).IsEmpty)
        {
            Toast.Show("No earlier area yet", "Capture an area first; then this captures the same spot again.", ok: false);
            return;
        }
        area = Screens.VirtualScreen.Intersect(area);
        if (!await Timer(area)) return;
        await Task.Delay(60);
        await Deliver(await Task.Run(() => ScreenGrab.Area(area)), area);
    }

    static async Task Scrolling()
    {
        var (result, _, _) = await Select(SelectionOverlay.Mode.Area, "Choose the part that scrolls");
        if (result is null) return;
        await ScrollCapture.Start(result.Rect);
    }

    static async Task Record(SelectionOverlay.Mode mode)
    {
        var (result, _, _) = await Select(mode, mode == SelectionOverlay.Mode.Window ? "Record a window" : "Record an area");
        if (result is null) return;
        await RecordingSession.Prepare(result.Rect, result.Window);
    }

    public static async Task RecordWindow()
    {
        if (busy || RecordingSession.Current is not null) return;
        busy = true;
        try { await Record(SelectionOverlay.Mode.Window); }
        finally { busy = false; }
    }

    public static async Task RecordScreen(MonitorInfo monitor) => await RecordingSession.Prepare(monitor.Bounds, IntPtr.Zero);

    // Text

    static async Task Text()
    {
        var (result, snapshot, virt) = await Select(SelectionOverlay.Mode.Area, "Copy text from");
        if (result is null) return;
        await RecognizeArea(result.Rect, snapshot, virt);
    }

    static async Task RecognizeArea(PixelRect rect, BgraImage snapshot, PixelRect virt)
    {
        if (!SelectionOverlay.LastFrozen)
        {
            await Task.Delay(150);
            snapshot = await Task.Run(() => ScreenGrab.Area(virt));
        }
        await Recognize(snapshot.Crop(rect.X - virt.X, rect.Y - virt.Y, rect.Width, rect.Height));
    }

    /// Reads the text and QR codes in a picture, copies them and says what was found.
    public static async Task Recognize(BgraImage image)
    {
        var codes = await Task.Run(() => TextRecognizer.ReadQrCodes(image));
        string text = "";
        string? language = null;
        Exception? problem = null;
        try
        {
            var outcome = await TextRecognizer.Recognize(image, Prefs.OcrLanguage, Prefs.OcrKeepLineBreaks);
            text = outcome.Text;
            language = outcome.Language;
        }
        catch (Exception e) { problem = e; }
        var all = string.Join(Environment.NewLine, new[] { text }.Concat(codes).Where(t => t.Trim().Length > 0));
        if (all.Trim().Length == 0)
        {
            if (problem is OcrUnavailableException)
                Toast.Show("Text recognition isn't set up", problem.Message, ok: false, action: ("Open Language settings", () => Native.Open("ms-settings:regionlanguage")), seconds: 20);
            else
                Toast.Show("No text found", problem is null ? "Try a bigger area, or one with clearer text." : JobQueue.Describe(problem), ok: false, glyph: "text");
            return;
        }
        CaptureKit.CopyText(all);
        var words = all.Split((char[])[' ', '\n', '\r', '\t'], StringSplitOptions.RemoveEmptyEntries).Length;
        var what = codes.Count > 0 && text.Trim().Length == 0 ? $"Copied {codes.Count} QR code{(codes.Count == 1 ? "" : "s")}"
            : $"Copied {words} word{(words == 1 ? "" : "s")}{(codes.Count > 0 ? $" and {codes.Count} QR code{(codes.Count == 1 ? "" : "s")}" : "")}";
        Toast.Show(what, all.Length > 160 ? all[..160] + "…" : all, glyph: "text");
        if (Prefs.HistoryDays != 0)
        {
            var file = OutputPaths.TempFile("txt");
            await File.WriteAllTextAsync(file, all);
            var preview = all.Replace("\r", " ").Replace("\n", " ");
            CaptureKit.History.Add(file, CaptureKind.Text, move: true, preview: preview.Length > 80 ? preview[..80] + "…" : preview);
        }
        _ = language;
    }

    // Results

    /// Saves, remembers, copies and shows a new screenshot as the settings say.
    public static async Task<CaptureItem> Deliver(BgraImage image, PixelRect? where, string what = "Screenshot")
    {
        var ext = Prefs.CaptureFormat == "jpg" ? "jpg" : "png";
        var temp = OutputPaths.TempFile(ext);
        await Task.Run(() => image.Save(temp, Prefs.ImageQuality));
        string? saved = null;
        if (Prefs.CaptureAutoSave)
        {
            try
            {
                Directory.CreateDirectory(CaptureKit.CaptureFolder);
                saved = OutputPaths.Unique(CaptureKit.CaptureFolder, CaptureKit.NewName(what), ext);
                File.Copy(temp, saved);
            }
            catch (Exception e)
            {
                saved = null;
                Toast.Show("Couldn't save to the capture folder", e.Message, ok: false);
            }
        }
        var item = Remember(temp, CaptureKind.Screenshot, image.Width, image.Height, 0, saved, where);
        if (Prefs.CaptureCopy) { try { CaptureKit.CopyImage(item.Path); } catch { } }
        if (Prefs.CaptureOverlay) QuickAccess.Show(item);
        else Toast.Show(saved is null ? "Screenshot taken" : "Screenshot saved", saved is null ? (Prefs.CaptureCopy ? "It's on the clipboard." : null) : Path.GetFileName(saved));
        return item;
    }

    /// Adds a finished file to the history (moving it there) unless history is off.
    public static CaptureItem Remember(string temp, CaptureKind kind, int width, int height, double seconds, string? saved, PixelRect? where)
    {
        string path = saved ?? temp;
        string? id = null;
        if (Prefs.HistoryDays != 0)
        {
            try
            {
                var entry = CaptureKit.History.Add(temp, kind, width, height, seconds, saved, move: true);
                id = entry.Id;
                if (saved is null) path = CaptureKit.History.PathOf(entry);
                CaptureKit.History.Prune(Prefs.HistoryDays);
            }
            catch { }
        }
        else if (saved is not null) OutputPaths.TryDelete(temp);
        return new CaptureItem(path, kind, width, height, seconds, where, id);
    }

    /// Text from a picture file (or a video's current frame) chosen by the user.
    public static async Task RecognizeFile(string path)
    {
        try
        {
            BgraImage image;
            if (Kinds.Of(path) == FileKind.Video)
            {
                var frame = await VideoEditEngine.PreviewFrame(path, 0, 4000, default) ?? throw new ConversionException("Couldn't read a frame of that video.");
                image = CaptureKit.FromBitmap(Editors.Bitmap(frame));
            }
            else
            {
                using var magick = ImageConverter.LoadFirst(path);
                image = BgraImage.FromMagick(magick);
            }
            await Recognize(image);
        }
        catch (Exception e)
        {
            Toast.Show("Couldn't read that file", JobQueue.Describe(e), ok: false);
        }
    }
}
