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
                let streams = await MediaStreams.read(input, ffmpeg: ffmpeg)
                do {
                    do {
                        try await runFFmpeg(ffmpeg, input: input, args: streams.maps(for: args) + args + meta,
                                            output: out, progress: progress)
                    } catch where !(error is CancellationError) && !args.contains("-an") {
                        // A second go without a track ffmpeg named as unreadable, and with plain stereo
                        // sound, which most failures on odd camera files come down to.
                        try? FileManager.default.removeItem(at: out)
                        let retry = streams.excluding(errorText: error.localizedDescription) ?? streams
                        try await runFFmpeg(ffmpeg, input: input, args: retry.maps(for: args) + args + meta + ["-ac", "2"],
                                            output: out, progress: progress)
                    }
                } catch let ffmpegError where !(ffmpegError is CancellationError) {
                    // macOS reads some files ffmpeg can't, so let it try before giving up.
                    try? FileManager.default.removeItem(at: out)
                    guard AppleMedia.canConvert(to: format) else {
                        throw ConversionError(MediaStreams.explain(error: ffmpegError, input: input))
                    }
                    do {
                        try await AppleMedia.convert(input, to: format, output: out, progress: progress)
                    } catch {
                        throw ConversionError(MediaStreams.explain(error: ffmpegError, input: input))
                    }
                }
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
                let streams = await MediaStreams.read(input, ffmpeg: ffmpeg)
                try await runFFmpeg(ffmpeg, input: input, args: streams.maps(for: args) + args, output: out, progress: progress)
            } else if kind == .video {
                // Pick an Apple preset by how much smaller it has to get.
                let ratio = Double(goal) / Double(max(1, OutputPaths.fileSize(input)))
                let preset = ratio < 0.25 ? AVAssetExportPreset640x480
                    : ratio < 0.5 ? AVAssetExportPreset960x540 : AVAssetExportPreset1280x720
                try await AppleMedia.export(input, preset: preset, type: .mp4, output: out, progress: progress)
            } else {
                let bitrate = Int(min(320_000, max(32_000, totalBitsPerSecond)))
                try await Shell.check("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", "-b", String(bitrate), input.path, out.path])
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
                let maps = await MediaStreams.read(input, ffmpeg: ffmpeg).copyMaps
                try await Shell.check(ffmpeg, ["-hide_banner", "-nostdin", "-y", "-i", input.path]
                                      + maps + ["-map_metadata", "-1", "-map_chapters", "-1", "-c", "copy", out.path])
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

/// The tracks in a media file as ffmpeg lists them, so a conversion can pick ones ffmpeg can decode.
/// Recent iPhones add a spatial-audio track (APAC) next to the normal one; ffmpeg picks the track
/// with the most channels by default, can't decode it, and the whole conversion fails.
struct MediaStreams: Equatable {
    struct Track: Equatable {
        var type: String        // "Video", "Audio", "Subtitle", "Data"
        var codec: String       // "h264", "aac", "none" when ffmpeg doesn't know it
        var channels: Int?
        var isDefault: Bool
        var attachedPicture: Bool
    }

    var tracks: [Track] = []

    /// Codecs ffmpeg lists but can't decode. ffmpeg 7.1 and later call Apple's spatial audio "apple_apac".
    static let undecodable: Set<String> = ["none", "apac", "apple_apac"]

    static func read(_ url: URL, ffmpeg: String) async -> MediaStreams {
        guard let output = try? await Shell.run(ffmpeg, ["-hide_banner", "-nostdin", "-i", url.path]) else { return MediaStreams() }
        return parse(output.stderr)
    }

    /// Reads lines like "Stream #0:1[0x2](und): Audio: aac (LC) (mp4a / 0x6134706D), 48000 Hz, stereo, fltp (default)".
    static func parse(_ banner: String) -> MediaStreams {
        var tracks: [Track] = []
        let pattern = try? NSRegularExpression(pattern: #"Stream #0:\d+(?:\[0x[0-9a-fA-F]+\])?(?:\([^)]*\))?: (\w+): (.*)"#)
        for line in banner.split(whereSeparator: \.isNewline).map(String.init) where line.contains("Stream #0:") {
            let ns = line as NSString
            guard let match = pattern?.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let type = ns.substring(with: match.range(at: 1))
            let details = ns.substring(with: match.range(at: 2))
            let codec = String(details.prefix { $0 != " " && $0 != "," }).lowercased()
            var channels: Int?
            let fields = details.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if type == "Audio", let hz = fields.firstIndex(where: { $0.hasSuffix(" Hz") }), hz + 1 < fields.count {
                channels = Self.channelCount(fields[hz + 1])
            }
            tracks.append(Track(type: type, codec: codec, channels: channels, isDefault: line.contains("(default)"),
                                attachedPicture: line.contains("attached pic")))
        }
        return MediaStreams(tracks: tracks)
    }

    static func channelCount(_ layout: String) -> Int? {
        switch layout {
        case "mono": return 1
        case "stereo", "downmix": return 2
        case "2.1", "3.0", "3.0(back)": return 3
        case "quad", "quad(side)", "4.0": return 4
        case "5.0", "5.0(side)", "4.1": return 5
        case "5.1", "5.1(side)", "6.0": return 6
        case "6.1", "7.0": return 7
        case "7.1", "7.1(wide)": return 8
        default:
            if let n = Int(layout.split(separator: " ").first ?? ""), layout.contains("channel") { return n }
            return nil
        }
    }

    /// "0:a:1": the default sound track if ffmpeg can decode it, otherwise the first one it can.
    var audioSpec: String? { spec(for: bestAudio, type: "Audio", prefix: "a") }
    /// "0:V:0": the first real video track (not cover art).
    var videoSpec: String? {
        let videos = tracks.filter { $0.type == "Video" && !$0.attachedPicture }
        guard let index = videos.firstIndex(where: { !Self.undecodable.contains($0.codec) }) else { return nil }
        return "0:V:\(index)"
    }

    var audioChannels: Int? { bestAudio?.channels }
    var hasUndecodableAudio: Bool { tracks.contains { $0.type == "Audio" && Self.undecodable.contains($0.codec) } }

    private var bestAudio: Track? {
        let audio = tracks.filter { $0.type == "Audio" && !Self.undecodable.contains($0.codec) }
        return audio.first(where: \.isDefault) ?? audio.first
    }

    private func spec(for track: Track?, type: String, prefix: String) -> String? {
        guard let track else { return nil }
        let same = tracks.filter { $0.type == type }
        guard let index = same.firstIndex(of: track) else { return nil }
        return "0:\(prefix):\(index)"
    }

    /// -map arguments for these encoder arguments (which say "-vn" for sound only, "-an" for no sound).
    /// Empty when the file couldn't be read, which leaves the choice to ffmpeg.
    func maps(for args: [String]) -> [String] {
        guard !tracks.isEmpty else { return [] }
        var maps: [String] = []
        if !args.contains("-vn"), let v = videoSpec { maps += ["-map", v] }
        if !args.contains("-an"), let a = audioSpec { maps += ["-map", a] }
        if maps.isEmpty { return [] }
        // MP3 and WMA hold at most two channels, and Opus refuses camera surround layouts like
        // 5.1(side): surround and spatial sound is mixed down to stereo for those.
        let twoChannelCodecs: Set<String> = ["libmp3lame", "wmav2", "libopus"]
        if let channels = audioChannels, channels > 2,
           let i = args.firstIndex(of: "-c:a"), i + 1 < args.count, twoChannelCodecs.contains(args[i + 1]) {
            maps += ["-ac", "2"]
        }
        // Files with sparse tracks otherwise stop with "Too many packets buffered for output stream".
        return maps + ["-max_muxing_queue_size", "4096"]
    }

    /// "-map 0" without the tracks ffmpeg can't read, for copying a file's tracks as they are.
    var copyMaps: [String] {
        var maps = ["-map", "0"]
        let prefixes = ["Video": "v", "Audio": "a", "Subtitle": "s", "Data": "d", "Attachment": "t"]
        for (type, prefix) in prefixes {
            for (i, track) in tracks.filter({ $0.type == type }).enumerated() where Self.undecodable.contains(track.codec) {
                maps += ["-map", "-0:\(prefix):\(i)"]
            }
        }
        return maps
    }

    /// The same tracks with the codec ffmpeg named in "no decoder found for: x" treated as unreadable,
    /// or nil when the error isn't about a missing decoder.
    func excluding(errorText: String) -> MediaStreams? {
        guard let range = errorText.range(of: "no decoder found for: ") else { return nil }
        let codec = String(errorText[range.upperBound...].prefix { !$0.isWhitespace }).lowercased()
        guard !codec.isEmpty, tracks.contains(where: { $0.codec == codec }) else { return nil }
        var copy = self
        for i in copy.tracks.indices where copy.tracks[i].codec == codec { copy.tracks[i].codec = "none" }
        return copy
    }

    /// A plainer message for the errors ffmpeg gives on files it can't read.
    static func explain(error: Error, input: URL) -> String {
        let text = error.localizedDescription
        if text.contains("Decoder") && text.contains("not found") || text.contains("no decoder") {
            return "\(input.lastPathComponent) uses a codec Spinform can't read yet. (\(text))"
        }
        return text
    }
}

/// Conversions macOS can do without ffmpeg.
enum AppleMedia {
    static func canConvert(to format: OutputFormat) -> Bool {
        [.mp4, .mov, .m4a, .wav, .aiff, .flac].contains(format)
    }

    static func convert(_ input: URL, to format: OutputFormat, output: URL, progress: @escaping ProgressHandler) async throws {
        switch format {
        case .mp4, .mov:
            try await export(input, preset: AVAssetExportPresetHighestQuality, type: format == .mp4 ? .mp4 : .mov,
                             output: output, progress: progress)
        case .m4a:
            try await export(input, preset: AVAssetExportPresetAppleM4A, type: .m4a, output: output, progress: progress)
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
