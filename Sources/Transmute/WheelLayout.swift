import Foundation

/// Which bubbles each drag wheel shows, and where. A layout is a list of item ids going clockwise
/// from the top; "gap" leaves a position empty so the others stay where the user put them.
/// Ids: "convert:pdf", "tool:edit" (and nobg, half, quarter, clean, split, merge, topdf, qr, zip),
/// "action:airdrop" (and float, copy, copypath, terminal, move). Any item can go on any wheel.
enum WheelLayout {
    static let gap = "gap"
    static let maxSlots = 12
    static let prefKey = "wheelLayouts"

    static let tools = ["edit", "nobg", "half", "quarter", "clean", "split", "merge", "topdf", "qr", "zip"]
    static let actions = FileAction.allCases.map(\.id)

    /// Where a customized layout is kept in the saved dictionary: "convert.document", "tools.image"…
    static func key(_ wheel: WheelKind, _ kind: FileKind) -> String { "\(wheel.id).\(kind.rawValue)" }

    static func convertID(_ format: OutputFormat) -> String { "convert:" + format.rawValue }

    static func format(of id: String) -> OutputFormat? {
        id.hasPrefix("convert:") ? OutputFormat(rawValue: String(id.dropFirst("convert:".count))) : nil
    }

    /// The layout Spinform ships with, the same as before wheels could be customized.
    static func defaultLayout(_ wheel: WheelKind, _ kind: FileKind) -> [String] {
        switch wheel {
        case .convert: kind.convertTargets.prefix(10).map(convertID)
        case .tools: tools.filter { toolFits($0, [kind], count: 2) }.map { "tool:" + $0 }
        case .actions: (toolFits("edit", [kind], count: 1) ? ["tool:edit"] : []) + actions.map { "action:" + $0 }
        }
    }

    /// Everything that can go on a wheel for this kind of file: formats, then tools, then actions.
    static func available(_ kind: FileKind) -> [String] {
        kind.convertTargets.map(convertID)
            + tools.filter { toolFits($0, [kind], count: 2) }.map { "tool:" + $0 }
            + actions.map { "action:" + $0 }
    }

    /// Whether an item works for every one of these files.
    static func fits(_ id: String, _ kinds: [FileKind]) -> Bool {
        if id == gap { return true }
        if let format = format(of: id) { return kinds.allSatisfy { $0.convertTargets.contains(format) } }
        if id.hasPrefix("tool:") { return toolFits(String(id.dropFirst(5)), kinds, count: kinds.count) }
        return id.hasPrefix("action:") && actions.contains(String(id.dropFirst(7)))
    }

    private static func toolFits(_ tool: String, _ kinds: [FileKind], count: Int) -> Bool {
        switch tool {
        case "half", "quarter": kinds.allSatisfy(\.canCompress)
        case "clean": kinds.allSatisfy(\.canStripMetadata)
        case "split": kinds.allSatisfy { $0 == .pdf }
        case "merge": kinds.allSatisfy { $0 == .pdf } && count > 1
        case "topdf", "qr", "nobg": kinds.allSatisfy { $0 == .image }
        case "zip": true
        case "edit": kinds.allSatisfy { [.image, .video, .audio].contains($0) }
        default: false
        }
    }

    /// A saved layout cleaned up: unknown or repeated items dropped and at most maxSlots positions.
    /// Empty positions stay, even at the end: they decide where the others sit.
    static func clean(_ ids: [String], _ kind: FileKind) -> [String] {
        let available = Set(available(kind))
        var seen = Set<String>()
        return Array(ids.filter { $0 == gap || (available.contains($0) && seen.insert($0).inserted) }.prefix(maxSlots))
    }

    /// The positions to draw for these files: the user's layout for the first file's kind (or the
    /// default), with anything that doesn't suit all of the files left out. In a customized layout
    /// those become empty positions, so the rest stay where the user put them. Empty when nothing is left.
    static func resolve(_ wheel: WheelKind, _ kinds: [FileKind], custom: [String: [String]]?) -> [String] {
        guard let first = kinds.first else { return [] }
        if let saved = custom?[key(wheel, first)] {
            let slots = clean(saved, first).map { fits($0, kinds) ? $0 : gap }
            return slots.contains { $0 != gap } ? slots : []
        }
        // The default for mixed files: the formats they have in common, as before.
        if wheel == .convert {
            return Array(first.convertTargets.map(convertID).filter { fits($0, kinds) }.prefix(10))
        }
        return defaultLayout(wheel, first).filter { fits($0, kinds) }
    }

    // MARK: Saved layouts

    static var saved: [String: [String]] {
        get { UserDefaults.standard.dictionary(forKey: prefKey) as? [String: [String]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: prefKey) }
    }

    static func layout(_ wheel: WheelKind, _ kind: FileKind) -> [String] {
        saved[key(wheel, kind)].map { clean($0, kind) } ?? defaultLayout(wheel, kind)
    }

    static func isCustom(_ wheel: WheelKind, _ kind: FileKind) -> Bool { saved[key(wheel, kind)] != nil }

    /// Saves a layout; one that matches the default is stored as "not customized".
    static func save(_ slots: [String], _ wheel: WheelKind, _ kind: FileKind) {
        var all = saved
        all[key(wheel, kind)] = slots == defaultLayout(wheel, kind) ? nil : slots
        saved = all
    }

    static func reset(_ wheel: WheelKind, _ kind: FileKind) {
        var all = saved
        all[key(wheel, kind)] = nil
        saved = all
    }
}
