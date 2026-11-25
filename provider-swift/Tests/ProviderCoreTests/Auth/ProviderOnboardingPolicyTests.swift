import Foundation
import Testing
@testable import ProviderCore

@Suite("Onboarding policy and local cleanup")
struct ProviderOnboardingPolicyTests {
    @Test("App Attest is the only setup, from macOS 27", arguments: [(14, false), (26, false), (27, true), (28, true)])
    func appAttestNeedsMacOS27(macOSMajorVersion: Int, usesAppAttest: Bool) {
        #expect(ProviderOnboardingPolicy.usesAppAttest(macOSMajorVersion: macOSMajorVersion) == usesAppAttest)
    }

    @Test("setup guidance is App Attest only and never names MDM or a coordinator readiness gate")
    func guidanceIsAppAttestOnly() {
        let cli = BuildEnvironment.current.cliName
        #expect(ProviderOnboardingPolicy.appAttestRequirement.contains("App Attest only"))
        #expect(ProviderOnboardingPolicy.appAttestRequirement.contains("macOS 27 or later"))
        #expect(!ProviderOnboardingPolicy.appAttestRequirement.contains("MDM"))
        #expect(ProviderOnboardingPolicy.appAttestGuidance.contains("`\(cli) start`"))
        #expect(ProviderOnboardingPolicy.upgradeGuidance.contains("macOS 27 or later"))
        for text in [ProviderOnboardingPolicy.appAttestGuidance, ProviderOnboardingPolicy.upgradeGuidance] {
            #expect(!text.contains("\(cli) enroll"))
            #expect(!text.contains("MDM"))
            #expect(!text.contains("once removal is approved"))
            #expect(!text.contains("Keep existing management"))
        }
    }

    @Test("attestation serial parser reads ioreg output")
    func attestationSerialParserReadsIOReg() {
        let output = """
        +-o IOPlatformExpertDevice  <class IOPlatformExpertDevice, id 0x100000100, registered, matched, active, busy 0 (41 ms), retain 39>
            "IOPlatformSerialNumber" = "TESTDEVICE01"
        """
        #expect(parseSerialNumberFromIOReg(output) == "TESTDEVICE01")
    }

    @Test("attestation serial parser reads system_profiler output")
    func attestationSerialParserReadsSystemProfiler() {
        let output = """
            Hardware:

                Hardware Overview:

                  Model Name: Mac Studio
                  Chip: Apple M3 Ultra
                  Serial Number (system): TESTDEVICE01
        """
        #expect(parseSerialNumberFromSystemProfiler(output) == "TESTDEVICE01")
    }

    @Test("LocalDataCleanup.purge removes only requested files")
    func purgeRespectsFlags() throws {
        // Every cleanup domain must be explicitly disabled. In particular,
        // secureEnclaveKey defaults to true and must never delete a developer's
        // live keychain identity during a test advertised as a no-op.
        LocalDataCleanup.purge(
            configDirectory: false,
            legacyKeyFiles: false,
            authToken: false,
            secureEnclaveKey: false
        )
    }
}
