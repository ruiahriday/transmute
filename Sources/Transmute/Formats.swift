import Foundation

/// What kind of file something is, decided by its extension.
enum FileKind: String, CaseIterable, Identifiable, Sendable {
    case image, video, audio, pdf, document, ebook, presentation, spreadsheet, subtitle, archive, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: "Images"
        case .video: "Videos"
        case .audio: "Audio"
        case .pdf: "PDFs"
        case .document: "Documents"
        case .ebook: "E-books"
        case .presentation: "Presentations"
        case .spreadsheet: "Spreadsheets"
        case .subtitle: "Subtitles"
        case .archive: "Archives"
        case .other: "Other files"
        }
    }

    var symbol: String {
        switch self {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .pdf: "doc.richtext"
        case .document: "doc.text"
        case .ebook: "book"
        case .presentation: "rectangle.on.rectangle"
        case .spreadsheet: "tablecells"
        case .subtitle: "captions.bubble"
        case .archive: "archivebox"
        case .other: "doc"
        }
    }

    static func of(_ url: URL) -> FileKind {
        let name = url.lastPathComponent.lowercased()
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz"] where name.hasSuffix(suffix) {
            return .archive
        }
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "heif", "webp", "tiff", "tif", "bmp", "gif", "svg",
             "ico", "jp2", "psd", "avif", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf":
            return .image
        case "mp4", "mov", "m4v", "mkv", "avi", "wmv", "webm", "flv", "mpg", "mpeg", "3gp", "ts", "mts", "m2ts":
            return .video
        case "mp3", "m4a", "wav", "flac", "ogg", "oga", "opus", "aiff", "aif", "aac", "wma", "caf":
            return .audio
        case "pdf":
            return .pdf
        case "txt", "md", "markdown", "rtf", "rtfd", "doc", "docx", "odt", "html", "htm", "webarchive", "pages":
            return .document
        case "epub":
            return .ebook
        case "pptx", "ppt", "key", "odp":
            return .presentation
        case "xlsx", "xls", "numbers", "csv", "tsv", "ods":
            return .spreadsheet
        case "srt", "vtt":
            return .subtitle
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "rar", "7z":
            return .archive
        default:
            return .other
        }
    }

    /// Formats this kind of file can be converted to, most useful first.
    var convertTargets: [OutputFormat] {
        switch self {
        case .image: [.jpeg, .png, .heic, .webp, .tiff, .bmp, .gif, .pdf, .svg]
        case .video: [.mp4, .mov, .mkv, .webm, .avi, .wmv, .gif, .mp3, .m4a, .wav]
        case .audio: [.mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff]
        case .pdf: [.png, .jpeg, .txt, .rtf, .docx, .html]
        case .document: [.pdf, .docx, .rtf, .txt, .html, .odt, .epub, .pages]
        case .ebook: [.pdf, .txt, .html, .docx, .rtf]
        case .presentation: [.pdf, .pptx, .key, .png, .jpeg]
        case .spreadsheet: [.csv, .xlsx, .numbers, .pdf, .html]
        case .subtitle: [.srt, .vtt]
        case .archive: [.extract, .zip, .tgz]
        case .other: [.zip, .tgz]
        }
    }

    var canCompress: Bool { [.image, .video, .audio, .pdf].contains(self) }
    var canStripMetadata: Bool { [.image, .video, .audio, .pdf].contains(self) }
}

enum OutputFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg, png, heic, webp, tiff, bmp, gif, svg, pdf
    case mp4, mov, mkv, avi, wmv, webm
    case mp3, m4a, wav, flac, ogg, opus, aiff
    case txt, rtf, docx, html, odt, epub, pages
    case pptx, key
    case xlsx, numbers, csv
    case srt, vtt
    case zip, tar, tgz, extract

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .tgz: "tar.gz"
        case .extract: ""
        default: rawValue
        }
    }

    var label: String {
        switch self {
        case .extract: "Extract"
        case .tgz: "TAR.GZ"
        default: rawValue.uppercased()
        }
    }

    var symbol: String {
        switch self {
        case .jpeg, .png, .heic, .webp, .tiff, .bmp, .gif, .svg: "photo"
        case .pdf: "doc.richtext"
        case .mp4, .mov, .mkv, .avi, .wmv, .webm: "film"
        case .mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff: "music.note"
        case .txt, .rtf, .docx, .html, .odt, .pages: "doc.text"
        case .epub: "book"
        case .pptx, .key: "rectangle.on.rectangle"
        case .xlsx, .numbers, .csv: "tablecells"
        case .srt, .vtt: "captions.bubble"
        case .zip, .tar, .tgz: "archivebox"
        case .extract: "arrow.up.bin"
        }
    }
}

enum CompressionTarget: Equatable, Sendable {
    /// Fraction of the original size, e.g. 0.5 for half.
    case percent(Double)
    case bytes(Int64)

    func goal(forOriginal size: Int64) -> Int64 {
        switch self {
        case .percent(let p): max(1, Int64(Double(size) * p))
        case .bytes(let b): b
        }
    }
}

enum JobOperation: Equatable, Sendable {
    case convert(OutputFormat)
    case compress(CompressionTarget)
    case stripMetadata
    case splitPDF
    case readQR
    // Editors (types defined in ImageEditor.swift, VideoEditor.swift, AudioEditor.swift, MetadataEditor.swift)
    case editImage(ImageEdit)
    case editVideo(VideoEdit)
    case editAudio(AudioEdit)
    case writeMetadata(MetadataEdit)
    case snapshot(seconds: Double)
}

/// Tools that take several files and produce one output.
enum BatchTool: Sendable {
    case mergePDFs
    case imagesToPDF
    case archive(OutputFormat)
    case joinVideos
}

struct JobResult: Equatable, Sendable {
    var outputs: [URL] = []
    var message: String?
}

struct ConversionOptions: Sendable {
    var quality: Double = 0.85
    /// nil means "next to the original file".
    var outputFolder: URL?
    var stripMetadata = false

    static func fromDefaults() -> ConversionOptions {
        let d = UserDefaults.standard
        var options = ConversionOptions()
        if d.object(forKey: Prefs.imageQuality) != nil { options.quality = d.double(forKey: Prefs.imageQuality) }
        options.stripMetadata = d.bool(forKey: Prefs.stripMetadata)
        #if APPSTORE
        // The sandbox needs the bookmark; the path is only shown in Settings.
        if d.string(forKey: Prefs.outputMode) == OutputMode.folder.rawValue {
            options.outputFolder = FolderAccess.savedOutputFolder
        }
        #else
        if d.string(forKey: Prefs.outputMode) == OutputMode.folder.rawValue,
           let path = d.string(forKey: Prefs.outputFolderPath), !path.isEmpty {
            options.outputFolder = URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        return options
    }
}

enum OutputMode: String {
    case besideOriginal = "beside"
    case folder = "folder"
}

/// UserDefaults keys, shared by @AppStorage and plain UserDefaults reads.
enum Prefs {
    static let imageQuality = "imageQuality"
    static let stripMetadata = "stripMetadataOnConvert"
    static let outputMode = "outputMode"
    /// Shown in Settings. The App Store build also keeps a bookmark (FolderAccess).
    static let outputFolderPath = "outputFolderPath"
    static let revealWhenDone = "revealWhenDone"
    static let wheelEnabled = "dragWheelEnabled"
    static let showInDock = "showInDock"
    static let shakeToShelf = "shakeToOpenFloatingFiles"
    static let notchToShelf = "notchOpensFloatingFiles"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            imageQuality: 0.85,
            revealWhenDone: true,
            wheelEnabled: true,
            showInDock: true,
            shakeToShelf: true,
            notchToShelf: true,
            outputMode: OutputMode.besideOriginal.rawValue,
        ])
    }
}

struct ConversionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

typealias ProgressHandler = @Sendable (Double) -> Void

enum OutputPaths {
    private static let lock = NSLock()
    private static var reserved = Set<String>()

    /// File name without extension, treating ".tar.gz" and friends as one extension.
    static func baseName(of url: URL) -> String {
        let name = url.lastPathComponent
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz"] where name.lowercased().hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return url.deletingPathExtension().lastPathComponent
    }

    static func destination(for input: URL, ext: String, suffix: String? = nil, folder: URL?) -> URL {
        let base = baseName(of: input) + (suffix.map { " (\($0))" } ?? "")
        return unique(in: folder ?? input.deletingLastPathComponent(), base: base, ext: ext)
    }

    /// A path in `dir` that doesn't exist yet and hasn't been handed to another running job.
    static func unique(in dir: URL, base: String, ext: String) -> URL {
        func make(_ b: String) -> URL { dir.appendingPathComponent(ext.isEmpty ? b : "\(b).\(ext)") }
        lock.lock()
        defer { lock.unlock() }
        var candidate = make(base)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) || reserved.contains(candidate.path) {
            candidate = make("\(base) \(n)")
            n += 1
        }
        reserved.insert(candidate.path)
        return candidate
    }

    static func fileSize(_ url: URL) -> Int64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        return size ?? 0
    }

    static func temporaryURL(ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("transmute-\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }
}

extension Int64 {
    var formattedSize: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
