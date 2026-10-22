import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Edit settings

/// What the video editor changes. A plain value so it can travel inside `JobOperation`.
struct VideoEdit: Equatable, Sendable {
    /// Centred crop to a fixed shape.
    enum CropAspect: String, CaseIterable, Identifiable, Sendable {
        case original, square, portrait9x16, landscape16x9, classic4x3

        var id: String { rawValue }

        var label: String {
            switch self {
            case .original: "Original"
            case .square: "Square 1:1"
            case .portrait9x16: "Portrait 9:16"
            case .landscape16x9: "Landscape 16:9"
            case .classic4x3: "Classic 4:3"
            }
        }

        /// Width and height of the shape, or nil to keep the frame as it is.
        var ratio: (width: Int, height: Int)? {
            switch self {
            case .original: return nil
            case .square: return (1, 1)
            case .portrait9x16: return (9, 16)
            case .landscape16x9: return (16, 9)
            case .classic4x3: return (4, 3)
            }
        }
    }

    /// Seconds into the original where the kept part starts.
    var trimStart: Double = 0
    /// Where the kept part ends; nil means the end of the video.
    var trimEnd: Double?
    /// Playback speed, 0.25…4.
    var speed: Double = 1
    var cropAspect: CropAspect = .original
    /// Clockwise quarter turns, 0…3.
    var quarterTurns: Int = 0
    var flipHorizontal = false
    var mute = false
    /// Loudness, 0…2; 1 leaves it as it is.
    var volume: Double = 1
    /// When set, the result is saved as two files split here (seconds into the original).
    var splitAt: Double?
    /// nil keeps MP4, MOV, MKV and WebM as they are and saves anything else as MP4.
    var outputFormat: OutputFormat?
}

// MARK: - Engine

/// Video editing, joining and frame grabs. Encoding goes through ffmpeg; frames come from
/// AVFoundation when it can read the file. Runs off the main thread.
enum VideoEditEngine {
    /// Containers the editor writes.
    static let editableFormats: [OutputFormat] = [.mp4, .mov, .mkv, .webm]

    static func outputFormat(for edit: VideoEdit, input: URL) -> OutputFormat {
        if let chosen = edit.outputFormat, editableFormats.contains(chosen) { return chosen }
        if let same = OutputFormat(rawValue: input.pathExtension.lowercased()), editableFormats.contains(same) {
            return same
        }
        return .mp4
    }

    // MARK: Edit

    private struct Segment {
        let start: Double
        /// nil runs to the end of the video.
        let end: Double?
        let suffix: String

        /// Seconds of the original this part covers, or 0 when that isn't known.
        func length(in total: Double) -> Double {
            let stop = end ?? total
            return stop > start ? stop - start : 0
        }
    }

    /// Trims, re-times, crops, rotates and remixes one video into a new file (two when splitting).
    static func apply(_ edit: VideoEdit, to input: URL, options: ConversionOptions,
                      progress: @escaping ProgressHandler) async throws -> JobResult {
        let ffmpeg = try Tools.requireFFmpeg(for: "Editing video")
        if let chosen = edit.outputFormat, !editableFormats.contains(chosen) {
            throw ConversionError("Edited videos can be saved as MP4, MOV, MKV or WebM, not \(chosen.label).")
        }
        let format = outputFormat(for: edit, input: input)
        let sourceLength = await MediaInfo.duration(of: input) // 0 when unknown
        let speed = edit.speed.isFinite ? min(4, max(0.25, edit.speed)) : 1

        // The kept range, checked against the real length when we know it.
        let start = edit.trimStart.isFinite ? max(0, edit.trimStart) : 0
        var stop = edit.trimEnd.flatMap { $0.isFinite ? $0 : nil }
        if let end = stop, sourceLength > 0, end >= sourceLength - 0.001 { stop = nil }
        if sourceLength > 0, start >= sourceLength - 0.01 {
            throw ConversionError("The start point is past the end of the video.")
        }
        if let end = stop, end <= start + 0.01 {
            throw ConversionError("The end point has to come after the start point.")
        }

        let segments: [Segment]
        if let split = edit.splitAt {
            let last = stop ?? (sourceLength > 0 ? sourceLength : .infinity)
            guard split.isFinite, split > start + 0.05, split < last - 0.05 else {
                throw ConversionError("The split point has to fall inside the part you're keeping.")
            }
            segments = [Segment(start: start, end: split, suffix: "part 1"),
                        Segment(start: split, end: stop, suffix: "part 2")]
        } else {
            segments = [Segment(start: start, end: stop, suffix: "edited")]
        }

        let keepAudio: Bool
        if edit.mute {
            keepAudio = false
        } else {
            keepAudio = await hasAudioTrack(input, ffmpeg: ffmpeg)
        }
        let videoChain = videoFilters(edit, speed: speed).joined(separator: ",")
        let audioChain = audioFilters(edit, speed: speed).joined(separator: ",")

        let totalWork = segments.map { $0.length(in: sourceLength) }.reduce(0, +)
        var outputs: [URL] = []
        var finished = 0.0
        // The sound track ffmpeg can decode (iPhones add a spatial-audio one it can't).
        let audioMap = keepAudio ? (await MediaStreams.read(input, ffmpeg: ffmpeg).audioSpec ?? "0:a:0") : "0:a:0"
        do {
            for segment in segments {
                let out = OutputPaths.destination(for: input, ext: format.fileExtension, suffix: segment.suffix,
                                                  folder: options.outputFolder)
                outputs.append(out)
                let part = segment.length(in: sourceLength)
                let before = finished
                let report: ProgressHandler = { fraction in
                    if totalWork > 0 { progress(min(1, (before + fraction * part) / totalWork)) }
                }

                var args = ["-hide_banner", "-nostdin", "-y", "-progress", "pipe:1", "-nostats"]
                // -ss/-t before -i seek fast and are still frame-accurate because we re-encode:
                // ffmpeg decodes from the keyframe before the start and drops what comes before it.
                if segment.start > 0 { args += ["-ss", stamp(segment.start)] }
                if let end = segment.end { args += ["-t", stamp(end - segment.start)] }
                args += ["-i", input.path, "-map", "0:V:0"]
                if keepAudio {
                    args += ["-map", audioMap]
                    if !audioChain.isEmpty { args += ["-af", audioChain] }
                } else {
                    args.append("-an")
                }
                args += ["-vf", videoChain, "-map_chapters", "-1"]
                if options.stripMetadata { args += ["-map_metadata", "-1"] }
                args += encoderArgs(for: format, audio: keepAudio)
                args.append(out.path)

                try await Shell.check(ffmpeg, args, onStdoutLine: progressParser(seconds: part / speed, report))
                finished += part
            }
        } catch {
            for url in outputs { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        progress(1)

        let lengths = segments.map { $0.length(in: sourceLength) / speed }
        let message: String?
        if lengths.contains(where: { $0 <= 0 }) {
            message = nil
        } else if lengths.count == 2 {
            message = "Parts: \(timeLabel(lengths[0], tenths: true)) and \(timeLabel(lengths[1], tenths: true))"
        } else {
            message = "Length \(timeLabel(lengths[0], tenths: true))"
        }
        return JobResult(outputs: outputs, message: message)
    }

    /// The -vf chain: speed, crop, rotation and flip, ending on even dimensions for the encoders.
    static func videoFilters(_ edit: VideoEdit, speed: Double) -> [String] {
        var filters: [String] = []
        if abs(speed - 1) > 0.001 { filters.append("setpts=(PTS-STARTPTS)/\(decimal(speed))") }
        if let ratio = edit.cropAspect.ratio {
            // Square pixels first so the shape is right for anamorphic video, then a centred crop
            // worked out from the frame size, so nothing has to be probed beforehand.
            let w = ratio.width, h = ratio.height
            filters.append("scale=w='trunc(iw*sar/2)*2':h=ih")
            filters.append("setsar=1")
            filters.append("crop=w='trunc(min(iw,ih*\(w)/\(h))/2)*2':h='trunc(min(ih,iw*\(h)/\(w))/2)*2'")
        }
        switch (edit.quarterTurns % 4 + 4) % 4 {
        case 1: filters.append("transpose=1") // 90° clockwise
        case 2: filters += ["hflip", "vflip"]
        case 3: filters.append("transpose=2") // 90° counter-clockwise
        default: break
        }
        if edit.flipHorizontal { filters.append("hflip") }
        filters.append("scale=trunc(iw/2)*2:trunc(ih/2)*2")
        return filters
    }

    /// The -af chain: tempo to match the speed, then volume. Empty when the sound is unchanged.
    static func audioFilters(_ edit: VideoEdit, speed: Double) -> [String] {
        var filters = atempoStages(for: speed).map { "atempo=\(decimal($0))" }
        let volume = edit.volume.isFinite ? min(2, max(0, edit.volume)) : 1
        if abs(volume - 1) > 0.001 { filters.append("volume=\(decimal(volume))") }
        return filters
    }

    /// atempo only takes 0.5…2 per stage, so bigger changes are chained: 4× is 2 × 2.
    static func atempoStages(for speed: Double) -> [Double] {
        var stages: [Double] = []
        var rest = speed
        while rest > 2.000_001 {
            stages.append(2)
            rest /= 2
        }
        while rest < 0.499_999 {
            stages.append(0.5)
            rest /= 0.5
        }
        if abs(rest - 1) > 0.000_001 { stages.append(rest) }
        return stages
    }

    private static func encoderArgs(for format: OutputFormat, audio: Bool) -> [String] {
        var args: [String]
        if format == .webm {
            args = ["-c:v", "libvpx-vp9", "-crf", "30", "-b:v", "0", "-row-mt", "1", "-pix_fmt", "yuv420p"]
            if audio { args += ["-c:a", "libopus", "-b:a", "128k"] }
        } else {
            args = ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p"]
            if audio { args += ["-c:a", "aac", "-b:a", "192k"] }
            if format != .mkv { args += ["-movflags", "+faststart"] }
        }
        return args
    }

    // MARK: Join

    /// Plays several videos one after another in one MP4. Each is fitted (letterboxed) into the
    /// first video's frame at 30 fps; videos without sound get silence so the audio stays in step.
    static func join(_ urls: [URL], options: ConversionOptions, progress: @escaping ProgressHandler) async throws -> URL {
        guard urls.count >= 2 else { throw ConversionError("Choose at least two videos to join.") }
        let ffmpeg = try Tools.requireFFmpeg(for: "Joining videos")
        let size = await frameSize(of: urls[0], ffmpeg: ffmpeg) ?? (width: 1920, height: 1080)
        let width = max(2, size.width / 2 * 2)
        let height = max(2, size.height / 2 * 2)

        var durations: [Double] = []
        var sound: [Bool] = []
        for url in urls {
            let length = await MediaInfo.duration(of: url)
            let audible = await hasAudioTrack(url, ffmpeg: ffmpeg)
            durations.append(length)
            sound.append(audible)
        }
        let withAudio = sound.contains(true)
        let audioFormat = "aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo"

        var args = ["-hide_banner", "-nostdin", "-y", "-progress", "pipe:1", "-nostats"]
        for url in urls { args += ["-i", url.path] }
        var graph: [String] = []
        var concatInputs = ""
        for index in urls.indices {
            graph.append("[\(index):v:0]scale=\(width):\(height):force_original_aspect_ratio=decrease,"
                + "pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,fps=30,format=yuv420p,"
                + "setpts=PTS-STARTPTS[v\(index)]")
            concatInputs += "[v\(index)]"
            guard withAudio else { continue }
            if sound[index] {
                graph.append("[\(index):a:0]aresample=48000,\(audioFormat),asetpts=PTS-STARTPTS[a\(index)]")
            } else {
                // Unknown lengths get a sliver of silence; concat pads short audio up to the video.
                let silence = durations[index] > 0 ? durations[index] : 0.1
                graph.append("anullsrc=channel_layout=stereo:sample_rate=48000,atrim=duration=\(decimal(silence)),"
                    + "\(audioFormat),asetpts=PTS-STARTPTS[a\(index)]")
            }
            concatInputs += "[a\(index)]"
        }
        let audioOut = withAudio ? "[outa]" : ""
        graph.append("\(concatInputs)concat=n=\(urls.count):v=1:a=\(withAudio ? 1 : 0)[outv]\(audioOut)")

        args += ["-filter_complex", graph.joined(separator: ";"), "-map", "[outv]"]
        if withAudio { args += ["-map", "[outa]"] }
        args += ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p"]
        if withAudio { args += ["-c:a", "aac", "-b:a", "192k"] }
        args += ["-movflags", "+faststart"]
        if options.stripMetadata { args += ["-map_metadata", "-1"] }

        let dir = options.outputFolder ?? urls[0].deletingLastPathComponent()
        let out = OutputPaths.unique(in: dir, base: "Joined", ext: "mp4")
        args.append(out.path)
        do {
            try await Shell.check(ffmpeg, args, onStdoutLine: progressParser(seconds: durations.reduce(0, +), progress))
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        progress(1)
        return out
    }

    // MARK: Snapshot

    /// Saves the frame at `seconds` as a PNG next to the video (or in the output folder).
    static func snapshot(of input: URL, at seconds: Double, options: ConversionOptions) async throws -> URL {
        var time = seconds.isFinite ? max(0, seconds) : 0
        let length = await MediaInfo.duration(of: input)
        // Asking for the very end finds no frame; use the last one instead.
        if length > 0, time > length - 0.04 { time = max(0, length - 0.04) }
        let out = OutputPaths.destination(for: input, ext: "png", suffix: "frame \(compact(time))s",
                                          folder: options.outputFolder)
        do {
            if let image = await appleFrame(of: input, at: time) {
                try ImageConverter.data(from: image, type: .png).write(to: out, options: .atomic)
            } else {
                // Containers AVFoundation can't read (MKV, WebM, AVI…).
                let what = "Taking a snapshot from \(input.pathExtension.uppercased()) video"
                let ffmpeg = try Tools.requireFFmpeg(for: what)
                try await Shell.check(ffmpeg, ["-hide_banner", "-nostdin", "-y", "-ss", stamp(time), "-i", input.path,
                                               "-map", "0:V:0", "-frames:v", "1", "-update", "1", out.path])
                guard OutputPaths.fileSize(out) > 0 else {
                    throw ConversionError("There's no frame at \(timeLabel(time, tenths: true)).")
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }

    /// The exact frame at a time, rotated upright, or nil when AVFoundation can't decode the file.
    private static func appleFrame(of url: URL, at seconds: Double) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        guard let frame = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) else {
            return nil
        }
        return frame.image
    }

    // MARK: Inspecting files

    /// Whether the file has a sound track. Asks AVFoundation first and ffmpeg for formats it can't open.
    static func hasAudioTrack(_ url: URL, ffmpeg: String?) async -> Bool {
        let asset = AVURLAsset(url: url)
        if let video = try? await asset.loadTracks(withMediaType: .video), !video.isEmpty,
           let audio = try? await asset.loadTracks(withMediaType: .audio) {
            return !audio.isEmpty
        }
        guard let ffmpeg, let output = try? await Shell.run(ffmpeg, ["-hide_banner", "-nostdin", "-i", url.path]) else {
            return false
        }
        return output.stderr.split(whereSeparator: \.isNewline).contains { $0.contains("Stream #") && $0.contains("Audio:") }
    }

    /// Whether AVFoundation, and so the preview player, can play the file.
    static func canPreview(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true else { return false }
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        return !tracks.isEmpty
    }

    /// Display size of the first video track with rotation applied, or nil when it can't be read.
    static func frameSize(of url: URL, ffmpeg: String?) async -> (width: Int, height: Int)? {
        let asset = AVURLAsset(url: url)
        if let tracks = try? await asset.loadTracks(withMediaType: .video), let track = tracks.first,
           let natural = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let box = CGRect(origin: .zero, size: natural).applying(transform)
            let width = Int(abs(box.width).rounded()), height = Int(abs(box.height).rounded())
            if width > 0, height > 0 { return (width, height) }
        }
        guard let ffmpeg, let output = try? await Shell.run(ffmpeg, ["-hide_banner", "-nostdin", "-i", url.path]) else {
            return nil
        }
        return parseFrameSize(output.stderr)
    }

    /// Reads "320x240" from the first video stream line of ffmpeg's banner.
    static func parseFrameSize(_ banner: String) -> (width: Int, height: Int)? {
        guard let line = banner.split(whereSeparator: \.isNewline)
            .first(where: { $0.contains("Stream #") && $0.contains("Video:") }),
            let regex = try? NSRegularExpression(pattern: "(?<![0-9x])([0-9]{2,5})x([0-9]{2,5})(?![0-9])")
        else { return nil }
        let text = String(line)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let widthRange = Range(match.range(at: 1), in: text),
              let heightRange = Range(match.range(at: 2), in: text),
              var width = Int(text[widthRange]), var height = Int(text[heightRange]),
              width > 0, height > 0
        else { return nil }
        // Phones store portrait video sideways with a rotation flag, which ffmpeg applies.
        if let degrees = rotation(in: banner), abs(degrees) % 180 == 90 { swap(&width, &height) }
        return (width, height)
    }

    private static func rotation(in banner: String) -> Int? {
        for pattern in ["rotation of (-?[0-9]+(?:\\.[0-9]+)?) degrees", "rotate\\s*:\\s*(-?[0-9]+)"] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: banner, range: NSRange(banner.startIndex..., in: banner)),
                  let range = Range(match.range(at: 1), in: banner),
                  let value = Double(banner[range]) else { continue }
            return Int(value.rounded())
        }
        return nil
    }

    // MARK: Formatting

    /// Turns ffmpeg's `-progress pipe:1` lines into 0…1 of an output `seconds` long.
    private static func progressParser(seconds total: Double,
                                       _ report: @escaping ProgressHandler) -> @Sendable (String) -> Void {
        return { line in
            guard total > 0, line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") else { return }
            guard let micro = Double(line.split(separator: "=").last ?? "") else { return }
            report(min(1, max(0, micro / 1_000_000 / total)))
        }
    }

    /// "1:05", "1:02:03", or with `tenths` "1:05.3".
    static func timeLabel(_ seconds: Double, tenths: Bool = false) -> String {
        let value = seconds.isFinite ? min(max(seconds, 0), 1_000_000) : 0
        let units = tenths ? Int((value * 10).rounded()) : Int(value.rounded())
        let whole = tenths ? units / 10 : units
        let h = whole / 3600, m = whole / 60 % 60, s = whole % 60
        var text = h > 0 ? "\(h):\(twoDigits(m)):\(twoDigits(s))" : "\(m):\(twoDigits(s))"
        if tenths { text += ".\(units % 10)" }
        return text
    }

    private static func twoDigits(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    /// "12.5", "3", "0.25": a number with no trailing zeros.
    static func compact(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Seconds for -ss/-t.
    private static func stamp(_ seconds: Double) -> String { String(format: "%.3f", seconds) }

    /// A number for a filter argument.
    private static func decimal(_ value: Double) -> String { String(format: "%.4f", value) }
}

// MARK: - Editor window

/// Trim, speed, crop, rotation and sound for one video, with a live preview when AVFoundation can
/// play the file. Nothing is encoded here: Save Copy hands the settings to `onSave`.
@MainActor
struct VideoEditorView: View {
    let url: URL
    let onSave: (VideoEdit) -> Void
    let onSnapshot: (Double) -> Void
    let onCancel: () -> Void

    @State private var edit = VideoEdit()
    @State private var player: AVPlayer? = nil
    @State private var timeObserver: Any? = nil
    @State private var loading = true
    @State private var duration: Double = 0
    @State private var playhead: Double = 0
    @State private var scrubbing = false
    @State private var splitEnabled = false
    @State private var splitPoint: Double = 0
    @State private var lastSnapshot: Double? = nil

    private static let speeds: [Double] = [0.25, 0.5, 1, 1.5, 2, 4]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(url.lastPathComponent)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            preview
                .frame(maxWidth: .infinity, minHeight: 200, idealHeight: 300, maxHeight: .infinity)
            timeline
            Divider()
            settings
            Divider()
            footer
        }
        .padding(16)
        .frame(minWidth: 640, idealWidth: 760, minHeight: 640, idealHeight: 760)
        .task { await prepare() }
        .onDisappear { tearDown() }
    }

    // MARK: Preview

    @ViewBuilder
    private var preview: some View {
        if let player {
            VideoPlayer(player: player)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if loading {
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "film")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Preview isn't available for this format")
                    .font(.headline)
                Text("Editing still works: pick times with the timeline below.")
                    .foregroundStyle(.secondary)
                if duration > 0 {
                    Text("Length \(clock(duration))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
        }
    }

    // MARK: Timeline

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(clock(playhead))
                    .monospacedDigit()
                Spacer()
                Text(duration > 0 ? clock(duration) : "Length unknown")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            rangeBar
                .frame(height: 8)
            Slider(value: playheadBinding, in: 0...timelineLength, onEditingChanged: { editing in
                scrubbing = editing
                if editing { player?.pause() }
            })
            HStack(spacing: 8) {
                Button("Set Start") { setStart() }
                TextField("Start", value: $edit.trimStart, format: secondsFormat)
                    .frame(width: 64)
                Text("to")
                TextField("End", value: $edit.trimEnd, format: secondsFormat, prompt: Text("End"))
                    .frame(width: 64)
                Button("Set End") { setEnd() }
                Text("seconds")
                    .foregroundStyle(.secondary)
                Spacer()
                if let lastSnapshot {
                    Text("Snapshot taken at \(clock(lastSnapshot))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    lastSnapshot = playhead
                    onSnapshot(playhead)
                } label: {
                    Label("Take Snapshot", systemImage: "camera")
                }
            }
        }
    }

    /// The whole length, with the kept part highlighted and the split point and playhead marked.
    private var rangeBar: some View {
        GeometryReader { geo in
            let total = timelineLength
            let width = geo.size.width
            let startX = width * position(edit.trimStart, of: total)
            let endX = width * position(edit.trimEnd ?? total, of: total)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: max(2, endX - startX))
                    .offset(x: startX)
                if splitEnabled {
                    Rectangle()
                        .fill(Color.orange)
                        .frame(width: 2)
                        .offset(x: width * position(splitPoint, of: total) - 1)
                }
                Rectangle()
                    .fill(Color.primary)
                    .frame(width: 2)
                    .offset(x: width * position(playhead, of: total) - 1)
            }
        }
    }

    private var playheadBinding: Binding<Double> {
        Binding(
            get: { playhead },
            set: { newValue in
                let clamped = min(max(newValue, 0), timelineLength)
                playhead = clamped
                seek(to: clamped)
            }
        )
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Speed") {
                Picker("Speed", selection: $edit.speed) {
                    ForEach(Self.speeds, id: \.self) { value in
                        Text(VideoEditEngine.compact(value) + "×").tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
            }
            row("Crop") {
                Picker("Crop", selection: $edit.cropAspect) {
                    ForEach(VideoEdit.CropAspect.allCases) { aspect in
                        Text(aspect.label).tag(aspect)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
            }
            row("Rotate") {
                Button {
                    edit.quarterTurns = (edit.quarterTurns + 3) % 4
                } label: {
                    Label("Left", systemImage: "rotate.left")
                }
                Button {
                    edit.quarterTurns = (edit.quarterTurns + 1) % 4
                } label: {
                    Label("Right", systemImage: "rotate.right")
                }
                Toggle(isOn: $edit.flipHorizontal) {
                    Label("Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .toggleStyle(.button)
                Text(orientationText)
                    .foregroundStyle(.secondary)
            }
            row("Sound") {
                Toggle("Mute", isOn: $edit.mute)
                Slider(value: $edit.volume, in: 0...2)
                    .frame(width: 160)
                    .disabled(edit.mute)
                Text("\(Int((edit.volume * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(edit.mute ? Color.secondary : Color.primary)
            }
            row("Split") {
                Toggle("Split at playhead into two files", isOn: splitBinding)
                if splitEnabled {
                    Text("at \(clock(splitPoint))")
                        .monospacedDigit()
                    Button("Move to Playhead") { splitPoint = playhead }
                }
            }
            row("Save as") {
                Picker("Save as", selection: $edit.outputFormat) {
                    Text(keepLabel).tag(Optional<OutputFormat>.none)
                    Text("MP4").tag(Optional(OutputFormat.mp4))
                    Text("MOV").tag(Optional(OutputFormat.mov))
                    Text("WebM").tag(Optional(OutputFormat.webm))
                    Text("MKV").tag(Optional(OutputFormat.mkv))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
            }
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 60, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private var splitBinding: Binding<Bool> {
        Binding(
            get: { splitEnabled },
            set: { on in
                splitEnabled = on
                guard on else { return }
                // Split at the playhead, or mid-way when the playhead is outside the kept part.
                let end = edit.trimEnd ?? duration
                splitPoint = playhead > edit.trimStart && playhead < end ? playhead : (edit.trimStart + end) / 2
            }
        )
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text(problem ?? resultText)
                .monospacedDigit()
                .foregroundStyle(problem == nil ? Color.secondary : Color.orange)
            Spacer()
            Button("Cancel") {
                player?.pause()
                onCancel()
            }
            .keyboardShortcut(.cancelAction)
            Button("Save Copy") {
                player?.pause()
                onSave(finishedEdit())
            }
            .buttonStyle(.borderedProminent)
            .disabled(problem != nil)
        }
    }

    /// Why the settings can't be saved yet, or nil when they can.
    private var problem: String? {
        let start = edit.trimStart
        let end = edit.trimEnd ?? (duration > 0 ? duration : .infinity)
        if !start.isFinite || start < 0 { return "The start can't be before 0:00." }
        if duration > 0 && start >= duration { return "The start is past the end of the video." }
        if end <= start + 0.05 { return "The end has to come after the start." }
        if splitEnabled && !(splitPoint > start + 0.05 && splitPoint < end - 0.05) {
            return "Move the split point inside the kept part."
        }
        return nil
    }

    private var resultText: String {
        let speed = max(edit.speed, 0.25)
        guard let end = edit.trimEnd ?? (duration > 0 ? duration : nil) else {
            return "Result: from \(clock(edit.trimStart)) to the end"
        }
        if splitEnabled {
            let first = clock((splitPoint - edit.trimStart) / speed), second = clock((end - splitPoint) / speed)
            return "Result: two files, \(first) and \(second)"
        }
        return "Result: \(clock((end - edit.trimStart) / speed)) long"
    }

    private var orientationText: String {
        var parts: [String] = []
        if edit.quarterTurns != 0 { parts.append("\(edit.quarterTurns * 90)° clockwise") }
        if edit.flipHorizontal { parts.append("mirrored") }
        return parts.isEmpty ? "Unchanged" : parts.joined(separator: ", ")
    }

    private var keepLabel: String {
        let kept = VideoEditEngine.outputFormat(for: VideoEdit(), input: url)
        return url.pathExtension.lowercased() == kept.rawValue ? "Keep" : "Keep (\(kept.label))"
    }

    private var secondsFormat: FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(0...2))
    }

    private var timelineLength: Double {
        max(duration, edit.trimEnd ?? 0, playhead, 1)
    }

    private func position(_ seconds: Double, of total: Double) -> CGFloat {
        guard total > 0, seconds.isFinite else { return 0 }
        return CGFloat(min(max(seconds / total, 0), 1))
    }

    private func clock(_ seconds: Double) -> String {
        VideoEditEngine.timeLabel(seconds, tenths: true)
    }

    // MARK: Actions

    private func setStart() {
        edit.trimStart = playhead
        if let end = edit.trimEnd, end <= playhead { edit.trimEnd = nil }
    }

    private func setEnd() {
        edit.trimEnd = playhead
        if edit.trimStart >= playhead { edit.trimStart = 0 }
    }

    private func finishedEdit() -> VideoEdit {
        var result = edit
        result.trimStart = max(0, edit.trimStart)
        if let end = result.trimEnd, duration > 0, end >= duration - 0.01 { result.trimEnd = nil }
        result.splitAt = splitEnabled ? splitPoint : nil
        return result
    }

    // MARK: Player

    private func prepare() async {
        let target = url
        let length = await MediaInfo.duration(of: target)
        let playable = await VideoEditEngine.canPreview(target)
        guard !Task.isCancelled else { return }
        duration = length
        if playable && player == nil {
            let newPlayer = AVPlayer(url: target)
            timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20),
                                                             queue: .main) { time in
                let seconds = time.seconds
                Task { @MainActor in
                    if !scrubbing && seconds.isFinite { playhead = seconds }
                }
            }
            player = newPlayer
        }
        loading = false
    }

    private func seek(to seconds: Double) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func tearDown() {
        player?.pause()
        if let token = timeObserver { player?.removeTimeObserver(token) }
        timeObserver = nil
        player = nil
        loading = true
    }
}
