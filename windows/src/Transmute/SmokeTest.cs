using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Transmute.App;

/// Run by the build server: opens every window with sample files, saves a picture of each, runs
/// a conversion through the real queue and checks how File Explorer drags look to the wheel.
/// Transmute --smoke-test <fixtures folder> <output folder>
static class SmokeTest
{
    public static bool Active { get; private set; }
    static readonly List<string> problems = [];
    static StreamWriter? log;

    public static void Fail(Exception e)
    {
        problems.Add(e.ToString());
        Log($"FAIL  {e.GetType().Name}: {e.Message}");
    }

    static void Log(string line)
    {
        Console.WriteLine(line);
        log?.WriteLine(line);
        log?.Flush();
    }

    static Task Wait(double seconds) => Task.Delay(TimeSpan.FromSeconds(seconds));

    public static async Task Run(string fixtures, string output)
    {
        Active = true;
        Directory.CreateDirectory(output);
        log = new StreamWriter(Path.Combine(output, "smoke-test.log"));
        // Keep test settings away from the real ones.
        Environment.SetEnvironmentVariable("TRANSMUTE_SETTINGS_DIR", Path.Combine(output, "settings"));
        Log($"Transmute {Feedback.Version} smoke test on {RuntimeInformation.OSDescription} ({RuntimeInformation.ProcessArchitecture})");
        Log($"ffmpeg: {Tools.Ffmpeg ?? "missing"}");
        var work = Path.Combine(output, "files");
        Directory.CreateDirectory(work);
        string Copy(string name)
        {
            var target = Path.Combine(work, name);
            File.Copy(Path.Combine(fixtures, name), target, true);
            return target;
        }

        try
        {
            var photo = Copy("photo.jpg");
            var clip = Copy("clip.mp4");
            var tone = Copy("tone.wav");
            var report = Copy("report.docx");
            var pdfSource = Directory.GetFiles(fixtures, "*.pdf").FirstOrDefault();
            var jobs = JobQueue.Shared.Add([photo, clip, tone, report]);

            await Step("main window", async () =>
            {
                App.Current.ShowMain();
                await Wait(1.5);
                return Application.Current.Windows.OfType<MainWindow>().Single();
            });

            await Step("convert through the queue", async () =>
            {
                await JobQueue.Shared.Start([(jobs[0], new JobOperation.Convert(OutputFormat.Png))], reveal: false);
                if (jobs[0].Status != JobStatus.Done) throw new Exception($"photo.jpg → PNG ended {jobs[0].Status}: {jobs[0].Error}");
                Log($"      made {Path.GetFileName(jobs[0].Result!.Outputs[0])}");
                return Application.Current.Windows.OfType<MainWindow>().Single();
            });

            await Step("settings", async () =>
            {
                SettingsWindow.Open(Application.Current.Windows.OfType<MainWindow>().Single());
                await Wait(1);
                return Application.Current.Windows.OfType<SettingsWindow>().Single();
            });

            await Step("floating files", async () =>
            {
                Shelf.Shared.Add([photo, report]);
                await Wait(1);
                return Application.Current.Windows.OfType<ShelfWindow>().Single();
            });

            await Step("drag wheel (formats)", async () =>
            {
                WheelWindow.Shared.Preview(WheelKind.Convert, [photo]);
                await Wait(0.8);
                return WheelWindow.Shared;
            });
            await Step("drag wheel (tools)", async () =>
            {
                WheelWindow.Shared.Preview(WheelKind.Tools, [photo]);
                await Wait(0.8);
                return WheelWindow.Shared;
            });
            await Step("drag wheel (actions)", async () =>
            {
                WheelWindow.Shared.Preview(WheelKind.Actions, [photo]);
                await Wait(0.8);
                var wheel = WheelWindow.Shared;
                return wheel;
            });
            // A customized wheel: PDF moved to the right, RTF taken off, Float added from the actions.
            Settings.Current.WheelLayouts[WheelLayout.Key(WheelKind.Convert, FileKind.Document)] =
                ["convert:docx", "convert:pdf", "convert:txt", "action:float"];
            await Step("drag wheel (customized)", async () =>
            {
                WheelWindow.Shared.Preview(WheelKind.Convert, [report]);
                await Wait(0.8);
                return WheelWindow.Shared;
            });
            WheelWindow.Shared.Hide();
            await Step("wheel editor", async () =>
            {
                var editor = WheelEditorWindow.Open(Application.Current.Windows.OfType<SettingsWindow>().SingleOrDefault());
                editor.Select(WheelKind.Convert, FileKind.Document);
                editor.Move(3, 2);
                await Wait(1);
                var saved = Settings.Current.WheelLayouts[WheelLayout.Key(WheelKind.Convert, FileKind.Document)];
                if (!saved.SequenceEqual(["convert:docx", "convert:pdf", "action:float", "convert:txt"]))
                    throw new Exception("swapping two bubbles saved " + string.Join(", ", saved));
                return editor;
            });
            await Step("wheel editor (tools)", async () =>
            {
                var editor = WheelEditorWindow.Open();
                editor.Select(WheelKind.Tools, FileKind.Image);
                await Wait(0.8);
                return editor;
            });
            Application.Current.Windows.OfType<WheelEditorWindow>().SingleOrDefault()?.Close();
            Settings.Current.WheelLayouts.Clear();

            await Step("progress card", async () =>
            {
                Hud.Shared.Track([jobs[0]]);
                await Wait(0.8);
                return Hud.Shared;
            });

            var main = Application.Current.Windows.OfType<MainWindow>().Single();
            await Step("photo editor", async () =>
            {
                Editors.Open(jobs[0], main);
                await Wait(4);
                return Application.Current.Windows.OfType<ImageEditorWindow>().Single();
            });
            await Step("video editor", async () =>
            {
                Editors.Open(jobs[1], main);
                await Wait(5);
                return Application.Current.Windows.OfType<VideoEditorWindow>().Single();
            });
            await Step("audio editor", async () =>
            {
                Editors.Open(jobs[2], main);
                await Wait(4);
                return Application.Current.Windows.OfType<AudioEditorWindow>().Single();
            });
            await Step("info", async () =>
            {
                new MetadataWindow(jobs[0]) { Owner = main }.Show();
                await Wait(3);
                return Application.Current.Windows.OfType<MetadataWindow>().Single();
            });

            DragProbe();
        }
        catch (Exception e)
        {
            Fail(e);
        }

        Log(problems.Count == 0 ? "SMOKE TEST PASSED" : $"SMOKE TEST FAILED ({problems.Count} problems)");
        log?.Dispose();
        Environment.Exit(problems.Count == 0 ? 0 : 1);

        async Task Step(string name, Func<Task<Window>> body)
        {
            try
            {
                var window = await body();
                Snapshot(window, Path.Combine(output, name.Replace(' ', '-').Replace("(", "").Replace(")", "") + ".png"));
                Log($"PASS  {name}");
            }
            catch (Exception e)
            {
                problems.Add($"{name}: {e}");
                Log($"FAIL  {name}: {e}");
            }
        }
    }

    static void Snapshot(Window window, string path)
    {
        if (window.Content is not FrameworkElement content || content.ActualWidth < 1) return;
        var dpi = VisualTreeHelper.GetDpi(content);
        var bitmap = new RenderTargetBitmap((int)(content.ActualWidth * dpi.DpiScaleX), (int)(content.ActualHeight * dpi.DpiScaleY), dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
        // Windows without a background of their own get the window's.
        var frame = new DrawingVisual();
        using (var dc = frame.RenderOpen())
        {
            dc.DrawRectangle(window.Background is SolidColorBrush { Color.A: > 0 } b ? b : Brushes.White, null, new Rect(0, 0, content.ActualWidth, content.ActualHeight));
            dc.DrawRectangle(new VisualBrush(content), null, new Rect(0, 0, content.ActualWidth, content.ActualHeight));
        }
        bitmap.Render(frame);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var file = File.Create(path);
        encoder.Save(file);
    }

    /// Starts a real OLE drag (as File Explorer does) and records what the drag watcher sees, so
    /// the wheel's drag detection is checked on real Windows.
    static void DragProbe()
    {
        // On some machines no mouse input reaches the drag loop, so it never ends: give up after 20 s.
        var finished = false;
        new Thread(() =>
        {
            Thread.Sleep(20_000);
            if (finished) return;
            Log("WARN  drag detection: the test drag didn't finish (no mouse input on this machine)");
            Log(problems.Count == 0 ? "SMOKE TEST PASSED" : $"SMOKE TEST FAILED ({problems.Count} problems)");
            log?.Flush();
            Environment.Exit(problems.Count == 0 ? 0 : 1);
        }) { IsBackground = true }.Start();
        var seen = new HashSet<string>();
        var detected = false;
        var calls = 0;
        var source = new System.Windows.Controls.Border { Width = 10, Height = 10 };
        var window = new Window { Width = 120, Height = 80, Content = source, ShowActivated = true, Topmost = true };
        window.Show();
        window.Activate();
        System.Windows.QueryContinueDragEventHandler query = (_, e) =>
        {
            calls++;
            seen.Add(Native.CaptureClassOfThisThread());
            detected |= Native.OleDragInProgress();
            e.Action = calls < 40 ? DragAction.Continue : DragAction.Cancel;
            e.Handled = true;
        };
        DragDrop.AddQueryContinueDragHandler(source, query);
        try
        {
            DragDrop.DoDragDrop(source, new DataObject(DataFormats.FileDrop, new[] { Environment.ProcessPath! }), DragDropEffects.Copy);
        }
        catch (Exception e)
        {
            Log($"NOTE  drag probe couldn't start a drag: {e.Message}");
        }
        finished = true;
        window.Close();
        Log($"{(detected ? "PASS" : "WARN")}  drag detection: {(detected ? "seen" : "not seen")} (capture window classes: {string.Join(", ", seen.Where(s => s.Length > 0).DefaultIfEmpty("none"))}; {calls} checks)");
    }
}
