import Testing
@testable import ProviderCore

@Test func versionMatchesSemver() {
    // Plain semver MAJOR.MINOR.PATCH (optional pre-release suffix). After the
    // Swift cutover (0.5.0+) the binary version is the canonical release tag,
    // not a `*-swift` suffix string.
    let version = ProviderCore.version
    let parts = version.split(separator: "-", maxSplits: 1).map(String.init)
    let core = parts[0].split(separator: ".")
    #expect(core.count == 3, "version '\(version)' must be MAJOR.MINOR.PATCH")
    for part in core {
        #expect(UInt(part) != nil, "version part '\(part)' is not a non-negative integer")
    }
}
