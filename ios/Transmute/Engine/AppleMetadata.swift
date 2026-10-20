import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Media tags through AVFoundation. The Mac app reads and writes them with ffmpeg; here they're
/// read from any file AVFoundation can open and written to MP4, M4V, MOV and M4A copies.
enum AppleMetadata {
    /// Tags shown for every file, in the editor's order (the same keys as the Mac app).
    static let keys = ["title", "artist", "album", "album_artist", "genre", "date", "comment", "copyright"]

    private static let writableExtensions: Set<String> = ["mp4", "m4v", "mov", "m4a"]

    /// Identifiers each tag is read from, most specific first.
    private static func readIdentifiers(_ key: String) -> [AVMetadataIdentifier] {
        switch key {
        case "title": [.iTunesMetadataSongName, .quickTimeMetadataTitle, .id3MetadataTitleDescription, .commonIdentifierTitle]
        case "artist": [.iTunesMetadataArtist, .quickTimeMetadataArtist, .id3MetadataLeadPerformer, .commonIdentifierArtist]
        case "album": [.iTunesMetadataAlbum, .quickTimeMetadataAlbum, .id3MetadataAlbumTitle, .commonIdentifierAlbumName]
        case "album_artist": [.iTunesMetadataAlbumArtist, .id3MetadataBand]
        case "genre": [.iTunesMetadataUserGenre, .quickTimeMetadataGenre, .id3MetadataContentType]
        case "date": [.iTunesMetadataReleaseDate, .quickTimeMetadataCreationDate, .id3MetadataYear,
                      .id3MetadataRecordingTime, .commonIdentifierCreationDate]
        case "comment": [.iTunesMetadataUserComment, .quickTimeMetadataComment, .id3MetadataComments]
        case "copyright": [.iTunesMetadataCopyright, .quickTimeMetadataCopyright, .id3MetadataCopyright, .commonIdentifierCopyrights]
        default: []
        }
    }

    /// The identifier written for a tag: iTunes-style in MP4 and M4A, QuickTime-style in MOV.
    private static func writeIdentifier(_ key: String, quickTime: Bool) -> AVMetadataIdentifier? {
        switch key {
        case "title": quickTime ? .quickTimeMetadataTitle : .iTunesMetadataSongName
        case "artist": quickTime ? .quickTimeMetadataArtist : .iTunesMetadataArtist
        case "album": quickTime ? .quickTimeMetadataAlbum : .iTunesMetadataAlbum
        case "album_artist": quickTime ? nil : .iTunesMetadataAlbumArtist
        case "genre": quickTime ? .quickTimeMetadataGenre : .iTunesMetadataUserGenre
        case "date": quickTime ? .quickTimeMetadataCreationDate : .iTunesMetadataReleaseDate
        case "comment": quickTime ? .quickTimeMetadataComment : .iTunesMetadataUserComment
        case "copyright": quickTime ? .quickTimeMetadataCopyright : .iTunesMetadataCopyright
        default: nil
        }
    }

    private static let locationIdentifiers: [AVMetadataIdentifier] = [.quickTimeMetadataLocationISO6709, .commonIdentifierLocation]

    static func read(_ url: URL, adding fileFields: [MetadataField]) async throws -> [MetadataField] {
        var fields = fileFields
        func add(_ key: String, _ label: String, _ value: String?, _ section: String) {
            guard let value, !value.isEmpty else { return }
            fields.append(MetadataField(key: key, label: label, value: value, editable: false, section: section))
        }
        let asset = AVURLAsset(url: url)
        let ext = url.pathExtension.lowercased()

        if let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 {
            add("media.duration", "Duration", clock(duration), "File")
        }
        if let video = try? await asset.loadTracks(withMediaType: .video).first {
            if let description = try? await video.load(.formatDescriptions).first {
                add("video.codec", "Codec", codecName(CMFormatDescriptionGetMediaSubType(description)), "Video")
            }
            if let size = try? await video.load(.naturalSize), let transform = try? await video.load(.preferredTransform) {
                let shown = size.applying(transform)
                add("video.resolution", "Resolution", "\(Int(abs(shown.width))) × \(Int(abs(shown.height)))", "Video")
            }
            if let fps = try? await video.load(.nominalFrameRate), fps > 0 {
                add("video.fps", "Frame rate", String(format: "%.3g fps", fps), "Video")
            }
        }
        if let audio = try? await asset.loadTracks(withMediaType: .audio).first,
           let description = try? await audio.load(.formatDescriptions).first {
            add("audio.codec", "Codec", codecName(CMFormatDescriptionGetMediaSubType(description)), "Audio")
            if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                if basic.mSampleRate > 0 {
                    add("audio.sampleRate", "Sample rate", String(format: "%g kHz", basic.mSampleRate / 1000), "Audio")
                }
                let channels = Int(basic.mChannelsPerFrame)
                add("audio.channels", "Channels", channels == 1 ? "Mono" : channels == 2 ? "Stereo" : "\(channels)", "Audio")
            }
        }

        let items = await allItems(asset)
        let editable = writableExtensions.contains(ext)
        for key in keys {
            let current = await value(for: key, in: items) ?? ""
            if editable && !(key == "album_artist" && ext == "mov") {
                fields.append(MetadataField(key: key, label: MetadataTool.label(forKey: key), value: current,
                                            editable: true, section: "Tags"))
            } else {
                add(key, MetadataTool.label(forKey: key), current, "Tags")
            }
        }
        if let location = await locationText(in: items) {
            if let point = MetadataTool.parseISO6709(location) {
                add("gps.latitude", "Latitude", coordinate(point.latitude, "N", "S"), "Location")
                add("gps.longitude", "Longitude", coordinate(point.longitude, "E", "W"), "Location")
                if let altitude = point.altitude { add("gps.altitude", "Altitude", String(format: "%.1f m", altitude), "Location") }
            } else {
                add("gps.coordinates", "Coordinates", location, "Location")
            }
        }
        return fields
    }

    static func write(_ changes: [String: String], removeLocation: Bool, to input: URL,
                      options: ConversionOptions) async throws -> URL {
        let ext = input.pathExtension.lowercased()
        guard writableExtensions.contains(ext) else {
            throw ConversionError("On iPhone and iPad, tags can be saved in MP4, M4V, MOV and M4A files.")
        }
        // MOV takes QuickTime-style tags and M4A iTunes-style ones. MP4 and M4V take either,
        // but some tags only stick in one style, so try iTunes-style first and fall back.
        let styles: [Bool] = switch ext {
        case "mov": [true]
        case "m4a": [false]
        default: [false, true]
        }
        var lastError: Error = ConversionError("Couldn't save the tags.")
        for quickTime in styles {
            do {
                return try await write(changes, removeLocation: removeLocation, to: input, quickTime: quickTime, options: options)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func write(_ changes: [String: String], removeLocation: Bool, to input: URL, quickTime: Bool,
                              options: ConversionOptions) async throws -> URL {
        let ext = input.pathExtension.lowercased()
        let asset = AVURLAsset(url: input)
        var items = await allItems(asset)

        var replaced = Set<AVMetadataIdentifier>()
        for key in changes.keys {
            guard keys.contains(key), writeIdentifier(key, quickTime: quickTime) != nil else {
                throw ConversionError("\(ext.uppercased()) files can't store \(MetadataTool.label(forKey: key).lowercased()) tags here.")
            }
            replaced.formUnion(readIdentifiers(key))
        }
        if removeLocation { replaced.formUnion(locationIdentifiers) }
        items.removeAll { item in item.identifier.map { replaced.contains($0) } ?? false }
        // Keep only the kinds of tags this container can hold.
        let allowed: Set<AVMetadataKeySpace> = switch ext {
        case "mov": [.quickTimeMetadata, .quickTimeUserData]
        case "m4a": [.iTunes]
        default: [.iTunes, .quickTimeMetadata]
        }
        items = items.filter { $0.keySpace.map(allowed.contains) ?? false }

        for key in changes.keys.sorted() {
            let text = changes[key] ?? ""
            guard !text.isEmpty, let identifier = writeIdentifier(key, quickTime: quickTime) else { continue }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = text as NSString
            item.extendedLanguageTag = "und"
            items.append(item)
        }

        let type: AVFileType = switch ext {
        case "mov": .mov
        case "m4a": .m4a
        case "m4v": .m4v
        default: .mp4
        }
        guard await AVAssetExportSession.canExport(asset, preset: AVAssetExportPresetPassthrough, as: type),
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ConversionError("This \(ext.uppercased()) file can't be re-saved with new tags.")
        }
        let out = OutputPaths.destination(for: input, ext: input.pathExtension, suffix: "tagged", folder: options.outputFolder)
        session.metadata = items
        if removeLocation { session.metadataItemFilter = .forSharing() }
        if let failure = await session.runExport(to: out, as: type, progress: { _ in }) {
            try? FileManager.default.removeItem(at: out)
            throw ConversionError(failure.localizedDescription)
        }

        // Read the copy back to make sure the changes landed.
        let written = await allItems(AVURLAsset(url: out))
        var failed: [String] = []
        for key in changes.keys.sorted() {
            let wanted = changes[key] ?? ""
            let now = await value(for: key, in: written) ?? ""
            if wanted.isEmpty ? !now.isEmpty : now != wanted { failed.append(MetadataTool.label(forKey: key).lowercased()) }
        }
        if removeLocation, await locationText(in: written) != nil { failed.append("the location removal") }
        guard failed.isEmpty else {
            try? FileManager.default.removeItem(at: out)
            throw ConversionError("Couldn't save \(failed.joined(separator: ", ")) in this \(ext.uppercased()) file.")
        }
        return out
    }

    // MARK: Helpers

    private static func allItems(_ asset: AVURLAsset) async -> [AVMetadataItem] {
        var items = (try? await asset.load(.metadata)) ?? []
        for format in (try? await asset.load(.availableMetadataFormats)) ?? [] {
            for item in (try? await asset.loadMetadata(for: format)) ?? [] where !items.contains(item) {
                items.append(item)
            }
        }
        return items
    }

    private static func value(for key: String, in items: [AVMetadataItem]) async -> String? {
        for identifier in readIdentifiers(key) {
            for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier) {
                if let text = try? await item.load(.stringValue), !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let date = try? await item.load(.dateValue) {
                    return ISO8601DateFormatter().string(from: date)
                }
            }
        }
        return nil
    }

    private static func locationText(in items: [AVMetadataItem]) async -> String? {
        for identifier in locationIdentifiers {
            for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier) {
                if let text = try? await item.load(.stringValue), !text.isEmpty { return text }
            }
        }
        return nil
    }

    private static func codecName(_ code: FourCharCode) -> String {
        let known: [String: String] = [
            "avc1": "H.264", "avc3": "H.264", "hvc1": "HEVC (H.265)", "hev1": "HEVC (H.265)", "mp4v": "MPEG-4",
            "ap4h": "ProRes 4444", "apcn": "ProRes 422", "apch": "ProRes 422 HQ", "apcs": "ProRes 422 LT",
            "jpeg": "Motion JPEG", "av01": "AV1", "vp09": "VP9",
            "aac ": "AAC", ".mp3": "MP3", "lpcm": "PCM", "alac": "Apple Lossless", "flac": "FLAC",
            "ac-3": "Dolby Digital", "ec-3": "Dolby Digital Plus", "opus": "Opus",
        ]
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        let text = String(decoding: bytes, as: UTF8.self)
        return known[text] ?? text.trimmingCharacters(in: .whitespaces).uppercased()
    }

    private static func coordinate(_ degrees: Double, _ positive: String, _ negative: String) -> String {
        String(format: "%.6f", abs(degrees)) + "° " + (degrees < 0 ? negative : positive)
    }

    private static func clock(_ seconds: Double) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded())
        let whole = tenths / 10
        let h = whole / 3600, m = whole / 60 % 60, s = whole % 60
        let mm = m < 10 ? "0\(m)" : "\(m)", ss = s < 10 ? "0\(s)" : "\(s)"
        return (h > 0 ? "\(h):\(mm):\(ss)" : "\(m):\(ss)") + ".\(tenths % 10)"
    }
}
