import AVFoundation
import Foundation

/// Video and audio. Uses ffmpeg when installed; otherwise falls back to what
/// macOS can do on its own (AVFoundation and the built-in `afconvert`).
enum MediaConverter {
    static func convert(_ input: URL, to format: OutputFormat, options: ConversionOptions,
                        progress: @escaping ProgressHandler) async throws -> URL {
        let out = OutputPaths.destination(for: input, ext: format.fileExtension, folder: options.outputFolder)
        do {
            if let ffmpeg = Tools.ffmpeg {
                guard let args = ffmpegArgs(for: format) else {
                    throw ConversionError("Can't convert media to \(format.label).")
                }
                let meta = options.stripMetadata ? ["-map_metadata", "-1"] : []
                try await runFFmpeg(ffmpeg, input: input, args: args + meta, output: out, progress: progress)
            } else {
                try await AppleMedia.convert(input, to: format, output: out, progress: progress)
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }

    private static let evenSize = ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2"]

    static func ffmpegArgs(for format: OutputFormat) -> [String]? {
        let h264 = ["-c:v", "libx264", "-preset", "medium", "-crf", "23", "-pix_fmt", "yuv420p"] + evenSize
        switch format {
        case .mp4: return h264 + ["-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]
        case .mov: return h264 + ["-c:a", "aac", "-b:a", "160k"]
        case .mkv: return h264 + ["-c:a", "aac", "-b:a", "160k"]
        case .avi: return ["-c:v", "mpeg4", "-q:v", "4", "-c:a", "libmp3lame", "-q:a", "4"]
        case .wmv: return ["-c:v", "wmv2", "-b:v", "2M", "-c:a", "wmav2", "-b:a", "160k"]
        case .webm: return ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus", "-b:a", "128k"]
        case .gif:
            return ["-an", "-vf", "fps=12,scale=480:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop", "0"]
        case .mp3: return ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case .m4a: return ["-vn", "-c:a", "aac", "-b:a", "192k"]
        case .wav: return ["-vn", "-c:a", "pcm_s16le"]
        case .flac: return ["-vn", "-c:a", "flac"]
        case .ogg: return ["-vn", "-c:a", "libvorbis", "-q:a", "5"]
        case .opus: return ["-vn", "-c:a", "libopus", "-b:a", "128k"]
        case .aiff: return ["-vn", "-c:a", "pcm_s16be"]
        default: return nil
        }
    }

    static func runFFmpeg(_ ffmpeg: String, input: URL, args: [String], output: URL,
                          progress: @escaping ProgressHandler) async throws {
        let tracker = FFmpegProgress(progress)
        let fullArgs = ["-hide_banner", "-nostdin", "-y", "-progress", "pipe:1", "-nostats", "-i", input.path]
            + args + [output.path]
        try await Shell.check(ffmpeg, fullArgs,
                              onStdoutLine: { tracker.stdout($0) },
                              onStderrLine: { tracker.stderr($0) })
        progress(1)
    }

    // MARK: Compression

    static func compress(_ input: URL, kind: FileKind, goal: Int64, options: ConversionOptions,
                         progress: @escaping ProgressHandler) async throws -> JobResult {
        let duration = await MediaInfo.duration(of: input)
        guard duration > 0 else { throw ConversionError("Couldn't read the length of \(input.lastPathComponent).") }
        let ext = input.pathExtension.lowercased()
        let totalBitsPerSecond = Double(goal) * 8 * 0.95 / duration

        let outExt: String
        var args: [String]
        if kind == .video {
            outExt = ["mp4", "mov", "mkv", "webm"].contains(ext) ? ext : "mp4"
            let audio = 96_000.0
            let video = min(500_000_000, max(80_000, totalBitsPerSecond - audio))
            var filters = "scale=trunc(iw/2)*2:trunc(ih/2)*2"
            if video < 500_000 {
                filters = "scale=w='min(854,iw)':h=-2"
            } else if video < 1_500_000 {
                filters = "scale=w='min(1280,iw)':h=-2"
            }
            let v = String(Int(video))
            if outExt == "webm" {
                args = ["-c:v", "libvpx-vp9", "-b:v", v, "-row-mt", "1", "-vf", filters, "-c:a", "libopus", "-b:a", "96k"]
            } else {
                args = ["-c:v", "libx264", "-preset", "medium", "-b:v", v, "-maxrate", String(Int(video * 1.4)),
                        "-bufsize", String(Int(video * 2)), "-pix_fmt", "yuv420p", "-vf", filters,
                        "-c:a", "aac", "-b:a", "96k"]
                if outExt != "mkv" { args += ["-movflags", "+faststart"] }
            }
        } else {
            outExt = ["mp3", "m4a", "ogg", "opus"].contains(ext) ? ext : "m4a"
            let bitrate = String(Int(min(320_000, max(32_000, totalBitsPerSecond))))
            let codec = ["mp3": "libmp3lame", "m4a": "aac", "ogg": "libvorbis", "opus": "libopus"][outExt] ?? "aac"
            args = ["-vn", "-c:a", codec, "-b:a", bitrate]
        }
        if options.stripMetadata { args += ["-map_metadata", "-1"] }

        let ffmpeg = Tools.ffmpeg
        // Without ffmpeg, Apple's encoders can only write MP4 video and M4A audio.
        let finalExt = ffmpeg != nil ? outExt : (kind == .video ? "mp4" : "m4a")
        let out = OutputPaths.destination(for: input, ext: finalExt, suffix: "compressed", folder: options.outputFolder)
        do {
            if let ffmpeg {
                try await runFFmpeg(ffmpeg, input: input, args: args, output: out, progress: progress)
            } else if kind == .video {
                // Pick an Apple preset by how much smaller it has to get.
                let ratio = Double(goal) / Double(max(1, OutputPaths.fileSize(input)))
                let preset = ratio < 0.25 ? AVAssetExportPreset640x480
                    : ratio < 0.5 ? AVAssetExportPreset960x540 : AVAssetExportPreset1280x720
                try await AppleMedia.export(input, preset: preset, type: .mp4, output: out, progress: progress)
            } else {
                let bitrate = Int(min(320_000, max(32_000, totalBitsPerSecond)))
                #if os(iOS)
                try await AppleAudio.transcode(input, to: .m4a, output: out, bitrate: bitrate, progress: progress)
                #else
                try await Shell.check("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", "-b", String(bitrate), input.path, out.path])
                #endif
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return result(input: input, output: out, goal: goal)
    }

    private static func result(input: URL, output: URL, goal: Int64) -> JobResult {
        let before = OutputPaths.fileSize(input), after = OutputPaths.fileSize(output)
        var message = "\(before.formattedSize) → \(after.formattedSize)"
        if after > goal + goal / 10 { message += " (target \(goal.formattedSize) was too small to hit exactly)" }
        return JobResult(outputs: [output], message: message)
    }

    // MARK: Metadata

    static func stripMetadata(_ input: URL, options: ConversionOptions) async throws -> URL {
        let out = OutputPaths.destination(for: input, ext: input.pathExtension, suffix: "clean", folder: options.outputFolder)
        do {
            if let ffmpeg = Tools.ffmpeg {
                try await Shell.check(ffmpeg, ["-hide_banner", "-nostdin", "-y", "-i", input.path,
                                               "-map", "0", "-map_metadata", "-1", "-map_chapters", "-1",
                                               "-c", "copy", out.path])
            } else {
                let type: AVFileType
                switch input.pathExtension.lowercased() {
                case "mp4": type = .mp4
                case "m4a": type = .m4a
                case "m4v": type = .m4v
                case "mov": type = .mov
                case "wav": type = .wav
                case "aif", "aiff": type = .aiff
                case "caf": type = .caf
                default:
                    throw ConversionError("Removing metadata from \(input.pathExtension.uppercased()) files needs ffmpeg. Install it once with: brew install ffmpeg")
                }
                try await AppleMedia.export(input, preset: AVAssetExportPresetPassthrough, type: type, output: out,
                                            clearMetadata: true, progress: { _ in })
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }
}

/// Turns ffmpeg's `-progress` output into a 0…1 fraction.
final class FFmpegProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var duration: Double = 0
    private let handler: ProgressHandler

    init(_ handler: @escaping ProgressHandler) { self.handler = handler }

    func stderr(_ line: String) {
        guard let seconds = Self.parseDuration(line) else { return }
        lock.lock()
        if duration == 0 { duration = seconds }
        lock.unlock()
    }

    func stdout(_ line: String) {
        guard line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") else { return }
        guard let micro = Double(line.split(separator: "=").last ?? "") else { return }
        lock.lock()
        let total = duration
        lock.unlock()
        if total > 0 { handler(min(1, max(0, micro / 1_000_000 / total))) }
    }

    /// Finds "Duration: 00:01:02.50" in ffmpeg's banner.
    static func parseDuration(_ text: String) -> Double? {
        guard let range = text.range(of: "Duration: ") else { return nil }
        let stamp = text[range.upperBound...].prefix { $0 != "," }
        let parts = stamp.split(separator: ":").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }
}

enum MediaInfo {
    static func duration(of url: URL) async -> Double {
        if let time = try? await AVURLAsset(url: url).load(.duration), time.isNumeric, time.seconds > 0 {
            return time.seconds
        }
        if let ffmpeg = Tools.ffmpeg, let output = try? await Shell.run(ffmpeg, ["-hide_banner", "-i", url.path]) {
            return FFmpegProgress.parseDuration(output.stderr) ?? 0
        }
        return 0
    }
}

/// Conversions macOS can do without ffmpeg.
enum AppleMedia {
    static func convert(_ input: URL, to format: OutputFormat, output: URL, progress: @escaping ProgressHandler) async throws {
        switch format {
        case .mp4, .mov:
            try await export(input, preset: AVAssetExportPresetHighestQuality, type: format == .mp4 ? .mp4 : .mov,
                             output: output, progress: progress)
        case .m4a:
            try await export(input, preset: AVAssetExportPresetAppleM4A, type: .m4a, output: output, progress: progress)
        #if os(iOS)
        case .wav, .aiff, .flac:
            try await AppleAudio.transcode(input, to: format, output: output, progress: progress)
        case .gif where FileKind.of(input) == .video:
            try await AppleGIF.make(from: input, output: output, progress: progress)
        #else
        case .wav, .aiff, .flac:
            let args: [String] = switch format {
            case .wav: ["-f", "WAVE", "-d", "LEI16"]
            case .aiff: ["-f", "AIFF", "-d", "BEI16"]
            default: ["-f", "flac", "-d", "flac"]
            }
            var source = input
            var temp: URL?
            if FileKind.of(input) == .video {
                // afconvert only reads audio files, so pull the soundtrack out first.
                let m4a = OutputPaths.temporaryURL(ext: "m4a")
                try await export(input, preset: AVAssetExportPresetAppleM4A, type: .m4a, output: m4a, progress: { _ in })
                source = m4a
                temp = m4a
            }
            defer { if let temp { try? FileManager.default.removeItem(at: temp) } }
            try await Shell.check("/usr/bin/afconvert", args + [source.path, output.path])
            progress(1)
        #endif
        default:
            throw ConversionError("\(format.label) needs ffmpeg. Install it once with: brew install ffmpeg")
        }
    }

    static func export(_ input: URL, preset: String, type: AVFileType, output: URL,
                       clearMetadata: Bool = false, progress: @escaping ProgressHandler) async throws {
        let asset = AVURLAsset(url: input)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionError("macOS can't export \(input.lastPathComponent) this way.")
        }
        session.outputURL = output
        // Setting an unsupported type raises an Objective-C exception, so check first.
        guard session.supportedFileTypes.contains(type) else {
            throw ConversionError("macOS can't save \(input.lastPathComponent) as \(type.rawValue).")
        }
        session.outputFileType = type
        if clearMetadata {
            session.metadata = []
            session.metadataItemFilter = .forSharing()
        }
        try? FileManager.default.removeItem(at: output)
        let poller = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        await withTaskCancellationHandler {
            await session.export()
        } onCancel: {
            session.cancelExport()
        }
        poller.cancel()
        try Task.checkCancellation()
        guard session.status == .completed else {
            throw ConversionError(session.error?.localizedDescription ?? "Export failed.")
        }
        progress(1)
    }
}
