import Cocoa

/// A real key combo (⌃⌥⇧⌘ + a key), stored for Trigger ▸ Keyboard shortcut.
struct Shortcut: Equatable {
    let keyCode: Int64
    let flags: CGEventFlags

    private static let modifierBits: CGEventFlags = [
        .maskCommand, .maskControl, .maskAlternate, .maskShift,
    ]

    private static let keyCodeDefaults = "shortcutKeyCode"
    private static let flagsDefaults = "shortcutFlags"

    static var saved: Shortcut? {
        guard UserDefaults.standard.object(forKey: keyCodeDefaults) != nil else { return nil }
        let code = Int64(UserDefaults.standard.integer(forKey: keyCodeDefaults))
        let raw = (UserDefaults.standard.object(forKey: flagsDefaults) as? NSNumber)?.uint64Value ?? 0
        return Shortcut(keyCode: code, flags: CGEventFlags(rawValue: raw))
    }

    func save() {
        UserDefaults.standard.set(Int(keyCode), forKey: Self.keyCodeDefaults)
        UserDefaults.standard.set(NSNumber(value: flags.rawValue), forKey: Self.flagsDefaults)
    }

    static func from(event: CGEvent) -> Shortcut {
        Shortcut(
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            flags: event.flags.intersection(modifierBits)
        )
    }

    func matches(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.keyboardEventKeycode) == keyCode
            && event.flags.intersection(Self.modifierBits) == flags
    }

    /// Bare letters would steal typing. Function keys, or anything with a modifier, are fine.
    var isUsable: Bool {
        if !flags.isEmpty { return !Self.isModifierKey(keyCode) }
        return Self.functionKeys.contains(keyCode)
    }

    var display: String {
        var s = ""
        if flags.contains(.maskControl) { s += "⌃" }
        if flags.contains(.maskAlternate) { s += "⌥" }
        if flags.contains(.maskShift) { s += "⇧" }
        if flags.contains(.maskCommand) { s += "⌘" }
        s += Self.name(for: keyCode)
        return s
    }

    private static let functionKeys: Set<Int64> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
        105, 107, 113, 106, 64, 79, 80,
    ]

    static func isModifierKey(_ code: Int64) -> Bool {
        [54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 179].contains(code)
    }

    private static func name(for code: Int64) -> String {
        switch code {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 52: return "⌤"
        case 53: return "⎋"
        case 63, 179: return "🌐"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 105: return "F13"
        case 106: return "F16"
        case 107: return "F14"
        case 109: return "F10"
        case 111: return "F12"
        case 113: return "F15"
        case 114: return "Help"
        case 115: return "↖"
        case 116: return "⇞"
        case 117: return "⌦"
        case 118: return "F4"
        case 119: return "↘"
        case 120: return "F2"
        case 121: return "⇟"
        case 122: return "F1"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 64: return "F17"
        case 79: return "F18"
        case 80: return "F19"
        default:
            let letters: [Int64: String] = [
                0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
                8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
                16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
                23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
                30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
                38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
                45: "N", 46: "M", 47: ".", 50: "`",
            ]
            return letters[code] ?? "Key \(code)"
        }
    }
}
