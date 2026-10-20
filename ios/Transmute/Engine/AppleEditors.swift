import AVFoundation
import Foundation

/// The video editor's trims, speed, crop, turns, flip, mute, volume and splitting, and joining
/// videos, done with AVFoundation compositions. The Mac app does the same edits with ffmpeg.
enum AppleVideoEditor {
    static func apply(_ edit: VideoEdit, to input: URL, options: ConversionOptions,
                      progress: @escaping ProgressHandler) async throws -> JobResult {
        if let chosen = edit.outputFormat, !VideoEditEngine.editableFormats.contains(chosen) {
            throw ConversionError("On iPhone and iPad, edited videos can be saved as MP4 or MOV, not \(chosen.label).")
        }
        let format = VideoEditEngine.outputFormat(for: edit, input: input)
        let asset = AVURLAsset(url: input)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionError("\(input.lastPathComponent) can't be opened on iPhone and iPad.")
        }
        var audioTrack: AVAssetTrack?
        if !edit.mute { audioTrack = try await asset.loadTracks(withMediaType: .audio).first }
        let sourceLength = try await asset.load(.duration).seconds
        guard sourceLength.isFinite, sourceLength > 0 else {
            throw ConversionError("Couldn't read the length of \(input.lastPathComponent).")
        }
        let speed = edit.speed.isFinite ? min(4, max(0.25, edit.speed)) : 1

        let start = edit.trimStart.isFinite ? max(0, edit.trimStart) : 0
        var stop = edit.trimEnd.flatMap { $0.isFinite ? $0 : nil } ?? sourceLength
        if stop >= sourceLength - 0.001 { stop = sourceLength }
        if start >= sourceLength - 0.01 { throw ConversionError("The start point is past the end of the video.") }
        if stop <= start + 0.01 { throw ConversionError("The end point has to come after the start point.") }

        var segments: [(start: Double, end: Double, suffix: String)] = [(start, stop, "edited")]
        if let split = edit.splitAt {
            guard split.isFinite, split > start + 0.05, split < stop - 0.05 else {
                throw ConversionError("The split point has to fall inside the part you're keeping.")
            }
            segments = [(start, split, "part 1"), (split, stop, "part 2")]
        }

        let natural = try await videoTrack.load(.naturalSize)
        let preferred = try await videoTrack.load(.preferredTransform)
        let fps = try await videoTrack.load(.nominalFrameRate)
        let (renderSize, transform) = geometry(natural: natural, preferred: preferred, edit: edit)
        let volume = edit.volume.isFinite ? Float(max(0, edit.volume)) : 1

        let total = segments.reduce(0) { $0 + ($1.end - $1.start) }
        var done = 0.0
        var outputs: [URL] = []
        do {
            for segment in segments {
                let composition = AVMutableComposition()
                let range = CMTimeRange(start: CMTime(seconds: segment.start, preferredTimescale: 600),
                                        end: CMTime(seconds: segment.end, preferredTimescale: 600))
                guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw ConversionError("Couldn't set up the video editor.")
                }
                try video.insertTimeRange(range, of: videoTrack, at: .zero)
                var audio: AVMutableCompositionTrack?
                if let audioTrack, let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try track.insertTimeRange(range, of: audioTrack, at: .zero)
                    audio = track
                }
                if abs(speed - 1) > 0.001 {
                    let whole = CMTimeRange(start: .zero, duration: range.duration)
                    let scaled = CMTimeMultiplyByFloat64(range.duration, multiplier: 1 / speed)
                    video.scaleTimeRange(whole, toDuration: scaled)
                    audio?.scaleTimeRange(whole, toDuration: scaled)
                }

                let videoComposition = AVMutableVideoComposition()
                videoComposition.renderSize = renderSize
                videoComposition.frameDuration = CMTime(value: 1, timescale: fps > 1 ? CMTimeScale(min(60, fps.rounded())) : 30)
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
                layer.setTransform(transform, at: .zero)
                instruction.layerInstructions = [layer]
                videoComposition.instructions = [instruction]

                var mix: AVMutableAudioMix?
                if let audio, abs(volume - 1) > 0.001 {
                    let parameters = AVMutableAudioMixInputParameters(track: audio)
                    parameters.setVolume(min(1, volume), at: .zero)
                    let audioMix = AVMutableAudioMix()
                    audioMix.inputParameters = [parameters]
                    mix = audioMix
                }

                let out = OutputPaths.destination(for: input, ext: format.fileExtension, suffix: segment.suffix,
                                                  folder: options.outputFolder)
                outputs.append(out)
                let part = segment.end - segment.start
                let before = done
                try await export(composition, to: out, type: format == .mov ? .mov : .mp4,
                                 videoComposition: videoComposition, audioMix: mix,
                                 stripMetadata: options.stripMetadata) { fraction in
                    progress(min(1, (before + fraction * part) / total))
                }
                done += part
            }
        } catch {
            for url in outputs { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        progress(1)

        let lengths = segments.map { ($0.end - $0.start) / speed }
        var message = lengths.count == 2
            ? "Parts: \(VideoEditEngine.timeLabel(lengths[0], tenths: true)) and \(VideoEditEngine.timeLabel(lengths[1], tenths: true))"
            : "Length \(VideoEditEngine.timeLabel(lengths[0], tenths: true))"
        if volume > 1.001 && audioTrack != nil { message += ". Volume above 100% isn't available on iPhone and iPad yet, so it was kept at 100%" }
        return JobResult(outputs: outputs, message: message)
    }

    /// Plays the videos one after another in one MP4, each fitted into the first video's frame.
    static func join(_ urls: [URL], options: ConversionOptions, progress: @escaping ProgressHandler) async throws -> URL {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ConversionError("Couldn't set up the video joiner.")
        }
        var audio: AVMutableCompositionTrack?
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
        var renderSize: CGSize?
        var cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw ConversionError("\(url.lastPathComponent) can't be opened on iPhone and iPad.")
            }
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            try video.insertTimeRange(range, of: track, at: cursor)
            if let sound = try await asset.loadTracks(withMediaType: .audio).first {
                if audio == nil {
                    audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                try audio?.insertTimeRange(range, of: sound, at: cursor)
            }
            let natural = try await track.load(.naturalSize)
            let preferred = try await track.load(.preferredTransform)
            let box = CGRect(origin: .zero, size: natural).applying(preferred)
            let upright = preferred.concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY))
            let frame = renderSize ?? CGSize(width: floor(box.width / 2) * 2, height: floor(box.height / 2) * 2)
            renderSize = frame
            let scale = min(frame.width / box.width, frame.height / box.height)
            let fitted = upright
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: (frame.width - box.width * scale) / 2,
                                                 y: (frame.height - box.height * scale) / 2))
            layer.setTransform(fitted, at: cursor)
            cursor = cursor + duration
        }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize ?? CGSize(width: 1920, height: 1080)
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        instruction.layerInstructions = [layer]
        videoComposition.instructions = [instruction]

        let dir = options.outputFolder ?? urls[0].deletingLastPathComponent()
        let out = OutputPaths.unique(in: dir, base: "Joined", ext: "mp4")
        try await export(composition, to: out, type: .mp4, videoComposition: videoComposition, audioMix: nil,
                         stripMetadata: options.stripMetadata, progress: progress)
        progress(1)
        return out
    }

    /// The frame size and the transform that turns the video upright, crops it to the chosen shape
    /// (centred), turns it clockwise and flips it, in that order, as the Mac editor does.
    static func geometry(natural: CGSize, preferred: CGAffineTransform, edit: VideoEdit) -> (CGSize, CGAffineTransform) {
        let box = CGRect(origin: .zero, size: natural).applying(preferred)
        var transform = preferred.concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY))
        var width = box.width, height = box.height
        if let ratio = edit.cropAspect.ratio {
            let target = CGFloat(ratio.width) / CGFloat(ratio.height)
            let cropWidth = width / height > target ? height * target : width
            let cropHeight = width / height > target ? height : width / target
            transform = transform.concatenating(CGAffineTransform(translationX: -(width - cropWidth) / 2,
                                                                  y: -(height - cropHeight) / 2))
            width = cropWidth
            height = cropHeight
        }
        let turns = ((edit.quarterTurns % 4) + 4) % 4
        for _ in 0..<turns {
            // A quarter turn clockwise with y pointing down: (x, y) → (height − y, x).
            transform = transform.concatenating(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0))
            swap(&width, &height)
        }
        if edit.flipHorizontal {
            transform = transform.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0))
        }
        // Video encoders want even dimensions.
        let size = CGSize(width: max(2, floor(width / 2) * 2), height: max(2, floor(height / 2) * 2))
        return (size, transform)
    }

    private static func export(_ asset: AVAsset, to out: URL, type: AVFileType, videoComposition: AVVideoComposition?,
                               audioMix: AVAudioMix?, stripMetadata: Bool, progress: @escaping ProgressHandler) async throws {
        guard await AVAssetExportSession.canExport(asset, preset: AVAssetExportPresetHighestQuality, as: type),
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ConversionError("This video can't be saved as \(type == .mov ? "MOV" : "MP4") here.")
        }
        try? FileManager.default.removeItem(at: out)
        session.videoComposition = videoComposition
        session.audioMix = audioMix
        session.audioTimePitchAlgorithm = .spectral // speed changes keep the pitch, like ffmpeg's atempo
        session.shouldOptimizeForNetworkUse = true
        if stripMetadata { session.metadataItemFilter = .forSharing() }
        let failure = await withTaskCancellationHandler {
            await session.runExport(to: out, as: type, progress: progress)
        } onCancel: {
            session.cancelExport()
        }
        try Task.checkCancellation()
        if let failure {
            try? FileManager.default.removeItem(at: out)
            throw ConversionError(failure.localizedDescription)
        }
    }
}

/// The audio editor's trim, bleeps, loudness, volume, fades and channel changes, worked out on the
/// samples themselves. The Mac app runs the same edits through ffmpeg filters.
enum AppleAudioEditor {
    static func apply(_ edit: AudioEdit, to input: URL, options: ConversionOptions,
                      progress: @escaping ProgressHandler) async throws -> JobResult {
        if let chosen = edit.outputFormat, !AudioEditEngine.editableFormats.contains(chosen) {
            throw ConversionError("On iPhone and iPad, edited sound can be saved as M4A, WAV, FLAC or AIFF, not \(chosen.label).")
        }
        let format = AudioEditEngine.outputFormat(for: edit, input: input)
        let source = try await AppleAudio.open(input)
        let length = source.duration

        let start = edit.trimStart.isFinite ? max(0, edit.trimStart) : 0
        var stop = edit.trimEnd.flatMap { $0.isFinite ? $0 : nil }
        if let end = stop, length > 0, end >= length - 0.001 { stop = nil }
        if length > 0, start >= length - 0.01 { throw ConversionError("The start point is past the end of the audio.") }
        if let end = stop, end <= start + 0.01 { throw ConversionError("The end point has to come after the start point.") }
        let keptEnd = stop ?? length
        let seconds = keptEnd > start ? keptEnd - start : 0

        let rate = source.sampleRate
        var range: CMTimeRange?
        if start > 0.0005 || stop != nil {
            let scale = CMTimeScale(max(600, min(Double(Int32.max), rate)))
            let begin = CMTime(seconds: start, preferredTimescale: scale)
            if let stop {
                range = CMTimeRange(start: begin, end: CMTime(seconds: stop, preferredTimescale: scale))
            } else {
                range = CMTimeRange(start: begin, duration: .positiveInfinity)
            }
        }

        let bleeps = edit.bleeps.filter { $0.start.isFinite && $0.end.isFinite && $0.end > max(0, $0.start) + 0.001 }
        var fadeIn = edit.fadeIn.isFinite ? max(0, edit.fadeIn) : 0
        if seconds > 0 { fadeIn = min(fadeIn, seconds) }
        var fadeOut = edit.fadeOut.isFinite ? max(0, edit.fadeOut) : 0
        if fadeOut > 0.001 {
            guard seconds > 0 else { throw ConversionError("Couldn't read the length of the audio, which the fade-out needs.") }
            fadeOut = min(fadeOut, seconds)
        }
        let decibels = edit.volumeDB.isFinite ? min(20, max(-20, edit.volumeDB)) : 0
        var gain = Float(pow(10, decibels / 20))

        let inputChannels = source.channels
        let outputChannels: Int = switch edit.channels {
        case .keep: inputChannels
        case .mono: 1
        case .stereo, .swapLeftRight: 2
        }

        func bleeped(_ time: Double) -> Bool { bleeps.contains { time >= $0.start && time < $0.end } }
        let total = seconds * rate

        // Loudness: bring the average level (RMS) to -16 dB, like loudnorm's -16 LUFS target,
        // with a soft limiter keeping the peaks under -1.5 dB.
        var limit = false
        if edit.normalize {
            var sum = 0.0
            var count = 0
            var frame = 0
            try AppleAudio.readPCM(source, range: range) { samples in
                let frames = samples.count / inputChannels
                for f in 0..<frames {
                    let time = start + Double(frame + f) / rate
                    for c in 0..<inputChannels {
                        let value = bleeped(time) ? 0.25 * sin(2 * .pi * 1000 * time) : Double(samples[f * inputChannels + c])
                        sum += value * value
                    }
                }
                count += samples.count
                frame += frames
                if total > 0 { progress(min(0.5, Double(frame) / total / 2)) }
            }
            let rms = count > 0 ? sqrt(sum / Double(count)) : 0
            if rms > 1e-6 {
                gain *= Float(pow(10, -16.0 / 20) / rms)
                limit = true
            }
        }
        if gain > 1 { limit = true }
        let ceiling: Float = 0.84 // -1.5 dB

        let out = OutputPaths.destination(for: input, ext: format.fileExtension, suffix: "edited", folder: options.outputFolder)
        do {
            let writer = try AppleAudio.Writer(out, format: format, sampleRate: rate, channels: outputChannels)
            var frame = 0
            let base = edit.normalize ? 0.5 : 0
            try AppleAudio.readPCM(source, range: range) { samples in
                let frames = samples.count / inputChannels
                var result = [Float](repeating: 0, count: frames * outputChannels)
                for f in 0..<frames {
                    let elapsed = Double(frame + f) / rate
                    let time = start + elapsed
                    var left = samples[f * inputChannels]
                    var right = inputChannels > 1 ? samples[f * inputChannels + 1] : left
                    if bleeped(time) {
                        let tone = Float(0.25 * sin(2 * .pi * 1000 * time))
                        left = tone
                        right = tone
                    }
                    var level = gain
                    if fadeIn > 0.001 && elapsed < fadeIn { level *= Float(elapsed / fadeIn) }
                    if fadeOut > 0.001 && elapsed > seconds - fadeOut { level *= Float(max(0, (seconds - elapsed) / fadeOut)) }
                    left *= level
                    right *= level
                    if limit {
                        left = soften(left, ceiling)
                        right = soften(right, ceiling)
                    }
                    switch (edit.channels, outputChannels) {
                    case (.mono, _): result[f] = (left + right) / 2
                    case (.swapLeftRight, _):
                        result[f * 2] = right
                        result[f * 2 + 1] = left
                    case (_, 1): result[f] = left
                    default:
                        result[f * 2] = left
                        result[f * 2 + 1] = right
                    }
                }
                frame += frames
                try writer.write(result)
                if total > 0 { progress(min(1, base + (1 - base) * Double(frame) / total)) }
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        progress(1)
        let message = seconds > 0 ? "Length \(VideoEditEngine.timeLabel(seconds, tenths: true))" : nil
        return JobResult(outputs: [out], message: message)
    }

    /// Leaves quiet samples alone and bends loud ones smoothly towards the ceiling.
    private static func soften(_ value: Float, _ ceiling: Float) -> Float {
        let magnitude = abs(value)
        let knee = ceiling * 0.9
        guard magnitude > knee else { return value }
        let room = ceiling - knee
        let bent = knee + room * Float(tanh(Double((magnitude - knee) / room)))
        return value < 0 ? -bent : bent
    }
}
