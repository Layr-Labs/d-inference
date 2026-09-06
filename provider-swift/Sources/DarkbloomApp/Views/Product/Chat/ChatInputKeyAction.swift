import AppKit

/// The editor owns all keyboard submission. Marked text always stays with the
/// native input system, including modified Return and numeric-keypad Enter.
enum ChatInputKeyAction: Equatable {
    case system
    case submit
    case newline

    static func resolve(
        keyCode: UInt16, modifiers: NSEvent.ModifierFlags, hasMarkedText: Bool
    ) -> Self {
        guard !hasMarkedText, keyCode == 36 || keyCode == 76 else { return .system }
        let modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.shift) || modifiers.contains(.option) { return .newline }
        return modifiers.contains(.control) ? .system : .submit
    }
}
