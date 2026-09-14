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

    @Test("pre-release suffix is stripped before comparison")
    func preReleaseSuffixStripped() {
        #expect(!UpdateBanner.isNewerSemver("0.5.0-rc1", than: "0.5.0"))
        #expect(UpdateBanner.isNewerSemver("0.5.1-rc1", than: "0.5.0"))
    }

    @Test("missing parts default to zero")
    func missingPartsDefaultToZero() {
        // "0.5" parses to [0, 5] which expands to [0, 5, 0] for comparison.
        #expect(!UpdateBanner.isNewerSemver("0.5", than: "0.5.0"))
        #expect(UpdateBanner.isNewerSemver("0.5.1", than: "0.5"))
    }
}
