namespace Transmute;

/// Sends each job to the right converter.
public static class Engine
{
    public static async Task<JobResult> Perform(JobOperation operation, string input, ConversionOptions options,
        ProgressHandler progress, CancellationToken token)
    {
        var kind = Kinds.Of(input);
        if (!File.Exists(input) && !Directory.Exists(input)) throw new ConversionException($"{Path.GetFileName(input)} isn't there any more.");
        switch (operation)
        {
            case JobOperation.Convert c:
                return await Convert(input, kind, c.Format, options, progress, token);

            case JobOperation.Compress c:
            {
                var goal = c.Target.Goal(OutputPaths.FileSize(input));
                return kind switch
                {
                    FileKind.Image => await ImageConverter.Compress(input, goal, options, token),
                    FileKind.Video or FileKind.Audio => await MediaConverter.Compress(input, kind, goal, options, progress, token),
                    FileKind.Pdf => await Task.Run(() => PdfTools.Compress(input, options, goal), token),
                    _ => throw new ConversionException($"{kind.Title()} can't be compressed."),
                };
            }

            case JobOperation.StripMetadata:
                return JobResult.Of(kind switch
                {
                    FileKind.Image => await ImageConverter.StripMetadata(input, options, token),
                    FileKind.Video or FileKind.Audio => await MediaConverter.StripMetadata(input, options, token),
                    FileKind.Pdf => await Task.Run(() => PdfTools.StripMetadata(input, options), token),
                    _ => throw new ConversionException($"No metadata tools for {kind.Title().ToLowerInvariant()}."),
                });

            case JobOperation.SplitPdf:
                if (kind != FileKind.Pdf) throw new ConversionException("Only PDFs can be split.");
                return JobResult.Of(await Task.Run(() => PdfTools.Split(input, options), token));

            case JobOperation.ReadQr:
                if (kind != FileKind.Image) throw new ConversionException("QR codes can only be read from images.");
                return JobResult.Note(await Task.Run(() => ImageConverter.ReadQr(input), token));

            case JobOperation.Resize r:
                if (kind != FileKind.Image) throw new ConversionException("Only pictures can be resized.");
                return JobResult.Of(await ImageConverter.Resize(input, r.Scale, options, token));

            case JobOperation.EditImage e:
                if (kind != FileKind.Image) throw new ConversionException("The photo editor only works on images.");
                return await ImageEditEngine.Apply(e.Edit, input, options, token);

            case JobOperation.EditVideo e:
                if (kind != FileKind.Video) throw new ConversionException("The video editor only works on videos.");
                return await VideoEditEngine.Apply(e.Edit, input, options, progress, token);

            case JobOperation.EditAudio e:
                if (kind is not (FileKind.Audio or FileKind.Video)) throw new ConversionException("The audio editor needs an audio or video file.");
                return await AudioEditEngine.Apply(e.Edit, input, options, progress, token);

            case JobOperation.WriteMetadata m:
                return JobResult.Of(await MetadataTool.Write(m.Edit, input, options, token));

            case JobOperation.Snapshot s:
                if (kind != FileKind.Video) throw new ConversionException("Snapshots can only be taken from videos.");
                return JobResult.Of(await VideoEditEngine.Snapshot(input, s.Seconds, options, token));
        }
        throw new ConversionException("Transmute doesn't know how to do that.");
    }

    public static async Task<JobResult> Convert(string input, FileKind kind, OutputFormat format, ConversionOptions options,
        ProgressHandler progress, CancellationToken token)
    {
        switch (kind, format)
        {
            case (FileKind.Archive, OutputFormat.Zip or OutputFormat.Tgz):
                return JobResult.Of(await Archives.Repack(input, format, options, token));
            case (_, OutputFormat.Zip or OutputFormat.Tgz):
                return JobResult.Of(await Archives.Compress([input], format, null, options, token));
            case (FileKind.Archive, OutputFormat.Extract):
                return JobResult.Of(await Archives.Extract(input, options, token));
        }
        if (IWork.IsIWork(input)) return await FromIWork(input, format, options, progress, token);
        switch (kind)
        {
            case FileKind.Image:
                return JobResult.Of(await ImageConverter.Convert(input, format, options, token));
            case FileKind.Video or FileKind.Audio:
                return JobResult.Of(await MediaConverter.Convert(input, format, options, progress, token));
            case FileKind.Pdf when format is OutputFormat.Png or OutputFormat.Jpeg:
                return new JobResult(await PdfTools.Rasterize(input, format, options, token));
            case FileKind.Subtitle:
                return JobResult.Of(Subtitles.Convert(input, format, options));
            case FileKind.Spreadsheet:
                return await FromSpreadsheet(input, format, options, token);
            case FileKind.Presentation:
                return await FromPresentation(input, format, options, token);
            case FileKind.Pdf or FileKind.Document or FileKind.Ebook:
                return await FromDocument(input, format, options, token);
        }
        throw new ConversionException($"Can't convert {Path.GetFileName(input)} to {format.Label()}.");
    }

    static async Task<JobResult> WithOfficeApp(string input, OutputFormat format, ConversionOptions options, CancellationToken token)
    {
        var outputs = await OfficeApps.Convert(input, format, options, token);
        return new JobResult(outputs);
    }

    static bool UseOffice(string input, OutputFormat format, ConversionOptions options) =>
        options.UseOfficeApps && OfficeApps.CanConvert(input, format);

    /// Old .doc/.ppt files go through Office or LibreOffice first; without them there's a clear error.
    static async Task<(string Path, string? Temp)> Readable(string input, CancellationToken token)
    {
        var ext = Path.GetExtension(input).ToLowerInvariant();
        if (ext is not (".doc" or ".ppt")) return (input, null);
        var modern = await OfficeApps.Modernize(input, token);
        return modern is null ? (input, null) : (modern, Path.GetDirectoryName(modern));
    }

    public static async Task<JobResult> FromDocument(string input, OutputFormat format, ConversionOptions options, CancellationToken token)
    {
        if (UseOffice(input, format, options))
        {
            try { return await WithOfficeApp(input, format, options, token); }
            catch (ConversionException) when (Path.GetExtension(input).ToLowerInvariant() is not ".doc") { /* fall back to the built-in converter */ }
        }
        var (path, temp) = await Readable(input, token);
        try
        {
            var output = OutputPaths.Destination(input, format.Extension(), null, options.OutputFolder);
            try
            {
                await Task.Run(() =>
                {
                    var doc = DocReaders.Read(path);
                    DocWriters.Write(doc, format, output);
                }, token);
            }
            catch
            {
                OutputPaths.TryDelete(output);
                throw;
            }
            return JobResult.Of(output);
        }
        finally
        {
            OutputPaths.TryDelete(temp);
        }
    }

    static async Task<JobResult> FromSpreadsheet(string input, OutputFormat format, ConversionOptions options, CancellationToken token)
    {
        if (UseOffice(input, format, options))
        {
            try { return await WithOfficeApp(input, format, options, token); }
            catch (ConversionException) { }
        }
        var output = OutputPaths.Destination(input, format.Extension(), null, options.OutputFolder);
        try
        {
            await Task.Run(() => Sheets.Write(Sheets.Read(input), format, output), token);
        }
        catch
        {
            OutputPaths.TryDelete(output);
            throw;
        }
        return new JobResult([output], Path.GetExtension(input).ToLowerInvariant() is ".xlsx" or ".xls" or ".ods" && format != OutputFormat.Xlsx
            ? "The first sheet's values were used." : null);
    }

    static async Task<JobResult> FromPresentation(string input, OutputFormat format, ConversionOptions options, CancellationToken token)
    {
        if (UseOffice(input, format, options))
        {
            try { return await WithOfficeApp(input, format, options, token); }
            catch (ConversionException) when (Path.GetExtension(input).ToLowerInvariant() is not ".ppt") { }
        }
        if (format == OutputFormat.Pptx)
            throw new ConversionException("Saving as PowerPoint needs Microsoft PowerPoint or the free LibreOffice installed.");
        var (path, temp) = await Readable(input, token);
        try
        {
            const string note = "Made without PowerPoint: the slides' words and pictures, not their design. Install PowerPoint or the free LibreOffice for exact slides.";
            var doc = await Task.Run(() => Slides.Read(path), token);
            if (format == OutputFormat.Pdf)
            {
                var output = OutputPaths.Destination(input, "pdf", null, options.OutputFolder);
                try { await Task.Run(() => DocWriters.WritePdf(doc, output, slides: true), token); }
                catch { OutputPaths.TryDelete(output); throw; }
                return new JobResult([output], note);
            }
            // Pictures: one per slide, made from the PDF.
            var pdf = OutputPaths.TempFile("pdf");
            try
            {
                await Task.Run(() => DocWriters.WritePdf(doc, pdf, slides: true), token);
                var bytes = await File.ReadAllBytesAsync(pdf, token);
                var count = PDFtoImage.Conversion.GetPageCount(bytes);
                var outputs = new List<string>();
                try
                {
                    for (var i = 0; i < count; i++)
                    {
                        var output = OutputPaths.Destination(input, format.Extension(), count == 1 ? null : $"slide {i + 1}", options.OutputFolder);
                        outputs.Add(output);
                        await Task.Run(() => PdfTools.RenderPage(bytes, i, format, output, 144, options.Quality), token);
                    }
                }
                catch
                {
                    outputs.ForEach(OutputPaths.TryDelete);
                    throw;
                }
                return new JobResult(outputs, note);
            }
            finally
            {
                OutputPaths.TryDelete(pdf);
            }
        }
        finally
        {
            OutputPaths.TryDelete(temp);
        }
    }

    static async Task<JobResult> FromIWork(string input, OutputFormat format, ConversionOptions options, ProgressHandler progress, CancellationToken token)
    {
        var app = IWork.AppName(input);
        var preview = IWork.ExtractPreview(input)
            ?? throw new ConversionException($"This {app} file can only be opened with Apple's {app} app. On a Mac, export it from {app} as a Word, Excel, PowerPoint or PDF file.");
        try
        {
            // The preview stands in for the file, under the file's own name.
            var stand = Path.Combine(OutputPaths.TempDir(), OutputPaths.BaseName(input) + Path.GetExtension(preview));
            File.Move(preview, stand);
            var outputOptions = options with { OutputFolder = options.OutputFolder ?? Path.GetDirectoryName(Path.GetFullPath(input)) };
            JobResult result;
            if (Path.GetExtension(stand) == ".pdf")
            {
                if (format == OutputFormat.Pdf)
                {
                    var output = OutputPaths.Destination(input, "pdf", null, outputOptions.OutputFolder);
                    File.Copy(stand, output);
                    result = JobResult.Of(output);
                }
                else result = await Convert(stand, FileKind.Pdf, format, outputOptions, progress, token);
            }
            else
            {
                if (format is not (OutputFormat.Pdf or OutputFormat.Png or OutputFormat.Jpeg))
                    throw new ConversionException($"This {app} file only has a picture of its first page inside, so it can become a PDF, PNG or JPEG. For anything else, export it from {app} on a Mac.");
                result = await Convert(stand, FileKind.Image, format, outputOptions, progress, token);
            }
            OutputPaths.TryDelete(Path.GetDirectoryName(stand));
            return result with { Message = $"Made from the preview inside the {app} file. Export it from {app} on a Mac for an exact copy." };
        }
        finally
        {
            OutputPaths.TryDelete(preview);
        }
    }

    public static async Task<string> Batch(BatchTool tool, IReadOnlyList<string> inputs, ConversionOptions options,
        ProgressHandler progress, CancellationToken token)
    {
        return tool switch
        {
            BatchTool.MergePdfs => await Task.Run(() => PdfTools.Merge(inputs, options), token),
            BatchTool.ImagesToPdf => await Task.Run(() => PdfTools.ImagesToPdf(inputs, options), token),
            BatchTool.Archive a => await Archives.Compress(inputs, a.Format, inputs.Count == 1 ? null : "Archive", options, token),
            BatchTool.JoinVideos => await VideoEditEngine.Join(inputs, options, progress, token),
            _ => throw new ConversionException("Unknown tool."),
        };
    }
}
