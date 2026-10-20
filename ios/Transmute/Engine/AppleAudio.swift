import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Audio conversion without command-line tools: AVAssetReader decodes any sound AVFoundation can
/// play (including the sound of a video) to 32-bit float samples, and AVAudioFile encodes them.
/// The Mac app uses `afconvert` and ffmpeg for this.
enum AppleAudio {
    struct Source {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let sampleRate: Double
        let channels: Int
        /// Seconds; 0 when unknown.
        let duration: Double
    }

    static func open(_ url: URL) async throws -> Source {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError("\(url.lastPathComponent) has no sound.")
        }
        var sampleRate = 44_100.0
        var channels = 2
        if let description = try await track.load(.formatDescriptions).first,
           let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            if basic.mSampleRate > 0 { sampleRate = basic.mSampleRate }
            if basic.mChannelsPerFrame > 0 { channels = Int(basic.mChannelsPerFrame) }
        }
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        return Source(asset: asset, track: track, sampleRate: sampleRate, channels: min(channels, 2),
                      duration: duration.isFinite ? duration : 0)
    }

    /// Calls `body` with blocks of interleaved samples (`source.channels` per frame) until the end
    /// of the sound or of `range`.
    static func readPCM(_ source: Source, range: CMTimeRange? = nil,
                        _ body: (inout [Float]) throws -> Void) throws {
        let reader = try AVAssetReader(asset: source.asset)
        if let range { reader.timeRange = range }
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: source.sampleRate,
            AVNumberOfChannelsKey: source.channels,
        ]
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = source.channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        let output = AVAssetReaderTrackOutput(track: source.track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ConversionError("This sound can't be decoded.") }
        reader.add(output)
        guard reader.startReading() else {
            throw ConversionError(reader.error?.localizedDescription ?? "This sound can't be decoded.")
        }
        defer { reader.cancelReading() }
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length >= 4 else { continue }
            var floats = [Float](repeating: 0, count: length / 4)
            let status = floats.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw ConversionError("This sound can't be decoded.") }
            try body(&floats)
        }
        if reader.status == .failed {
            throw ConversionError(reader.error?.localizedDescription ?? "Decoding the sound failed.")
        }
    }

    /// Writes interleaved float samples to a file in `format`.
    final class Writer {
        private let file: AVAudioFile
        private let format: AVAudioFormat
        let channels: Int

        init(_ url: URL, format outputFormat: OutputFormat, sampleRate: Double, channels: Int, bitrate: Int? = nil) throws {
            self.channels = channels
            var rate = sampleRate
            var settings: [String: Any] = [AVNumberOfChannelsKey: channels]
            switch outputFormat {
            case .wav:
                settings[AVFormatIDKey] = kAudioFormatLinearPCM
                settings[AVLinearPCMBitDepthKey] = 16
                settings[AVLinearPCMIsFloatKey] = false
                settings[AVLinearPCMIsBigEndianKey] = false
            case .aiff:
                settings[AVFormatIDKey] = kAudioFormatLinearPCM
                settings[AVLinearPCMBitDepthKey] = 16
                settings[AVLinearPCMIsFloatKey] = false
                settings[AVLinearPCMIsBigEndianKey] = true
            case .flac:
                settings[AVFormatIDKey] = kAudioFormatFLAC
            case .m4a:
                settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
                // AAC tops out at 48 kHz.
                if rate > 48_000 { rate = 48_000 }
                settings[AVEncoderBitRateKey] = min(320_000, max(32_000, bitrate ?? 192_000))
            default:
                throw ConversionError("Sound can't be saved as \(outputFormat.label) on iPhone and iPad.")
            }
            guard rate == sampleRate else {
                throw ConversionError("Sound above 48 kHz can't be saved as M4A here yet.")
            }
            settings[AVSampleRateKey] = rate
            try? FileManager.default.removeItem(at: url)
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                             channels: AVAudioChannelCount(channels), interleaved: true) else {
                throw ConversionError("Couldn't set up the audio encoder.")
            }
            self.format = format
        }

        func write(_ samples: [Float]) throws {
            let frames = samples.count / channels
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let data = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = AVAudioFrameCount(frames)
            samples.withUnsafeBufferPointer { data.update(from: $0.baseAddress!, count: frames * channels) }
            try file.write(from: buffer)
        }
    }

    /// Re-encodes the sound of `input` (an audio or video file) as WAV, AIFF, FLAC or M4A.
    static func transcode(_ input: URL, to format: OutputFormat, output: URL, bitrate: Int? = nil,
                          progress: @escaping ProgressHandler) async throws {
        let source = try await open(input)
        do {
            let writer = try Writer(output, format: format, sampleRate: source.sampleRate,
                                    channels: source.channels, bitrate: bitrate)
            let total = source.duration * source.sampleRate
            var done = 0.0
            try readPCM(source) { samples in
                try writer.write(samples)
                done += Double(samples.count / source.channels)
                if total > 0 { progress(min(1, done / total)) }
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        progress(1)
    }
}

/// Animated GIFs from video, through AVAssetImageGenerator and ImageIO (the Mac app uses ffmpeg).
enum AppleGIF {
    static func make(from input: URL, output: URL, maxWidth: CGFloat = 480,
                     progress: @escaping ProgressHandler) async throws {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionError("\(input.lastPathComponent) has no picture.")
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw ConversionError("Couldn't read the length of \(input.lastPathComponent).") }
        // Up to 10 frames a second and 300 frames in all, so long videos stay a sensible size.
        let fps = min(10, 300 / duration)
        let count = max(1, Int(duration * fps))
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let natural = size.applying(transform)
        let width = min(maxWidth, abs(natural.width))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: width, height: 0)

        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw ConversionError("Couldn't create the GIF.")
        }
        let loop = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(destination, loop)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for index in 0..<count {
            try Task.checkCancellation()
            let time = CMTime(seconds: Double(index) / fps, preferredTimescale: 600)
            let image = try await generator.image(at: time).image
            CGImageDestinationAddImage(destination, image, frameProps)
            progress(Double(index + 1) / Double(count))
        }
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            throw ConversionError("Couldn't save the GIF.")
        }
    }
}
