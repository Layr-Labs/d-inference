import Foundation

extension NemotronTemplateFilters {
    static let stringFilterName = "__darkbloom_nemotron_string"

    /// Swift-Jinja shares environment names between filters and `is` tests.
    /// Bind only the filter identifier to a private name before compilation;
    /// literal text, quoted strings, comments and `is string` remain unchanged.
    public static func bindingFilters(in template: String, modelType: String?) -> String {
        guard applies(modelType: modelType) else { return template }
        let input = Array(template.utf8)
        let name = Array("string".utf8)
        let replacement = Array(stringFilterName.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var i = 0
        var tag: UInt8? = nil
        var quote: UInt8? = nil
        var braces = 0
        while i < input.count {
            let byte = input[i]
            let next = i + 1 < input.count ? input[i + 1] : 0
            if tag == nil {
                if byte == 123 && [123, 37, 35].contains(next) {
                    tag = next
                    braces = 0
                    output += [byte, next]
                    i += 2
                    continue
                }
            } else if tag == 35 {
                if byte == 35 && next == 125 {
                    tag = nil
                    output += [byte, next]
                    i += 2
                    continue
                }
            } else if let activeQuote = quote {
                if byte == 92 && i + 1 < input.count {
                    output += [byte, next]
                    i += 2
                    continue
                }
                if byte == activeQuote { quote = nil }
            } else {
                if byte == 34 || byte == 39 {
                    quote = byte
                } else if braces == 0 && next == 125
                    && ((tag == 123 && byte == 125) || (tag == 37 && byte == 37)) {
                    tag = nil
                    output += [byte, next]
                    i += 2
                    continue
                } else if byte == 123 {
                    braces += 1
                } else if byte == 125 {
                    braces = max(0, braces - 1)
                } else if byte == 124 {
                    var start = i + 1
                    while start < input.count && [9, 10, 13, 32].contains(input[start]) { start += 1 }
                    let end = start + name.count
                    if end <= input.count && Array(input[start..<end]) == name
                        && (end == input.count || !isIdentifierByte(input[end])) {
                        output += input[i..<start]
                        output += replacement
                        i = end
                        continue
                    }
                }
            }
            output.append(byte)
            i += 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func isIdentifierByte(_ byte: UInt8) -> Bool {
        byte >= 128 || byte == 95 || (48...57).contains(byte)
            || (65...90).contains(byte) || (97...122).contains(byte)
    }
}
