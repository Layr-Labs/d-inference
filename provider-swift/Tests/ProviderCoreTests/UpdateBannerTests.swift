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

    @Test("pre-release identifiers use SemVer precedence")
    func preReleasePrecedence() {
        #expect(UpdateBanner.isNewerSemver("0.5.0", than: "0.5.0-rc.1"))
        #expect(!UpdateBanner.isNewerSemver("0.5.0-rc.1", than: "0.5.0"))
        #expect(UpdateBanner.isNewerSemver("0.5.0-rc.2", than: "0.5.0-rc.1"))
        #expect(UpdateBanner.isNewerSemver("0.5.0-beta", than: "0.5.0-alpha"))
    }

    @Test("build metadata is equal precedence")
    func buildMetadataDoesNotOrderVersions() {
        #expect(!UpdateBanner.isNewerSemver("0.5.0+build.2", than: "0.5.0"))
        #expect(!UpdateBanner.isNewerSemver("0.5.0", than: "0.5.0+build.2"))
        #expect(
            !UpdateBanner.isNewerSemver(
                "0.5.0+build.2",
                than: "0.5.0+build.1"
            )
        )
    }

    @Test("noncanonical versions never produce a banner")
    func noncanonicalVersionsAreRejected() {
        #expect(!UpdateBanner.isNewerSemver("0.5", than: "0.4.0"))
        #expect(!UpdateBanner.isNewerSemver("0.5.1", than: "0.5"))
        #expect(!UpdateBanner.isNewerSemver("01.0.0", than: "0.9.0"))
        #expect(!UpdateBanner.isNewerSemver("1.0.0-alpha.01", than: "0.9.0"))
    }

    @Test("numeric identifiers are not machine-width limited")
    func unboundedNumericIdentifiers() {
        #expect(
            UpdateBanner.isNewerSemver(
                "184467440737095516160.0.0",
                than: "2.0.0"
            )
        )
    }
}
