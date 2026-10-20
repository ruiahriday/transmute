import AppKit
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// One row in the metadata editor: a value read from a file, and whether it can be changed.
struct MetadataField: Identifiable, Equatable, Sendable {
    /// Stable key. Editable fields use the keys `MetadataEdit.changes` takes ("artist", "dateTaken"…);
    /// read-only ones are namespaced ("file.size", "video.codec", "gps.latitude"…).
    let key: String
    var label: String
    var value: String
    var editable: Bool
    var section: String

    var id: String { key }
}

/// Changes to save into a copy of a file.
struct MetadataEdit: Equatable, Sendable {
    /// Field key → new value. An empty string removes that field.
    var changes: [String: String] = [:]
    /// Drops GPS coordinates from photos and location tags from videos.
    var removeLocation = false

    var isEmpty: Bool { changes.isEmpty && !removeLocation }
}

/// Reads and writes the descriptive information inside images, video, audio and PDFs.
/// Writing never touches the original: it saves a copy with "(tagged)" in the name.
enum MetadataTool {
    /// Editable keys per kind of file.
    static let imageKeys = ["description", "artist", "copyright", "dateTaken"]
    static let mediaKeys = ["title", "artist", "album", "album_artist", "genre", "date", "comment", "copyright", "track"]
    static let pdfKeys = ["title", "author", "subject", "keywords", "creator"]

    static func read(_ url: URL) async throws -> [MetadataField] {
        let fields: [MetadataField]
        switch FileKind.of(url) {
        case .image: fields = readImage(url)
        case .video, .audio: fields = try await readMedia(url)
        case .pdf: fields = try readPDF(url)
        default: fields = fileFields(url)
        }
        // Keys are the editor's row identities, so they must be unique.
        var seen = Set<String>()
        return fields.filter { seen.insert($0.key).inserted }
    }

    static func write(_ edit: MetadataEdit, to input: URL, options: ConversionOptions) async throws -> URL {
        var changes: [String: String] = [:]
        for (key, value) in edit.changes {
            changes[key] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !changes.isEmpty || edit.removeLocation else { throw ConversionError("There are no changes to save.") }
        let kind = FileKind.of(input)
        switch kind {
        case .image:
            return try writeImage(changes, removeLocation: edit.removeLocation, to: input, options: options)
        case .video, .audio:
            return try await writeMedia(changes, removeLocation: edit.removeLocation, to: input, options: options)
        case .pdf:
            guard !changes.isEmpty else { throw ConversionError("PDFs have no location to remove.") }
            return try writePDF(changes, to: input, options: options)
        default:
            throw ConversionError("Transmute can't edit the metadata of \(kind.title.lowercased()).")
        }
    }

    // MARK: Helpers for the editor and the self-test

    static func label(forKey key: String) -> String {
        switch key {
        case "description": "Description"
        case "artist": "Artist"
        case "copyright": "Copyright"
        case "dateTaken": "Date taken"
        case "title": "Title"
        case "album": "Album"
        case "album_artist": "Album artist"
        case "genre": "Genre"
        case "date": "Year"
        case "comment": "Comment"
        case "track": "Track"
        case "author": "Author"
        case "subject": "Subject"
        case "keywords": "Keywords"
        case "creator": "Creator"
        default: key
        }
    }

    /// Example text for an empty field.
    static func placeholder(forKey key: String) -> String? {
        switch key {
        case "dateTaken": return "2024:05:31 14:30:00"
        case "date": return "2024"
        case "track": return "3 or 3/12"
        case "keywords": return "holiday, beach"
        default: return nil
        }
    }

    /// Section names in the order their first field appears.
    static func sections(of fields: [MetadataField]) -> [String] {
        var names: [String] = []
        for field in fields where !names.contains(field.section) {
            names.append(field.section)
        }
        return names
    }

    static func value(of key: String, in fields: [MetadataField]) -> String? {
        fields.first(where: { $0.key == key })?.value
    }

    /// True when a photo has GPS coordinates or a video has location tags.
    static func hasLocation(_ fields: [MetadataField]) -> Bool {
        fields.contains { $0.key.hasPrefix("gps.") }
    }

    /// Everything as plain text, one "Label: value" line per field, grouped by section.
    static func plainText(_ fields: [MetadataField], title: String) -> String {
        var lines = [title]
        for section in sections(of: fields) {
            let rows = fields.filter { $0.section == section && !$0.value.isEmpty }
            guard !rows.isEmpty else { continue }
            lines.append("")
            lines.append(section)
            for row in rows {
                lines.append("  \(row.label): \(row.value.replacingOccurrences(of: "\n", with: "\n    "))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Accepts "2024:05:31 14:30:00", "2024-05-31 14:30", "2024-05-31T14:30:00" or "2024-05-31" and
    /// returns EXIF's "yyyy:MM:dd HH:mm:ss", or nil when the text isn't a date in that order.
    static func exifDate(from text: String) -> String? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.contains(where: { $0.isLetter && $0 != "T" && $0 != "Z" }) else { return nil }
        let groups = cleaned.split(whereSeparator: { !($0.isASCII && $0.isNumber) }).map(String.init)
        guard [3, 5, 6].contains(groups.count), groups[0].count == 4 else { return nil }
        let numbers = groups.compactMap { Int($0) }
        guard numbers.count == groups.count else { return nil }
        let year = numbers[0], month = numbers[1], day = numbers[2]
        let hour = numbers.count > 3 ? numbers[3] : 0
        let minute = numbers.count > 4 ? numbers[4] : 0
        let second = numbers.count > 5 ? numbers[5] : 0
        guard (1800...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
        return "\(year):\(twoDigits(month)):\(twoDigits(day)) \(twoDigits(hour)):\(twoDigits(minute)):\(twoDigits(second))"
    }

    // MARK: Any file

    private static func fileFields(_ url: URL) -> [MetadataField] {
        var fields: [MetadataField] = []
        addField("file.kind", "Kind", UTType(filenameExtension: url.pathExtension.lowercased())?.localizedDescription,
                 in: "File", to: &fields)
        let size = OutputPaths.fileSize(url)
        let bytes = NumberFormatter.localizedString(from: NSNumber(value: size), number: .decimal)
        addField("file.size", "Size", "\(size.formattedSize) (\(bytes) bytes)", in: "File", to: &fields)
        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        if let created = attributes[.creationDate] as? Date {
            addField("file.created", "Created", dateText(created), in: "File", to: &fields)
        }
        if let modified = attributes[.modificationDate] as? Date {
            addField("file.modified", "Modified", dateText(modified), in: "File", to: &fields)
        }
        return fields
    }

    // MARK: Images

    /// Where an editable image field lives in ImageIO's property dictionaries, most authoritative first.
    private struct ImageSlot {
        enum Rule { case always, ifPresent, pngOnly }
        let dictionary: CFString
        let property: CFString
        /// `.ifPresent` slots are only filled in when the file already has that dictionary
        /// (so IPTC doesn't go stale); every slot is cleared when a field is removed.
        var rule = Rule.always
        /// IPTC keeps the by-line as a list of names.
        var isList = false
    }

    private static func imageSlots(for key: String) -> [ImageSlot] {
        switch key {
        case "description":
            return [ImageSlot(dictionary: kCGImagePropertyTIFFDictionary, property: kCGImagePropertyTIFFImageDescription),
                    ImageSlot(dictionary: kCGImagePropertyPNGDictionary, property: kCGImagePropertyPNGDescription, rule: .pngOnly),
                    ImageSlot(dictionary: kCGImagePropertyIPTCDictionary, property: kCGImagePropertyIPTCCaptionAbstract,
                              rule: .ifPresent)]
        case "artist":
            return [ImageSlot(dictionary: kCGImagePropertyTIFFDictionary, property: kCGImagePropertyTIFFArtist),
                    ImageSlot(dictionary: kCGImagePropertyPNGDictionary, property: kCGImagePropertyPNGAuthor, rule: .pngOnly),
                    ImageSlot(dictionary: kCGImagePropertyIPTCDictionary, property: kCGImagePropertyIPTCByline,
                              rule: .ifPresent, isList: true)]
        case "copyright":
            return [ImageSlot(dictionary: kCGImagePropertyTIFFDictionary, property: kCGImagePropertyTIFFCopyright),
                    ImageSlot(dictionary: kCGImagePropertyPNGDictionary, property: kCGImagePropertyPNGCopyright, rule: .pngOnly),
                    ImageSlot(dictionary: kCGImagePropertyIPTCDictionary, property: kCGImagePropertyIPTCCopyrightNotice,
                              rule: .ifPresent)]
        case "dateTaken":
            return [ImageSlot(dictionary: kCGImagePropertyExifDictionary, property: kCGImagePropertyExifDateTimeOriginal)]
        default:
            return []
        }
    }

    private static func readImage(_ url: URL) -> [MetadataField] {
        var fields = fileFields(url)
        // SVG and anything else ImageIO can't open only get the file facts.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let typeID = CGImageSourceGetType(source) else { return fields }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        let canWrite = imageWriteProblem(typeID, ext: url.pathExtension) == nil

        // File
        if let width = numberValue(props[kCGImagePropertyPixelWidth]),
           let height = numberValue(props[kCGImagePropertyPixelHeight]) {
            // Orientations 5–8 are turned a quarter, so viewers show the image the other way round.
            let orientation = Int(numberValue(props[kCGImagePropertyOrientation]) ?? 1)
            let (shownWidth, shownHeight) = (5...8).contains(orientation) ? (height, width) : (width, height)
            addField("image.size", "Dimensions", "\(Int(shownWidth)) × \(Int(shownHeight)) pixels", in: "File", to: &fields)
        }
        var colour: [String] = []
        if let model = stringValue(props[kCGImagePropertyColorModel]) { colour.append(model) }
        if let depth = numberValue(props[kCGImagePropertyDepth]) { colour.append("\(Int(depth)) bits per channel") }
        if (props[kCGImagePropertyHasAlpha] as? Bool) == true { colour.append("with transparency") }
        addField("image.colour", "Colour", colour.isEmpty ? nil : colour.joined(separator: ", "), in: "File", to: &fields)
        addField("image.profile", "Colour profile", stringValue(props[kCGImagePropertyProfileName]), in: "File", to: &fields)
        if let dpiX = numberValue(props[kCGImagePropertyDPIWidth]) {
            let dpiY = numberValue(props[kCGImagePropertyDPIHeight]) ?? dpiX
            let dpi = dpiX == dpiY ? "\(decimal(dpiX)) dpi" : "\(decimal(dpiX)) × \(decimal(dpiY)) dpi"
            addField("image.dpi", "Resolution", dpi, in: "File", to: &fields)
        }
        let frames = CGImageSourceGetCount(source)
        if frames > 1 { addField("image.frames", "Frames", "\(frames)", in: "File", to: &fields) }

        // Camera
        addField("camera.make", "Make", stringValue(tiff[kCGImagePropertyTIFFMake]), in: "Camera", to: &fields)
        addField("camera.model", "Model", stringValue(tiff[kCGImagePropertyTIFFModel]), in: "Camera", to: &fields)
        addField("camera.lens", "Lens",
                 stringValue(exif[kCGImagePropertyExifLensModel]) ?? stringValue(aux[kCGImagePropertyExifAuxLensModel]),
                 in: "Camera", to: &fields)
        if let seconds = numberValue(exif[kCGImagePropertyExifExposureTime]), seconds > 0 {
            let exposure = seconds < 1 ? "1/\(Int((1 / seconds).rounded())) s" : "\(decimal(seconds)) s"
            addField("camera.exposure", "Exposure", exposure, in: "Camera", to: &fields)
        }
        if let aperture = numberValue(exif[kCGImagePropertyExifFNumber]), aperture > 0 {
            addField("camera.aperture", "Aperture", "f/\(decimal(aperture, digits: 1))", in: "Camera", to: &fields)
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first {
            addField("camera.iso", "ISO", "ISO \(iso.intValue)", in: "Camera", to: &fields)
        }
        if let focal = numberValue(exif[kCGImagePropertyExifFocalLength]), focal > 0 {
            var focalText = "\(decimal(focal, digits: 1)) mm"
            if let equivalent = numberValue(exif[kCGImagePropertyExifFocalLenIn35mmFilm]), equivalent > 0 {
                focalText += " (\(Int(equivalent)) mm in 35 mm terms)"
            }
            addField("camera.focalLength", "Focal length", focalText, in: "Camera", to: &fields)
        }
        addField("camera.software", "Software", stringValue(tiff[kCGImagePropertyTIFFSoftware]), in: "Camera", to: &fields)
        addImageField("dateTaken", section: "Camera", props: props, editable: canWrite, to: &fields)

        // Location
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let latitude = numberValue(gps[kCGImagePropertyGPSLatitude]),
           let longitude = numberValue(gps[kCGImagePropertyGPSLongitude]) {
            let south = (stringValue(gps[kCGImagePropertyGPSLatitudeRef]) ?? "N").uppercased() == "S"
            let west = (stringValue(gps[kCGImagePropertyGPSLongitudeRef]) ?? "E").uppercased() == "W"
            var altitude = numberValue(gps[kCGImagePropertyGPSAltitude])
            if let height = altitude, numberValue(gps[kCGImagePropertyGPSAltitudeRef]) == 1 { altitude = -height }
            fields += locationFields(latitude: south ? -abs(latitude) : abs(latitude),
                                     longitude: west ? -abs(longitude) : abs(longitude), altitude: altitude)
        }

        // Description
        for key in imageKeys where key != "dateTaken" {
            addImageField(key, section: "Description", props: props, editable: canWrite, to: &fields)
        }
        addField("iptc.keywords", "Keywords", stringValue(iptc[kCGImagePropertyIPTCKeywords]), in: "Description", to: &fields)
        return fields
    }

    /// Editable images always show the field so it can be filled in; others only when it has a value.
    private static func addImageField(_ key: String, section: String, props: [CFString: Any], editable: Bool,
                                      to fields: inout [MetadataField]) {
        let current = imageValue(key, in: props)
        if editable {
            fields.append(MetadataField(key: key, label: label(forKey: key), value: current, editable: true, section: section))
        } else {
            addField(key, label(forKey: key), current, in: section, to: &fields)
        }
    }

    private static func imageValue(_ key: String, in props: [CFString: Any]) -> String {
        for slot in imageSlots(for: key) {
            let dictionary = props[slot.dictionary] as? [CFString: Any]
            if let found = stringValue(dictionary?[slot.property]) { return found }
        }
        return ""
    }

    private static func hasGPS(_ props: [CFString: Any]) -> Bool {
        guard let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] else { return false }
        return gps[kCGImagePropertyGPSLatitude] != nil || gps[kCGImagePropertyGPSLongitude] != nil
    }

    /// Why ImageIO can't save metadata into this type of image, or nil when it can.
    private static func imageWriteProblem(_ typeID: CFString, ext: String) -> String? {
        let identifier = typeID as String
        let holdsMetadata = [UTType.jpeg, .tiff, .png, .heic, .heif].map(\.identifier).contains(identifier)
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(identifier)
        guard holdsMetadata && writable else {
            return "macOS can't save metadata into \(ext.uppercased()) files. Convert to JPEG, PNG, TIFF or HEIC first."
        }
        return nil
    }

    private static func writeImage(_ requested: [String: String], removeLocation: Bool, to input: URL,
                                   options: ConversionOptions) throws -> URL {
        var changes = requested
        for key in changes.keys.sorted() where !imageKeys.contains(key) {
            throw ConversionError("“\(key)” isn't something Transmute can edit in images.")
        }
        if let typed = changes["dateTaken"], !typed.isEmpty {
            guard let normalised = exifDate(from: typed) else {
                throw ConversionError("Date taken should look like 2024:05:31 14:30:00.")
            }
            changes["dateTaken"] = normalised
        }
        let ext = input.pathExtension
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let typeID = CGImageSourceGetType(source) else {
            if ext.lowercased() == "svg" {
                throw ConversionError("SVG files can't hold photo metadata. Convert to PNG or JPEG first.")
            }
            throw ConversionError("Couldn't read \(input.lastPathComponent).")
        }
        if let problem = imageWriteProblem(typeID, ext: ext) { throw ConversionError(problem) }
        let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]

        // Lossless first: the pixels are copied as they are and only the metadata changes.
        // ImageIO quietly ignores some metadata edits, so the result is read back before it's trusted.
        var result: Data?
        if let copied = losslessImageCopy(source, type: typeID, changes: changes, removeLocation: removeLocation,
                                          original: original),
           imageFailures(copied, changes: changes, removeLocation: removeLocation, original: original).isEmpty {
            result = copied
        }
        if result == nil {
            // Re-encode with complete property dictionaries (near-lossless for JPEG and HEIC, lossless otherwise).
            let encoded = try reencodeImage(source, type: typeID, changes: changes, removeLocation: removeLocation)
            let failed = imageFailures(encoded, changes: changes, removeLocation: removeLocation, original: original)
            guard failed.isEmpty else {
                throw ConversionError("Couldn't save \(failed.joined(separator: ", ")) in this \(ext.uppercased()) file.")
            }
            result = encoded
        }
        guard let data = result else { throw ConversionError("Couldn't encode the image.") }
        let out = OutputPaths.destination(for: input, ext: ext, suffix: "tagged", folder: options.outputFolder)
        try data.write(to: out, options: .atomic)
        return out
    }

    private static func losslessImageCopy(_ source: CGImageSource, type typeID: CFString, changes: [String: String],
                                          removeLocation: Bool, original: [CFString: Any]) -> Data? {
        let metadata = CGImageMetadataCreateMutable()
        for (key, value) in changes {
            for slot in imageSlots(for: key) where slot.rule != .pngOnly {
                if !value.isEmpty && slot.rule == .ifPresent && original[slot.dictionary] == nil { continue }
                let newValue: AnyObject
                if value.isEmpty {
                    newValue = NSNull() // kCFNull: merging removes the tag
                } else if slot.isList {
                    newValue = [value] as NSArray
                } else {
                    newValue = value as NSString
                }
                _ = CGImageMetadataSetValueMatchingImageProperty(metadata, slot.dictionary, slot.property, newValue)
            }
        }
        var copyOptions: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: true,
        ]
        if removeLocation { copyOptions[kCGImageMetadataShouldExcludeGPS] = true }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, typeID, 1, nil),
              CGImageDestinationCopyImageSource(destination, source, copyOptions as CFDictionary, nil) else { return nil }
        return output as Data
    }

    private static func reencodeImage(_ source: CGImageSource, type typeID: CFString, changes: [String: String],
                                      removeLocation: Bool) throws -> Data {
        let output = NSMutableData()
        let count = CGImageSourceGetCount(source)
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, typeID, count, nil) else {
            throw ConversionError("Couldn't create the image encoder.")
        }
        let isPNG = (typeID as String) == UTType.png.identifier
        for index in 0..<count {
            // Raw pixels, not rotated: the Orientation property is kept, so viewers turn it as before.
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                throw ConversionError("Couldn't decode the image.")
            }
            let frameProps = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            var props = applying(changes, removeLocation: removeLocation, to: frameProps, isPNG: isPNG)
            props[kCGImageDestinationLossyCompressionQuality] = 0.95
            CGImageDestinationAddImage(destination, image, props as CFDictionary)
        }
        if count > 1, let containerProps = CGImageSourceCopyProperties(source, nil) {
            CGImageDestinationSetProperties(destination, containerProps)
        }
        guard CGImageDestinationFinalize(destination) else { throw ConversionError("Couldn't encode the image.") }
        return output as Data
    }

    /// The source's properties with the changes applied, ready for CGImageDestinationAddImage.
    private static func applying(_ changes: [String: String], removeLocation: Bool,
                                 to original: [CFString: Any], isPNG: Bool) -> [CFString: Any] {
        var props = original
        for (key, value) in changes {
            for slot in imageSlots(for: key) {
                var dictionary = props[slot.dictionary] as? [CFString: Any] ?? [:]
                if value.isEmpty {
                    dictionary[slot.property] = nil
                } else if slot.rule == .always || (slot.rule == .pngOnly && isPNG)
                            || (slot.rule == .ifPresent && props[slot.dictionary] != nil) {
                    if slot.isList {
                        dictionary[slot.property] = [value]
                    } else {
                        dictionary[slot.property] = value
                    }
                }
                if dictionary.isEmpty {
                    props[slot.dictionary] = nil
                } else {
                    props[slot.dictionary] = dictionary
                }
            }
        }
        if removeLocation { props[kCGImagePropertyGPSDictionary] = nil }
        props[kCGImagePropertyPixelWidth] = nil
        props[kCGImagePropertyPixelHeight] = nil
        return props
    }

    /// Labels of the changes that don't show up when `data` is read back the way the editor reads files.
    private static func imageFailures(_ data: Data, changes: [String: String], removeLocation: Bool,
                                      original: [CFString: Any]) -> [String] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return ["the image"]
        }
        var failed: [String] = []
        for key in changes.keys.sorted() {
            let wanted = changes[key] ?? ""
            if !took(wanted, now: imageValue(key, in: props), before: imageValue(key, in: original)) {
                failed.append(label(forKey: key).lowercased())
            }
        }
        if removeLocation && hasGPS(props) { failed.append("the location removal") }
        return failed
    }

    // MARK: Video and audio

    /// What `ffmpeg -i file` prints about its input: container, length, tracks and tags.
    struct MediaBanner {
        struct Tag {
            var key: String
            var value: String
        }

        struct Track {
            /// "Video", "Audio", "Subtitle", "Data", "Attachment" or "Other".
            var kind: String
            /// Everything after "Video: ", e.g. "h264 (High) (avc1 / 0x31637661), yuv420p, 320x240, 25 fps".
            var details: String
            var tags: [Tag] = []
        }

        var foundInput = false
        /// ffmpeg's demuxer names, e.g. "mov,mp4,m4a,3gp,3g2,mj2" or "matroska,webm".
        var container = ""
        var duration: Double?
        var bitrate: String?
        var tags: [Tag] = []
        var tracks: [Track] = []

        private enum Block { case idle, global, track, skipped }

        init(parsing text: String) {
            var block = Block.idle
            var entryIndent = 0
            var afterTrackLine = false
            for rawLine in text.split(whereSeparator: \.isNewline) {
                let line = String(rawLine)
                let indent = line.prefix(while: { $0 == " " }).count
                let content = line.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("Input #") {
                    if foundInput { break }
                    foundInput = true
                    // "Input #0, mov,mp4,m4a,3gp,3g2,mj2, from '/path/clip.mp4':"
                    if let comma = line.range(of: ", "), let from = line.range(of: ", from '"),
                       comma.upperBound <= from.lowerBound {
                        container = String(line[comma.upperBound..<from.lowerBound])
                    }
                    continue
                }
                if line.hasPrefix("Output #") { break }
                guard foundInput, line.hasPrefix(" ") else { continue }

                if content == "Metadata:" {
                    // Two spaces in: the file's tags. Four, right after a stream line: that track's tags.
                    if indent == 2 {
                        block = .global
                    } else if indent == 4 && afterTrackLine {
                        block = .track
                    } else {
                        block = .skipped
                    }
                    entryIndent = indent + 2
                    continue
                }
                if block != .idle, indent >= entryIndent, let colon = content.firstIndex(of: ":") {
                    // "title           : My Title". Extra lines of a long value come with an empty key.
                    let key = content[..<colon].trimmingCharacters(in: .whitespaces)
                    let value = content[content.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    switch block {
                    case .global: Self.append(key, value, to: &tags)
                    case .track where !tracks.isEmpty: Self.append(key, value, to: &tracks[tracks.count - 1].tags)
                    default: break
                    }
                    continue
                }
                block = .idle
                if content.hasPrefix("Duration:") {
                    afterTrackLine = false
                    duration = FFmpegProgress.parseDuration(content)
                    if let range = content.range(of: "bitrate: ") {
                        let rate = content[range.upperBound...].trimmingCharacters(in: .whitespaces)
                        if !rate.isEmpty && rate != "N/A" { bitrate = rate }
                    }
                } else if content.hasPrefix("Stream #") {
                    afterTrackLine = true
                    var track = Track(kind: "Other", details: content)
                    for kind in ["Video", "Audio", "Subtitle", "Data", "Attachment"] {
                        if let range = content.range(of: ": \(kind): ") {
                            track = Track(kind: kind, details: String(content[range.upperBound...]))
                            break
                        }
                    }
                    tracks.append(track)
                } else {
                    afterTrackLine = false
                }
            }
        }

        private static func append(_ key: String, _ value: String, to list: inout [Tag]) {
            if key.isEmpty {
                if !list.isEmpty { list[list.count - 1].value += "\n" + value }
            } else {
                list.append(Tag(key: key, value: value))
            }
        }

        /// Tracks of one kind, leaving out cover art (which ffmpeg lists as a video track).
        func tracksOfKind(_ kind: String) -> [Track] {
            tracks.filter { $0.kind == kind && !$0.details.contains("(attached pic)") }
        }

        var hasCoverArt: Bool {
            tracks.contains(where: { $0.details.contains("(attached pic)") })
        }

        var isOgg: Bool { container.hasPrefix("ogg") }

        /// The tags as players see them. Ogg keeps its comments on the audio track, not the container.
        var allTags: [Tag] {
            guard isOgg, let audio = tracksOfKind("Audio").first else { return tags }
            return tags + audio.tags
        }
    }

    static func probe(_ url: URL, ffmpeg: String) async throws -> MediaBanner {
        // With no output file ffmpeg prints the input's details and exits non-zero; that's expected.
        let output = try await Shell.run(ffmpeg, ["-hide_banner", "-nostdin", "-i", url.path])
        let banner = MediaBanner(parsing: output.stderr)
        guard banner.foundInput else {
            let reason = output.stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "unknown error"
            throw ConversionError("ffmpeg couldn't read \(url.lastPathComponent): \(reason)")
        }
        return banner
    }

    /// Keys this container keeps when ffmpeg writes them (checked with ffmpeg 6.1).
    private static func editableMediaKeys(forExtension ext: String) -> [String] {
        switch ext {
        case "mpg", "mpeg", "ts", "mts", "m2ts", "3gp": return []
        case "wav": return mediaKeys.filter { $0 != "album_artist" }
        case "avi": return mediaKeys.filter { $0 != "album_artist" && $0 != "album" }
        default: return mediaKeys
        }
    }

    /// Other names the same tag goes by, lowercased. The first is what ffmpeg writes.
    private static func mediaAliases(_ key: String) -> [String] {
        switch key {
        case "title": ["title", "com.apple.quicktime.title"]
        case "artist": ["artist", "com.apple.quicktime.artist"]
        case "album": ["album", "com.apple.quicktime.album"]
        case "album_artist": ["album_artist", "albumartist", "album artist"]
        case "genre": ["genre", "com.apple.quicktime.genre"]
        case "date": ["date", "year"]
        case "comment": ["comment", "com.apple.quicktime.comment"]
        case "copyright": ["copyright", "com.apple.quicktime.copyright"]
        case "track": ["track", "tracknumber"]
        default: [key.lowercased()]
        }
    }

    private static func tagValue(_ key: String, in tags: [MediaBanner.Tag]) -> String {
        for alias in mediaAliases(key) {
            if let tag = tags.first(where: { $0.key.lowercased() == alias && !$0.value.isEmpty }) {
                return tag.value
            }
        }
        return ""
    }

    private static func isLocationKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        return lower.hasPrefix("location") || lower.hasPrefix("com.apple.quicktime.location")
    }

    /// An ISO 6709 string like "+51.5007-000.1275+035.000/" from a phone video.
    private static func mediaLocation(_ tags: [MediaBanner.Tag]) -> String? {
        for name in ["com.apple.quicktime.location.iso6709", "location", "location-eng"] {
            if let tag = tags.first(where: { $0.key.lowercased() == name && !$0.value.isEmpty }) {
                return tag.value
            }
        }
        return nil
    }

    /// Decimal-degree ISO 6709 ("+51.5007-000.1275+035.000/"); nil for anything else.
    static func parseISO6709(_ text: String) -> (latitude: Double, longitude: Double, altitude: Double?)? {
        var parts: [String] = []
        var current = ""
        for character in text {
            if character == "+" || character == "-" {
                if !current.isEmpty { parts.append(current) }
                current = String(character)
            } else if character.isASCII && (character.isNumber || character == ".") {
                current.append(character)
            } else {
                break
            }
        }
        if !current.isEmpty { parts.append(current) }
        guard parts.count >= 2, let latitude = Double(parts[0]), let longitude = Double(parts[1]),
              abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        return (latitude, longitude, parts.count > 2 ? Double(parts[2]) : nil)
    }

    private static func readMedia(_ url: URL) async throws -> [MetadataField] {
        var fields = fileFields(url)
        let ext = url.pathExtension.lowercased()
        guard let ffmpeg = Tools.ffmpeg else {
            let seconds = await MediaInfo.duration(of: url)
            if seconds > 0 { addField("media.duration", "Duration", clock(seconds), in: "File", to: &fields) }
            let hint = AppInfo.isAppStoreBuild ? "Needs the included ffmpeg" : "Install ffmpeg to see and edit tags"
            addField("tags.note", "Tags", hint, in: "Tags", to: &fields)
            return fields
        }
        let banner = try await probe(url, ffmpeg: ffmpeg)
        let tags = banner.allTags

        addField("media.container", "Container", containerName(banner, ext: ext), in: "File", to: &fields)
        if let seconds = banner.duration, seconds > 0 {
            addField("media.duration", "Duration", clock(seconds), in: "File", to: &fields)
        }
        addField("media.bitrate", "Bitrate", banner.bitrate, in: "File", to: &fields)
        let subtitles = banner.tracksOfKind("Subtitle")
        if !subtitles.isEmpty {
            addField("media.subtitles", "Subtitles", "\(subtitles.count) track\(subtitles.count == 1 ? "" : "s")",
                     in: "File", to: &fields)
        }
        if banner.hasCoverArt { addField("media.coverArt", "Cover art", "Yes", in: "File", to: &fields) }

        let videos = banner.tracksOfKind("Video")
        if let video = videos.first {
            let parts = splitDetails(video.details)
            addField("video.codec", "Codec", parts.first.map { codecName($0) }, in: "Video", to: &fields)
            addField("video.resolution", "Resolution", resolution(in: parts), in: "Video", to: &fields)
            addField("video.fps", "Frame rate", frameRate(in: parts), in: "Video", to: &fields)
            if videos.count > 1 { addField("video.tracks", "Video tracks", "\(videos.count)", in: "Video", to: &fields) }
        }
        let audios = banner.tracksOfKind("Audio")
        if let audio = audios.first {
            let parts = splitDetails(audio.details)
            addField("audio.codec", "Codec", parts.first.map { codecName($0) }, in: "Audio", to: &fields)
            if let hz = parts.firstIndex(where: { $0.hasSuffix(" Hz") }) {
                if let rate = Double(parts[hz].dropLast(3)) {
                    addField("audio.sampleRate", "Sample rate", "\(decimal(rate / 1000, digits: 3)) kHz", in: "Audio", to: &fields)
                }
                if hz + 1 < parts.count {
                    addField("audio.channels", "Channels", channelsText(parts[hz + 1]), in: "Audio", to: &fields)
                }
            }
            if audios.count > 1 { addField("audio.tracks", "Audio tracks", "\(audios.count)", in: "Audio", to: &fields) }
        }

        // Tags this container can keep are editable; the rest are shown when present.
        let editableKeys = editableMediaKeys(forExtension: ext)
        var shown = Set<String>()
        for key in mediaKeys {
            let current = tagValue(key, in: tags)
            shown.formUnion(mediaAliases(key))
            if editableKeys.contains(key) {
                fields.append(MetadataField(key: key, label: label(forKey: key), value: current, editable: true, section: "Tags"))
            } else {
                addField(key, label(forKey: key), current, in: "Tags", to: &fields)
            }
        }

        if let location = mediaLocation(tags) {
            if let point = parseISO6709(location) {
                fields += locationFields(latitude: point.latitude, longitude: point.longitude, altitude: point.altitude)
            } else {
                addField("gps.coordinates", "Coordinates", location, in: "Location", to: &fields)
            }
        }
        for tag in tags where isLocationKey(tag.key) {
            shown.insert(tag.key.lowercased())
        }
        for tag in tags where !shown.contains(tag.key.lowercased()) {
            addField("tag.\(tag.key.lowercased())", tag.key, tag.value, in: "Other tags", to: &fields)
        }
        return fields
    }

    private static func writeMedia(_ changes: [String: String], removeLocation: Bool, to input: URL,
                                   options: ConversionOptions) async throws -> URL {
        let ffmpeg = try Tools.requireFFmpeg(for: "Editing tags")
        let ext = input.pathExtension.lowercased()
        let allowed = editableMediaKeys(forExtension: ext)
        for key in changes.keys.sorted() where !allowed.contains(key) {
            throw ConversionError(mediaKeys.contains(key)
                ? "\(ext.uppercased()) files can't store \(label(forKey: key).lowercased()) tags."
                : "“\(key)” isn't something Transmute can edit in \(ext.uppercased()) files.")
        }
        let source = try await probe(input, ffmpeg: ffmpeg)
        let sourceTags = source.allTags
        let isMP4 = ["mp4", "m4v", "mov", "m4a"].contains(ext)
        // use_metadata_tags keeps custom QuickTime keys (an iPhone video's com.apple.quicktime.*), but then
        // ffmpeg writes no iTunes-style tags, which Music and Finder read. So only files that have such keys get it.
        let keepQuickTimeKeys = isMP4 && sourceTags.contains(where: { $0.key.contains(".") })

        var tagArgs: [String] = []
        for key in changes.keys.sorted() {
            let value = changes[key] ?? ""
            for name in tagNames(for: key, sourceTags: sourceTags, quickTimeKeys: keepQuickTimeKeys) {
                tagArgs += ["-metadata", "\(name)=\(value)"]
                // Ogg ignores container tags when the track has its own, so set both.
                if source.isOgg { tagArgs += ["-metadata:s:a:0", "\(name)=\(value)"] }
            }
        }
        if removeLocation {
            var names = ["location", "location-eng"]
            for tag in sourceTags where isLocationKey(tag.key) && !names.contains(tag.key.lowercased()) {
                names.append(tag.key)
            }
            for name in names {
                tagArgs += ["-metadata", "\(name)="]
                if source.isOgg { tagArgs += ["-metadata:s:a:0", "\(name)="] }
            }
        }
        var formatArgs: [String] = []
        if keepQuickTimeKeys { formatArgs += ["-movflags", "use_metadata_tags"] }
        if ["aiff", "aif", "aac"].contains(ext) { formatArgs += ["-write_id3v2", "1"] } // otherwise only a few tags fit

        let out = OutputPaths.destination(for: input, ext: input.pathExtension, suffix: "tagged", folder: options.outputFolder)
        // Every track as it is. Some containers can't take a source's data tracks (timecode, for example),
        // so the second try keeps just picture, sound and subtitles.
        let mappings = [["-map", "0"], ["-map", "0:v?", "-map", "0:a?", "-map", "0:s?"]]
        var failure: Error?
        for mapping in mappings {
            // Built step by step: one long concatenation is too much for the type checker.
            var args: [String] = ["-hide_banner", "-nostdin", "-y", "-i", input.path]
            args += mapping
            args += ["-c", "copy", "-map_metadata", "0"]
            args += formatArgs
            args += tagArgs
            args.append(out.path)
            do {
                try await Shell.check(ffmpeg, args)
                failure = nil
                break
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: out)
                throw CancellationError()
            } catch {
                failure = error
            }
        }
        if let failure {
            try? FileManager.default.removeItem(at: out)
            throw failure
        }

        // Containers drop tags they have no place for without complaint, so read the copy back.
        let written: MediaBanner
        do {
            written = try await probe(out, ffmpeg: ffmpeg)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        let writtenTags = written.allTags
        var failed: [String] = []
        for key in changes.keys.sorted() {
            let wanted = changes[key] ?? ""
            if !took(wanted, now: tagValue(key, in: writtenTags), before: tagValue(key, in: sourceTags)) {
                failed.append(label(forKey: key).lowercased())
            }
        }
        if removeLocation && mediaLocation(writtenTags) != nil { failed.append("the location removal") }
        guard failed.isEmpty else {
            try? FileManager.default.removeItem(at: out)
            throw ConversionError("Couldn't save \(failed.joined(separator: ", ")) in this \(ext.uppercased()) file.")
        }
        return out
    }

    /// Every name to set for one change: ffmpeg's own key, the spellings the file already uses, and the
    /// QuickTime key Apple's apps read when the file keeps QuickTime keys.
    private static func tagNames(for key: String, sourceTags: [MediaBanner.Tag], quickTimeKeys: Bool) -> [String] {
        var names = [key]
        let aliases = mediaAliases(key)
        for tag in sourceTags where aliases.contains(tag.key.lowercased()) {
            if !names.contains(where: { $0.lowercased() == tag.key.lowercased() }) { names.append(tag.key) }
        }
        if quickTimeKeys && ["title", "artist", "album", "genre", "comment", "copyright"].contains(key) {
            let quickTimeName = "com.apple.quicktime.\(key)"
            if !names.contains(where: { $0.lowercased() == quickTimeName }) { names.append(quickTimeName) }
        }
        return names
    }

    private static func containerName(_ banner: MediaBanner, ext: String) -> String? {
        let raw = banner.container
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("mov,mp4") {
            let brandTag = banner.tags.first(where: { $0.key.lowercased() == "major_brand" })
            let brand = brandTag?.value.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            if brand == "qt" { return "QuickTime movie" }
            if brand.hasPrefix("m4a") || brand.hasPrefix("m4b") { return "MPEG-4 audio" }
            if brand.hasPrefix("3g") { return "3GPP" }
            return "MPEG-4"
        }
        if raw.hasPrefix("matroska") { return ext == "webm" ? "WebM" : "Matroska" }
        let names: [String: String] = [
            "mp3": "MP3", "wav": "WAVE", "flac": "FLAC", "ogg": "Ogg", "aiff": "AIFF", "avi": "AVI",
            "asf": "Windows Media", "flv": "Flash Video", "mpegts": "MPEG transport stream",
            "mpeg": "MPEG program stream", "aac": "AAC (ADTS)", "caf": "Core Audio Format",
        ]
        return names[raw] ?? raw
    }

    /// Splits a stream description at commas outside brackets: "yuv420p(tv, bt709)" stays one part.
    private static func splitDetails(_ details: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in details {
            switch character {
            case "(", "[":
                depth += 1
                current.append(character)
            case ")", "]":
                depth = max(0, depth - 1)
                current.append(character)
            case "," where depth == 0:
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            default:
                current.append(character)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }
        return parts
    }

    /// "h264 (High) (avc1 / 0x31637661)" → "H.264 (High)".
    private static func codecName(_ part: String) -> String {
        var cleaned = part
        if let fourCC = try? NSRegularExpression(pattern: "\\s*\\([^()]*/ 0x[0-9A-Fa-f]+\\)") {
            cleaned = fourCC.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned),
                                                      withTemplate: "")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        let name = String(cleaned.prefix(while: { $0 != " " }))
        let rest = cleaned.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
        let names: [String: String] = [
            "h264": "H.264", "hevc": "HEVC (H.265)", "av1": "AV1", "vp8": "VP8", "vp9": "VP9", "prores": "ProRes",
            "mpeg4": "MPEG-4 Part 2", "mpeg2video": "MPEG-2", "mjpeg": "Motion JPEG", "wmv2": "Windows Media Video 8",
            "aac": "AAC", "mp3": "MP3", "mp3float": "MP3", "opus": "Opus", "vorbis": "Vorbis", "flac": "FLAC",
            "alac": "Apple Lossless", "ac3": "Dolby Digital", "eac3": "Dolby Digital Plus", "wmav2": "Windows Media Audio 2",
            "pcm_s16le": "PCM 16-bit", "pcm_s16be": "PCM 16-bit", "pcm_s24le": "PCM 24-bit", "pcm_s24be": "PCM 24-bit",
            "pcm_f32le": "PCM 32-bit float",
        ]
        let pretty = names[name] ?? name
        return rest.isEmpty ? pretty : "\(pretty) \(rest)"
    }

    /// The "320x240" part of a video description.
    private static func resolution(in parts: [String]) -> String? {
        for part in parts {
            let size = part.prefix(while: { $0 != " " }).split(separator: "x")
            if size.count == 2, let width = Int(size[0]), let height = Int(size[1]), width > 0, height > 0 {
                return "\(width) × \(height)"
            }
        }
        return nil
    }

    private static func frameRate(in parts: [String]) -> String? {
        if let fps = parts.first(where: { $0.hasSuffix(" fps") }) { return fps }
        if let tbr = parts.first(where: { $0.hasSuffix(" tbr") }) { return String(tbr.dropLast(4)) + " fps" }
        return nil
    }

    private static func channelsText(_ raw: String) -> String {
        switch raw {
        case "mono": return "Mono"
        case "stereo": return "Stereo"
        case "1 channels": return "1 channel"
        default:
            if raw.hasPrefix("5.1") { return "5.1 surround" }
            if raw.hasPrefix("7.1") { return "7.1 surround" }
            return raw
        }
    }

    // MARK: PDFs

    private static func pdfAttribute(forKey key: String) -> PDFDocumentAttribute? {
        switch key {
        case "title": return PDFDocumentAttribute.titleAttribute
        case "author": return PDFDocumentAttribute.authorAttribute
        case "subject": return PDFDocumentAttribute.subjectAttribute
        case "keywords": return PDFDocumentAttribute.keywordsAttribute
        case "creator": return PDFDocumentAttribute.creatorAttribute
        default: return nil
        }
    }

    /// documentAttributes with plain string keys, whichever way PDFKit handed them over.
    private static func stringKeyed(_ attributes: [AnyHashable: Any]?) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in attributes ?? [:] {
            if let name = key.base as? String {
                result[name] = value
            } else if let attribute = key.base as? PDFDocumentAttribute {
                result[attribute.rawValue] = value
            }
        }
        return result
    }

    private static func readPDF(_ url: URL) throws -> [MetadataField] {
        let document = try PDFTools.open(url)
        let attributes = stringKeyed(document.documentAttributes)
        var fields = fileFields(url)
        addField("pdf.pages", "Pages", "\(document.pageCount)", in: "File", to: &fields)
        addField("pdf.version", "PDF version", "\(document.majorVersion).\(document.minorVersion)", in: "File", to: &fields)
        if document.isEncrypted { addField("pdf.encrypted", "Encrypted", "Yes", in: "File", to: &fields) }
        for key in pdfKeys {
            guard let attribute = pdfAttribute(forKey: key) else { continue }
            let current = stringValue(attributes[attribute.rawValue]) ?? ""
            if document.isEncrypted {
                addField(key, label(forKey: key), current, in: "Document", to: &fields)
            } else {
                fields.append(MetadataField(key: key, label: label(forKey: key), value: current, editable: true,
                                            section: "Document"))
            }
        }
        addField("pdf.producer", "Producer", stringValue(attributes[PDFDocumentAttribute.producerAttribute.rawValue]),
                 in: "Document", to: &fields)
        if let created = attributes[PDFDocumentAttribute.creationDateAttribute.rawValue] as? Date {
            addField("pdf.created", "Created", dateText(created), in: "Document", to: &fields)
        }
        if let modified = attributes[PDFDocumentAttribute.modificationDateAttribute.rawValue] as? Date {
            addField("pdf.modified", "Modified", dateText(modified), in: "Document", to: &fields)
        }
        return fields
    }

    private static func writePDF(_ changes: [String: String], to input: URL, options: ConversionOptions) throws -> URL {
        for key in changes.keys.sorted() where pdfAttribute(forKey: key) == nil {
            throw ConversionError("“\(key)” isn't something Transmute can edit in PDFs.")
        }
        let document = try PDFTools.open(input)
        if document.isEncrypted {
            throw ConversionError("This PDF is encrypted, and saving a copy here would remove the encryption.")
        }
        let before = stringKeyed(document.documentAttributes)
        var attributes = before
        for (key, value) in changes {
            guard let attribute = pdfAttribute(forKey: key) else { continue }
            if value.isEmpty {
                attributes[attribute.rawValue] = nil
            } else if attribute == PDFDocumentAttribute.keywordsAttribute {
                attributes[attribute.rawValue] = value.split(whereSeparator: { $0 == "," || $0 == ";" })
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            } else {
                attributes[attribute.rawValue] = value
            }
        }
        attributes[PDFDocumentAttribute.modificationDateAttribute.rawValue] = Date()
        var info: [AnyHashable: Any] = [:]
        for (name, value) in attributes { info[AnyHashable(name)] = value }
        document.documentAttributes = info

        let out = OutputPaths.destination(for: input, ext: "pdf", suffix: "tagged", folder: options.outputFolder)
        guard document.write(to: out) else { throw ConversionError("Couldn't save the PDF.") }
        let saved = stringKeyed(PDFDocument(url: out)?.documentAttributes)
        var failed: [String] = []
        for key in changes.keys.sorted() {
            guard let attribute = pdfAttribute(forKey: key) else { continue }
            let wanted = changes[key] ?? ""
            if !took(wanted, now: stringValue(saved[attribute.rawValue]) ?? "",
                     before: stringValue(before[attribute.rawValue]) ?? "") {
                failed.append(label(forKey: key).lowercased())
            }
        }
        guard failed.isEmpty else {
            try? FileManager.default.removeItem(at: out)
            throw ConversionError("Couldn't save \(failed.joined(separator: ", ")) in this PDF.")
        }
        return out
    }

    // MARK: Formatting

    private static func addField(_ key: String, _ label: String, _ value: String?, in section: String,
                                 to fields: inout [MetadataField]) {
        guard let value, !value.isEmpty else { return }
        fields.append(MetadataField(key: key, label: label, value: value, editable: false, section: section))
    }

    private static func locationFields(latitude: Double, longitude: Double, altitude: Double?) -> [MetadataField] {
        var fields: [MetadataField] = []
        addField("gps.latitude", "Latitude", coordinate(latitude, positive: "N", negative: "S"), in: "Location", to: &fields)
        addField("gps.longitude", "Longitude", coordinate(longitude, positive: "E", negative: "W"), in: "Location", to: &fields)
        if let altitude {
            addField("gps.altitude", "Altitude", "\(decimal(altitude, digits: 1)) m", in: "Location", to: &fields)
        }
        return fields
    }

    private static func coordinate(_ degrees: Double, positive: String, negative: String) -> String {
        String(format: "%.6f", abs(degrees)) + "° " + (degrees < 0 ? negative : positive)
    }

    /// Whether a change shows up when the file is read back. Containers sometimes normalise a value
    /// (an ID3 genre number becomes its name), so any new non-empty value counts.
    private static func took(_ wanted: String, now: String, before: String) -> Bool {
        if wanted.isEmpty { return now.isEmpty }
        return now == wanted || (!now.isEmpty && now != before)
    }

    /// Text from a property value: strings, lists of strings and numbers.
    private static func stringValue(_ value: Any?) -> String? {
        guard let value = value else { return nil }
        let raw: String
        if let string = value as? String {
            raw = string
        } else if let list = value as? [String] {
            raw = list.joined(separator: ", ")
        } else if let number = value as? NSNumber {
            raw = number.stringValue
        } else {
            return nil
        }
        let cleaned = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func numberValue(_ value: Any?) -> Double? {
        guard let value = value else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    /// "2.50" → "2.5", "48.000" → "48".
    private static func decimal(_ number: Double, digits: Int = 2) -> String {
        var result = String(format: "%.\(digits)f", number)
        while result.contains("."), result.hasSuffix("0") { result.removeLast() }
        if result.hasSuffix(".") { result.removeLast() }
        return result
    }

    private static func twoDigits(_ number: Int) -> String {
        number < 10 ? "0\(number)" : "\(number)"
    }

    /// "0:03.0", "12:05.4", "1:02:03.0".
    private static func clock(_ seconds: Double) -> String {
        let tenths = seconds.isFinite ? Int((max(0, seconds) * 10).rounded()) : 0
        let whole = tenths / 10
        let h = whole / 3600, m = whole / 60 % 60, s = whole % 60
        let time = h > 0 ? "\(h):\(twoDigits(m)):\(twoDigits(s))" : "\(m):\(twoDigits(s))"
        return "\(time).\(tenths % 10)"
    }

    private static func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Shows what's inside a file (camera, codec, tags, PDF properties) and lets the descriptive fields be
/// changed. Nothing is written here: Save Copy hands the changes to `onSave`.
@MainActor
struct MetadataEditorView: View {
    let url: URL
    let onSave: (MetadataEdit) -> Void
    let onCancel: () -> Void

    @State private var fields: [MetadataField] = []
    @State private var values: [String: String] = [:]
    @State private var removeLocation = false
    @State private var loading = true
    @State private var loadError: String? = nil
    @State private var copied = false

    init(url: URL, onSave: @escaping (MetadataEdit) -> Void, onCancel: @escaping () -> Void) {
        self.url = url
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 520, height: 560)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Changes are saved to a copy; the original isn't touched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView("Reading metadata…")
        } else if let loadError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(loadError)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            .padding(24)
        } else {
            Form {
                ForEach(MetadataTool.sections(of: fields), id: \.self) { section in
                    Section(section) {
                        ForEach(fieldsIn(section)) { field in
                            row(for: field)
                        }
                        if section == "Location" && canRemoveLocation {
                            Toggle("Remove location", isOn: $removeLocation)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder
    private func row(for field: MetadataField) -> some View {
        if field.editable {
            TextField(field.label, text: binding(for: field.key),
                      prompt: MetadataTool.placeholder(forKey: field.key).map { Text($0) }, axis: .vertical)
                .lineLimit(1...4)
        } else {
            LabeledContent(field.label) {
                Text(field.value)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(copied ? "Copied" : "Copy All") { copyAll() }
                .disabled(fields.isEmpty)
                .help("Copies every field as text")
            if let note = problem ?? viewOnlyNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(problem == nil ? Color.secondary : Color.orange)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Cancel") { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button("Save Copy") { onSave(pendingEdit) }
                .buttonStyle(.borderedProminent)
                .disabled(!hasChanges || problem != nil)
        }
        .padding(16)
    }

    // MARK: State

    private func fieldsIn(_ section: String) -> [MetadataField] {
        fields.filter { $0.section == section }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    /// Location can only be removed from files whose metadata this app can write.
    private var canRemoveLocation: Bool {
        MetadataTool.hasLocation(fields) && fields.contains(where: \.editable)
    }

    private func currentText(_ field: MetadataField) -> String {
        (values[field.key] ?? field.value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Editable fields whose text differs from what the file has, keyed for `MetadataEdit`.
    private var pendingChanges: [String: String] {
        var changes: [String: String] = [:]
        for field in fields where field.editable {
            var typed = currentText(field)
            if field.key == "dateTaken", !typed.isEmpty, let normalised = MetadataTool.exifDate(from: typed) {
                typed = normalised
            }
            if typed != field.value.trimmingCharacters(in: .whitespacesAndNewlines) {
                changes[field.key] = typed
            }
        }
        return changes
    }

    private var pendingEdit: MetadataEdit {
        MetadataEdit(changes: pendingChanges, removeLocation: removeLocation && canRemoveLocation)
    }

    private var hasChanges: Bool {
        !pendingChanges.isEmpty || (removeLocation && canRemoveLocation)
    }

    /// Why the changes can't be saved yet, or nil when they can.
    private var problem: String? {
        if let date = fields.first(where: { $0.key == "dateTaken" && $0.editable }) {
            let typed = currentText(date)
            if !typed.isEmpty && MetadataTool.exifDate(from: typed) == nil {
                return "Date taken should look like 2024:05:31 14:30:00."
            }
        }
        return nil
    }

    private var viewOnlyNote: String? {
        guard !loading, loadError == nil, !fields.isEmpty, !fields.contains(where: \.editable) else { return nil }
        return "This file's metadata can be viewed but not edited."
    }

    // MARK: Actions

    private func load() async {
        let target = url
        do {
            let result = try await MetadataTool.read(target)
            guard !Task.isCancelled else { return }
            fields = result
            values = Dictionary(result.filter(\.editable).map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
        }
        loading = false
    }

    private func copyAll() {
        let shown = fields.map { field -> MetadataField in
            var copy = field
            if field.editable { copy.value = currentText(field) }
            return copy
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(MetadataTool.plainText(shown, title: url.lastPathComponent), forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}
