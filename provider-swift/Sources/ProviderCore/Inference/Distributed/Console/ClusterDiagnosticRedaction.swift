import Foundation
import Darwin

/// Removes what identifies a Mac, its user or its peer from diagnostic text:
/// network addresses, host names, user names, serial numbers, key material,
/// credentials and paths under a home directory. Digests of public files
/// (configuration, capability, artifact, Plan) are kept: they are what a
/// report is compared by.
///
/// Two kinds of rule run. Patterns catch a value by its shape wherever it
/// appears. Identifiers are the literal values known for this Mac and its
/// saved peer, which no shape gives away (a host name is just a word).
public struct ClusterDiagnosticRedaction: Sendable {
    /// Literal values to remove. Matching ignores case; values shorter than
    /// three characters are ignored, because they would match inside
    /// ordinary words.
    public struct Identifiers: Sendable, Equatable {
        public var homeDirectories: [String]
        public var userNames: [String]
        public var hostNames: [String]
        public var serials: [String]
        public var secrets: [String]

        public init(homeDirectories: [String] = [], userNames: [String] = [], hostNames: [String] = [],
                    serials: [String] = [], secrets: [String] = []) {
            self.homeDirectories = homeDirectories; self.userNames = userNames; self.hostNames = hostNames
            self.serials = serials; self.secrets = secrets
        }
    }

    public let identifiers: Identifiers

    public init(identifiers: Identifiers) { self.identifiers = identifiers }

    public func redact(_ text: String) -> String {
        var result = text
        for rule in Self.keyMaterialRules { result = rule.apply(to: result) }
        result = replacingLiterals(identifiers.secrets, in: result, with: "<secret>", wholeWord: false)
        // The home directory first, so the user name in it never needs a rule of its own.
        result = replacingLiterals(identifiers.homeDirectories, in: result, with: "~", wholeWord: false)
        for rule in Self.pathRules { result = rule.apply(to: result) }
        result = replacingLiterals(identifiers.hostNames, in: result, with: "<host>", wholeWord: true)
        result = replacingLiterals(identifiers.serials, in: result, with: "<serial>", wholeWord: true)
        result = replacingLiterals(identifiers.userNames, in: result, with: "<user>", wholeWord: true)
        for rule in Self.shapeRules { result = rule.apply(to: result) }
        result = Self.redactingIPv6(in: result)
        return Self.ipv4Rule.apply(to: result)
    }

    /// What is still recognizable after `redact`. Empty for anything `redact`
    /// returned; the export checks it before a file is written.
    public func residue(in text: String) -> [String] {
        var found = [String]()
        let lowered = text.lowercased()
        let literals = identifiers.secrets + identifiers.homeDirectories + identifiers.hostNames
            + identifiers.serials + identifiers.userNames
        for literal in literals where Self.usable(literal) {
            // Whole-word literals are searched for as `redact` matches them.
            let pattern = NSRegularExpression.escapedPattern(for: literal.lowercased())
            let wholeWord = !identifiers.secrets.contains(literal) && !identifiers.homeDirectories.contains(literal)
            let expression = wholeWord ? "(?<![A-Za-z0-9])\(pattern)(?![A-Za-z0-9])" : pattern
            if lowered.range(of: expression, options: .regularExpression) != nil { found.append("a known identifier") }
        }
        for (name, rule) in [("an IPv4 address", Self.ipv4Rule), ("a MAC address", Self.macRule),
                             ("a private key", Self.keyMaterialRules[0]), ("a public key", Self.keyMaterialRules[1])]
        where rule.matches(text) { found.append(name) }
        if Self.redactingIPv6(in: text) != text { found.append("an IPv6 address") }
        return found
    }

    // MARK: - Rules

    struct Rule: @unchecked Sendable {
        let expression: NSRegularExpression
        let template: String

        init(_ pattern: String, _ template: String, options: NSRegularExpression.Options = []) {
            // Patterns are fixed text in this file.
            expression = try! NSRegularExpression(pattern: pattern, options: options)
            self.template = template
        }

        func apply(to text: String) -> String {
            expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }

        func matches(_ text: String) -> Bool {
            expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }

    /// Private keys, public key blobs, fingerprints, bearer tokens and named
    /// credential fields. A quote may be backslash-escaped: the text is often
    /// JSON inside JSON.
    static let keyMaterialRules: [Rule] = [
        Rule(#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)"#, "<private-key>",
             options: [.dotMatchesLineSeparators]),
        Rule(#"\b(ssh-(?:rsa|dss|ed25519)|ecdsa-sha2-[A-Za-z0-9-]+|sk-[A-Za-z0-9@.-]+)\s+AAAA[0-9A-Za-z+/=]+"#, "$1 <public-key>"),
        Rule(#"\bSHA256:[A-Za-z0-9+/]{43}=?"#, "SHA256:<fingerprint>"),
        Rule(#"\bMD5:(?:[0-9A-Fa-f]{2}:){15}[0-9A-Fa-f]{2}\b"#, "MD5:<fingerprint>"),
        Rule(#"\bBearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer <secret>"),
        Rule(#"\bdk-[A-Za-z0-9]+-[A-Za-z0-9_-]{8,}"#, "<secret>"),
        Rule(#"(?i)(\\?"(?:api[_-]?key|token|secret|password|passphrase|authorization)\\?"\s*:\s*\\?")[^"\\]*(\\?")"#, "$1<secret>$2"),
        Rule(#"(?i)\b((?:api[_-]?key|token|secret|password|passphrase)\s*=\s*)[^\s"',;]+"#, "$1<secret>"),
    ]

    /// Home directories other than the known one, and `user@host` pairs.
    static let pathRules: [Rule] = [
        Rule(#"/(Users|home)/[^/\s"'\\:,;)]+"#, "/$1/<user>"),
        Rule(#"/(?:private/)?var/root\b"#, "/Users/<user>"),
        Rule(#"\b[A-Za-z0-9._-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\b"#, "<user>@<host>"),
    ]

    static let macRule = Rule(#"(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{1,2}:){5}[0-9A-Fa-f]{1,2}(?![0-9A-Fa-f:])"#, "<mac>")

    /// Local-network host names, MAC addresses and labelled serial numbers.
    static let shapeRules: [Rule] = [
        Rule(#"(?i)\b[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9-]+)*\.(?:local|lan|home|internal|localdomain)\b"#, "<host>"),
        macRule,
        Rule(#"(?i)\b((?:serial(?:[ _-]?number)?|IOPlatformSerialNumber|IOPlatformUUID|hardware[ _-]?uuid|provisioning[ _-]?udid)\\?"?\s*[:=]\s*\\?"?)[A-Za-z0-9-]{6,}"#, "$1<serial>"),
    ]

    static let ipv4Rule = Rule(
        #"(?<![0-9.])(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(?:\.(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])){3}(?![0-9.])"#, "<ipv4>")

    /// IPv6 has too many spellings for one pattern. Every run of hexadecimal
    /// digits, colons and dots (with an optional `%zone`) is offered to the
    /// system's own parser, and replaced when the parser accepts it.
    static func redactingIPv6(in text: String) -> String {
        let candidate = Rule(#"(?<![0-9A-Za-z:.])[0-9A-Fa-f:.]*:[0-9A-Fa-f:.]*(?:%[0-9A-Za-z]+)?(?![0-9A-Za-z:])"#, "")
        let whole = NSRange(text.startIndex..., in: text)
        var result = text
        for match in candidate.expression.matches(in: text, range: whole).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let token = String(result[range])
            let address = token.split(separator: "%", maxSplits: 1).first.map(String.init) ?? token
            var parsed = in6_addr()
            if address.contains("::") || address.filter({ $0 == ":" }).count >= 2, inet_pton(AF_INET6, address, &parsed) == 1 {
                result.replaceSubrange(range, with: "<ipv6>")
            }
        }
        return result
    }

    // MARK: - Literals

    private static func usable(_ literal: String) -> Bool { literal.count >= 3 }

    /// Longest first, so a host name is replaced before its first label is.
    private func replacingLiterals(_ literals: [String], in text: String, with replacement: String, wholeWord: Bool) -> String {
        var result = text
        for literal in Set(literals).filter(Self.usable).sorted(by: { ($0.count, $0) > ($1.count, $1) }) {
            let escaped = NSRegularExpression.escapedPattern(for: literal)
            let pattern = wholeWord ? "(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])" : escaped
            result = Rule(pattern, NSRegularExpression.escapedTemplate(for: replacement), options: [.caseInsensitive]).apply(to: result)
        }
        return result
    }
}
