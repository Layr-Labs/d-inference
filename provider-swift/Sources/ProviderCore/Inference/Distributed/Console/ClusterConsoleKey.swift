import Foundation

public enum ClusterConsoleKey: Equatable, Sendable {
    /// A printable ASCII character.
    case character(Character)
    case enter, escape, tab, backspace
    case up, down, left, right, pageUp, pageDown, home, end
    /// Ctrl-C. The screen runs without terminal signals, so it arrives as a byte.
    case interrupt
    /// Ctrl-D.
    case endOfInput
    /// A control byte, a non-ASCII character or an escape sequence the screen
    /// has no use for. It is consumed whole and does nothing.
    case unknown
}

/// Turns terminal input bytes into keys. An escape sequence may arrive split
/// across reads, so an unfinished one is kept until the rest arrives or
/// `flush` says nothing more is coming.
public struct ClusterConsoleKeyDecoder: Sendable {
    /// Longer than any sequence a terminal sends for a key; a longer one is dropped.
    static let maximumSequenceBytes = 32
    private static let escape: UInt8 = 0x1B

    private var pending = [UInt8]()

    public init() {}

    /// Whether an unfinished sequence is waiting for more bytes.
    public var hasPending: Bool { !pending.isEmpty }

    public mutating func feed(_ bytes: [UInt8]) -> [ClusterConsoleKey] {
        pending += bytes
        var keys = [ClusterConsoleKey]()
        while let (key, consumed) = Self.next(pending) {
            keys.append(key)
            pending.removeFirst(consumed)
        }
        if pending.count > Self.maximumSequenceBytes {
            pending.removeAll()
            keys.append(.unknown)
        }
        return keys
    }

    /// No more bytes are coming for now: a lone escape byte was the Escape
    /// key, and any other unfinished sequence is dropped as one unknown key.
    public mutating func flush() -> [ClusterConsoleKey] {
        guard !pending.isEmpty else { return [] }
        let key: ClusterConsoleKey = pending == [Self.escape] ? .escape : .unknown
        pending.removeAll()
        return [key]
    }

    /// The first key in `bytes` and how many bytes it used; nil when `bytes`
    /// is empty or holds only the start of a sequence.
    private static func next(_ bytes: [UInt8]) -> (ClusterConsoleKey, Int)? {
        guard let first = bytes.first else { return nil }
        switch first {
        case escape: return escapeSequence(bytes)
        case 0x03: return (.interrupt, 1)
        case 0x04: return (.endOfInput, 1)
        case 0x09: return (.tab, 1)
        case 0x0A, 0x0D: return (.enter, 1)
        case 0x08, 0x7F: return (.backspace, 1)
        case 0x20...0x7E: return (.character(Character(UnicodeScalar(first))), 1)
        case 0xC0...0xFD:
            // One whole UTF-8 character: its length is in the lead byte.
            let length = first >= 0xF0 ? 4 : first >= 0xE0 ? 3 : 2
            return bytes.count >= length ? (.unknown, length) : nil
        default: return (.unknown, 1)
        }
    }

    private static func escapeSequence(_ bytes: [UInt8]) -> (ClusterConsoleKey, Int)? {
        guard bytes.count >= 2 else { return nil }
        switch bytes[1] {
        case escape:
            // Two escapes: the first was the key, the second starts over.
            return (.escape, 1)
        case UInt8(ascii: "["):
            // Control sequence: parameter and intermediate bytes, then one final byte.
            guard let end = bytes[2...].firstIndex(where: { (0x40...0x7E).contains($0) }) else {
                // A byte that cannot be part of a control sequence ends it.
                if let stray = bytes[2...].firstIndex(where: { !(0x20...0x3F).contains($0) }) { return (.unknown, stray) }
                return nil
            }
            return (controlSequence(parameters: Array(bytes[2..<end]), final: bytes[end]), end + 1)
        case UInt8(ascii: "O"):
            guard bytes.count >= 3 else { return nil }
            return (controlSequence(parameters: [], final: bytes[2]), 3)
        default:
            // Escape then a character: an Alt chord.
            return (.unknown, 2)
        }
    }

    private static func controlSequence(parameters: [UInt8], final: UInt8) -> ClusterConsoleKey {
        switch (String(decoding: parameters, as: UTF8.self), final) {
        case ("", UInt8(ascii: "A")): return .up
        case ("", UInt8(ascii: "B")): return .down
        case ("", UInt8(ascii: "C")): return .right
        case ("", UInt8(ascii: "D")): return .left
        case ("", UInt8(ascii: "H")), ("1", UInt8(ascii: "~")), ("7", UInt8(ascii: "~")): return .home
        case ("", UInt8(ascii: "F")), ("4", UInt8(ascii: "~")), ("8", UInt8(ascii: "~")): return .end
        case ("5", UInt8(ascii: "~")): return .pageUp
        case ("6", UInt8(ascii: "~")): return .pageDown
        default: return .unknown
        }
    }
}
