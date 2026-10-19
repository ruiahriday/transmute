import AVFoundation
import CoreMedia
import SwiftUI

// MARK: - Edit settings

/// What the audio editor changes. A plain value so it can travel inside `JobOperation`.
struct AudioEdit: Equatable, Sendable {
    /// A stretch of the original whose sound is replaced by a 1 kHz tone.
    struct BleepRange: Equatable, Sendable {
        /// Seconds into the original file (not the trimmed result).
        var start: Double
        var end: Double
    }

    enum ChannelMode: String, CaseIterable, Identifiable, Sendable {
        case keep, mono, stereo, swapLeftRight

        var id: String { rawValue }

        var label: String {
            switch self {
            case .keep: "Keep"
            case .mono: "Mono"
            case .stereo: "Stereo"
            case .swapLeftRight: "Swap left and right"
            }
        }
    }

    /// Seconds into the original where the kept part starts.
    var trimStart: Double = 0
    /// Where the kept part ends; nil means the end of the file.
    var trimEnd: Double?
    /// EBU R128 loudness normalisation to -16 LUFS.
    var normalize = false
    /// Gain in decibels, -20…20; 0 leaves the level as it is.
    var volumeDB: Double = 0
    /// Fade lengths in seconds; 0 means no fade.
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var bleeps: [BleepRange] = []
    var channels: ChannelMode = .keep
    /// nil keeps MP3, M4A, WAV, FLAC, OGG, Opus and AIFF as they are and saves anything else as M4A.
    var outputFormat: OutputFormat?
}

// MARK: - Engine

/// Audio editing and waveforms. Editing goes through ffmpeg in one pass; it works on audio files
/// and on the sound track of a video. Runs off the main thread.
enum AudioEditEngine {
    /// Formats the editor writes.
    static let editableFormats: [OutputFormat] = [.mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff]

    static func outputFormat(for edit: AudioEdit, input: URL) -> OutputFormat {
        if let chosen = edit.outputFormat, editableFormats.contains(chosen) { return chosen }
        let ext = input.pathExtension.lowercased()
        let name = ["aif": "aiff", "oga": "ogg"][ext] ?? ext
        if let same = OutputFormat(rawValue: name), editableFormats.contains(same) { return same }
        return .m4a
    }

    /// What ffmpeg's banner says about a file's first sound track; nil fields weren't in it.
    struct SoundTrack: Equatable {
        var sampleRate: Int?
        var channels: Int?
    }

    /// The label of the filter graph's output pad.
    private static let outputLabel = "aout"

    // MARK: Edit

    /// Bleeps, trims, normalises, fades and remixes one file's sound into a new audio file.
    static func apply(_ edit: AudioEdit, to input: URL, options: ConversionOptions,
                      progress: @escaping ProgressHandler) async throws -> JobResult {
        let ffmpeg = try Tools.requireFFmpeg(for: "Editing audio")
        if let chosen = edit.outputFormat, !editableFormats.contains(chosen) {
            throw ConversionError("Edited audio can be saved as MP3, M4A, WAV, FLAC, OGG, Opus or AIFF, not \(chosen.label).")
        }
        guard let track = await soundTrack(of: input, ffmpeg: ffmpeg) else {
            throw ConversionError("\(input.lastPathComponent) has no sound to edit.")
        }
        let format = outputFormat(for: edit, input: input)
        let sourceLength = await MediaInfo.duration(of: input) // 0 when unknown
        let plan = try filterGraph(for: edit, sourceLength: sourceLength, track: track)

        let out = OutputPaths.destination(for: input, ext: format.fileExtension, suffix: "edited",
                                          folder: options.outputFolder)
        var args = ["-hide_banner", "-nostdin", "-y", "-progress", "pipe:1", "-nostats",
                    "-i", input.path,
                    "-filter_complex", plan.graph,
                    "-map", "[\(outputLabel)]", "-vn", "-map_chapters", "-1"]
        if options.stripMetadata { args += ["-map_metadata", "-1"] }
        args += encoderArgs(for: format)
        args.append(out.path)
        do {
            try await Shell.check(ffmpeg, args, onStdoutLine: progressParser(seconds: plan.seconds, progress))
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        progress(1)
        let message = plan.seconds > 0 ? "Length \(VideoEditEngine.timeLabel(plan.seconds, tenths: true))" : nil
        return JobResult(outputs: [out], message: message)
    }

    /// The -filter_complex graph for an edit, and how many seconds long the result will be (0 when unknown).
    ///
    /// Bleeps come first so their times are on the original timeline. Then the trim, loudness
    /// (before the gain, so the volume slider still does something, and before the fades, so
    /// loudnorm can't lift them back up), gain, fades and finally the channel layout.
    static func filterGraph(for edit: AudioEdit, sourceLength: Double, track: SoundTrack) throws -> (graph: String, seconds: Double) {
        // The kept range, checked against the real length when we know it.
        let start = edit.trimStart.isFinite ? max(0, edit.trimStart) : 0
        var stop = edit.trimEnd.flatMap { $0.isFinite ? $0 : nil }
        if let end = stop, sourceLength > 0, end >= sourceLength - 0.001 { stop = nil }
        if sourceLength > 0, start >= sourceLength - 0.01 {
            throw ConversionError("The start point is past the end of the audio.")
        }
        if let end = stop, end <= start + 0.01 {
            throw ConversionError("The end point has to come after the start point.")
        }
        let keptEnd = stop ?? sourceLength
        let seconds = keptEnd > start ? keptEnd - start : 0

        var chain: [String] = []
        if start > 0.0005 || stop != nil {
            var trim = "atrim=start=\(decimal(start))"
            if let end = stop { trim += ":end=\(decimal(end))" }
            chain += [trim, "asetpts=PTS-STARTPTS"]
        }
        let rate = track.sampleRate ?? 48000
        if edit.normalize {
            // Single-pass EBU R128. loudnorm works at 192 kHz internally, so resample back afterwards.
            chain += ["loudnorm=I=-16:TP=-1.5:LRA=11", "aresample=\(rate)"]
        }
        // A plain factor: the filter would read "-6dB" as minus (6 dB), which flips the phase.
        let gain = edit.volumeDB.isFinite ? min(20, max(-20, edit.volumeDB)) : 0
        if abs(gain) > 0.01 { chain.append("volume=\(decimal(pow(10, gain / 20)))") }

        var fadeIn = edit.fadeIn.isFinite ? max(0, edit.fadeIn) : 0
        if seconds > 0 { fadeIn = min(fadeIn, seconds) }
        if fadeIn > 0.001 { chain.append("afade=t=in:st=0:d=\(decimal(fadeIn))") }
        let fadeOut = edit.fadeOut.isFinite ? max(0, edit.fadeOut) : 0
        if fadeOut > 0.001 {
            guard seconds > 0 else {
                throw ConversionError("Couldn't read the length of the audio, which the fade-out needs.")
            }
            let length = min(fadeOut, seconds)
            chain.append("afade=t=out:st=\(decimal(seconds - length)):d=\(decimal(length))")
        }
        chain += channelFilters(edit.channels, inputChannels: track.channels)

        let tail = chain.isEmpty ? "anull" : chain.joined(separator: ",")
        let ranges = bleepRanges(edit.bleeps)
        var graph: [String] = []
        if ranges.isEmpty {
            graph.append("[0:a:0]\(tail)[\(outputLabel)]")
        } else {
            // Mute the ranges, and mix in a 1 kHz tone that only sounds inside them. Small frames keep
            // the switch-over within a few milliseconds; the quotes stop the commas in between()
            // from splitting the chain. amix ends with the file (duration=first) and doesn't halve
            // the level (normalize=0). The file's chain comes first in the graph so its channel
            // layout wins and the mono tone is the one that gets converted.
            let inside = ranges.map { "between(t,\(decimal($0.start)),\(decimal($0.end)))" }.joined(separator: "+")
            graph.append("[0:a:0]asetnsamples=n=256:p=0,volume=0:enable='\(inside)'[bleepmain]")
            graph.append("sine=frequency=1000:sample_rate=\(rate):samples_per_frame=256,volume=2,"
                + "volume=0:enable='not(\(inside))'[bleeptone]")
            graph.append("[bleepmain][bleeptone]amix=inputs=2:duration=first:dropout_transition=0:normalize=0,"
                + "\(tail)[\(outputLabel)]")
        }
        return (graph.joined(separator: ";"), seconds)
    }

    /// Valid bleeps, in order. Overlaps are fine: the enable expressions just add up.
    private static func bleepRanges(_ bleeps: [AudioEdit.BleepRange]) -> [AudioEdit.BleepRange] {
        bleeps
            .compactMap { range -> AudioEdit.BleepRange? in
                guard range.start.isFinite, range.end.isFinite else { return nil }
                let start = max(0, range.start)
                guard range.end > start + 0.001 else { return nil }
                return AudioEdit.BleepRange(start: start, end: range.end)
            }
            .sorted { $0.start < $1.start }
    }

    /// pan when the input's layout is known and simple; otherwise aformat, which uses ffmpeg's own
    /// up- and downmixing (so 5.1 folds down properly).
    static func channelFilters(_ mode: AudioEdit.ChannelMode, inputChannels: Int?) -> [String] {
        switch mode {
        case .keep:
            return []
        case .mono:
            if inputChannels == 1 { return [] }
            if inputChannels == 2 { return ["pan=mono|c0=0.5*c0+0.5*c1"] }
            return ["aformat=channel_layouts=mono"]
        case .stereo:
            if inputChannels == 1 { return ["pan=stereo|c0=c0|c1=c0"] } // same sound on both sides
            if inputChannels == 2 { return [] }
            return ["aformat=channel_layouts=stereo"]
        case .swapLeftRight:
            if inputChannels == 1 { return [] } // nothing to swap
            if inputChannels == 2 { return ["pan=stereo|c0=c1|c1=c0"] }
            return ["aformat=channel_layouts=stereo", "pan=stereo|c0=c1|c1=c0"]
        }
    }

    private static func encoderArgs(for format: OutputFormat) -> [String] {
        switch format {
        case .mp3: return ["-c:a", "libmp3lame", "-q:a", "2"]
        case .wav: return ["-c:a", "pcm_s16le"]
        case .flac: return ["-c:a", "flac"]
        case .ogg: return ["-c:a", "libvorbis", "-q:a", "5"]
        case .opus: return ["-c:a", "libopus", "-b:a", "128k"]
        case .aiff: return ["-c:a", "pcm_s16be"]
        default: return ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"] // M4A
        }
    }

    // MARK: Inspecting files

    /// The first sound track's sample rate and channel count, or nil when the file has no sound.
    static func soundTrack(of url: URL, ffmpeg: String) async -> SoundTrack? {
        guard let output = try? await Shell.run(ffmpeg, ["-hide_banner", "-nostdin", "-i", url.path]) else { return nil }
        return parseSoundTrack(output.stderr)
    }

    /// Reads "Audio: aac (LC), 44100 Hz, stereo, fltp" from ffmpeg's banner.
    static func parseSoundTrack(_ banner: String) -> SoundTrack? {
        guard let line = banner.split(whereSeparator: \.isNewline)
            .first(where: { $0.contains("Stream #") && $0.contains("Audio:") }),
            let audio = line.range(of: "Audio:")
        else { return nil }
        let fields = line[audio.upperBound...].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var track = SoundTrack()
        if let index = fields.firstIndex(where: { $0.hasSuffix(" Hz") }) {
            track.sampleRate = Int(fields[index].dropLast(3))
            if index + 1 < fields.count { track.channels = channelCount(fields[index + 1]) }
        }
        return track
    }

    /// "mono", "stereo", "2 channels", "5.1(side)" and friends as a number.
    private static func channelCount(_ layout: String) -> Int? {
        let name = layout.lowercased()
        switch name {
        case "mono": return 1
        case "stereo", "downmix": return 2
        default: break
        }
        if name.hasSuffix(" channels") || name.hasSuffix(" channel") {
            return Int(name.prefix { $0.isNumber })
        }
        let named: [String: Int] = [
            "2.1": 3, "3.0": 3, "3.0(back)": 3, "4.0": 4, "quad": 4, "quad(side)": 4, "3.1": 4,
            "5.0": 5, "5.0(side)": 5, "4.1": 5, "5.1": 6, "5.1(side)": 6, "6.0": 6, "6.0(front)": 6,
            "hexagonal": 6, "6.1": 7, "6.1(back)": 7, "6.1(front)": 7, "7.0": 7, "7.0(front)": 7,
            "7.1": 8, "7.1(wide)": 8, "7.1(wide-side)": 8, "octagonal": 8,
        ]
        return named[name]
    }

    /// Whether AVFoundation, and so the editor's player, can play the file's sound.
    static func canPlay(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true else { return false }
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        return !tracks.isEmpty
    }

    // MARK: Waveform

    /// Peak levels 0…1 in `buckets` equal slices of the whole file, for drawing.
    static func waveform(of url: URL, buckets: Int) async throws -> [Float] {
        let count = max(1, buckets)
        guard let ffmpeg = Tools.ffmpeg else {
            return try await appleWaveform(of: url, buckets: count)
        }
        // Mono 8 kHz 16-bit is plenty for a picture and small enough for long files (about 1 MB a minute).
        let raw = OutputPaths.temporaryURL(ext: "pcm")
        defer { try? FileManager.default.removeItem(at: raw) }
        do {
            try await Shell.check(ffmpeg, ["-hide_banner", "-nostdin", "-nostats", "-loglevel", "error",
                                           "-i", url.path, "-map", "0:a:0", "-vn",
                                           "-f", "s16le", "-ac", "1", "-ar", "8000", "-"],
                                  stdoutFile: raw)
        } catch {
            // ffmpeg's own message for a file without sound is a confusing "-map" complaint.
            if !(error is CancellationError), await soundTrack(of: url, ffmpeg: ffmpeg) == nil {
                throw ConversionError("\(url.lastPathComponent) has no sound.")
            }
            throw error
        }
        let data = try Data(contentsOf: raw, options: .mappedIfSafe)
        return peaks(ofPCM16: data, buckets: count)
    }

    /// The same through AVFoundation, for when ffmpeg isn't installed.
    private static func appleWaveform(of url: URL, buckets: Int) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError("\(url.lastPathComponent) has no sound macOS can read.")
        }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 8000,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ConversionError("macOS can't decode \(url.lastPathComponent).") }
        reader.add(output)
        guard reader.startReading() else {
            throw ConversionError(reader.error?.localizedDescription ?? "macOS can't decode \(url.lastPathComponent).")
        }
        var pcm = Data()
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            let offset = pcm.count
            pcm.count += length
            let status = pcm.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) -> OSStatus in
                guard let base = bytes.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base + offset)
            }
            guard status == 0 else { throw ConversionError("Couldn't read the sound in \(url.lastPathComponent).") }
        }
        guard reader.status == .completed else {
            throw ConversionError(reader.error?.localizedDescription ?? "Couldn't read the sound in \(url.lastPathComponent).")
        }
        return peaks(ofPCM16: pcm, buckets: buckets)
    }

    /// Peak level 0…1 of each of `buckets` equal slices of 16-bit little-endian mono samples.
    static func peaks(ofPCM16 data: Data, buckets: Int) -> [Float] {
        let sampleCount = data.count / 2
        guard sampleCount > 0, buckets > 0 else { return [] }
        var levels = [Float](repeating: 0, count: buckets)
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for bucket in 0..<buckets {
                // Every bucket gets at least one sample, even when there are more buckets than samples.
                let from = min(sampleCount - 1, bucket * sampleCount / buckets)
                let to = min(sampleCount, max(from + 1, (bucket + 1) * sampleCount / buckets))
                var peak: Int32 = 0
                var index = from
                while index < to {
                    let low = UInt16(bytes[2 * index])
                    let high = UInt16(bytes[2 * index + 1])
                    let sample = Int32(Int16(bitPattern: low | (high << 8)))
                    peak = max(peak, abs(sample))
                    index += 1
                }
                levels[bucket] = Float(peak) / 32768
            }
        }
        return levels
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

    /// A number for a filter argument.
    private static func decimal(_ value: Double) -> String { String(format: "%.4f", value) }
}

// MARK: - Editor window

/// One row of the editor's bleep list. The id keeps rows stable while their times are edited.
private struct BleepItem: Identifiable {
    let id = UUID()
    var start: Double
    var end: Double
}

/// Trim, bleeps, loudness, fades and channels for one audio file (or a video's sound), with a
/// waveform and playback when AVFoundation can play the file. Nothing is encoded here: Save Copy
/// hands the settings to `onSave`.
@MainActor
struct AudioEditorView: View {
    let url: URL
    let onSave: (AudioEdit) -> Void
    let onCancel: () -> Void

    @State private var edit = AudioEdit()
    @State private var bleeps: [BleepItem] = []
    @State private var peaks: [Float] = []
    @State private var waveformLoading = true
    @State private var waveformError: String? = nil
    @State private var player: AVPlayer? = nil
    @State private var timeObserver: Any? = nil
    @State private var loading = true
    @State private var isPlaying = false
    @State private var duration: Double = 0
    @State private var playhead: Double = 0
    @State private var scrubbing = false

    /// Bars in the waveform, about one per point at the window's usual width.
    private static let waveformBuckets = 700
    private static let bleepLength = 0.5

    init(url: URL, onSave: @escaping (AudioEdit) -> Void, onCancel: @escaping () -> Void) {
        self.url = url
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(url.lastPathComponent)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            waveform
                .frame(maxWidth: .infinity, minHeight: 110, idealHeight: 140, maxHeight: 180)
            transport
            trimRow
            Divider()
            bleepList
            Divider()
            settings
            Divider()
            footer
        }
        .padding(16)
        .frame(minWidth: 640, idealWidth: 740, minHeight: 620, idealHeight: 700)
        .task { await prepare() }
        .task { await loadWaveform() }
        .onDisappear { tearDown() }
    }

    // MARK: Waveform

    /// Peaks across the whole file, the kept part highlighted, bleeps in red and the playhead.
    /// Click or drag to move the playhead.
    private var waveform: some View {
        GeometryReader { geo in
            let viewWidth = max(geo.size.width, 1)
            let total = timelineLength
            let levels = peaks
            let loudest = max(levels.max() ?? 0, 0.01)
            // The bars cover the file's length, which can be less than the timeline when an end is typed past it.
            let barsSpan = duration > 0 ? CGFloat(min(1, duration / total)) : 1
            let keptFrom = fraction(edit.trimStart, of: total)
            let keptTo = max(keptFrom, fraction(edit.trimEnd ?? total, of: total))
            let marks = bleeps.map { fraction(min($0.start, $0.end), of: total)...fraction(max($0.start, $0.end), of: total) }
            let head = fraction(playhead, of: total)
            Canvas { context, size in
                let w = size.width, h = size.height
                guard w > 0, h > 0 else { return }
                let keptRect = CGRect(x: keptFrom * w, y: 0, width: max(1, (keptTo - keptFrom) * w), height: h)
                context.fill(Path(keptRect), with: .color(Color.accentColor.opacity(0.14)))
                if !levels.isEmpty {
                    let step = w * barsSpan / CGFloat(levels.count)
                    let barWidth = max(1, step * 0.7)
                    var inside = Path()
                    var outside = Path()
                    for (index, level) in levels.enumerated() {
                        let x = CGFloat(index) * step
                        let barHeight = max(1, CGFloat(min(1, level / loudest)) * (h - 8))
                        let bar = CGRect(x: x, y: (h - barHeight) / 2, width: barWidth, height: barHeight)
                        let centre = (x + step / 2) / w
                        if centre >= keptFrom && centre <= keptTo {
                            inside.addRect(bar)
                        } else {
                            outside.addRect(bar)
                        }
                    }
                    context.fill(outside, with: .color(Color.secondary.opacity(0.45)))
                    context.fill(inside, with: .color(Color.accentColor))
                }
                for mark in marks {
                    let rect = CGRect(x: mark.lowerBound * w, y: 0,
                                      width: max(2, (mark.upperBound - mark.lowerBound) * w), height: h)
                    context.fill(Path(rect), with: .color(Color.red.opacity(0.35)))
                }
                for edge in [keptFrom, keptTo] {
                    context.fill(Path(CGRect(x: edge * w - 1, y: 0, width: 2, height: h)), with: .color(Color.accentColor))
                }
                context.fill(Path(CGRect(x: head * w - 1, y: 0, width: 2, height: h)), with: .color(Color.primary))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in scrub(to: Double(value.location.x / viewWidth) * total) }
                    .onEnded { value in endScrub(at: Double(value.location.x / viewWidth) * total) }
            )
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { waveformOverlay.allowsHitTesting(false) }
        .help("Click or drag to move the playhead")
    }

    @ViewBuilder
    private var waveformOverlay: some View {
        if waveformLoading {
            ProgressView()
                .controlSize(.small)
        } else if let waveformError {
            Text("No waveform: \(waveformError)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(8)
        }
    }

    // MARK: Playback and trim

    private var transport: some View {
        HStack(spacing: 10) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .disabled(player == nil)
            .help(isPlaying ? "Pause" : "Play")
            Text("\(clock(playhead)) / \(lengthText)")
                .monospacedDigit()
            if player == nil && !loading {
                Text("Playback isn't available for this format. Click the waveform to move the playhead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                addBleep()
            } label: {
                Label("Add Bleep at Playhead", systemImage: "speaker.slash")
            }
            .help("Replaces \(VideoEditEngine.compact(Self.bleepLength)) s from the playhead with a tone; adjust the times below")
        }
    }

    private var trimRow: some View {
        HStack(spacing: 8) {
            Button("Set Start") { setStart() }
            TextField("Start", value: $edit.trimStart, format: secondsFormat)
                .frame(width: 70)
            Text("to")
            TextField("End", value: endBinding, format: secondsFormat)
                .frame(width: 70)
            Button("Set End") { setEnd() }
            Text("seconds")
                .foregroundStyle(.secondary)
            Spacer()
            if edit.trimStart > 0 || edit.trimEnd != nil {
                Button("Keep All") {
                    edit.trimStart = 0
                    edit.trimEnd = nil
                }
            }
        }
    }

    /// The end as a plain number: the file's length stands for "to the end".
    private var endBinding: Binding<Double> {
        Binding(
            get: { edit.trimEnd ?? duration },
            set: { newValue in
                edit.trimEnd = duration > 0 && newValue >= duration - 0.01 ? nil : newValue
            }
        )
    }

    // MARK: Bleeps

    private var bleepList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Bleeps")
                    .font(.subheadline.weight(.semibold))
                Text(bleeps.isEmpty
                     ? "None yet. A bleep replaces the sound with a 1 kHz tone."
                     : "Times are in the original file, in seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if !bleeps.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach($bleeps) { $item in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color.red.opacity(0.7))
                                    .frame(width: 8, height: 8)
                                TextField("From", value: $item.start, format: secondsFormat)
                                    .frame(width: 70)
                                Text("to")
                                TextField("To", value: $item.end, format: secondsFormat)
                                    .frame(width: 70)
                                Button {
                                    seek(to: item.start)
                                } label: {
                                    Image(systemName: "arrow.right.to.line")
                                }
                                .buttonStyle(.borderless)
                                .help("Move the playhead to this bleep")
                                Button(role: .destructive) {
                                    removeBleep(item.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove this bleep")
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .frame(maxHeight: 96)
            }
        }
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Loudness") {
                Toggle("Normalize to −16 LUFS", isOn: $edit.normalize)
                    .help("EBU R128 loudness normalisation, the level podcasts and streaming services use")
            }
            row("Volume") {
                Slider(value: $edit.volumeDB, in: -20...20, step: 0.5)
                    .frame(width: 200)
                Text(String(format: "%+.1f dB", edit.volumeDB))
                    .monospacedDigit()
                    .frame(width: 64, alignment: .leading)
                if edit.volumeDB != 0 {
                    Button("Reset") { edit.volumeDB = 0 }
                }
            }
            row("Fade in") {
                Slider(value: $edit.fadeIn, in: 0...10, step: 0.1)
                    .frame(width: 200)
                Text(fadeLabel(edit.fadeIn))
                    .monospacedDigit()
            }
            row("Fade out") {
                Slider(value: $edit.fadeOut, in: 0...10, step: 0.1)
                    .frame(width: 200)
                Text(fadeLabel(edit.fadeOut))
                    .monospacedDigit()
            }
            row("Channels") {
                Picker("Channels", selection: $edit.channels) {
                    ForEach(AudioEdit.ChannelMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }
            row("Save as") {
                Picker("Save as", selection: $edit.outputFormat) {
                    Text(keepLabel).tag(Optional<OutputFormat>.none)
                    Text("MP3").tag(Optional(OutputFormat.mp3))
                    Text("M4A").tag(Optional(OutputFormat.m4a))
                    Text("WAV").tag(Optional(OutputFormat.wav))
                    Text("FLAC").tag(Optional(OutputFormat.flac))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 380)
            }
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 70, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
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
        if duration > 0 && start >= duration { return "The start is past the end of the audio." }
        if !(end > start + 0.05) { return "The end has to come after the start." }
        if bleeps.contains(where: { !($0.start >= 0 && $0.end > $0.start + 0.01) }) {
            return "Each bleep has to end after it starts."
        }
        return nil
    }

    private var resultText: String {
        let format = AudioEditEngine.outputFormat(for: edit, input: url).label
        guard let end = edit.trimEnd ?? (duration > 0 ? duration : nil) else {
            return "Result: \(format), from \(clock(edit.trimStart)) to the end"
        }
        return "Result: \(format), \(clock(end - edit.trimStart)) long"
    }

    private var keepLabel: String {
        let kept = AudioEditEngine.outputFormat(for: AudioEdit(), input: url)
        return url.pathExtension.lowercased() == kept.fileExtension ? "Keep" : "Keep (\(kept.label))"
    }

    private var lengthText: String {
        duration > 0 ? clock(duration) : "length unknown"
    }

    private var secondsFormat: FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(0...2))
    }

    private var timelineLength: Double {
        max(duration, edit.trimEnd ?? 0, playhead, bleeps.map(\.end).max() ?? 0, 1)
    }

    private func fraction(_ seconds: Double, of total: Double) -> CGFloat {
        guard total > 0, seconds.isFinite else { return 0 }
        return CGFloat(min(max(seconds / total, 0), 1))
    }

    private func clock(_ seconds: Double) -> String {
        VideoEditEngine.timeLabel(seconds, tenths: true)
    }

    private func fadeLabel(_ seconds: Double) -> String {
        seconds < 0.05 ? "Off" : String(format: "%.1f s", seconds)
    }

    // MARK: Actions

    private func setStart() {
        edit.trimStart = playhead
        if let end = edit.trimEnd, end <= playhead { edit.trimEnd = nil }
    }

    private func setEnd() {
        edit.trimEnd = duration > 0 && playhead >= duration - 0.01 ? nil : playhead
        if edit.trimStart >= playhead { edit.trimStart = 0 }
    }

    private func addBleep() {
        var start = playhead
        var end = start + Self.bleepLength
        if duration > 0 && end > duration {
            // Near the end: keep the full length where there's room, ending at the end of the file.
            end = duration
            start = max(0, min(start, duration - Self.bleepLength))
        }
        bleeps.append(BleepItem(start: start, end: end))
        bleeps.sort { $0.start < $1.start }
    }

    private func removeBleep(_ id: UUID) {
        bleeps.removeAll { $0.id == id }
    }

    private func finishedEdit() -> AudioEdit {
        var result = edit
        result.trimStart = max(0, edit.trimStart)
        if let end = result.trimEnd, duration > 0, end >= duration - 0.01 { result.trimEnd = nil }
        result.volumeDB = min(20, max(-20, edit.volumeDB))
        result.fadeIn = max(0, edit.fadeIn)
        result.fadeOut = max(0, edit.fadeOut)
        result.bleeps = bleeps
            .map { AudioEdit.BleepRange(start: $0.start, end: $0.end) }
            .sorted { $0.start < $1.start }
        return result
    }

    // MARK: Player

    private func prepare() async {
        let target = url
        let length = await MediaInfo.duration(of: target)
        let playable = await AudioEditEngine.canPlay(target)
        guard !Task.isCancelled else { return }
        duration = length
        if playable && player == nil {
            let newPlayer = AVPlayer(url: target)
            // Also called when playback starts or stops, so it keeps the play button honest at the end.
            timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30),
                                                             queue: .main) { time in
                let seconds = time.seconds
                Task { @MainActor in
                    if !scrubbing && seconds.isFinite { playhead = seconds }
                    isPlaying = (player?.rate ?? 0) != 0
                }
            }
            player = newPlayer
        }
        loading = false
    }

    private func loadWaveform() async {
        do {
            let levels = try await AudioEditEngine.waveform(of: url, buckets: Self.waveformBuckets)
            guard !Task.isCancelled else { return }
            peaks = levels
            waveformError = nil
        } catch {
            guard !Task.isCancelled else { return }
            waveformError = error.localizedDescription
        }
        waveformLoading = false
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            // From the very end, start again at the beginning of the kept part.
            if duration > 0 && playhead >= duration - 0.05 { seek(to: edit.trimStart) }
            player.play()
            isPlaying = true
        }
    }

    private func scrub(to seconds: Double) {
        scrubbing = true
        seek(to: seconds)
    }

    private func endScrub(at seconds: Double) {
        seek(to: seconds)
        scrubbing = false
    }

    private func seek(to seconds: Double) {
        let limit = duration > 0 ? duration : timelineLength
        let clamped = seconds.isFinite ? min(max(seconds, 0), limit) : 0
        playhead = clamped
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func tearDown() {
        player?.pause()
        if let token = timeObserver { player?.removeTimeObserver(token) }
        timeObserver = nil
        player = nil
        isPlaying = false
        loading = true
    }
}
