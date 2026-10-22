using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Transmute.Desktop;

namespace Transmute.App;

/// The capture part of the smoke test: real screenshots through the whole pipeline (overlay,
/// thumbnail, history, frame, mark-up, pin), a real scrolling capture of a window that scrolls
/// itself, and a real two-second recording.
static partial class SmokeTest
{
    static async Task CaptureSteps(MainWindow main, string photo, string output, Func<string, Func<Task<Window>>, Task> step)
    {
        var prefs = Settings.Current;
        prefs.CaptureFolder = Path.Combine(output, "captures");
        prefs.RecordingFolder = Path.Combine(output, "captures");
        prefs.RecordCountdown = 0;
        prefs.OverlaySeconds = 0;
        var monitor = Screens.Monitors()[0];
        Log($"      display: {monitor.Label} at {monitor.Scale * 100:0}%, Windows.Graphics.Capture {(GraphicsCapture.IsAvailable ? "available" : "not available")}");
        CaptureItem? shot = null;

        await step("main window capture", async () =>
        {
            main.CaptureTab.IsChecked = true;
            await Wait(1);
            return main;
        });

        var area = new PixelRect(monitor.Bounds.X + monitor.Bounds.Width / 6, monitor.Bounds.Y + monitor.Bounds.Height / 5, monitor.Bounds.Width / 2, monitor.Bounds.Height / 2);
        await step("capture overlay", async () =>
        {
            var virt = Screens.VirtualScreen;
            var snapshot = await Task.Run(() => ScreenGrab.Area(virt));
            _ = SelectionOverlay.Pick(snapshot, virt, SelectionOverlay.Mode.Area, "Capture an area");
            await Wait(0.8);
            var overlay = SelectionOverlay.Current ?? throw new Exception("the overlay didn't open");
            overlay.Preview(area);
            await Wait(0.5);
            return overlay;
        });
        SelectionOverlay.Current?.Close();
        await step("capture all-in-one", async () =>
        {
            var virt = Screens.VirtualScreen;
            var snapshot = await Task.Run(() => ScreenGrab.Area(virt));
            _ = SelectionOverlay.Pick(snapshot, virt, SelectionOverlay.Mode.Area, "Capture", allInOne: true);
            await Wait(0.8);
            var overlay = SelectionOverlay.Current ?? throw new Exception("the overlay didn't open");
            overlay.Preview(area);
            await Wait(0.5);
            return overlay;
        });
        SelectionOverlay.Current?.Close();

        await step("quick access", async () =>
        {
            main.Activate();
            await Wait(0.3);
            var image = await Task.Run(() => ScreenGrab.Area(area));
            shot = await Capture.Deliver(image, area);
            if (!File.Exists(shot.Path)) throw new Exception("the screenshot wasn't saved");
            if (shot.HistoryId is null) throw new Exception("the screenshot isn't in the history");
            Log($"      screenshot {shot.Width} × {shot.Height}: {Path.GetFileName(shot.Path)}");
            await Wait(1);
            return QuickAccess.Open.LastOrDefault() ?? throw new Exception("no thumbnail");
        });

        await step("window capture", async () =>
        {
            var hwnd = CaptureKit.Handle(main);
            var image = await Task.Run(() => WindowCapture.Capture(hwnd));
            Log($"      window capture by {WindowCapture.LastMethod}: {image.Width} × {image.Height}");
            image = await Task.Run(() => WindowLook.Apply(image, monitor.Scale));
            var item = await Capture.Deliver(image, Screens.WindowBounds(hwnd));
            await Wait(0.8);
            return QuickAccess.Open.LastOrDefault() ?? throw new Exception("no thumbnail");
        });

        await step("frame tool", async () =>
        {
            var window = FrameWindow.Open(shot?.Path ?? photo) ?? throw new Exception("the frame window didn't open");
            await Wait(2.5);
            return window;
        });
        foreach (var w in Application.Current.Windows.OfType<FrameWindow>().ToList()) w.Close();

        await step("annotate tools", async () =>
        {
            foreach (var w in Application.Current.Windows.OfType<ImageEditorWindow>().ToList()) w.Close();
            Editors.Open(new Job(photo), main);
            var editor = Application.Current.Windows.OfType<ImageEditorWindow>().Single();
            for (var i = 0; i < 40 && editor.RenderCount == 0; i++) await Wait(0.25);
            var before = editor.RenderCount;
            editor.ShowSampleMarks();
            for (var i = 0; i < 60 && editor.RenderCount == before; i++) await Wait(0.25);
            await Wait(0.5);
            if (editor.RenderCount == before) throw new Exception("the marks didn't render");
            return editor;
        });
        foreach (var w in Application.Current.Windows.OfType<ImageEditorWindow>().ToList()) w.Close();

        await step("pin window", async () =>
        {
            var pin = PinWindow.Show(shot?.Path ?? photo) ?? throw new Exception("the pin didn't open");
            await Wait(0.8);
            return pin;
        });
        PinWindow.CloseAll();

        await step("scrolling capture", async () =>
        {
            // A window with a long list that scrolls itself, captured for real.
            var list = new StackPanel { Background = Brushes.White };
            for (var i = 1; i <= 80; i++)
                list.Children.Add(new Border
                {
                    Height = 34, Padding = new Thickness(14, 6, 14, 6), BorderBrush = new SolidColorBrush(Color.FromRgb(0xE4, 0xE2, 0xEE)), BorderThickness = new Thickness(0, 0, 0, 1),
                    Background = i % 2 == 0 ? new SolidColorBrush(Color.FromRgb(0xF7, 0xF6, 0xFB)) : Brushes.White,
                    Child = new TextBlock { Text = $"Row {i}: Spinform joins each part as the page scrolls ({i * 37 % 1000})", FontSize = 14, Foreground = new SolidColorBrush(Color.FromRgb((byte)(i * 3), 0x30, 0x90)) },
                });
            var viewer = new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden };
            var page = new Window { Width = 460, Height = 360, Content = viewer, Topmost = true, WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize, Title = "Scrolling page", ShowInTaskbar = false };
            page.Show();
            CaptureKit.MoveTo(page, monitor.WorkArea.X + 40, monitor.WorkArea.Y + 40);
            await Wait(0.6);
            var bounds = Screens.WindowBounds(CaptureKit.Handle(page));
            var inner = new PixelRect(bounds.X + 4, bounds.Y + 4, bounds.Width - 8, bounds.Height - 8);
            var cards = QuickAccess.Open.Count;
            var run = ScrollCapture.Start(inner, () => viewer.ScrollToVerticalOffset(viewer.VerticalOffset + 90));
            var done = await Task.WhenAny(run, Task.Delay(30_000));
            page.Close();
            if (done != run) { await (ScrollCapture.Current?.Done() ?? Task.CompletedTask); throw new Exception("the scrolling capture didn't finish within 30 s"); }
            var card = QuickAccess.Open.LastOrDefault();
            if (card is null || QuickAccess.Open.Count == cards && card.Item.Kind != CaptureKind.Screenshot) throw new Exception("no result");
            Log($"      stitched {card.Item.Width} × {card.Item.Height} from a {inner.Width} × {inner.Height} area");
            if (card.Item.Height < inner.Height * 3) throw new Exception($"only {card.Item.Height} pixels tall");
            await Wait(0.5);
            return PinWindow.Show(card.Item.Path) ?? throw new Exception("couldn't show the result");
        });
        PinWindow.CloseAll();

        await step("history", async () =>
        {
            var window = HistoryWindow.Open();
            await Wait(2);
            return window;
        });
        foreach (var w in Application.Current.Windows.OfType<HistoryWindow>().ToList()) w.Close();

        if (Tools.Ffmpeg is not null)
        {
            Window? bar = null;
            Task? recording = null;
            await step("recording bar", async () =>
            {
                var recordArea = new PixelRect(monitor.Bounds.X, monitor.Bounds.Y, Math.Min(800, monitor.Bounds.Width), Math.Min(500, monitor.Bounds.Height));
                recording = RecordingSession.Prepare(recordArea, IntPtr.Zero, TimeSpan.FromSeconds(2.5));
                for (var i = 0; i < 20 && RecordingSession.Current?.IsRecording != true; i++) await Wait(0.25);
                if (RecordingSession.Current?.IsRecording != true) throw new Exception("the recording didn't start");
                await Wait(1);
                bar = RecordingSession.Current.Bar;
                return bar;
            });
            await step("recording thumbnail", async () =>
            {
                if (recording is null) throw new Exception("no recording");
                if (await Task.WhenAny(recording, Task.Delay(40_000)) != recording) throw new Exception("the recording didn't finish within 40 s");
                var card = QuickAccess.Open.LastOrDefault(c => c.Item.Kind == CaptureKind.Recording) ?? throw new Exception("no recording thumbnail");
                Log($"      recorded {card.Item.Width} × {card.Item.Height}, {card.Item.Seconds:0.0} s: {Path.GetFileName(card.Item.Path)}");
                if (card.Item.Seconds < 1.5) throw new Exception($"only {card.Item.Seconds:0.0} s");
                await Wait(0.5);
                return card;
            });
        }

        await step("capture settings", async () =>
        {
            SettingsWindow.Open("capture");
            await Wait(1.2);
            return Application.Current.Windows.OfType<SettingsWindow>().Single();
        });
        foreach (var w in Application.Current.Windows.OfType<SettingsWindow>().ToList()) w.Close();
        foreach (var card in QuickAccess.Open.ToList()) card.Dismiss(0, animate: false);
        main.ConvertTab.IsChecked = true;
    }
}
