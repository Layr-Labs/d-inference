import Testing
@testable import ProviderCore

/// Regression tests for the enroll "Already enrolled" bug: the old heuristic
/// (marker file / `profiles list` / mdmclient substring) reported a Mac with no
/// Darkbloom profile as enrolled, permanently blocking re-enrollment. The new
/// check parses `profiles status -type enrollment` and matches the MDM server
/// host, so it must distinguish ours / foreign / none.
@Suite struct MDMEnrollmentTests {

    @Test func darkbloomProdServerIsOurs() {
        let out = """
        Enrolled via DEP: No
        MDM enrollment: Yes (User Approved)
        MDM server: https://api.darkbloom.dev/mdm/connect
        """
        #expect(parseMDMEnrollmentStatus(out)
            == .enrolledDarkbloom(serverURL: "https://api.darkbloom.dev/mdm/connect"))
    }

    @Test func darkbloomDevServerIsOurs() {
        let out = """
        MDM enrollment: Yes (User Approved)
        MDM server: https://api.dev.darkbloom.xyz/mdm/connect
        """
        #expect(parseMDMEnrollmentStatus(out).isDarkbloom)
    }

    @Test func coordinatorHostFromConfigIsAccepted() {
        // A self-hosted / future coordinator host outside the static lists is
        // matched via the configured coordinator URL's host.
        let out = """
        MDM enrollment: Yes
        MDM server: https://coordinator.example.com/mdm/connect
        """
        #expect(parseMDMEnrollmentStatus(out, expectedHosts: ["coordinator.example.com"]).isDarkbloom)
        #expect(!parseMDMEnrollmentStatus(out).isDarkbloom)
    }

    @Test func corporateMDMIsForeign() {
        let out = """
        Enrolled via DEP: Yes
        MDM enrollment: Yes (User Approved)
        MDM server: https://3a58bd58.web-api.kandji.io/mdm/commands
        """
        #expect(parseMDMEnrollmentStatus(out)
            == .enrolledOtherMDM(serverURL: "https://3a58bd58.web-api.kandji.io/mdm/commands"))
    }

    @Test func notEnrolledIsNotEnrolled() {
        let out = """
        Enrolled via DEP: No
        MDM enrollment: No
        """
        #expect(parseMDMEnrollmentStatus(out) == .notEnrolled)
    }

    /// THE original false positive: the `Enrolled via DEP` line contains the
    /// substring "enrolled" — it must never make an unenrolled Mac "enrolled".
    @Test func depLineAloneIsNotEnrollment() {
        #expect(parseMDMEnrollmentStatus("Enrolled via DEP: No") == .notEnrolled)
        #expect(parseMDMEnrollmentStatus("Enrolled via DEP: Yes") == .notEnrolled)
    }

    @Test func emptyOrGarbageOutputIsNotEnrolled() {
        #expect(parseMDMEnrollmentStatus("") == .notEnrolled)
        #expect(parseMDMEnrollmentStatus("profiles tool not available") == .notEnrolled)
    }

    /// Enrolled but unparsable server: must NOT claim Darkbloom (that would
    /// resurrect the skip-enrollment bug) — report as foreign for inspection.
    @Test func enrolledWithoutServerIsForeign() {
        let out = "MDM enrollment: Yes (User Approved)"
        #expect(parseMDMEnrollmentStatus(out) == .enrolledOtherMDM(serverURL: "<unknown>"))
    }

    @Test func hostMatchingIsCaseInsensitive() {
        let out = """
        MDM enrollment: Yes
        MDM server: https://API.DARKBLOOM.DEV/mdm/connect
        """
        #expect(parseMDMEnrollmentStatus(out).isDarkbloom)
    }
}
