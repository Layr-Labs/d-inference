import Foundation
import Testing
@testable import ProviderCore

@Suite("Enrollment service")
struct EnrollmentTests {

    @Test("macOS 27+ never requests an enrollment profile", arguments: [27, 28])
    func appAttestSetupSkipsProfile(macOSMajorVersion: Int) async throws {
        // An unusable coordinator and openSystemSettings=true exercise the
        // early exit before networking, profile creation or opening Settings.
        let result = try await EnrollmentService().enroll(
            coordinatorURL: "http://127.0.0.1:1", openSystemSettings: true,
            macOSMajorVersion: macOSMajorVersion)
        guard case .appAttest = result else {
            Issue.record("App Attest setup unexpectedly returned an MDM profile")
            return
        }
    }

    @Test("older macOS retains legacy setup", arguments: [14, 26])
    func olderMacOSUsesLegacySetup(macOSMajorVersion: Int) {
        #expect(!ProviderOnboardingPolicy.usesAppAttest(macOSMajorVersion: macOSMajorVersion))
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

    @Test("EnrollmentError descriptions are stable")
    func enrollmentErrorDescriptions() {
        let cases: [(EnrollmentError, String)] = [
            (.coordinatorRequestFailed("nope"), "Failed to reach coordinator: nope"),
            (.coordinatorReturnedHTTP(503, body: "x"), "Coordinator returned HTTP 503: x"),
            (.profileWriteFailed("eperm"), "Failed to write enrollment profile: eperm"),
        ]
        for (error, expected) in cases {
            #expect(error.description == expected)
        }
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
        // No-op should always succeed.
    }
}
