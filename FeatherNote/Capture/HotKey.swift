import AppKit
import Carbon.HIToolbox

/// A key combination for a global shortcut, in Carbon terms (`RegisterEventHotKey`).
struct Shortcut: Equatable, Codable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// ⌥⌘N
    static let quickNoteDefault = Shortcut(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(cmdKey | optionKey))

    /// Stored in UserDefaults as "<keyCode>:<modifiers>".
    var stored: String { "\(keyCode):\(modifiers)" }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(stored: String) {
        let parts = stored.split(separator: ":")
        guard parts.count == 2, let k = UInt32(parts[0]), let m = UInt32(parts[1]), m != 0 else { return nil }
        self.init(keyCode: k, modifiers: m)
    }

    /// From a key-down event; nil unless ⌘, ⌥ or ⌃ is held.
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        guard m != 0 else { return nil }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: m)
    }

    /// "⌥⌘N", in the system's modifier order.
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let letters: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
            kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
            kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_Space: "Space", kVK_Return: "↩", kVK_ANSI_Period: ".", kVK_ANSI_Comma: ",", kVK_ANSI_Slash: "/",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_Grave: "`", kVK_ANSI_Backslash: "\\",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        return letters[Int(code)] ?? "Key \(code)"
    }
}

enum HotKeyError: Error, Equatable {
    /// Another app (or another registration) holds this combination.
    case unavailable
}

/// A system-wide shortcut. Registered with `kEventHotKeyExclusive`, so a combination another app holds fails.
/// Unregisters when released.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    init(shortcut: Shortcut, action: @escaping () -> Void) throws {
        Self.installHandler()
        id = Self.nextID
        Self.nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x464E_4F54) /* "FNOT" */, id: id)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(),
                                         OptionBits(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else { throw HotKeyError.unavailable }
        self.ref = ref
        Self.actions[id] = action
    }

    isolated deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.actions[id] = nil
    }

    /// Shortcuts macOS itself uses and has enabled (Spotlight, input sources, screenshots…), from the symbolic
    /// hotkeys. Another app's ordinary registration can't be detected through the public API.
    static func systemShortcuts() -> [Shortcut] {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr, let list = array?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard (d[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = (d[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value,
                  let mods = (d[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value,
                  code != 0xFFFF, mods != 0 else { return nil }
            return Shortcut(keyCode: code, modifiers: mods & UInt32(cmdKey | optionKey | controlKey | shiftKey))
        }
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.actions[id]?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
