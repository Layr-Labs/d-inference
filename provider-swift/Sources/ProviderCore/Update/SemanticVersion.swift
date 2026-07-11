import Foundation

struct SemanticVersion: Comparable, Sendable, Equatable {
    enum Identifier: Sendable, Equatable {
        case numeric(UInt64)
        case text(String)
    }

    let major: UInt64
    let minor: UInt64
    let patch: UInt64
    let prerelease: [Identifier]

    init?(_ raw: String) {
        var value = raw
        if value.first == "v" { value.removeFirst() }
        let withoutBuild = value.split(
            separator: "+",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )[0]
        let pieces = withoutBuild.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let core = pieces[0].split(
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
        if pieces.count == 2 {
            let identifiers = pieces[1].split(
                separator: ".",
                omittingEmptySubsequences: false
            )
            guard !identifiers.isEmpty else { return nil }
            for identifier in identifiers {
                guard !identifier.isEmpty,
                      identifier.allSatisfy({
                          $0.isASCII
                              && ($0.isLetter || $0.isNumber || $0 == "-")
                      })
                else {
                    return nil
                }
                if identifier.allSatisfy(\.isNumber) {
                    guard identifier == "0" || identifier.first != "0",
                          let number = UInt64(identifier)
                    else {
                        return nil
                    }
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

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let leftCore = [lhs.major, lhs.minor, lhs.patch]
        let rightCore = [rhs.major, rhs.minor, rhs.patch]
        if leftCore != rightCore {
            return leftCore.lexicographicallyPrecedes(rightCore)
        }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
            if left == right { continue }
            switch (left, right) {
            case (.numeric(let a), .numeric(let b)): return a < b
            case (.numeric, .text): return true
            case (.text, .numeric): return false
            case (.text(let a), .text(let b)): return a < b
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func parseCore(_ raw: Substring) -> UInt64? {
        guard !raw.isEmpty,
              raw.allSatisfy(\.isNumber),
              raw == "0" || raw.first != "0"
        else {
            return nil
        }
        return UInt64(raw)
    }
}
