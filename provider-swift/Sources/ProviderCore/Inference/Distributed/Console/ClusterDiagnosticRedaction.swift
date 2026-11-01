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
/// peer, which no shape gives away (a host name is just a word).
///
/// While the rules run, each removed value is one private-use character, so
/// no later rule and no identifier can match inside an earlier replacement.
/// The characters become the readable placeholders only at the end.
public struct ClusterDiagnosticRedaction: Sendable {
    /// Literal values to remove. Matching ignores case and respects word
    /// boundaries; values shorter than three characters are ignored, because
    /// they would match inside ordinary words.
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

    /// What a removed value was, and the placeholder it is shown as.
    enum Mark: UInt32, CaseIterable {
        case ipv4 = 0xE000, ipv6, mac, host, user, serial, secret, privateKey, publicKey, fingerprint, homePath, volume, encoded

        var character: String { String(UnicodeScalar(rawValue)!) }

        var placeholder: String {
            switch self {
            case .ipv4: return "<ipv4>"
            case .ipv6: return "<ipv6>"
            case .mac: return "<mac>"
            case .host: return "<host>"
            case .user: return "<user>"
            case .serial: return "<serial>"
            case .secret: return "<secret>"
            case .privateKey: return "<private-key>"
            case .publicKey: return "<public-key>"
            case .fingerprint: return "<fingerprint>"
            case .homePath: return "<home-path>"
            case .volume: return "<volume>"
            case .encoded: return "<encoded>"
            }
        }
    }

    public let identifiers: Identifiers

    public init(identifiers: Identifiers) { self.identifiers = identifiers }

    /// The text with everything identifying replaced by a placeholder in angle brackets.
    public func redact(_ text: String) -> String { Self.named(marked(text)) }

    /// `redact` before the placeholders are spelled out.
    func marked(_ text: String) -> String {
        // A private-use character already in the text would read as a mark.
        var result = String(String.UnicodeScalarView(text.unicodeScalars.map { (0xE000...0xF8FF).contains($0.value) ? "?" : $0 }))
        for rule in Self.keyMaterialRules { result = rule.apply(to: result) }
        result = replacing(identifiers.secrets, in: result, with: .secret)
        result = replacingHomePaths(in: result)
        for rule in Self.pathRules { result = rule.apply(to: result) }
        // Addresses go before any name: a name that happens to be part of an
        // address, such as the first number of a peer's, must not split one.
        result = Self.replacingIPv6(in: result)
        result = Self.ipv4Rule.apply(to: result)
        for rule in Self.hardwareRules { result = rule.apply(to: result) }
        for rule in Self.accountRules { result = rule.apply(to: result) }
        result = replacing(identifiers.hostNames, in: result, with: .host)
        result = replacing(identifiers.serials, in: result, with: .serial)
        result = replacing(identifiers.userNames, in: result, with: .user)
        for rule in Self.shapeRules { result = rule.apply(to: result) }
        return Self.replacingEncodedRuns(in: result)
    }

    static func named(_ marked: String) -> String {
        Mark.allCases.reduce(marked) { $0.replacingOccurrences(of: $1.character, with: $1.placeholder) }
    }

    // MARK: - Rules

    struct Rule: @unchecked Sendable {
        let expression: NSRegularExpression
        let template: String

        init(_ pattern: String, _ template: String, options: NSRegularExpression.Options = []) {
            // Patterns are fixed text in this file, or escaped literals.
            expression = try! NSRegularExpression(pattern: pattern, options: options)
            self.template = template
        }

        func apply(to text: String) -> String {
            expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
    }

    private static func mark(_ mark: Mark) -> String { NSRegularExpression.escapedTemplate(for: mark.character) }

    /// A field whose name says it holds a credential.
    private static let credentialName = #"[A-Za-z0-9_.-]*(?:token(?!s\b|izer)|secret|password|passphrase|api[_-]?key|authorization|credential)[A-Za-z0-9_.-]*"#

    /// Private keys, public key blobs, fingerprints, bearer tokens and
    /// credential fields: in JSON, in JSON quoted inside a string, and as
    /// `name: value` or `name=value`.
    static let keyMaterialRules: [Rule] = [
        Rule(#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)"#, mark(.privateKey),
             options: [.dotMatchesLineSeparators]),
        // The end of a key whose beginning scrolled away.
        Rule(#"(?:[A-Za-z0-9+/=]{20,}\s+)*-----END [A-Z0-9 ]*PRIVATE KEY-----"#, mark(.privateKey)),
        Rule(#"\b(ssh-(?:rsa|dss|ed25519)|ecdsa-sha2-[A-Za-z0-9-]+|sk-[A-Za-z0-9@.-]+)\s+AAAA[0-9A-Za-z+/=]+"#, "$1 " + mark(.publicKey)),
        Rule(#"\bSHA256:[A-Za-z0-9+/]{43}=?"#, "SHA256:" + mark(.fingerprint)),
        Rule(#"\bMD5:(?:[0-9A-Fa-f]{2}:){15}[0-9A-Fa-f]{2}\b"#, "MD5:" + mark(.fingerprint)),
        Rule(#"\bBearer\s+(?=[A-Za-z0-9._~+/=-]*[0-9])[A-Za-z0-9._~+/=-]{8,}"#, "Bearer " + mark(.secret)),
        Rule(#"\bdk-[A-Za-z0-9]+-[A-Za-z0-9_-]{8,}"#, mark(.secret)),
        // A signed token: three base64url parts, the first a JSON header.
        Rule(#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, mark(.secret)),
        Rule(#"(?i)(?<!\\)("\#(credentialName)"\s*:\s*")(?:[^"\\]|\\.)*(")"#, "$1" + mark(.secret) + "$2"),
        Rule(#"(?i)((\\+)"\#(credentialName)\2"\s*:\s*\2")(?:(?!\2")[\s\S])*(\2")"#, "$1" + mark(.secret) + "$3"),
        // The name bare and the value quoted, as a description of a value prints it.
        Rule(#"(?i)\b(\#(credentialName)\s*[:=]\s*)(["'])(?:(?!\2)[^\n])*\2"#, "$1$2" + mark(.secret) + "$2"),
        // A command-line flag and its value.
        Rule(#"(?i)(--\#(credentialName)\s+)(?!-)[^\s"',;\x{E000}-\x{F8FF}]+"#, "$1" + mark(.secret)),
        // What stands before the @ in a URL is a login.
        Rule(#"(?i)(\b[a-z][a-z0-9+.-]*://)[^/\s@"']+@"#, "$1" + mark(.secret) + "@"),
        // A scheme word whose token is already gone is left to say what it was.
        Rule(#"(?i)\b(\#(credentialName)\s*[:=]\s*)(?!(?:Bearer|Basic|Digest)\s+[\x{E000}-\x{F8FF}])(?:(?:Bearer|Basic|Digest)\s+)?[^\s"',;\x{E000}-\x{F8FF}]+"#, "$1" + mark(.secret)),
    ]

    /// What one component of a path may hold: not a slash, a space, a quote
    /// or the punctuation a sentence puts around a path.
    private static let componentCharacters = #"[^/\s"'\\,;:()<>|\x{E000}-\x{F8FF}]"#
    /// Further components, each after a slash that JSON inside a string may have escaped.
    private static let components = #"(?:\\?/\#(componentCharacters)*)*"#
    /// A further part of a path after a space, as in "Application Support/…"
    /// or "untitled folder/…": up to three words and then a slash directly
    /// after the last. Prose after a path has no slash there and is left
    /// alone, and a word that begins with a tilde begins another path.
    private static let spacedContinuation = #"(?:(?: (?!~)\#(componentCharacters)+){1,3}\\?/\#(componentCharacters)*\#(components))*"#

    /// Any user's home directory and everything under it, and a mounted
    /// volume with what is on it. Whole paths go: what is kept there is the
    /// user's own.
    static let pathRules: [Rule] = [
        Rule(#"(?i)\\?/(?:Users|home)\\?/\#(componentCharacters)+\#(components)\#(spacedContinuation)"#, mark(.homePath)),
        Rule(#"(?i)\\?/(?:private\\?/)?var\\?/root(?![A-Za-z0-9])\#(components)"#, mark(.homePath)),
        Rule(#"(?<![A-Za-z0-9_.~/\x{E000}-\x{F8FF}])~[A-Za-z0-9._-]*\\?/\#(componentCharacters)*\#(components)\#(spacedContinuation)"#, mark(.homePath)),
        Rule(#"\\?/Volumes\\?/\#(componentCharacters)+\#(components)\#(spacedContinuation)"#, "/Volumes/" + mark(.volume)),
    ]

    /// Hardware addresses: a colon-separated run longer than a MAC address,
    /// which is a fingerprint; MAC addresses in their three spellings; and
    /// the four-group identifiers RDMA tools print.
    static let hardwareRules: [Rule] = [
        Rule(#"(?<![0-9A-Za-z])(?:[0-9A-Fa-f]{2}:){6,}[0-9A-Fa-f]{2}(?![0-9A-Za-z])"#, mark(.fingerprint)),
        Rule(#"(?<![0-9A-Za-z])(?:[0-9A-Fa-f]{1,2}:){5}[0-9A-Fa-f]{1,2}(?![0-9A-Za-z])"#, mark(.mac)),
        Rule(#"(?<![0-9A-Za-z-])(?:[0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}(?![0-9A-Za-z-])"#, mark(.mac)),
        Rule(#"(?<![0-9A-Za-z.])[0-9A-Fa-f]{4}\.[0-9A-Fa-f]{4}\.[0-9A-Fa-f]{4}(?![0-9A-Za-z.])"#, mark(.mac)),
        Rule(#"(?<![0-9A-Za-z])[0-9A-Fa-f]{4}(?::[0-9A-Fa-f]{4}){3}(?![0-9A-Za-z])"#, mark(.mac)),
    ]

    /// `user@host`, where the host is a name or an address already replaced.
    static let accountRules: [Rule] = [
        Rule(#"(?<![A-Za-z0-9._-])[A-Za-z0-9._-]+@(?=[\x{E000}-\x{F8FF}])"#, mark(.user) + "@"),
        Rule(#"(?<![A-Za-z0-9._-])[A-Za-z0-9._-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\b"#, mark(.user) + "@" + mark(.host)),
    ]

    /// Host names by where they stand or how they end, and labelled serial numbers.
    static let shapeRules: [Rule] = [
        Rule(#"(?i)\b((?:host(?:name)?|peer|server|ssh|connect(?:ing|ion)? to)\s*[:=]?\s+)(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}\b"#, "$1" + mark(.host)),
        // The host of a URL, whatever it is called; this Mac's own loopback name stays.
        Rule(#"(?i)(\b[a-z][a-z0-9+.-]*://(?:[\x{E000}-\x{F8FF}]@)?)(?!localhost(?![A-Za-z0-9.-]))[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?"#, "$1" + mark(.host)),
        Rule(#"(?i)\b[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9-]+)*\.(?:local|lan|home|internal|localdomain)\b"#, mark(.host)),
        Rule(#"(?i)\b((?:serial(?:[ _-]?number)?|IOPlatformSerialNumber|IOPlatformUUID|hardware[ _-]?uuid|provisioning[ _-]?udid)\\?"?\s*[:=]\s*\\?"?)[A-Za-z0-9-]{6,}"#, "$1" + mark(.serial)),
    ]

    /// Four numbers and three dots, wherever a sentence leaves them: after a
    /// colon, before a port, before a full stop; with leading zeros; and with
    /// a port after a fourth dot, as `netstat` writes one. Longer dotted
    /// numbers are something else and are left.
    static let ipv4Rule = Rule(
        #"(?<![0-9])(?<![0-9]\.)[0-9]{1,3}(?:\.[0-9]{1,3}){3}(?:\.[0-9]{1,5})?(?![0-9]|\.[0-9])"#, mark(.ipv4))

    /// IPv6 has too many spellings for one pattern. Every run that could be
    /// an address is offered to the system's own parser, whole and with a
    /// stray colon trimmed from either end, and replaced when it is accepted.
    private static let ipv6Candidates = Rule(
        #"(?:(?<![0-9A-Za-z])[0-9A-Fa-f]{1,4}|(?<=[A-Za-z]:)[0-9A-Fa-f]{1,4}|(?<![0-9A-Za-z:]):)(?::[0-9A-Fa-f]{0,4}){1,8}(?:(?:\.[0-9]{1,3}){3})?(?:%[0-9A-Za-z]+)?"#, "")

    static func replacingIPv6(in text: String) -> String {
        var result = text
        for match in ipv6Candidates.expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let token = String(result[range])
            for (leading, trailing) in [(0, 0), (1, 0), (0, 1), (1, 1)] where leading + trailing < token.count {
                let trimmed = token.dropFirst(leading).dropLast(trailing)
                if leading == 1, token.first != ":" { continue }
                if trailing == 1, token.last != ":" { continue }
                guard isIPv6(String(trimmed)) else { continue }
                let start = result.index(range.lowerBound, offsetBy: leading), end = result.index(range.upperBound, offsetBy: -trailing)
                result.replaceSubrange(start..<end, with: Mark.ipv6.character)
                break
            }
        }
        return result
    }

    static func isIPv6(_ text: String) -> Bool {
        let address = text.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
        var parsed = in6_addr()
        return address.filter { $0 == ":" }.count >= 2 && inet_pton(AF_INET6, address, &parsed) == 1
    }

    /// A long run of base64 that is not a digest: the body of a key or a
    /// token with nothing around it to say what it is. Hexadecimal digests
    /// are kept, and so is a run with no digit or no capital, which is a word
    /// or a path rather than an encoding.
    private static let encodedRuns = Rule(#"(?<![A-Za-z0-9+/=])[A-Za-z0-9+/]{40,}={0,2}(?![A-Za-z0-9+/=])"#, "")
    /// The same in the URL-safe alphabet. Names joined by hyphens are of that
    /// alphabet too, so a run counts only with several capitals and several
    /// small letters as well as a digit, which a file name does not have.
    private static let urlSafeRuns = Rule(#"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{40,}(?![A-Za-z0-9_-])"#, "")
    /// A shorter run that ends in padding: the last line of a key or a blob.
    private static let paddedRuns = Rule(#"(?<![A-Za-z0-9+/=])[A-Za-z0-9+/]{16,}={1,2}(?![A-Za-z0-9+/=])"#, mark(.encoded))

    static func replacingEncodedRuns(in text: String) -> String {
        func count(_ run: Substring.UnicodeScalarView, _ range: ClosedRange<UInt32>) -> Int { run.filter { range.contains($0.value) }.count }
        var result = paddedRuns.apply(to: text)
        for (rule, urlSafe) in [(encodedRuns, false), (urlSafeRuns, true)] {
            let source = result
            for match in rule.expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let run = result[range].unicodeScalars
                let capitals = count(run, 0x41...0x5A), small = count(run, 0x61...0x7A), digits = count(run, 0x30...0x39)
                let encoded = urlSafe ? capitals >= 4 && small >= 4 && digits >= 1
                    : capitals >= 1 && small >= 1 && digits >= 1 && !run.allSatisfy { $0.properties.isASCIIHexDigit }
                if encoded { result.replaceSubrange(range, with: Mark.encoded.character) }
            }
        }
        return result
    }

    // MARK: - Identifiers

    /// Long enough to be a name, and not a bare number: a number is part of
    /// too many other things to be replaced wherever it stands.
    static func usable(_ literal: String) -> Bool { literal.count >= 3 && !literal.allSatisfy(\.isNumber) }

    /// Longest first, so a host name is replaced before its first label is.
    private func replacing(_ literals: [String], in text: String, with mark: Mark) -> String {
        var result = text
        for literal in Set(literals).filter(Self.usable).sorted(by: { ($0.count, $0) > ($1.count, $1) }) {
            let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: literal) + "(?![A-Za-z0-9])"
            result = Rule(pattern, Self.mark(mark), options: [.caseInsensitive]).apply(to: result)
        }
        return result
    }

    /// A path under a known home directory goes whole, name and all: what a
    /// user keeps there is theirs. Slashes may be escaped, as JSON inside a
    /// string escapes them.
    private func replacingHomePaths(in text: String) -> String {
        var result = text
        for home in Set(identifiers.homeDirectories).filter(Self.usable).sorted(by: { ($0.count, $0) > ($1.count, $1) }) {
            let prefix = home.split(separator: "/").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\\?/"#)
            let pattern = #"\\?/"# + prefix + "(?![A-Za-z0-9])" + Self.components + Self.spacedContinuation
            result = Rule(pattern, Self.mark(.homePath), options: [.caseInsensitive]).apply(to: result)
        }
        return result
    }
}
