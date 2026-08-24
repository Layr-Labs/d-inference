/// Strict SemVer 2 parser and precedence implementation.
///
/// Numeric identifiers stay as canonical decimal strings so valid versions
/// are not constrained by machine integer width.
public struct SemanticVersion: Comparable, Sendable, Equatable {
    private enum Identifier: Sendable, Equatable {
        case numeric(String)
        case text(String)
    }

    private let major: String
    private let minor: String
    private let patch: String
    private let prerelease: [Identifier]

    public init?(_ raw: String) {
        let buildParts = raw.split(
            separator: "+",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard buildParts.count <= 2,
              buildParts.allSatisfy({ !$0.isEmpty })
        else {
            return nil
        }
        if buildParts.count == 2,
           !Self.validIdentifiers(
            buildParts[1],
            numericLeadingZeroAllowed: true
           )
        {
            return nil
        }

        let versionParts = buildParts[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let core = versionParts[0].split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard core.count == 3,
              Self.validCoreIdentifier(core[0]),
              Self.validCoreIdentifier(core[1]),
              Self.validCoreIdentifier(core[2])
        else {
            return nil
        }

        var prerelease: [Identifier] = []
        if versionParts.count == 2 {
            let rawPrerelease = versionParts[1]
            guard Self.validIdentifiers(
                rawPrerelease,
                numericLeadingZeroAllowed: false
            ) else {
                return nil
            }
            prerelease = rawPrerelease.split(separator: ".").map { identifier in
                identifier.allSatisfy(\.isNumber)
                    ? .numeric(String(identifier))
                    : .text(String(identifier))
            }
        }

        major = String(core[0])
        minor = String(core[1])
        patch = String(core[2])
        self.prerelease = prerelease
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        for (left, right) in zip(
            [lhs.major, lhs.minor, lhs.patch],
            [rhs.major, rhs.minor, rhs.patch]
        ) {
            if left == right { continue }
            return numericIdentifierIsLess(left, right)
        }

        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
            if left == right { continue }
            switch (left, right) {
            case (.numeric(let left), .numeric(let right)):
                return numericIdentifierIsLess(left, right)
            case (.numeric, .text):
                return true
            case (.text, .numeric):
                return false
            case (.text(let left), .text(let right)):
                return left.utf8.lexicographicallyPrecedes(right.utf8)
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func numericIdentifierIsLess(
        _ left: String,
        _ right: String
    ) -> Bool {
        if left.count != right.count {
            return left.count < right.count
        }
        return left.utf8.lexicographicallyPrecedes(right.utf8)
    }

    private static func validCoreIdentifier(_ raw: Substring) -> Bool {
        !raw.isEmpty
            && raw.allSatisfy({ $0.isASCII && $0.isNumber })
            && (raw == "0" || raw.first != "0")
    }

    private static func validIdentifiers(
        _ raw: Substring,
        numericLeadingZeroAllowed: Bool
    ) -> Bool {
        let identifiers = raw.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        return !identifiers.isEmpty && identifiers.allSatisfy { identifier in
            guard !identifier.isEmpty,
                  identifier.allSatisfy({
                      $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")
                  })
            else {
                return false
            }
            return numericLeadingZeroAllowed
                || !identifier.allSatisfy(\.isNumber)
                || identifier == "0"
                || identifier.first != "0"
        }
    }
}
