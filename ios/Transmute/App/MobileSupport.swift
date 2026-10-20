import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What the iPhone and iPad app offers for each file. The Mac app can do more because it has
/// ffmpeg and can drive Pages, Keynote and Numbers; everything listed here runs on the device
/// and is exercised by the iOS self-test.
enum Mobile {
    static let images: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "tiff", "tif", "bmp", "gif",
                                      "ico", "jp2", "psd", "avif", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf"]
    static let videos: Set<String> = ["mp4", "mov", "m4v", "3gp"]
    static let audio: Set<String> = ["mp3", "m4a", "wav", "flac", "aiff", "aif", "aac", "caf"]
    static let documents: Set<String> = ["txt", "md", "markdown", "rtf", "docx", "html", "htm"]
    static let spreadsheets: Set<String> = ["xlsx", "csv", "tsv", "ods"]
    static let presentations: Set<String> = ["pptx", "key", "odp"]
    static let archives: Set<String> = ["zip", "tar", "gz", "tgz"]

    /// HEIC needs a hardware HEVC encoder, which every supported iPhone and iPad has but the
    /// simulator may not.
    static let canWriteHEIC: Bool = {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let image = ctx.makeImage() else { return false }
        return (try? ImageConverter.data(from: image, type: .heic)) != nil
    }()

    private static func ext(_ url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") { return "tgz" }
        return url.pathExtension.lowercased()
    }

    /// Whether the device can read the file at all (anything can still be zipped).
    static func canOpen(_ url: URL) -> Bool {
        let e = ext(url)
        switch FileKind.of(url) {
        case .image: return images.contains(e)
        case .video: return videos.contains(e)
        case .audio: return audio.contains(e)
        case .pdf, .ebook, .subtitle: return true
        case .document: return documents.contains(e)
        case .spreadsheet: return spreadsheets.contains(e)
        case .presentation: return presentations.contains(e)
        case .archive: return archives.contains(e)
        case .other: return false
        }
    }

    /// Formats a file can be converted to here, most useful first (the Mac app's order).
    static func targets(for url: URL) -> [OutputFormat] {
        let kind = FileKind.of(url)
        let open = canOpen(url)
        let allowed: Set<OutputFormat>
        switch kind {
        case .image:
            var formats: Set<OutputFormat> = [.jpeg, .png, .tiff, .bmp, .gif, .pdf, .svg]
            if canWriteHEIC { formats.insert(.heic) }
            if ImageConverter.canWriteWebP { formats.insert(.webp) }
            allowed = open ? formats : []
        case .video: allowed = open ? [.mp4, .mov, .gif, .m4a, .wav] : []
        case .audio: allowed = open ? [.m4a, .wav, .flac, .aiff] : []
        case .pdf: allowed = [.png, .jpeg, .txt, .rtf, .docx, .html]
        case .document: allowed = open ? [.pdf, .docx, .rtf, .txt, .html, .epub] : []
        case .ebook: allowed = [.pdf, .txt, .html, .docx, .rtf]
        case .presentation: allowed = open ? [.png, .jpeg] : []
        case .spreadsheet: allowed = open ? [.csv, .xlsx, .pdf, .html] : []
        case .subtitle: allowed = [.srt, .vtt]
        case .archive: allowed = open ? [.extract, .zip, .tgz] : [.zip, .tgz]
        case .other: allowed = [.zip, .tgz]
        }
        let ordered = kind.convertTargets.filter(allowed.contains)
        // Anything else can still be packed into an archive.
        return ordered.isEmpty ? [.zip, .tgz] : ordered
    }

    static func canCompress(_ url: URL) -> Bool {
        switch FileKind.of(url) {
        case .image, .video, .audio: return canOpen(url)
        case .pdf: return true
        default: return false
        }
    }

    static func canStripMetadata(_ url: URL) -> Bool {
        let e = ext(url)
        switch FileKind.of(url) {
        // Removing metadata re-saves the picture in its own format, which needs an encoder for it.
        case .image: return canOpen(url) && (e != "webp" || ImageConverter.canWriteWebP) && (e != "heic" || canWriteHEIC)
        case .pdf: return true
        case .video: return ["mp4", "mov", "m4v"].contains(e)
        case .audio: return ["m4a", "wav", "aiff", "aif", "caf"].contains(e)
        default: return false
        }
    }

    enum Editor: Equatable { case image, video, audio }

    static func editor(for url: URL) -> Editor? {
        guard canOpen(url) else { return nil }
        switch FileKind.of(url) {
        case .image: return .image
        case .video: return .video
        case .audio: return .audio
        default: return nil
        }
    }

    static func hasInfo(_ url: URL) -> Bool {
        switch FileKind.of(url) {
        case .image, .video, .audio: return canOpen(url)
        case .pdf: return true
        default: return false
        }
    }
}
