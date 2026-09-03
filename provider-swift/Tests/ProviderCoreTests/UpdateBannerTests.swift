import Foundation
import Testing
@testable import ProviderCore

@Suite("UpdateBanner semver comparison")
struct UpdateBannerTests {

    @Test("0.5.0 is newer than 0.4.10 (numeric, not lexicographic)")
    func newerMinorBeatsLargerPatch() {
        #expect(UpdateBanner.isNewerSemver("0.5.0", than: "0.4.10"))
        #expect(!UpdateBanner.isNewerSemver("0.4.10", than: "0.5.0"))
    }

    @Test("identical versions are not newer")
    func identicalVersionsNotNewer() {
        #expect(!UpdateBanner.isNewerSemver("0.5.0", than: "0.5.0"))
        #expect(!UpdateBanner.isNewerSemver("1.2.3", than: "1.2.3"))
    }

    @Test("patch bumps register as newer")
    func patchBumpsAreNewer() {
        #expect(UpdateBanner.isNewerSemver("0.5.1", than: "0.5.0"))
        #expect(UpdateBanner.isNewerSemver("0.5.10", than: "0.5.9"))
    }

    @Test("major bumps register as newer")
    func majorBumpsAreNewer() {
        #expect(UpdateBanner.isNewerSemver("1.0.0", than: "0.99.99"))
        #expect(!UpdateBanner.isNewerSemver("0.99.99", than: "1.0.0"))
    }

    @Test("stable releases have higher precedence than matching prereleases")
    func stableReleaseBeatsPrerelease() {
        #expect(UpdateBanner.isNewerSemver("1.0.0", than: "1.0.0-rc.1"))
        #expect(!UpdateBanner.isNewerSemver("1.0.0-rc.1", than: "1.0.0"))
    }

    @Test("prereleases use SemVer identifier precedence")
    func prereleaseOrdering() {
        let ordered = [
            "1.0.0-alpha",
            "1.0.0-alpha.1",
            "1.0.0-alpha.beta",
            "1.0.0-beta",
            "1.0.0-beta.2",
            "1.0.0-beta.11",
            "1.0.0-rc.1",
            "1.0.0-rc.2",
            "1.0.0",
        ]

        for pair in zip(ordered, ordered.dropFirst()) {
            #expect(UpdateBanner.isNewerSemver(pair.1, than: pair.0))
            #expect(!UpdateBanner.isNewerSemver(pair.0, than: pair.1))
        }
    }

    @Test("numeric prerelease identifiers compare numerically")
    func numericPrereleaseOrdering() {
        #expect(UpdateBanner.isNewerSemver("1.0.0-rc.10", than: "1.0.0-rc.2"))
        #expect(!UpdateBanner.isNewerSemver("1.0.0-rc.2", than: "1.0.0-rc.10"))
    }

    @Test("build metadata does not affect precedence")
    func buildMetadataIgnored() {
        #expect(!UpdateBanner.isNewerSemver("1.0.0+build.2", than: "1.0.0+build.1"))
        #expect(!UpdateBanner.isNewerSemver("1.0.0", than: "1.0.0+build.1"))
        #expect(!UpdateBanner.isNewerSemver("1.0.0+build.1", than: "1.0.0"))
        #expect(!UpdateBanner.isNewerSemver(
            "1.0.0-rc.1+build.2",
            than: "1.0.0-rc.1+build.1"
        ))
    }

    @Test("malformed versions never trigger an update")
    func malformedVersionsNotNewer() {
        #expect(!UpdateBanner.isNewerSemver("not-a-version", than: "1.0.0"))
        #expect(!UpdateBanner.isNewerSemver("1.0.0", than: "not-a-version"))
        #expect(!UpdateBanner.isNewerSemver("1.0", than: "1.0.0"))
        #expect(!UpdateBanner.isNewerSemver("1.0.0", than: "1.0"))
        #expect(!UpdateBanner.isNewerSemver("1.0.0-rc.01", than: "1.0.0-rc.1"))
    }
}
