// Copyright © 2026 Eigen Labs.

import Foundation

/// One tool-channel invoke as the block the ATEM parser reads.
///
/// The model writes `<atem:function_calls>` around its invokes, usually one
/// per message and sometimes several. Each invoke is handed to the parser in
/// its own block, so every call of a block is returned and one that does not
/// parse fails alone.
enum MuseGlimmerToolFrame {
    static func block(invoke element: String, declaredNames: Set<String>) -> String {
        "<atem:function_calls>\n" + normalizingName(in: element, declaredNames: declaredNames)
            + "\n</atem:function_calls>"
    }

    /// The template lists a tool named `get_weather` under the recipient
    /// `"get_weather.*"`, and the model then sometimes invokes
    /// `get_weather.get_weather`. That doubled form names the declared tool.
    /// Nothing else is rewritten: matching on a trailing segment alone could
    /// dispatch another namespace's tool.
    static func normalizingName(in element: String, declaredNames: Set<String>) -> String {
        guard let tagEnd = element.firstIndex(of: ">"),
            let name = nameAttribute(in: element[..<tagEnd])
        else { return element }
        let emitted = element[name]
        guard !declaredNames.contains(String(emitted)),
            let dot = emitted.firstIndex(of: "."),
            emitted[..<dot] == emitted[emitted.index(after: dot)...],
            declaredNames.contains(String(emitted[..<dot]))
        else { return element }
        return element.replacingCharacters(in: name, with: emitted[..<dot])
    }

    /// The value of the open tag's quoted `name` attribute.
    private static func nameAttribute(in tag: Substring) -> Range<String.Index>? {
        var search = tag.startIndex
        while let attribute = tag.range(of: "name=", range: search..<tag.endIndex) {
            search = attribute.upperBound
            guard attribute.lowerBound > tag.startIndex,
                tag[tag.index(before: attribute.lowerBound)].isWhitespace,
                attribute.upperBound < tag.endIndex
            else { continue }
            let quote = tag[attribute.upperBound]
            guard quote == "\"" || quote == "'" else { return nil }
            let start = tag.index(after: attribute.upperBound)
            guard let end = tag[start...].firstIndex(of: quote) else { return nil }
            return start..<end
        }
        return nil
    }
}
