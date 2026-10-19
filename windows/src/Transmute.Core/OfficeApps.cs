using System.Runtime.InteropServices;

namespace Transmute;

/// Uses Microsoft Office (Word, Excel, PowerPoint) or the free LibreOffice, when installed, for
/// exact conversions of Office files. Transmute's own converters are the fallback.
public static class OfficeApps
{
    public enum App { Word, Excel, PowerPoint }

    /// Lets the self-test exercise the built-in converters on machines with Office.
    static bool Disabled => Environment.GetEnvironmentVariable("TRANSMUTE_NO_OFFICE") is not null;

    static readonly Dictionary<App, bool> Installed = [];

    public static bool Has(App app)
    {
        if (Disabled || !OperatingSystem.IsWindows()) return false;
        lock (Installed)
        {
            if (!Installed.TryGetValue(app, out var found))
            {
                found = Type.GetTypeFromProgID($"{app}.Application") is not null;
                Installed[app] = found;
            }
            return found;
        }
    }

    static string? libreOffice;
    static bool searchedLibreOffice;

    public static string? LibreOffice
    {
        get
        {
            if (Disabled) return null;
            if (searchedLibreOffice) return libreOffice;
            var candidates = new List<string>();
            if (OperatingSystem.IsWindows())
            {
                foreach (var root in new[] { Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86) })
                    if (root.Length > 0) candidates.Add(Path.Combine(root, "LibreOffice", "program", "soffice.exe"));
            }
            else
            {
                foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
                    if (dir.Length > 0) { candidates.Add(Path.Combine(dir, "soffice")); candidates.Add(Path.Combine(dir, "libreoffice")); }
            }
            libreOffice = candidates.FirstOrDefault(File.Exists);
            searchedLibreOffice = true;
            return libreOffice;
        }
    }

    public static App? AppFor(string input) => Path.GetExtension(input).ToLowerInvariant() switch
    {
        ".doc" or ".docx" or ".rtf" or ".odt" => App.Word,
        ".xls" or ".xlsx" or ".ods" => App.Excel,
        ".ppt" or ".pptx" or ".odp" => App.PowerPoint,
        _ => null,
    };

    /// Which outputs each Office app writes well.
    static bool AppWrites(App app, OutputFormat format) => app switch
    {
        App.Word => format is OutputFormat.Pdf or OutputFormat.Docx or OutputFormat.Odt or OutputFormat.Rtf,
        App.Excel => format is OutputFormat.Pdf or OutputFormat.Xlsx,
        _ => format is OutputFormat.Pdf or OutputFormat.Pptx or OutputFormat.Png or OutputFormat.Jpeg,
    };

    static bool LibreOfficeWrites(App app, OutputFormat format) => app switch
    {
        App.Word => format is OutputFormat.Pdf or OutputFormat.Docx or OutputFormat.Odt or OutputFormat.Rtf,
        App.Excel => format is OutputFormat.Pdf or OutputFormat.Xlsx,
        _ => format is OutputFormat.Pdf or OutputFormat.Pptx,
    };

    /// Whether an installed app can do this conversion.
    public static bool CanConvert(string input, OutputFormat format)
    {
        if (AppFor(input) is not { } app) return false;
        if (Has(app) && AppWrites(app, format)) return true;
        return LibreOffice is not null && LibreOfficeWrites(app, format);
    }

    /// Converts with Office or LibreOffice into `outputs` (one file, or one per slide for pictures).
    public static async Task<List<string>> Convert(string input, OutputFormat format, ConversionOptions options, CancellationToken token)
    {
        var app = AppFor(input) ?? throw new ConversionException("No app for this file.");
        Exception? firstError = null;
        if (Has(app) && AppWrites(app, format))
        {
            try { return await RunOffice(app, input, format, options, token); }
            catch (Exception e) when (e is not OperationCanceledException) { firstError = e; }
        }
        if (LibreOffice is not null && LibreOfficeWrites(app, format))
        {
            try
            {
                var output = OutputPaths.Destination(input, format.Extension(), null, options.OutputFolder);
                await RunLibreOffice(input, format, output, token);
                return [output];
            }
            catch (Exception e) when (e is not OperationCanceledException) { firstError ??= e; }
        }
        throw firstError ?? new ConversionException("No Office app can do this conversion.");
    }

    /// Turns an old .doc/.ppt/.xls (or any Office file) into its modern equivalent in a temp folder,
    /// so Transmute's own readers can take it from there.
    public static async Task<string?> Modernize(string input, CancellationToken token)
    {
        var app = AppFor(input);
        if (app is null) return null;
        var format = app switch { App.Word => OutputFormat.Docx, App.Excel => OutputFormat.Xlsx, _ => OutputFormat.Pptx };
        if (!CanConvert(input, format)) return null;
        var dir = OutputPaths.TempDir();
        var outputs = await Convert(input, format, new ConversionOptions { OutputFolder = dir }, token);
        return outputs.FirstOrDefault();
    }

    // Microsoft Office through COM automation

    static Task<List<string>> RunOffice(App app, string input, OutputFormat format, ConversionOptions options, CancellationToken token)
    {
        var full = Path.GetFullPath(input);
        var result = new TaskCompletionSource<List<string>>();
        var thread = new Thread(() =>
        {
            var outputs = new List<string>();
            try
            {
                switch (app)
                {
                    case App.Word: outputs.Add(WordConvert(full, format, options)); break;
                    case App.Excel: outputs.Add(ExcelConvert(full, format, options)); break;
                    default: outputs.AddRange(PowerPointConvert(full, format, options)); break;
                }
                result.SetResult(outputs);
            }
            catch (Exception e)
            {
                outputs.ForEach(OutputPaths.TryDelete);
                var inner = e is System.Reflection.TargetInvocationException { InnerException: { } i } ? i : e;
                result.SetException(new ConversionException($"{app} couldn't convert {Path.GetFileName(input)}: {inner.Message}"));
            }
        });
        if (OperatingSystem.IsWindows()) thread.SetApartmentState(ApartmentState.STA);
        thread.IsBackground = true;
        thread.Start();
        return result.Task.WaitAsync(TimeSpan.FromMinutes(5), token);
    }

    static dynamic Create(App app) =>
        Activator.CreateInstance(Type.GetTypeFromProgID($"{app}.Application")!)
        ?? throw new ConversionException($"Couldn't start {app}.");

    static void Release(object? com)
    {
        if (com is not null && OperatingSystem.IsWindows() && Marshal.IsComObject(com)) Marshal.FinalReleaseComObject(com);
    }

    static string WordConvert(string input, OutputFormat format, ConversionOptions options)
    {
        var output = OutputPaths.Destination(input, format.Extension(), null, options.OutputFolder);
        dynamic? word = null, doc = null;
        try
        {
            word = Create(App.Word);
            word.Visible = false;
            word.DisplayAlerts = 0;
            doc = word.Documents.Open(FileName: input, ConfirmConversions: false, ReadOnly: true, AddToRecentFiles: false, Visible: false);
            var code = format switch { OutputFormat.Pdf => 17, OutputFormat.Docx => 16, OutputFormat.Odt => 23, _ => 6 };
            doc.SaveAs2(FileName: output, FileFormat: code, AddToRecentFiles: false);
            return output;
        }
        catch
        {
            OutputPaths.TryDelete(output);
            throw;
        }
        finally
        {
            try { doc?.Close(SaveChanges: 0); } catch { }
            try { word?.Quit(SaveChanges: 0); } catch { }
            Release(doc);
            Release(word);
        }
    }

    static string ExcelConvert(string input, OutputFormat format, ConversionOptions options)
    {
        var output = OutputPaths.Destination(input, format.Extension(), null, options.OutputFolder);
        dynamic? excel = null, book = null;
        try
        {
            excel = Create(App.Excel);
            excel.Visible = false;
            excel.DisplayAlerts = false;
            book = excel.Workbooks.Open(Filename: input, ReadOnly: true, AddToMru: false);
            if (format == OutputFormat.Pdf) book.ExportAsFixedFormat(Type: 0, Filename: output);
            else book.SaveAs(Filename: output, FileFormat: 51);
            return output;
        }
        catch
        {
            OutputPaths.TryDelete(output);
            throw;
        }
        finally
        {
            try { book?.Close(SaveChanges: false); } catch { }
            try { excel?.Quit(); } catch { }
            Release(book);
            Release(excel);
        }
    }

    static List<string> PowerPointConvert(string input, OutputFormat format, ConversionOptions options)
    {
        var outputs = new List<string>();
        dynamic? ppt = null, deck = null;
        try
        {
            ppt = Create(App.PowerPoint);
            deck = ppt.Presentations.Open(FileName: input, ReadOnly: -1, Untitled: 0, WithWindow: 0);
            if (format is OutputFormat.Png or OutputFormat.Jpeg)
            {
                int count = deck.Slides.Count;
                for (var i = 1; i <= count; i++)
                {
                    var output = OutputPaths.Destination(input, format.Extension(), count == 1 ? null : $"slide {i}", options.OutputFolder);
                    outputs.Add(output);
                    deck.Slides[i].Export(output, format == OutputFormat.Png ? "PNG" : "JPG", 1920, 1080);
                }
            }
            else
            {
                var output = OutputPaths.Destination(input, format.Extension(), null, options.OutputFolder);
                outputs.Add(output);
                deck.SaveAs(FileName: output, FileFormat: format == OutputFormat.Pdf ? 32 : 24);
            }
            return outputs;
        }
        catch
        {
            outputs.ForEach(OutputPaths.TryDelete);
            throw;
        }
        finally
        {
            try { deck?.Close(); } catch { }
            try { ppt?.Quit(); } catch { }
            Release(deck);
            Release(ppt);
        }
    }

    // LibreOffice

    static async Task RunLibreOffice(string input, OutputFormat format, string output, CancellationToken token)
    {
        var soffice = LibreOffice!;
        var dir = OutputPaths.TempDir();
        var profile = OutputPaths.TempDir();
        try
        {
            var filter = format switch
            {
                OutputFormat.Docx => "docx:MS Word 2007 XML",
                OutputFormat.Xlsx => "xlsx:Calc MS Excel 2007 XML",
                OutputFormat.Pptx => "pptx:Impress MS PowerPoint 2007 XML",
                _ => format.Extension(),
            };
            var profileUri = new Uri(profile + Path.DirectorySeparatorChar).AbsoluteUri;
            await Shell.Check(soffice, [$"-env:UserInstallation={profileUri}", "--headless", "--norestore", "--nologo",
                "--convert-to", filter, "--outdir", dir, Path.GetFullPath(input)], token).WaitAsync(TimeSpan.FromMinutes(5), token);
            var made = Directory.GetFiles(dir).FirstOrDefault()
                ?? throw new ConversionException($"LibreOffice couldn't convert {Path.GetFileName(input)}.");
            File.Move(made, output, true);
        }
        finally
        {
            OutputPaths.TryDelete(dir);
            OutputPaths.TryDelete(profile);
        }
    }
}
