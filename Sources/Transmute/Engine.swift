import Foundation

/// Routes each job to the right converter. Runs off the main thread.
enum Engine {
    static func perform(_ operation: JobOperation, on input: URL, options: ConversionOptions,
                        progress: @escaping ProgressHandler) async throws -> JobResult {
        let kind = FileKind.of(input)
        switch operation {
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

    static func batch(_ tool: BatchTool, urls: [URL], options: ConversionOptions) async throws -> URL {
        switch tool {
        case .mergePDFs: return try PDFTools.merge(urls, options: options)
        case .imagesToPDF: return try PDFTools.imagesToPDF(urls, options: options)
        case .archive(let format):
            return try await ArchiveTool.compress(urls, to: format, name: urls.count == 1 ? nil : "Archive", options: options)
        }
    }
}
