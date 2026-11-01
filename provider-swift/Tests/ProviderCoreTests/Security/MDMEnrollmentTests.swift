import Foundation
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

    /// A dev and a production provider can be installed on one Mac. Each
    /// accepts only its own environment's coordinator host, and names the
    /// other install's profile instead of claiming or removing it.
    @Test func otherEnvironmentsProfileBelongsToTheOtherInstall() {
        for (owner, other) in [(BuildEnvironment.dev, BuildEnvironment.prod), (.prod, .dev)] {
            let serverURL = owner.coordinatorHTTPURL + "/mdm/connect"
            let out = """
            MDM enrollment: Yes (User Approved)
            MDM server: \(serverURL)
            """
            #expect(parseMDMEnrollmentStatus(out, environment: owner)
                == .enrolledDarkbloom(serverURL: serverURL))
            #expect(parseMDMEnrollmentStatus(out, environment: other)
                == .enrolledOtherMDM(serverURL: serverURL))
        }
        let devServer = BuildEnvironment.dev.coordinatorHTTPURL + "/mdm/connect"
        let state = parseMDMEnrollmentStatus("MDM enrollment: Yes\nMDM server: \(devServer)\n")
        #expect(!state.isDarkbloom)
        #expect(state.otherInstall == .dev)
        #expect(describeOtherMDM(state).contains("`\(BuildEnvironment.dev.cliName) unenroll`"))
        // An explicitly configured coordinator host is still accepted.
        let configuredHost = URL(string: BuildEnvironment.dev.coordinatorHTTPURL)?.host ?? ""
        #expect(parseMDMEnrollmentStatus(
            "MDM enrollment: Yes\nMDM server: \(devServer)\n", expectedHosts: [configuredHost]).isDarkbloom)
        // A foreign MDM is not attributed to either install.
        #expect(MDMEnrollmentState.enrolledOtherMDM(serverURL: "https://corp.example/mdm").otherInstall == nil)
    }

    /// The retired dev domain darkbloom.xyz is not ours: no host on it is a
    /// Darkbloom MDM server.
    @Test func retiredDevDomainIsForeign() {
        for url in ["https://api.dev.darkbloom.xyz/mdm/connect", "https://mdm.darkbloom.xyz/mdm/connect"] {
            let out = """
            MDM enrollment: Yes (User Approved)
            MDM server: \(url)
            """
            #expect(parseMDMEnrollmentStatus(out) == .enrolledOtherMDM(serverURL: url))
        }
    }

    @Test func configuredRetiredDevHostRemainsForeign() {
        let serverURL = "https://api.dev.darkbloom.xyz/mdm/connect"
        let output = """
        MDM enrollment: Yes (User Approved)
        MDM server: \(serverURL)
        """
        let runner = SecurityCommandRunner { path, arguments in
            #expect(path == "/usr/bin/profiles")
            #expect(arguments == ["status", "-type", "enrollment"])
            return SecurityCommandResult(terminationStatus: 0, stdout: output)
        }

        #expect(checkMDMEnrollment(
            coordinatorURL: "wss://api.dev.darkbloom.xyz/ws/provider",
            runner: runner
        ) == .enrolledOtherMDM(serverURL: serverURL))
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

    @Test func attestationPostureUsesTheCoordinatorTheLoopConnectsTo() {
        // `start --coordinator-url` sets ProviderLoopConfig.coordinatorURL, which
        // may differ from provider.toml; the posture check receives that URL.
        let loopConfig = ProviderLoopConfig(
            coordinatorURL: "wss://coordinator.example/ws/provider",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                memoryGb: 64, memoryAvailableGb: 64,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546),
            models: [], config: ConfigManager.parse(""))
        #expect(loopConfig.coordinatorURL != loopConfig.config.coordinator.url)
        let configured = loopConfig.coordinatorURL
        var seen: [String?] = []
        let enrolled = postureMDMEnrolled(coordinatorURL: configured) { url in
            seen.append(url)
            return .enrolledDarkbloom(serverURL: "https://coordinator.example/mdm/connect")
        }
        #expect(enrolled)
        #expect(seen == [configured])
        #expect(!postureMDMEnrolled(coordinatorURL: configured) { _ in
            .enrolledOtherMDM(serverURL: BuildEnvironment.dev.coordinatorHTTPURL + "/mdm/connect")
        })
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
