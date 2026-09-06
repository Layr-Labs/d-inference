import Foundation

/// Small, streaming-tolerant fence parser. Ordinary Markdown stays in text
/// blocks; fenced code preserves whitespace and remains copyable while open.
enum ChatTextBlock: Equatable {
    case text(String)
    case code(language: String, content: String)

    static func parse(_ source: String) -> [Self] {
        var blocks: [Self] = []
        var lines: [String] = []
        var language: String?
        var fenceMarker: Character?
        var fenceLength = 0

        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = fenceMarker {
                let run = trimmed.prefix(while: { $0 == marker })
                if run.count >= fenceLength, run.count == trimmed.count {
                    blocks.append(.code(language: language ?? "", content: lines.joined(separator: "\n")))
                    lines = []
                    language = nil
                    fenceMarker = nil
                    continue
                }
            } else if let marker = trimmed.first, marker == "`" || marker == "~" {
                let run = trimmed.prefix(while: { $0 == marker })
                if run.count >= 3 {
                    if !lines.isEmpty { blocks.append(.text(lines.joined(separator: "\n"))) }
                    lines = []
                    fenceMarker = marker
                    fenceLength = run.count
                    language = String(trimmed.dropFirst(run.count)).trimmingCharacters(in: .whitespaces)
                    continue
                }
            }
            lines.append(line)
        }
        if fenceMarker != nil {
            blocks.append(.code(language: language ?? "", content: lines.joined(separator: "\n")))
        } else if !lines.isEmpty {
            blocks.append(.text(lines.joined(separator: "\n")))
        }
        return blocks
    }
}
