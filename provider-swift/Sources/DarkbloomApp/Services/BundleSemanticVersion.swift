/// Strict SemVer 2 ordering for release-version fields in app Info.plists.
/// Build metadata is intentionally excluded from precedence, as required by
/// SemVer; prerelease identifiers retain their numeric/text ordering.
struct BundleSemanticVersion: Comparable {
    private enum Identifier: Equatable {
        case numeric(UInt64)
        case text(String)
    }

    private let major: UInt64
    private let minor: UInt64
    private let patch: UInt64
    private let prerelease: [Identifier]

    init?(_ raw: String) {
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
           !Self.validIdentifiers(buildParts[1], allowNumericLeadingZero: true)
        {
            return nil
        }

        let versionParts = buildParts[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard !versionParts[0].isEmpty else { return nil }
        let core = versionParts[0].split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard core.count == 3,
              let major = Self.parseCore(core[0]),
              let minor = Self.parseCore(core[1]),
              let patch = Self.parseCore(core[2])
        else {
            return nil
        }

        var prerelease: [Identifier] = []
        if versionParts.count == 2 {
            let rawPrerelease = versionParts[1]
            guard Self.validIdentifiers(
                rawPrerelease,
                allowNumericLeadingZero: false
            ) else {
                return nil
            }
            for identifier in rawPrerelease.split(separator: ".") {
                if identifier.allSatisfy(\.isNumber) {
                    guard let number = UInt64(identifier) else { return nil }
                    prerelease.append(.numeric(number))
                } else {
                    prerelease.append(.text(String(identifier)))
                }
            }
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let lhsCore = [lhs.major, lhs.minor, lhs.patch]
        let rhsCore = [rhs.major, rhs.minor, rhs.patch]
        if lhsCore != rhsCore {
            return lhsCore.lexicographicallyPrecedes(rhsCore)
        }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
            if left == right { continue }
            switch (left, right) {
            case (.numeric(let left), .numeric(let right)):
                return left < right
            case (.numeric, .text):
                return true
            case (.text, .numeric):
                return false
            case (.text(let left), .text(let right)):
                return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func parseCore(_ raw: Substring) -> UInt64? {
        guard !raw.isEmpty,
              raw.allSatisfy({ $0.isASCII && $0.isNumber }),
              raw == "0" || raw.first != "0"
        else {
            return nil
        }
        return UInt64(raw)
    }

    private static func validIdentifiers(
        _ raw: Substring,
        allowNumericLeadingZero: Bool
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
            return allowNumericLeadingZero
                || !identifier.allSatisfy(\.isNumber)
                || identifier == "0"
                || identifier.first != "0"
        }
    }
}
