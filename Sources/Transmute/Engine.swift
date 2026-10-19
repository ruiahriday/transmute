import Foundation

/// Routes each job to the right converter. Runs off the main thread.
enum Engine {
    static func perform(_ operation: JobOperation, on input: URL, options: ConversionOptions,
                        progress: @escaping ProgressHandler) async throws -> JobResult {
        let kind = FileKind.of(input)
        switch operation {
        // Office and e-book conversions can add a note, for example when only the first slide was used.
        case .convert(let format) where isOffice(input, kind: kind, to: format):
            return try await OfficeConverter.run(input, kind: kind, to: format, options: options)

        case .convert(let format):
            return JobResult(outputs: try await convert(input, kind: kind, to: format, options: options, progress: progress))

        case .compress(let target):
            let goal = target.goal(forOriginal: OutputPaths.fileSize(input))
            switch kind {
            case .image: return try ImageConverter.compress(input, goal: goal, options: options)
            case .video, .audio:
                return try await MediaConverter.compress(input, kind: kind, goal: goal, options: options, progress: progress)
            case .pdf: return try PDFTools.compress(input, options: options)
            default: throw ConversionError("\(kind.title) can't be compressed.")
            }

        case .stripMetadata:
            let out: URL
            switch kind {
            case .image: out = try await ImageConverter.stripMetadata(input, options: options)
            case .video, .audio: out = try await MediaConverter.stripMetadata(input, options: options)
            case .pdf: out = try PDFTools.stripMetadata(input, options: options)
            default: throw ConversionError("No metadata tools for \(kind.title.lowercased()).")
            }
            return JobResult(outputs: [out])

        case .splitPDF:
            guard kind == .pdf else { throw ConversionError("Only PDFs can be split.") }
            return JobResult(outputs: [try PDFTools.split(input, options: options)])

        case .readQR:
            guard kind == .image else { throw ConversionError("QR codes can only be read from images.") }
            return JobResult(message: try ImageConverter.readQR(input))

        case .editImage(let edit):
            guard kind == .image else { throw ConversionError("The photo editor only works on images.") }
            return try await ImageEditEngine.apply(edit, to: input, options: options)

        case .editVideo(let edit):
            guard kind == .video else { throw ConversionError("The video editor only works on videos.") }
            return try await VideoEditEngine.apply(edit, to: input, options: options, progress: progress)

        case .editAudio(let edit):
            guard kind == .audio || kind == .video else { throw ConversionError("The audio editor needs an audio or video file.") }
            return try await AudioEditEngine.apply(edit, to: input, options: options, progress: progress)

        case .writeMetadata(let edit):
            return JobResult(outputs: [try await MetadataTool.write(edit, to: input, options: options)])

        case .snapshot(let seconds):
            guard kind == .video else { throw ConversionError("Snapshots can only be taken from videos.") }
            return JobResult(outputs: [try await VideoEditEngine.snapshot(of: input, at: seconds, options: options)])
        }
    }

    static func convert(_ input: URL, kind: FileKind, to format: OutputFormat, options: ConversionOptions,
                        progress: @escaping ProgressHandler) async throws -> [URL] {
        switch (kind, format) {
        case (.archive, .zip), (.archive, .tar), (.archive, .tgz):
            return [try await ArchiveTool.repack(input, to: format, options: options)]
        case (_, .zip), (_, .tar), (_, .tgz):
            return [try await ArchiveTool.compress([input], to: format, name: nil, options: options)]
        case (.archive, .extract):
            return [try await ArchiveTool.extract(input, options: options)]
        case (.ebook, _), (.presentation, _), (.spreadsheet, _), (.document, .epub), (.document, .pages):
            return try await OfficeConverter.convert(input, kind: kind, to: format, options: options)
        case (.document, _) where input.pathExtension.lowercased() == "pages":
            return try await OfficeConverter.convert(input, kind: kind, to: format, options: options)
        case (.image, _):
            return [try await ImageConverter.convert(input, to: format, options: options)]
        case (.video, _), (.audio, _):
            return [try await MediaConverter.convert(input, to: format, options: options, progress: progress)]
        case (.pdf, .png), (.pdf, .jpeg):
            return try PDFTools.rasterize(input, format: format, options: options)
        case (.pdf, _), (.document, _):
            return [try await DocumentConverter.convert(input, kind: kind, to: format, options: options)]
        case (.subtitle, _):
            return [try SubtitleConverter.convert(input, to: format, options: options)]
        default:
            throw ConversionError("Can't convert \(input.lastPathComponent) to \(format.label).")
        }
    }

    private static func isOffice(_ input: URL, kind: FileKind, to format: OutputFormat) -> Bool {
        let officeKinds: [FileKind] = [.ebook, .presentation, .spreadsheet]
        if officeKinds.contains(kind) { return true }
        if input.pathExtension.lowercased() == "pages" { return true }
        return kind == .document && (format == .epub || format == .pages)
    }

    static func batch(_ tool: BatchTool, urls: [URL], options: ConversionOptions) async throws -> URL {
        switch tool {
        case .mergePDFs: return try PDFTools.merge(urls, options: options)
        case .imagesToPDF: return try PDFTools.imagesToPDF(urls, options: options)
        case .archive(let format):
            return try await ArchiveTool.compress(urls, to: format, name: urls.count == 1 ? nil : "Archive", options: options)
        case .joinVideos:
            return try await VideoEditEngine.join(urls, options: options, progress: { _ in })
        }
    }
}
