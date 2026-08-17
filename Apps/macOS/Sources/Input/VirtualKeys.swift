import Carbon.HIToolbox
import CoreGraphics
import MacLinkKit

/// Maps the protocol's key vocabulary onto macOS virtual key codes.
enum VirtualKeys {

    static func code(for special: SpecialKey) -> CGKeyCode {
        switch special {
        case .returnKey: return CGKeyCode(kVK_Return)
        case .enterKey: return CGKeyCode(kVK_ANSI_KeypadEnter)
        case .tab: return CGKeyCode(kVK_Tab)
        case .space: return CGKeyCode(kVK_Space)
        case .escape: return CGKeyCode(kVK_Escape)
        case .delete: return CGKeyCode(kVK_Delete)
        case .forwardDelete: return CGKeyCode(kVK_ForwardDelete)
        case .up: return CGKeyCode(kVK_UpArrow)
        case .down: return CGKeyCode(kVK_DownArrow)
        case .left: return CGKeyCode(kVK_LeftArrow)
        case .right: return CGKeyCode(kVK_RightArrow)
        case .home: return CGKeyCode(kVK_Home)
        case .end: return CGKeyCode(kVK_End)
        case .pageUp: return CGKeyCode(kVK_PageUp)
        case .pageDown: return CGKeyCode(kVK_PageDown)
        case .f1: return CGKeyCode(kVK_F1)
        case .f2: return CGKeyCode(kVK_F2)
        case .f3: return CGKeyCode(kVK_F3)
        case .f4: return CGKeyCode(kVK_F4)
        case .f5: return CGKeyCode(kVK_F5)
        case .f6: return CGKeyCode(kVK_F6)
        case .f7: return CGKeyCode(kVK_F7)
        case .f8: return CGKeyCode(kVK_F8)
        case .f9: return CGKeyCode(kVK_F9)
        case .f10: return CGKeyCode(kVK_F10)
        case .f11: return CGKeyCode(kVK_F11)
        case .f12: return CGKeyCode(kVK_F12)
        }
    }

    /// US-ANSI layout positions. Shortcuts are defined by physical key position on macOS — ⌘Z is
    /// "the key where Z sits on a US board" — so a fixed table is the correct behaviour here, not a
    /// bug. Free text typing goes through `keyboardSetUnicodeString` instead and stays layout-agnostic.
    private static let ansi: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket,
        "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash, ";": kVK_ANSI_Semicolon,
        "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
        "`": kVK_ANSI_Grave, " ": kVK_Space,
    ]

    static func code(forCharacter character: String) -> CGKeyCode? {
        guard let first = character.lowercased().first, let code = ansi[first] else { return nil }
        return CGKeyCode(code)
    }

    /// The physical modifier keys behind a `KeyModifiers` set, in the order a person would press
    /// them. Needed because system shortcuts only react to real modifier key events.
    static func modifierKeyCodes(for modifiers: KeyModifiers) -> [(code: CGKeyCode, flag: CGEventFlags)] {
        var keys: [(CGKeyCode, CGEventFlags)] = []
        if modifiers.contains(.function) { keys.append((CGKeyCode(kVK_Function), .maskSecondaryFn)) }
        if modifiers.contains(.control) { keys.append((CGKeyCode(kVK_Control), .maskControl)) }
        if modifiers.contains(.option) { keys.append((CGKeyCode(kVK_Option), .maskAlternate)) }
        if modifiers.contains(.shift) { keys.append((CGKeyCode(kVK_Shift), .maskShift)) }
        if modifiers.contains(.command) { keys.append((CGKeyCode(kVK_Command), .maskCommand)) }
        return keys
    }

    static func flags(for modifiers: KeyModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }
}

/// `NX_KEYTYPE_*` selectors for the system-defined media event. These come from IOKit's
/// `ev_keymap.h`, which has no Swift overlay.
enum MediaKey: Int32 {
    case soundUp = 0
    case soundDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case mute = 7
    case play = 16
    case next = 17
    case previous = 18
    case illuminationUp = 21
    case illuminationDown = 22
}
