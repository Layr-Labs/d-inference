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

    /// "●●○○○" for a heading that starts "2 / 5"; nil for any other heading.
    static func meter(_ title: String) -> String? {
        let parts = title.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[1] == "/", let step = Int(parts[0]), let total = Int(parts[2]),
              (1...9).contains(total), (1...total).contains(step) else { return nil }
        return String(repeating: "\u{25CF}", count: step) + String(repeating: "\u{25CB}", count: total - step)
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
