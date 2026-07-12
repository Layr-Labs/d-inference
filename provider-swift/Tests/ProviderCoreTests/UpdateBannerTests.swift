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

    @Test("pre-release ordering follows SemVer")
    func preReleaseOrdering() {
        #expect(!UpdateBanner.isNewerSemver("0.5.0-rc1", than: "0.5.0"))
        #expect(UpdateBanner.isNewerSemver("0.5.1-rc1", than: "0.5.0"))
        #expect(UpdateBanner.isNewerSemver("0.5.0-beta.2", than: "0.5.0-beta.1"))
        #expect(UpdateBanner.isNewerSemver("0.5.0", than: "0.5.0-beta.9"))
    }

    @Test("invalid abbreviated versions are rejected")
    func abbreviatedVersionsRejected() {
        #expect(!UpdateBanner.isNewerSemver("0.5", than: "0.5.0"))
        #expect(!UpdateBanner.isNewerSemver("0.5.1", than: "0.5"))
    }
}
