import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Everything the capture tools can do from a shortcut, the menu bar or the Capture tab.
enum CaptureAction: String, CaseIterable, Identifiable {
    case allInOne, area, window, fullscreen, previous, scrolling, text, recordArea, recordWindow, recordScreen, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allInOne: "All-in-One Capture"
        case .area: "Capture Area"
        case .window: "Capture Window"
        case .fullscreen: "Capture Full Screen"
        case .previous: "Capture Previous Area"
        case .scrolling: "Scrolling Capture"
        case .text: "Copy Text from Screen"
        case .recordArea: "Record Area"
        case .recordWindow: "Record Window"
        case .recordScreen: "Record Full Screen"
        case .history: "Capture History"
        }
    }

    /// Short name for tiles.
    var shortTitle: String {
        switch self {
        case .allInOne: "All-in-One"
        case .area: "Area"
        case .window: "Window"
        case .fullscreen: "Full Screen"
        case .previous: "Previous Area"
        case .scrolling: "Scrolling"
        case .text: "Copy Text"
        case .recordArea: "Area"
        case .recordWindow: "Window"
        case .recordScreen: "Full Screen"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .allInOne: "square.grid.3x3.square"
        case .area: "rectangle.dashed"
        case .window: "macwindow"
        case .fullscreen: "display"
        case .previous: "arrow.counterclockwise.circle"
        case .scrolling: "arrow.up.and.down.text.horizontal"
        case .text: "text.viewfinder"
        case .recordArea: "rectangle.dashed.badge.record"
        case .recordWindow: "macwindow.badge.plus"
        case .recordScreen: "record.circle"
        case .history: "clock.arrow.circlepath"
        }
    }

    /// Control-Shift with the same numbers as macOS's ⌘⇧3/4/5, so nothing clashes.
    var defaultHotkey: Hotkey? {
        switch self {
        case .allInOne: Hotkey(keyCode: 19, modifiers: [.control, .shift])
        case .fullscreen: Hotkey(keyCode: 20, modifiers: [.control, .shift])
        case .area: Hotkey(keyCode: 21, modifiers: [.control, .shift])
        case .recordArea: Hotkey(keyCode: 23, modifiers: [.control, .shift])
        case .window: Hotkey(keyCode: 22, modifiers: [.control, .shift])
        case .previous: Hotkey(keyCode: 26, modifiers: [.control, .shift])
        case .scrolling: Hotkey(keyCode: 28, modifiers: [.control, .shift])
        case .text: Hotkey(keyCode: 25, modifiers: [.control, .shift])
        case .history: Hotkey(keyCode: 29, modifiers: [.control, .shift])
        case .recordWindow, .recordScreen: nil
        }
    }
}

/// A key with modifiers, stored as text like "ctrl+shift+4".
struct Hotkey: Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection([.command, .option, .control, .shift])
    }

    static func == (a: Hotkey, b: Hotkey) -> Bool {
        a.keyCode == b.keyCode && a.modifiers.rawValue == b.modifiers.rawValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers.rawValue)
    }

    /// Key codes and their names, for storing and showing shortcuts.
    static let keyNames: [UInt32: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M",
        45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 42: "\\", 50: "`",
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        123: "Left", 124: "Right", 125: "Down", 126: "Up",
    ]

    private static let functionKeys: Set<UInt32> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113]

    private static let symbols: [String: String] = [
        "Space": "Space", "Return": "↩", "Tab": "⇥", "Delete": "⌫", "Left": "←", "Right": "→", "Down": "↓", "Up": "↑",
    ]

    var keyName: String { Self.keyNames[keyCode] ?? "Key \(keyCode)" }

    /// Global shortcuts need ⌘, ⌃ or ⌥ (Shift alone would take over normal typing), except F-keys.
    var isUsable: Bool {
        guard Self.keyNames[keyCode] != nil else { return false }
        return Self.functionKeys.contains(keyCode) || !modifiers.intersection([.command, .option, .control]).isEmpty
    }

    /// "⌃⇧4", in the order macOS menus use.
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + (Self.symbols[keyName] ?? keyName)
    }

    /// "ctrl+shift+4"
    var storageString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(keyName.lowercased())
        return parts.joined(separator: "+")
    }

    init?(string: String) {
        let parts = string.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty else { return nil }
        var flags: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            switch part {
            case "ctrl", "control", "⌃": flags.insert(.control)
            case "alt", "opt", "option", "⌥": flags.insert(.option)
            case "shift", "⇧": flags.insert(.shift)
            case "cmd", "command", "⌘": flags.insert(.command)
            default: return nil
            }
        }
        guard let code = Self.keyNames.first(where: { $0.value.lowercased() == last })?.key else { return nil }
        self.init(keyCode: code, modifiers: flags)
        guard isUsable else { return nil }
    }

    /// For SwiftUI menus. nil for keys a menu can't show.
    var keyEquivalent: KeyEquivalent? {
        let name = keyName
        if name.count == 1, let character = name.lowercased().first { return KeyEquivalent(character) }
        switch name {
        case "Space": return .space
        case "Return": return .return
        case "Tab": return .tab
        case "Delete": return .delete
        case "Left": return .leftArrow
        case "Right": return .rightArrow
        case "Up": return .upArrow
        case "Down": return .downArrow
        default: return nil
        }
    }

    var eventModifiers: SwiftUI.EventModifiers {
        var result: SwiftUI.EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        return result
    }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    /// macOS's own screenshot shortcuts, which Spinform must not take.
    static let reserved: [Hotkey] = [
        Hotkey(keyCode: 20, modifiers: [.command, .shift]), Hotkey(keyCode: 21, modifiers: [.command, .shift]),
        Hotkey(keyCode: 23, modifiers: [.command, .shift]), Hotkey(keyCode: 22, modifiers: [.command, .shift]),
        Hotkey(keyCode: 20, modifiers: [.command, .shift, .control]), Hotkey(keyCode: 21, modifiers: [.command, .shift, .control]),
    ]
}

/// Which shortcut each action has. Unset means the default; an empty string means none.
enum HotkeyStore {
    static func key(for action: CaptureAction) -> String { "hotkey.\(action.rawValue)" }

    static func hotkey(for action: CaptureAction, defaults: UserDefaults = .standard) -> Hotkey? {
        guard let stored = defaults.string(forKey: key(for: action)) else { return action.defaultHotkey }
        return stored.isEmpty ? nil : Hotkey(string: stored)
    }

    static func set(_ hotkey: Hotkey?, for action: CaptureAction, defaults: UserDefaults = .standard) {
        defaults.set(hotkey?.storageString ?? "", forKey: key(for: action))
    }

    static func reset(_ action: CaptureAction, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(for: action))
    }

    /// Actions that share a shortcut with another action.
    static func clashes(defaults: UserDefaults = .standard) -> Set<CaptureAction> {
        var seen: [Hotkey: CaptureAction] = [:]
        var clashing = Set<CaptureAction>()
        for action in CaptureAction.allCases {
            guard let hotkey = hotkey(for: action, defaults: defaults) else { continue }
            if let other = seen[hotkey] {
                clashing.insert(action)
                clashing.insert(other)
            } else {
                seen[hotkey] = action
            }
        }
        return clashing
    }
}

private let spinformHotkeySignature: OSType = 0x5350_464D // "SPFM"

/// Global shortcuts through Carbon's RegisterEventHotKey, which needs no Accessibility permission.
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    var onAction: ((CaptureAction) -> Void)?
    /// Actions whose shortcut another app already owns.
    private(set) var unavailable = Set<CaptureAction>()
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var suspended = false

    func start() {
        installHandler()
        reload()
    }

    func reload() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        unavailable.removeAll()
        guard !suspended else { return }
        for (index, action) in CaptureAction.allCases.enumerated() {
            guard let hotkey = HotkeyStore.hotkey(for: action) else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: spinformHotkeySignature, id: UInt32(index + 1))
            let status = RegisterEventHotKey(hotkey.keyCode, hotkey.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
            } else {
                unavailable.insert(action)
            }
        }
    }

    /// Off while a shortcut is being recorded in Settings, so the old one doesn't fire.
    func suspend(_ suspend: Bool) {
        suspended = suspend
        reload()
    }

    fileprivate func fire(index: Int) {
        let actions = CaptureAction.allCases
        guard actions.indices.contains(index) else { return }
        let action = actions[index]
        onAction?(action)
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_: EventHandlerCallRef?, event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == spinformHotkeySignature else { return OSStatus(eventNotHandledErr) }
            let index = Int(hotKeyID.id) - 1
            Task { @MainActor in HotkeyCenter.shared.fire(index: index) }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}

// MARK: - Recorder

/// A shortcut field for Settings: click, then press the keys.
struct HotkeyField: View {
    let action: CaptureAction
    var onChange: () -> Void = {}

    @State private var hotkey: Hotkey?
    @State private var recording = false
    @State private var monitor: Any?
    @State private var problem: String?

    init(action: CaptureAction, onChange: @escaping () -> Void = {}) {
        self.action = action
        self.onChange = onChange
        _hotkey = State(initialValue: HotkeyStore.hotkey(for: action))
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stopRecording() : startRecording()
            } label: {
                Text(recording ? "Press keys…" : (hotkey?.display ?? "None"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(recording ? Theme.accentText : (hotkey == nil ? Theme.textTertiary : Theme.textPrimary))
                    .frame(minWidth: 74)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .fill(recording ? Theme.accent.opacity(0.12) : Theme.surfaceRaised))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .strokeBorder(recording ? Theme.accent : Theme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(problem ?? "Click, then press the new shortcut. Esc cancels, Delete clears it.")
            Button {
                HotkeyStore.reset(action)
                hotkey = HotkeyStore.hotkey(for: action)
                changed()
            } label: {
                Image(systemName: "arrow.uturn.backward.circle")
            }
            .buttonStyle(.borderless)
            .disabled(hotkey == action.defaultHotkey)
            .help("Back to the default shortcut")
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        problem = nil
        HotkeyCenter.shared.suspend(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) }
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.keyCode {
        case 53:
            stopRecording()
        case 51 where event.modifierFlags.intersection([.command, .option, .control]).isEmpty:
            HotkeyStore.set(nil, for: action)
            hotkey = nil
            stopRecording()
            changed()
        default:
            let candidate = Hotkey(keyCode: UInt32(event.keyCode), modifiers: event.modifierFlags)
            if Hotkey.reserved.contains(candidate) {
                problem = "\(candidate.display) belongs to macOS's own screenshots."
                NSSound.beep()
            } else if candidate.isUsable {
                HotkeyStore.set(candidate, for: action)
                hotkey = candidate
                stopRecording()
                changed()
            } else {
                problem = "Use ⌘, ⌃ or ⌥ with a key."
                NSSound.beep()
            }
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            HotkeyCenter.shared.suspend(false)
        }
    }

    private func changed() {
        HotkeyCenter.shared.reload()
        onChange()
    }
}
