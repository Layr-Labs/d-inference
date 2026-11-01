import Foundation
import Darwin

/// A second look at redacted text, written without the rules that did the
/// redacting: it splits the text into tokens and asks the system's own
/// parsers. Whatever it still recognizes stops an export from being written.
extension ClusterDiagnosticRedaction {
    /// What is still recognizable in text `marked` returned; empty when nothing is.
    func residue(inMarked text: String) -> [String] {
        var found = Set<String>()
        let words = Self.words(text)
        let known: [(String, [String])] = [("a credential", identifiers.secrets), ("a home directory", identifiers.homeDirectories),
            ("a host name", identifiers.hostNames), ("a serial number", identifiers.serials), ("a user name", identifiers.userNames)]
        for (name, literals) in known {
            for literal in literals where Self.usable(literal) {
                let sought = Self.words(literal)
                if !sought.isEmpty, Self.contains(words, run: sought) { found.insert(name) }
            }
        }
        // Four short numbers between dots, or five where the last is a port.
        for token in Self.tokens(text, of: "0123456789.") {
            let parts = token.trimmingCharacters(in: CharacterSet(charactersIn: ".")).split(separator: ".", omittingEmptySubsequences: false)
            if parts.count == 4 || parts.count == 5, parts.prefix(4).allSatisfy({ (1...3).contains($0.count) }),
               parts.dropFirst(4).allSatisfy({ (1...5).contains($0.count) }) { found.insert("an IPv4 address") }
        }
        // The rest of an address beside a placeholder: something replaced a part of one.
        let scalars = Array(text.unicodeScalars)
        func isMark(_ index: Int) -> Bool { scalars.indices.contains(index) && (0xE000...0xF8FF).contains(scalars[index].value) }
        func numbersAndDots(from start: Int, step: Int) -> String {
            var index = start, run = ""
            while scalars.indices.contains(index), scalars[index] == "." || scalars[index].properties.numericType == .decimal {
                run.unicodeScalars.append(scalars[index]); index += step
            }
            return run
        }
        for index in scalars.indices where isMark(index) {
            for run in [numbersAndDots(from: index + 1, step: 1), numbersAndDots(from: index - 1, step: -1)] {
                let parts = run.split(separator: ".", omittingEmptySubsequences: false)
                // A dot next to the placeholder, then three short numbers.
                if parts.count == 4, parts[0].isEmpty, parts.dropFirst().allSatisfy({ (1...3).contains($0.count) }) {
                    found.insert("part of an IPv4 address")
                }
            }
        }
        // Words are kept whole, so "std::string" is a word with colons in it
        // and not an address between two letters.
        let alphanumerics = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        for token in Self.tokens(text, of: alphanumerics + ":.%") {
            let address = token.split(separator: "%", omittingEmptySubsequences: false).first.map(String.init) ?? token
            var groups = address.trimmingCharacters(in: CharacterSet(charactersIn: ".")).split(separator: ":", omittingEmptySubsequences: false)[...]
            // A label before the address, or a word after it, is not part of it.
            while let first = groups.first, !first.isEmpty, !Self.isHexadecimalGroup(first) { groups = groups.dropFirst() }
            while let last = groups.last, !last.isEmpty, !Self.isHexadecimalGroup(last), !last.contains(".") { groups = groups.dropLast() }
            guard groups.count >= 3 else { continue }
            let candidates = [groups, groups.dropFirst(), groups.dropLast(), groups.dropFirst().dropLast()]
            if candidates.contains(where: { Self.isIPv6($0.joined(separator: ":")) }) { found.insert("an IPv6 address") }
        }
        for token in Self.tokens(text, of: alphanumerics + ":.-") {
            for separator in [":", "-"] as [Character] {
                // Six pairs in a row anywhere in the token, whatever is joined to either end.
                let pairs = token.split(separator: separator, omittingEmptySubsequences: false).map { (1...2).contains($0.count) && Self.isHexadecimalGroup($0) }
                if pairs.count >= 6, (0...(pairs.count - 6)).contains(where: { pairs[$0..<($0 + 6)].allSatisfy { $0 } }) { found.insert("a MAC address") }
            }
            let quads = token.split(separator: ".", omittingEmptySubsequences: false)
            if quads.count == 3, quads.allSatisfy({ $0.count == 4 && Self.isHexadecimalGroup($0) }) { found.insert("a MAC address") }
            let fours = token.split(separator: ":", omittingEmptySubsequences: false)
            if fours.count == 4, fours.allSatisfy({ $0.count == 4 && Self.isHexadecimalGroup($0) }) { found.insert("a hardware identifier") }
        }
        if text.contains("PRIVATE KEY-----") { found.insert("a private key") }
        for prefix in ["ssh-rsa AAAA", "ssh-ed25519 AAAA", "ssh-dss AAAA", "nistp256 AAAA", "nistp384 AAAA", "nistp521 AAAA"]
        where text.contains(prefix) { found.insert("a public key") }
        for directory in ["/Users/", "/home/"] {
            var search = text[...]
            while let range = search.range(of: directory, options: .caseInsensitive) {
                // A name after it is a home directory that was not replaced whole.
                if let next = search[range.upperBound...].first, next.isLetter || next.isNumber || next == "." || next == "_" {
                    found.insert("a home directory")
                }
                search = search[range.upperBound...]
            }
        }
        return found.sorted()
    }

    private static func isHexadecimalGroup(_ group: Substring) -> Bool {
        (1...4).contains(group.count) && group.unicodeScalars.allSatisfy { $0.properties.isASCIIHexDigit }
    }

    /// Lowercased runs of letters and digits, in order.
    private static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) }).map(String.init)
    }

    private static func contains(_ words: [String], run: [String]) -> Bool {
        guard run.count <= words.count else { return false }
        return (0...(words.count - run.count)).contains { Array(words[$0..<($0 + run.count)]) == run }
    }

    /// Maximal runs of the given characters.
    private static func tokens(_ text: String, of characters: String) -> [String] {
        let allowed = Set(characters)
        return text.split(whereSeparator: { !allowed.contains($0) }).map(String.init)
    }
}
