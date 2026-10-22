using System.Diagnostics;
using ImageMagick;
using ImageMagick.Drawing;
using Transmute;
using Transmute.Desktop;

/// Screenshot and recording checks: the pure parts (stitching, frames, marks, history,
/// shortcuts) everywhere, and the real thing (screen grabs, text recognition, a short
/// recording) on Windows.
static partial class Tests
{
    sealed class Skip(string reason) : Exception(reason);
    static bool Skipped(Exception e) => e is Skip;
    static Task<IReadOnlyList<string>> None() => Task.FromResult<IReadOnlyList<string>>([]);

    /// A tall picture whose every row is different, with a few blank stretches like a web page.
    static BgraImage Page(int width, int height, int seed)
    {
        var random = new Random(seed);
        var image = new BgraImage(width, height);
        var p = image.Pixels;
        for (var y = 0; y < height; y++)
        {
            var blank = y % 97 < 9;
            byte shade = (byte)random.Next(256);
            for (var x = 0; x < width; x++)
            {
                var i = (y * width + x) * 4;
                if (blank) { p[i] = p[i + 1] = p[i + 2] = 250; }
                else
                {
                    p[i] = (byte)((x * 7 + y * 3) & 0xFF);
                    p[i + 1] = shade;
                    p[i + 2] = (byte)random.Next(256);
                }
                p[i + 3] = 255;
            }
        }
        return image;
    }

    static BgraImage Stack(params BgraImage[] parts)
    {
        var result = new BgraImage(parts[0].Width, parts.Sum(p => p.Height));
        var offset = 0;
        foreach (var part in parts) { Buffer.BlockCopy(part.Pixels, 0, result.Pixels, offset, part.Pixels.Length); offset += part.Pixels.Length; }
        return result;
    }

    static BgraImage Solid(int w, int h, byte r, byte g, byte b)
    {
        var image = new BgraImage(w, h);
        for (var i = 0; i < image.Pixels.Length; i += 4) { image.Pixels[i] = b; image.Pixels[i + 1] = g; image.Pixels[i + 2] = r; image.Pixels[i + 3] = 255; }
        return image;
    }

    static bool SameImage(BgraImage a, BgraImage b) => a.Width == b.Width && a.Height == b.Height && a.Pixels.AsSpan(0, a.Width * a.Height * 4).SequenceEqual(b.Pixels.AsSpan(0, b.Width * b.Height * 4));

    /// Just these checks (Transmute.SelfTest --capture-only), for working on capture.
    public static async Task<int> RunCaptureOnly()
    {
        outDir = Path.Combine(Path.GetTempPath(), "spinform-capture-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(outDir);
        await CaptureChecks(new ConversionOptions { OutputFolder = Sub("capture") });
        Console.WriteLine($"\n{passed} passed, {skipped} skipped, {Failed.Count} failed");
        foreach (var f in Failed) Console.WriteLine($"  FAILED: {f}");
        return Failed.Count == 0 ? 0 : 1;
    }

    static async Task CaptureChecks(ConversionOptions options)
    {
        var folder = options.OutputFolder!;
        await Check("Shortcuts: parse, write back and check", () =>
        {
            Expect(Hotkey.Parse("Ctrl+Shift+4") == new Hotkey(HotkeyModifiers.Ctrl | HotkeyModifiers.Shift, '4'), "Ctrl+Shift+4");
            Expect(Hotkey.Parse(" shift + ctrl + a ")?.ToString() == "Ctrl+Shift+A", "order and case");
            Expect(Hotkey.Parse("Win+Alt+F9")?.ToString() == "Alt+Win+F9", "Win+Alt+F9");
            Expect(Hotkey.Parse("PrtScn") == new Hotkey(HotkeyModifiers.None, Hotkey.PrintScreen), "PrtScn alias");
            Expect(Hotkey.Parse("Ctrl+Shift+=")?.Key == 0xBB && Hotkey.Parse("Ctrl++")?.Key == 0xBB, "plus key");
            Expect(Hotkey.Parse("Ctrl+Shift") is null && Hotkey.Parse("Ctrl+A+B") is null && Hotkey.Parse("Ctrl+Banana") is null && Hotkey.Parse("") is null, "rejects non-shortcuts");
            Expect(Hotkey.Parse("Win+Shift+S")!.Value.Problem is not null, "Win+Shift+S is Windows' own");
            Expect(Hotkey.Parse("PrintScreen")!.Value.Problem is not null && Hotkey.Parse("Alt+PrintScreen")!.Value.Problem is not null, "Print Screen is Windows' own");
            Expect(Hotkey.Parse("Shift+A")!.Value.Problem is not null && Hotkey.Parse("F8")!.Value.Problem is null, "typing keys need Ctrl, Alt or Win");
            var defaults = Enum.GetValues<CaptureAction>().Select(Hotkey.Default).Where(h => h is not null).Select(h => h!.Value).ToList();
            Expect(defaults.Count >= 8 && defaults.Distinct().Count() == defaults.Count, "defaults must be distinct");
            Expect(defaults.All(h => h.Problem is null && h.Key != Hotkey.PrintScreen && !(h.Key == 'S' && h.Modifiers.HasFlag(HotkeyModifiers.Win))), "defaults clash with Windows");
            foreach (var h in defaults) Expect(Hotkey.Parse(h.ToString()) == h, $"{h} doesn't round-trip");
            return None();
        });

        await Check("Scrolling capture: stitch overlapping frames back into the page", () =>
        {
            var page = Page(360, 1500, 1);
            var offsets = new[] { 0, 120, 233, 410, 411, 690, 900, 1180 };
            var stitcher = new ScrollStitcher();
            foreach (var o in offsets) stitcher.Add(page.Crop(0, o, 360, 320));
            var result = stitcher.Result();
            Expect(SameImage(result, page), $"stitched {result.Width}×{result.Height}, expected the 360×1500 page exactly");
            Expect(stitcher.Frames == offsets.Length, $"used {stitcher.Frames} frames");
            return None();
        });
        await Check("Scrolling capture: a sticky header and footer appear once", () =>
        {
            var header = Solid(300, 40, 30, 60, 200);
            var footer = Page(300, 30, 9);
            var content = Page(300, 1200, 2);
            var stitcher = new ScrollStitcher();
            var offsets = new[] { 0, 150, 260, 500, 640, 880 };
            foreach (var o in offsets) stitcher.Add(Stack(header, content.Crop(0, o, 300, 280), footer));
            stitcher.Add(Stack(header, content.Crop(0, 880, 300, 280), footer)); // no movement
            var expected = Stack(header, content.Crop(0, 0, 300, 880 + 280), footer);
            var result = stitcher.Result();
            Expect(SameImage(result, expected), $"got {result.Width}×{result.Height}, expected {expected.Width}×{expected.Height}");
            return None();
        });
        await Check("Scrolling capture: sideways, and a jump too far is refused", () =>
        {
            var wide = Page(900, 260, 3).Transposed().Crop(0, 0, 260, 900).Transposed(); // 900 wide, 260 tall, unique columns
            var sideways = new ScrollStitcher(ScrollDirection.Horizontal);
            foreach (var o in new[] { 0, 140, 300, 520 }) sideways.Add(wide.Crop(o, 0, 380, 260));
            var r = sideways.Result();
            Expect(SameImage(r, wide), $"sideways got {r.Width}×{r.Height}");
            var page = Page(300, 2000, 4);
            var jumpy = new ScrollStitcher();
            jumpy.Add(page.Crop(0, 0, 300, 300));
            Expect(jumpy.Add(page.Crop(0, 900, 300, 300)) == StitchStep.Lost, "a jump with no overlap should be refused");
            Expect(jumpy.Add(page.Crop(0, 0, 300, 300)) == StitchStep.Unchanged, "the same frame again changes nothing");
            return None();
        });

        await Check("Background frame: layout for each shape and alignment", () =>
        {
            var style = new FrameStyle { Padding = 0.1 };
            Expect(Frames.Layout(1000, 500, style) == (1200, 700, 100, 100), $"fit: {Frames.Layout(1000, 500, style)}");
            var (w, h, _, _) = Frames.Layout(1000, 500, style with { Aspect = FrameAspect.Square });
            Expect(w == 1200 && h == 1200, $"square: {w}×{h}");
            (w, h, _, _) = Frames.Layout(1000, 500, style with { Aspect = FrameAspect.Story });
            Expect(Math.Abs(w / (double)h - 9.0 / 16) < 0.01, $"9:16: {w}×{h}");
            var left = Frames.Layout(1000, 500, style with { Aspect = FrameAspect.Square, Align = FrameAlign.TopLeft });
            Expect(left.X == 100 && left.Y == 100, $"top-left: {left}");
            var bottomRight = Frames.Layout(1000, 500, style with { Aspect = FrameAspect.Square, Align = FrameAlign.BottomRight });
            Expect(bottomRight.X == 100 && bottomRight.Y == 1200 - 500 - 100, $"bottom-right: {bottomRight}");
            Expect(Frames.BuiltIn.Length >= 20 && Frames.BuiltIn.Select(p => p.Id).Distinct().Count() == Frames.BuiltIn.Length, "twenty distinct presets");
            return None();
        });
        await Check("Background frame: renders the background, rounded corners and a shadow", () =>
        {
            using var picture = new MagickImage(MagickColors.Yellow, 400, 300);
            using var framed = Frames.Render(picture, new FrameStyle { Background = FrameBackground.Solid, From = "2040C0", Padding = 0.1, Corners = 0.1, Shadow = 1 });
            Expect(framed.Width == 480 && framed.Height == 380, $"size {framed.Width}×{framed.Height}");
            var corner = Pixel(framed, 2, 2);
            Expect(Math.Abs(corner.R - 0x20 / 255.0) < 0.03 && Math.Abs(corner.B - 0xC0 / 255.0) < 0.03, $"background {corner}");
            var middle = Pixel(framed, 240, 190);
            Expect(middle.R > 0.95 && middle.G > 0.95 && middle.B < 0.1, $"picture {middle}");
            var rounded = Pixel(framed, 41, 41);
            Expect(rounded.B > 0.5, $"the picture's corner should be rounded off: {rounded}");
            var below = Pixel(framed, 240, 352);
            Expect(below.B < 0xC0 / 255.0 - 0.05, $"there should be a shadow under the picture: {below}");
            var gradient = Frames.Render(picture, Frames.BuiltIn[0].Style);
            var a = Pixel(gradient, 1, 1);
            var b = Pixel(gradient, (int)gradient.Width - 2, (int)gradient.Height - 2);
            Expect(a.B > a.R && b.R > b.B, $"Spinform gradient runs indigo to pink: {a} → {b}");
            var path = Path.Combine(folder, "framed.png");
            gradient.Write(path);
            gradient.Dispose();
            return Task.FromResult<IReadOnlyList<string>>([path]);
        });
        await Check("Background frame: auto balance evens out the margins", () =>
        {
            var image = Solid(200, 100, 255, 255, 255);
            for (var y = 20; y < 60; y++) for (var x = 10; x < 70; x++) { var i = (y * 200 + x) * 4; image.Pixels[i] = image.Pixels[i + 1] = image.Pixels[i + 2] = 0; }
            var box = Frames.Balanced(image);
            Expect(box == (0, 0, 80, 80), $"balanced box {box}");
            return None();
        });

        await Check("Marks: oval, line, steps, spotlight, filled box, pencil, arrows and text styles", async () =>
        {
            var white = Path.Combine(folder, "white.png");
            using (var canvas = new MagickImage(MagickColors.White, 400, 300)) canvas.Write(white);
            var blue = new Rgba(0, 0, 1);
            var edit = new ImageEdit
            {
                Annotations =
                [
                    new Annotation(AnnotationKind.Spotlight, new NormPoint(0.75, 0.75), new NormPoint(0.95, 0.95), Rgba.Black, 0.01),
                    new Annotation(AnnotationKind.Ellipse, new NormPoint(0.05, 0.05), new NormPoint(0.25, 0.25), blue, 0.01),
                    new Annotation(AnnotationKind.Line, new NormPoint(0.3, 0.1), new NormPoint(0.5, 0.1), blue, 0.02),
                    new Annotation(AnnotationKind.Step, new NormPoint(0.6, 0.15), default, Rgba.Red, 0.05, "2"),
                    new Annotation(AnnotationKind.FilledRectangle, new NormPoint(0.05, 0.4), new NormPoint(0.15, 0.5), Rgba.Green, 0.01),
                    new Annotation(AnnotationKind.Pencil, default, default, blue, 0.015, Points: [new(0.2, 0.45), new(0.25, 0.5), new(0.3, 0.45)]),
                    new Annotation(AnnotationKind.Arrow, new NormPoint(0.05, 0.65), new NormPoint(0.3, 0.65), blue, 0.012, Style: (int)ArrowStyle.Open),
                    new Annotation(AnnotationKind.Arrow, new NormPoint(0.35, 0.65), new NormPoint(0.6, 0.65), blue, 0.012, Style: (int)ArrowStyle.Double),
                    new Annotation(AnnotationKind.Arrow, new NormPoint(0.05, 0.85), new NormPoint(0.3, 0.85), blue, 0.012, Style: (int)ArrowStyle.Curved),
                    new Annotation(AnnotationKind.Text, new NormPoint(0.4, 0.4), default, Rgba.Yellow, 0.08, "Hi", Style: (int)TextStyle.Label),
                    new Annotation(AnnotationKind.Text, new NormPoint(0.62, 0.4), default, Rgba.Red, 0.08, "Yo", Style: (int)TextStyle.Outlined),
                ],
                OutputFormat = OutputFormat.Png,
            };
            var result = await Engine.Perform(new JobOperation.EditImage(edit), white, options, _ => { }, default);
            using var image = new MagickImage(result.Outputs[0]);
            static bool Bluish((double R, double G, double B, double A) p) => p.B > 0.6 && p.R < 0.4;
            Expect(Bluish(Pixel(image, 60, 15 + 1)) || Bluish(Pixel(image, 60, 16)) || Bluish(Pixel(image, 60, 17)), $"oval top edge {Pixel(image, 60, 16)}");
            Expect(Bluish(Pixel(image, 160, 30)), $"line {Pixel(image, 160, 30)}");
            var step = Pixel(image, 240 - 10, 45);
            Expect(step.R > 0.7 && step.G < 0.4, $"step circle {step}");
            Expect(Pixel(image, 40, 135).G > 0.5 && Pixel(image, 40, 135).R < 0.4, $"filled box {Pixel(image, 40, 135)}");
            Expect(Pixel(image, 10, 10).R < 0.6, $"outside the spotlight is dimmed {Pixel(image, 10, 10)}");
            Expect(Pixel(image, 340, 250).R > 0.95, $"inside the spotlight is untouched {Pixel(image, 340, 250)}");
            Expect(Bluish(Pixel(image, 160, 195)) && Bluish(Pixel(image, 150, 195)), "double arrow shaft");
            var label = Pixel(image, 158, 125);
            Expect(label.R > 0.6 && label.G > 0.5 && label.B < 0.5, $"text label background {label}");
            return result.Outputs;
        });
        await Check("Marks: pixelate and secure blur scramble, resize to half", async () =>
        {
            var source = Path.Combine(folder, "stripes.png");
            using (var stripes = new MagickImage(MagickColors.White, 400, 200))
            {
                var d = new Drawables().FillColor(MagickColors.Black);
                for (var x = 0; x < 400; x += 8) d.Rectangle(x, 0, x + 3, 200);
                d.Draw(stripes);
                stripes.Write(source);
            }
            var edit = new ImageEdit
            {
                Redactions = [new Redaction(new NormRect(0, 0, 0.5, 1), RedactionStyle.Pixelate), new Redaction(new NormRect(0.5, 0, 0.5, 1), RedactionStyle.SecureBlur)],
                Scale = 0.5,
                OutputFormat = OutputFormat.Png,
            };
            var result = await Engine.Perform(new JobOperation.EditImage(edit), source, options, _ => { }, default);
            using var image = new MagickImage(result.Outputs[0]);
            Expect(image.Width == 200 && image.Height == 100, $"size {image.Width}×{image.Height}");
            // Pixelated blocks average the stripes into greys that are not all exactly equal.
            var greys = Enumerable.Range(0, 10).Select(i => Pixel(image, 5 + i * 9, 50).R).ToList();
            Expect(greys.All(g => g > 0.2 && g < 0.8), $"pixelate should leave greys, got {string.Join(", ", greys.Select(g => g.ToString("0.00")))}");
            Expect(greys.Distinct().Count() > 1, "pixelate should be scrambled, not uniform");
            var blurred = Enumerable.Range(0, 20).Select(i => Pixel(image, 110 + i * 4, 50).R).ToList();
            Expect(blurred.Max() - blurred.Min() < 0.5, "secure blur should leave no stripes");
            return result.Outputs;
        });

        await Check("Mark-up: smooth pencil, highlight fits the text, crop shapes snap", () =>
        {
            var jagged = new List<NormPoint>();
            for (var i = 0; i <= 20; i++) jagged.Add(new NormPoint(i * 0.04, i % 2 == 0 ? 0.5 : 0.56));
            var smooth = Markup.Smooth(jagged);
            Expect(smooth[0] == jagged[0] && smooth[^1] == jagged[^1], "the stroke's ends stay put");
            Expect(smooth.Count > jagged.Count, $"corners are cut ({smooth.Count} points)");
            var wiggle = smooth.Skip(1).Zip(smooth).Max(p => Math.Abs(p.First.Y - p.Second.Y));
            Expect(wiggle < 0.04, $"steps are softened (largest {wiggle:0.000})");
            // A white picture with one dark line of "text" at rows 40-52.
            var page = new BgraImage(200, 120);
            Array.Fill(page.Pixels, (byte)255);
            for (var y = 40; y < 52; y++) for (var x = 20; x < 180; x += 3) { var i = (y * 200 + x) * 4; page.Pixels[i] = page.Pixels[i + 1] = page.Pixels[i + 2] = 20; }
            var fitted = Markup.FitHighlight(page, new NormRect(0.05, 0.1, 0.9, 0.7));
            var top = fitted.Y * 120; var bottom = fitted.MaxY * 120;
            Expect(top is > 34 and <= 40 && bottom is >= 52 and < 58, $"highlight rows {top:0}-{bottom:0}");
            var blank = Markup.FitHighlight(new BgraImage(50, 50, Enumerable.Repeat((byte)255, 50 * 50 * 4).ToArray()), new NormRect(0.1, 0.1, 0.5, 0.5));
            Expect(blank == new NormRect(0.1, 0.1, 0.5, 0.5), "no text leaves the box alone");
            var square = Markup.Crop(new NormPoint(0.1, 0.1), new NormPoint(0.9, 0.5), 1000, 500, 1);
            Expect(Math.Abs(square.Width * 1000 - square.Height * 500) < 1, $"square crop {square}");
            var snapped = Markup.Crop(new NormPoint(0.006, 0.3), new NormPoint(0.995, 0.7), 1000, 500);
            Expect(snapped.X == 0 && snapped.MaxX == 1, $"edges snap {snapped}");
            Expect(Markup.TextPresets.Length >= 7, "seven text presets");
            return None();
        });
        await Check("Mark-up: a .spinform project keeps every mark and placed picture", async () =>
        {
            var original = Path.Combine(folder, "project-original.png");
            var sticker = Path.Combine(folder, "project-sticker.png");
            using (var a = new MagickImage(MagickColors.SkyBlue, 300, 200)) a.Write(original);
            using (var b = new MagickImage(MagickColors.Orange, 60, 60)) b.Write(sticker);
            var edit = new ImageEdit
            {
                Annotations = [new Annotation(AnnotationKind.Arrow, new NormPoint(0.1, 0.1), new NormPoint(0.5, 0.5), Rgba.Red, 0.01, Style: (int)ArrowStyle.Curved),
                    new Annotation(AnnotationKind.Pencil, default, default, Rgba.Blue, 0.01, Points: [new(0.1, 0.9), new(0.2, 0.8)])],
                Redactions = [new Redaction(new NormRect(0.6, 0.1, 0.2, 0.2), RedactionStyle.SecureBlur)],
                Overlays = [new PlacedImage(sticker, new NormRect(0.7, 0.6, 0.2, 0.3))],
                QuarterTurns = 1, Scale = 0.5, Background = null, Crop = new NormRect(0, 0, 0.9, 0.9),
            };
            var project = Path.Combine(folder, "markup" + ImageProject.Extension);
            ImageProject.Save(project, original, edit);
            var (back, loaded) = ImageProject.Load(project, Path.Combine(folder, "project-open"));
            Expect(File.Exists(back) && back != original, "the original travels inside the project");
            Expect(loaded.Annotations.Count == 2 && loaded.Annotations[0].Style == (int)ArrowStyle.Curved && loaded.Annotations[1].Points?.Count == 2, "marks come back");
            Expect(loaded.Redactions.Single().Style == RedactionStyle.SecureBlur, "redaction comes back");
            Expect(loaded.Overlays.Single().Path != sticker && File.Exists(loaded.Overlays.Single().Path), "placed picture travels too");
            Expect(loaded.QuarterTurns == 1 && loaded.Scale == 0.5 && loaded.Crop == edit.Crop, "turns, size and crop come back");
            var result = await Engine.Perform(new JobOperation.EditImage(loaded with { OutputFormat = OutputFormat.Png }), back, options, _ => { }, default);
            using var image = new MagickImage(result.Outputs[0]);
            Expect(image.Width == 90 && image.Height == 135, $"rendered {image.Width}×{image.Height}");
            return [project, .. result.Outputs];
        });

        await Check("Video studio: zooms follow clicks, the pointer glides, frames land on the background", () =>
        {
            var samples = new List<StudioSample> { new(0, 100, 100, false), new(1.0, 300, 200, false), new(1.0, 300, 200, true), new(1.6, 310, 205, true), new(5.0, 50, 50, true) };
            var windows = StudioDirector.ClickZooms(samples);
            Expect(windows.Count == 2, $"two bursts of clicks, got {windows.Count}");
            Expect(Math.Abs(windows[0].Start - 0.45) < 0.01 && Math.Abs(windows[0].End - 3.3) < 0.01, $"first zoom {windows[0]}");
            var options = new StudioOptions { ZoomLevel = 2 };
            var path = new PointerPath(samples, 6, 0.35);
            var still = StudioDirector.At(0.1, options, windows, path, 400, 300);
            Expect(still.Zoom == 1, $"no zoom before the click ({still.Zoom})");
            var close = StudioDirector.At(1.8, options, windows, path, 400, 300);
            Expect(Math.Abs(close.Zoom - 2) < 0.01, $"zoomed at the click ({close.Zoom:0.00})");
            Expect(Math.Abs(close.X - 0.75) < 0.03 && Math.Abs(close.Y - 0.6833) < 0.05, $"centred near the pointer ({close.X:0.00}, {close.Y:0.00})");
            var edge = StudioDirector.At(5.5, options, windows, path, 400, 300);
            Expect(edge.X >= 0.25 - 1e-9 && edge.Y >= 0.25 - 1e-9, $"the view stays inside the picture ({edge.X:0.00}, {edge.Y:0.00})");
            var manual = StudioDirector.At(8, options with { Zooms = [new StudioZoom(7, 9, 3, 0.5, 0.5)] }, windows, path, 400, 300);
            Expect(Math.Abs(manual.Zoom - 3) < 0.01, $"a manual zoom wins ({manual.Zoom:0.00})");
            var jumpy = new PointerPath([new(0, 0, 0, false), new(1, 100, 0, false)], 2, 0.1);
            Expect(jumpy.At(1).X is > 30 and < 70, $"the pointer glides instead of jumping ({jumpy.At(1).X:0})");

            // A four-colour source on a landscape gradient with rounded corners and a drawn pointer.
            var source = new BgraImage(320, 240);
            for (var y = 0; y < 240; y++)
                for (var x = 0; x < 320; x++)
                {
                    var i = (y * 320 + x) * 4;
                    source.Pixels[i] = (byte)(x < 160 ? 255 : 0); source.Pixels[i + 1] = (byte)(y < 120 ? 255 : 0); source.Pixels[i + 2] = 40; source.Pixels[i + 3] = 255;
                }
            var track = new PointerTrack(320, 240, 1, [new(0, 160, 120, false)], CursorDrawn: false);
            var look = new StudioOptions { Shape = StudioShape.Landscape, Background = Frames.BuiltIn[0].Style, AutoZoom = false, DrawCursor = true };
            var renderer = new StudioRenderer(320, 240, look, track, 2);
            Expect(renderer.Width == 1280 && renderer.Height == 720, $"size {renderer.Width}×{renderer.Height}");
            var frame = new BgraImage(renderer.Width, renderer.Height);
            renderer.Render(source, 0.5, frame);
            var c = renderer.Content;
            Expect(c.X > 0 && c.Height < 720 && Math.Abs(c.Width / (double)c.Height - 4.0 / 3) < 0.02, $"content box {c}");
            var inner = frame.HexAt(c.X + c.Width / 4, c.Y + c.Height / 4);
            Expect(inner == "28FFFF", $"top-left quarter shows through ({inner})");
            Expect(frame.HexAt(c.X, c.Y) != "28FFFF", "rounded corner shows the background");
            Expect(frame.HexAt(5, 5) != frame.HexAt(c.X + 5, c.Y + c.Height / 2), "background around the video");
            var pointer = frame.HexAt(c.X + c.Width / 2 + 4, c.Y + c.Height / 2 + 10);
            Expect(pointer is "FFFFFF" or "141418", $"the pointer is drawn ({pointer})");
            return None();
        });
        await Check("Video studio: export a clip with a zoom, square, trimmed", async () =>
        {
            if (Tools.Ffmpeg is not { } ffmpeg) throw new Skip("no ffmpeg");
            var clipPath = Path.Combine(folder, "studio-source.mp4");
            await Shell.Check(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=480x270:rate=30:duration=3", "-f", "lavfi", "-i", "sine=duration=3",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", clipPath]);
            var track = new PointerTrack(480, 270, 1, [new(0, 100, 100, false), new(1.2, 400, 200, true)], CursorDrawn: false);
            var output = Path.Combine(folder, "studio-export.mp4");
            var options = new StudioOptions { Shape = StudioShape.Square, Background = Frames.BuiltIn[2].Style, ZoomLevel = 2, DrawCursor = true, MotionBlur = true, TrimStart = 0.5, TrimEnd = 2.5 };
            await VideoStudio.Export(clipPath, track, options, output, _ => { }, default);
            var banner = await Banner(output);
            var duration = MediaInfo.ParseDuration(banner) ?? 0;
            Expect(duration is > 1.8 and < 2.3, $"trimmed to {duration:0.00} s");
            Expect(MediaInfo.ParseFrameSize(banner) == (720, 720), $"square {MediaInfo.ParseFrameSize(banner)}");
            Expect(MediaInfo.StreamLines(banner, "Audio").Any(), "sound kept");
            return [output];
        }, Skipped);

        await Check("Capture history: add, list, prune by age, delete and reload", () =>
        {
            var dir = Path.Combine(folder, "history");
            var history = new CaptureHistory(dir);
            var shot = Path.Combine(folder, "shot.png");
            Solid(40, 30, 255, 0, 0).Save(shot);
            var note = Path.Combine(folder, "note.txt");
            File.WriteAllText(note, "Hello history");
            var now = DateTime.Now;
            var old = history.Add(shot, CaptureKind.Screenshot, 40, 30, created: now.AddDays(-10));
            var recent = history.Add(shot, CaptureKind.Screenshot, 40, 30, created: now.AddHours(-1));
            var text = history.Add(note, CaptureKind.Text, preview: "Hello history");
            Expect(history.Items.Count == 3 && history.Items[0].Id == text.Id, "newest first");
            Expect(File.Exists(history.PathOf(old)), "the copy is kept in the history folder");
            Expect(history.Prune(7, now) == 1 && history.Items.All(i => i.Id != old.Id), "pruned the 10-day-old capture");
            Expect(!File.Exists(history.PathOf(old)), "pruning deletes the file");
            history.Delete(recent.Id);
            var reloaded = new CaptureHistory(dir);
            Expect(reloaded.Items.Count == 1 && reloaded.Items[0].Kind == CaptureKind.Text && reloaded.Items[0].Preview == "Hello history", "reloaded from disk");
            Expect(reloaded.Prune(-1) == 0 && reloaded.Prune(0) == 1 && reloaded.Items.Count == 0, "keep forever / keep none");
            Expect(CaptureHistory.When(now.Date.AddHours(9.5), now).StartsWith("Today") && CaptureHistory.Duration(75) == "1:15", "labels");
            return None();
        });

        await Check("Recording: video sizes and the sound mix", () =>
        {
            Expect(ScreenRecording.OutputSize(new RecordingFormat { Width = 1921, Height = 1081 }) == (1920, 1080), "even size");
            Expect(ScreenRecording.OutputSize(new RecordingFormat { Width = 3840, Height = 2160, MaxSide = 1920 }) == (1920, 1080), "limited to 1920");
            var args = ScreenRecording.MuxArgs("v.mp4", [new("mic.wav", -0.25), new("pc.wav", 0.5)], "out.mp4");
            var text = string.Join(" ", args);
            Expect(text.Contains("-ss 0.25 -i mic.wav") && text.Contains("-itsoffset 0.5 -i pc.wav") && text.Contains("amix=inputs=2"), text);
            Expect(ScreenRecording.LiveArgs(new RecordingFormat { Width = 640, Height = 480 }, "x.mp4").Contains("-use_wallclock_as_timestamps"), "frames are stamped as they arrive");
            return None();
        });

        // The real thing, on Windows.
        if (!OperatingSystem.IsWindows())
        {
            await Check("Screen capture on this machine", () => throw new Skip("not Windows"), Skipped);
            return;
        }
        await WindowsCaptureChecks(folder);
    }

    static async Task WindowsCaptureChecks(string folder)
    {
        await Check("Screen capture: displays and a real grab of the desktop", () =>
        {
            var monitors = Screens.Monitors();
            Console.WriteLine($"      {monitors.Count} display(s): {string.Join("; ", monitors.Select(m => $"{m.Bounds} at {m.Scale * 100:0}%"))}");
            Expect(monitors.Count >= 1, "no displays");
            var all = Screens.VirtualScreen;
            Expect(all.Width > 0 && all.Height > 0, $"virtual screen {all}");
            var main = monitors[0].Bounds;
            var grab = ScreenGrab.Area(new PixelRect(main.X, main.Y, Math.Min(main.Width, 800), Math.Min(main.Height, 600)), cursor: true);
            Expect(grab.Width == Math.Min(main.Width, 800) && grab.Height == Math.Min(main.Height, 600), $"grab is {grab.Width}×{grab.Height}");
            var path = Path.Combine(folder, "desktop.png");
            grab.Save(path);
            var colours = new HashSet<string>();
            for (var y = 0; y < grab.Height; y += 37) for (var x = 0; x < grab.Width; x += 41) colours.Add(grab.HexAt(x, y));
            Console.WriteLine($"      {colours.Count} different colours sampled");
            return Task.FromResult<IReadOnlyList<string>>([path]);
        });
        await Check("Screen capture: Windows.Graphics.Capture of the main display", () =>
        {
            if (!GraphicsCapture.IsAvailable) throw new Skip("Windows.Graphics.Capture isn't available on this machine; Spinform uses PrintWindow and GDI instead");
            var monitor = Screens.Monitors()[0];
            BgraImage? image;
            try { image = GraphicsCapture.Monitor(monitor.Handle); }
            catch (Exception e) { throw new Skip($"Windows.Graphics.Capture didn't start here ({e.GetType().Name}: {e.Message.Split('\n')[0]}); Spinform falls back to GDI"); }
            if (image is null) throw new Skip("no frame arrived within 2 s (no desktop composition on this machine); Spinform falls back to GDI");
            Expect(image.Width == monitor.Bounds.Width && image.Height == monitor.Bounds.Height, $"{image.Width}×{image.Height}, expected {monitor.Bounds.Width}×{monitor.Bounds.Height}");
            var path = Path.Combine(folder, "display-wgc.png");
            image.Save(path);
            return Task.FromResult<IReadOnlyList<string>>([path]);
        }, Skipped);

        await Check("Text recognition: reads a generated picture of text", async () =>
        {
            var languages = TextRecognizer.Languages;
            Console.WriteLine($"      OCR languages: {(languages.Count == 0 ? "none" : string.Join(", ", languages.Select(l => l.Tag)))}");
            if (languages.Count == 0) throw new Skip("this machine has no Windows OCR language installed (users without one get a message explaining how to add it)");
            using var picture = new MagickImage(MagickColors.White, 900, 220);
            var d = new Drawables().FillColor(MagickColors.Black).FontPointSize(56).Text(40, 90, "Spinform reads text");
            if (Fonts.BoldSansFile() is { } font) d = d.Font(font);
            d.Text(40, 175, "Invoice 2048").Draw(picture);
            var outcome = await TextRecognizer.Recognize(BgraImage.FromMagick(picture));
            Console.WriteLine($"      read ({outcome.Language}): {Quote(outcome.Text)}");
            Expect(outcome.Text.Contains("Spinform", StringComparison.OrdinalIgnoreCase) && outcome.Text.Contains("2048"), $"read {Quote(outcome.Text)}");
            Expect(outcome.Lines == 2, $"expected 2 lines, got {outcome.Lines}");
            var flat = await TextRecognizer.Recognize(BgraImage.FromMagick(picture), keepLineBreaks: false);
            Expect(!flat.Text.Contains('\n'), "line breaks should be gone");
            return [];
        }, Skipped);
        await Check("Text recognition: QR codes in a capture", () =>
        {
            var qr = Path.Combine(folder, "qr.png");
            ImageConverter.WriteQr("https://example.com/spinform", qr);
            using var image = new MagickImage(qr);
            var found = TextRecognizer.ReadQrCodes(BgraImage.FromMagick(image));
            Expect(found.SequenceEqual(["https://example.com/spinform"]), $"read {string.Join(", ", found)}");
            return None();
        });

        if (Tools.Ffmpeg is null) { await Check("Screen recording", () => throw new Skip("no ffmpeg"), Skipped); return; }
        string? recorded = null;
        await Check("Screen recording: two seconds of the desktop to MP4", async () =>
        {
            var encoder = await ScreenRecorder.PickEncoder("auto");
            Console.WriteLine($"      encoder: {encoder}");
            var main = Screens.Monitors()[0].Bounds;
            var area = new PixelRect(main.X, main.Y, 640, 360);
            var output = Path.Combine(folder, "recording.mp4");
            var recorder = new ScreenRecorder(area, new RecordingFormat { Fps = 30, Encoder = encoder }, new RecordingLook { Clicks = true, Keystrokes = true }, output);
            var clock = Stopwatch.StartNew();
            recorder.Start();
            await Task.Delay(2000);
            var result = await recorder.Stop();
            recorder.CleanUp();
            Console.WriteLine($"      {recorder.FramesWritten} frames grabbed in {result.Seconds:0.00} s, finished in {clock.Elapsed.TotalSeconds:0.0} s");
            var banner = await Banner(output);
            var duration = MediaInfo.ParseDuration(banner) ?? 0;
            Expect(duration is > 1.5 and < 2.8, $"recording is {duration:0.00} s");
            Expect(MediaInfo.ParseFrameSize(banner) == (640, 360), $"size {MediaInfo.ParseFrameSize(banner)}");
            Expect(recorder.FramesWritten >= 10, $"only {recorder.FramesWritten} frames");
            recorded = output;
            return [output];
        });
        await Check("Screen recording: the recording as a GIF", async () =>
        {
            if (recorded is null) throw new CheckFailed("no recording to convert");
            var gif = await Engine.Perform(new JobOperation.Convert(OutputFormat.Gif), recorded, new ConversionOptions { OutputFolder = folder }, _ => { }, default);
            using var frames = new MagickImageCollection(gif.Outputs[0]);
            Expect(frames.Count > 5, $"{frames.Count} frames");
            return gif.Outputs;
        });
        await Check("Camera: the webcam bubble's feed", async () =>
        {
            CameraFeed feed;
            try { feed = await CameraFeed.Start(); }
            catch (Exception e) { throw new Skip($"no camera here ({e.Message.Split('\n')[0]})"); }
            using (feed)
            {
                for (var i = 0; i < 30 && feed.Latest is null; i++) await Task.Delay(100);
                if (feed.Latest is not { } frame) throw new Skip($"the camera {feed.Name} sent no frames");
                var bubble = CameraFeed.Shape(frame, 160, 160, CameraShape.Circle);
                Expect(bubble.Pixels[3] == 0 && bubble.Pixels[(80 * 160 + 80) * 4 + 3] == 255, "circle mask");
            }
            return [];
        }, Skipped);
    }
}
