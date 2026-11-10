import Foundation

/// The Darkbloom mark for terminals: the brand's 7x8 pixel "d"
/// (`landing/public/favicon.svg`, #1456ff), drawn two pixel rows per text row
/// with half blocks and two columns per pixel so it stays square. Pure and
/// deterministic: the terminal decides whether to colour or animate it.
public enum ClusterOnboardingBrand {
    /// Pixel rows, top to bottom; `#` is filled.
    static let pixels = [
        "##.##.#",
        "##..#.#",
        "##..##.",
        "##..##.",
        "##.#...",
        "##.#...",
        "######.",
        "######.",
    ]

    /// The order the mark blooms in: the base, the stem upwards, then the
    /// petals from the stem outwards. Every filled pixel exactly once.
    static let bloom: [(row: Int, column: Int)] = [
        (7, 0), (7, 1), (6, 0), (6, 1), (7, 2), (6, 2), (7, 3), (6, 3), (7, 4), (6, 4), (7, 5), (6, 5),
        (5, 0), (5, 1), (4, 0), (4, 1), (3, 0), (3, 1), (2, 0), (2, 1), (1, 0), (1, 1), (0, 0), (0, 1),
        (5, 3), (4, 3), (3, 4), (2, 4), (3, 5), (2, 5), (1, 4), (0, 4), (0, 3), (1, 6), (0, 6),
    ]

    /// Text columns and rows the mark occupies.
    static let width = 14, height = 4

    /// Pixels revealed by each animation frame; the last frame is the whole mark.
    static let frames = [4, 8, 12, 16, 20, 24, 28, 32, 35]

    /// The mark's text rows with the first `revealed` pixels of the bloom drawn.
    static func rows(revealed: Int = Int.max) -> [String] {
        var lit = Set<Int>()
        for pixel in bloom.prefix(max(0, revealed)) { lit.insert(pixel.row * 7 + pixel.column) }
        return (0..<height).map { line in
            (0..<7).map { column -> String in
                let top = lit.contains(2 * line * 7 + column), bottom = lit.contains((2 * line + 1) * 7 + column)
                let glyph = top && bottom ? "\u{2588}" : top ? "\u{2580}" : bottom ? "\u{2584}" : " "
                return glyph + glyph
            }.joined()
        }
    }

    /// "●●○○○" for a heading that starts "2/5" (or "2 / 5"); nil for any other heading.
    static func meter(_ title: String) -> String? {
        let parts = title.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        let fraction = parts.count >= 3 && parts[1] == "/" ? [parts[0], parts[2]] : parts.first?.split(separator: "/") ?? []
        guard fraction.count == 2, let step = Int(fraction[0]), let total = Int(fraction[1]),
              (1...9).contains(total), (1...total).contains(step) else { return nil }
        return String(repeating: "\u{25CF}", count: step) + String(repeating: "\u{25CB}", count: total - step)
    }

    // MARK: - Live rows

    /// Turns the terminal's line wrap off for a live row's redraw and back on after it, in the same write. A row the
    /// terminal counts wider than its text (a petal or an ellipsis drawn two columns wide, a character it shows wide) is
    /// then cut at the window's edge, never wrapped: a wrapped row's start stayed behind at every redraw, so the line
    /// read as repeated end to end (0.10.8, a Gemma 4 26B start whose part's reason ran past the window).
    public static let noWrap = "\u{1B}[?7l", wrap = "\u{1B}[?7h"

    /// `text` as one live row of at most `room` columns: each control character (a reason's newline or tab, an escape)
    /// becomes a space, and a longer text is shortened, counting a character the terminal shows wide as two; a row that
    /// ends with its time keeps it.
    public static func liveText(_ text: String, room: Int) -> String {
        let flat = String(text.map { character -> Character in
            character.unicodeScalars.contains { $0.properties.generalCategory == .control } ? " " : character
        })
        let room = max(1, room)
        guard textColumns(flat) > room else { return flat }
        // A row that ends with its time (" · 1 min 3 s") keeps it: the reason before it is shortened instead.
        if let mark = flat.range(of: " \u{00B7} ", options: .backwards) {
            let tail = String(flat[mark.lowerBound...])
            if textColumns(tail) <= 24, room - textColumns(tail) >= 12 {
                return cut(String(flat[..<mark.lowerBound]), room - textColumns(tail) - 1) + "\u{2026}" + tail
            }
        }
        return cut(flat, room)
    }

    /// The columns `text` takes.
    static func textColumns(_ text: String) -> Int { text.reduce(0) { $0 + columns($1) } }

    /// The start of `text` that fits `room` columns.
    static func cut(_ text: String, _ room: Int) -> String {
        var fitted = "", used = 0
        for character in text {
            let width = columns(character)
            guard used + width <= room else { break }
            fitted.append(character); used += width
        }
        return fitted
    }

    /// The columns `character` takes: two for East Asian wide and full-width characters and emoji, else one.
    static func columns(_ character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 0 }
        if scalar.properties.isEmojiPresentation { return 2 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    /// One pixel petal turning, eight frames a second.
    static let spinner = ["\u{2596}", "\u{2598}", "\u{259D}", "\u{2597}"]
    static func spin(_ uptimeNanoseconds: UInt64) -> String {
        spinner[Int((uptimeNanoseconds / 125_000_000) % UInt64(spinner.count))]
    }

    /// The brand colour: truecolor where the terminal says so, else the
    /// nearest of the 256 (27, #005fff).
    static func colour(_ environment: [String: String]) -> String {
        let depth = environment["COLORTERM"]?.lowercased() ?? ""
        return depth.contains("truecolor") || depth.contains("24bit") ? "38;2;20;86;255" : "38;5;27"
    }

    /// Whether the terminal can draw the mark's block glyphs (a UTF-8 locale).
    static func drawsBlocks(_ environment: [String: String]) -> Bool {
        let locale = environment["LC_ALL"].flatMap { $0.isEmpty ? nil : $0 }
            ?? environment["LC_CTYPE"].flatMap { $0.isEmpty ? nil : $0 } ?? environment["LANG"] ?? ""
        let lowered = locale.lowercased()
        return lowered.contains("utf-8") || lowered.contains("utf8")
    }
}
