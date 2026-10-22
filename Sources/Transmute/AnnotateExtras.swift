import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Pictures placed on a canvas

/// Decoded pictures for `.picture` annotations, so the live overlay doesn't decode on every frame.
enum PictureCache {
    private static let cache = NSCache<NSString, CGImageBox>()

    private final class CGImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    static func image(atPath path: String) -> CGImage? {
        if let hit = cache.object(forKey: path as NSString) { return hit.image }
        guard let image = try? ImageConverter.loadCGImage(URL(fileURLWithPath: path)) else { return nil }
        cache.setObject(CGImageBox(image), forKey: path as NSString)
        return image
    }
}

enum PicturePlacement {
    /// Where a dropped picture goes: a third of the canvas wide (at most its own size), centred on the
    /// drop point, kept inside the canvas. Normalized, top-left origin.
    static func rect(pictureSize: CGSize, canvas: CGSize, centre: CGPoint) -> NormRect {
        let cw = max(canvas.width, 1), ch = max(canvas.height, 1)
        var width = cw / 3
        var height = width * pictureSize.height / max(pictureSize.width, 1)
        if height > ch * 0.6 {
            height = ch * 0.6
            width = height * pictureSize.width / max(pictureSize.height, 1)
        }
        let x = min(max(centre.x - width / 2, 0), max(0, cw - width))
        let y = min(max(centre.y - height / 2, 0), max(0, ch - height))
        return NormRect(x: Double(x / cw), y: Double(y / ch), width: Double(width / cw), height: Double(height / ch))
    }
}

// MARK: - Pencil smoothing

/// Turns a shaky freehand stroke into a smooth one: a light moving average takes out the jitter,
/// then points that add nothing to the shape are dropped (Ramer–Douglas–Peucker), and the
/// renderer joins what's left with curves through the midpoints.
enum StrokeSmoothing {
    static func smooth(_ points: [NormPoint], tolerance: Double = 0.0012) -> [NormPoint] {
        guard points.count > 2 else { return points }
        var averaged = points
        for i in 1..<(points.count - 1) {
            let lo = max(0, i - 2), hi = min(points.count - 1, i + 2)
            let window = points[lo...hi]
            let n = Double(window.count)
            averaged[i] = NormPoint(x: window.map(\.x).reduce(0, +) / n, y: window.map(\.y).reduce(0, +) / n)
        }
        return simplify(averaged, tolerance: tolerance)
    }

    static func simplify(_ points: [NormPoint], tolerance: Double) -> [NormPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            var worst = 0.0
            var index = first
            for i in (first + 1)..<last {
                let d = distance(points[i], toSegment: points[first], points[last])
                if d > worst { worst = d; index = i }
            }
            if worst > tolerance {
                keep[index] = true
                stack.append((first, index))
                stack.append((index, last))
            }
        }
        return points.enumerated().filter { keep[$0.offset] }.map(\.element)
    }

    static func distance(_ p: NormPoint, toSegment a: NormPoint, _ b: NormPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return ((p.x - a.x) * (p.x - a.x) + (p.y - a.y) * (p.y - a.y)).squareRoot() }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        let cx = a.x + t * dx, cy = a.y + t * dy
        return ((p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy)).squareRoot()
    }

    /// Quadratic curves through the midpoints between points, starting and ending on the stroke's ends.
    static func path(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            if points.count == 2 { path.addLine(to: points[1]) }
            return path
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}

// MARK: - Highlighter that fits the text

enum TextSnap {
    /// The highlight for a drag over text: the lines it covers (at least 40% of a line's height),
    /// from the drag's left edge to its right edge but no further than the text, with a little room
    /// above and below. nil when the drag isn't over any text.
    static func fit(_ drag: NormRect, to lines: [NormRect]) -> NormRect? {
        let hits = lines.filter { line in
            let overlapY = min(drag.maxY, line.maxY) - max(drag.minY, line.minY)
            let overlapX = min(drag.maxX, line.maxX) - max(drag.minX, line.minX)
            return overlapX > 0 && overlapY >= line.height * 0.4
        }
        guard !hits.isEmpty else { return nil }
        let top = hits.map(\.minY).min() ?? drag.minY
        let bottom = hits.map(\.maxY).max() ?? drag.maxY
        let left = max(drag.minX, hits.map(\.minX).min() ?? drag.minX)
        let right = min(drag.maxX, hits.map(\.maxX).max() ?? drag.maxX)
        let pad = (hits.map(\.height).min() ?? 0) * 0.12
        guard right > left else { return nil }
        return NormRect(x: left, y: top - pad, width: right - left, height: bottom - top + pad * 2).clamped
    }
}

// MARK: - Crop snapping

/// Crop edges snap to the picture's edges and centre lines when they come close.
enum CropSnap {
    static let threshold = 0.015
    static let targets: [Double] = [0, 0.5, 1]

    static func snap(_ value: Double) -> Double {
        for target in targets where abs(value - target) < threshold { return target }
        return value
    }

    static func snapPoint(_ p: NormPoint) -> NormPoint { NormPoint(x: snap(p.x), y: snap(p.y)) }

    /// A crop box being moved: the nearest edge (or the centre) snaps, keeping its size.
    static func snapMove(_ r: NormRect) -> NormRect {
        func offset(_ low: Double, _ mid: Double, _ high: Double) -> Double {
            var best = 0.0
            var bestDistance = threshold
            for value in [low, mid, high] {
                for target in targets where abs(value - target) < bestDistance {
                    best = target - value
                    bestDistance = abs(value - target)
                }
            }
            return best
        }
        let dx = offset(r.minX, r.midX, r.maxX), dy = offset(r.minY, r.midY, r.maxY)
        return NormRect(x: r.x + dx, y: r.y + dy, width: r.width, height: r.height)
    }
}

// MARK: - My colours

/// Colours the user keeps for markup, beside the built-in swatches (up to ten).
enum MarkupPalette {
    private static let key = "markupCustomColors"
    static let limit = 10

    static func colors(defaults: UserDefaults = .standard) -> [RGBAColor] {
        (defaults.array(forKey: key) as? [Int] ?? []).map { RGBAColor(hex: UInt32(truncatingIfNeeded: $0)) }
    }

    static func add(_ color: RGBAColor, defaults: UserDefaults = .standard) {
        var hexes = defaults.array(forKey: key) as? [Int] ?? []
        let hex = Int(color.hexValue)
        hexes.removeAll { $0 == hex }
        hexes.append(hex)
        defaults.set(Array(hexes.suffix(limit)), forKey: key)
    }

    static func remove(_ color: RGBAColor, defaults: UserDefaults = .standard) {
        let hexes = (defaults.array(forKey: key) as? [Int] ?? []).filter { $0 != Int(color.hexValue) }
        defaults.set(hexes, forKey: key)
    }
}

// MARK: - Drag the result out

enum EditedDrag {
    /// A drag item that renders the edited picture only when it's dropped somewhere.
    static func provider(for url: URL, edit: ImageEdit) -> NSItemProvider {
        let provider = NSItemProvider()
        let name = url.deletingPathExtension().lastPathComponent + " edited"
        provider.suggestedName = name
        provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { done in
            Task.detached(priority: .userInitiated) {
                do {
                    let image = try ImageEditEngine.render(edit, on: try ImageConverter.loadCGImage(url))
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Spinform Drags", isDirectory: true)
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let out = folder.appendingPathComponent(name + ".png")
                    try ImageConverter.data(from: image, type: .png).write(to: out, options: .atomic)
                    done(out, false, nil)
                } catch {
                    done(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }
}

// MARK: - Project files

/// A .spinform project: the original picture and every edit, still editable when it's opened again.
/// One JSON file, so it can be mailed or kept next to the picture. Pictures dropped onto the canvas
/// travel inside it too.
struct SpinformProject: Codable {
    static let fileExtension = "spinform"
    static let typeIdentifier = "local.personal.transmute.project"
    static var contentType: UTType {
        UTType(typeIdentifier) ?? UTType(exportedAs: typeIdentifier, conformingTo: .data)
    }
    static let formatName = "spinform-project"

    var format = SpinformProject.formatName
    var version = 1
    var imageName: String
    var image: Data
    var edit: ImageEdit
    /// Dropped pictures, by the name their annotation uses inside the project.
    var pictures: [String: Data] = [:]

    static func make(image url: URL, edit: ImageEdit) throws -> SpinformProject {
        var stored = edit
        var pictures: [String: Data] = [:]
        for index in stored.annotations.indices {
            guard case .picture(let path, let rect) = stored.annotations[index].kind else { continue }
            let file = URL(fileURLWithPath: path)
            guard let data = try? Data(contentsOf: file) else { continue }
            let key = "\(index)-\(file.lastPathComponent)"
            pictures[key] = data
            stored.annotations[index].kind = .picture(key, rect)
        }
        return SpinformProject(imageName: url.lastPathComponent, image: try Data(contentsOf: url), edit: stored, pictures: pictures)
    }

    static func save(image url: URL, edit: ImageEdit, to target: URL) throws {
        let project = try make(image: url, edit: edit)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(project).write(to: target, options: .atomic)
    }

    /// Unpacks a project into a folder of its own: the picture to edit and the edit to start from.
    static func open(_ url: URL, into folder: URL? = nil) throws -> (image: URL, edit: ImageEdit) {
        let data = try Data(contentsOf: url)
        let project: SpinformProject
        do {
            project = try JSONDecoder().decode(SpinformProject.self, from: data)
        } catch {
            throw ConversionError("\(url.lastPathComponent) isn't a Spinform project.")
        }
        guard project.format == formatName else { throw ConversionError("\(url.lastPathComponent) isn't a Spinform project.") }
        guard project.version <= 1 else { throw ConversionError("This project was made by a newer Spinform. Update Spinform to open it.") }
        let base = folder ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Spinform/Projects", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let name = (project.imageName as NSString).lastPathComponent
        let image = base.appendingPathComponent(name.isEmpty ? "picture.png" : name)
        try project.image.write(to: image, options: .atomic)
        var edit = project.edit
        for index in edit.annotations.indices {
            guard case .picture(let key, let rect) = edit.annotations[index].kind, let bytes = project.pictures[key] else { continue }
            let file = base.appendingPathComponent("picture-" + (key as NSString).lastPathComponent)
            try bytes.write(to: file, options: .atomic)
            edit.annotations[index].kind = .picture(file.path, rect)
        }
        return (image, edit)
    }
}
