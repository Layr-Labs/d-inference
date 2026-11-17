import Foundation
import Testing
@testable import ProviderCore

/// `ProviderLoop.run()` acts on the startup security posture: a refusal holds
/// before any coordinator connection; the default registers and reports the
/// exact SIP configuration and Secure Boot policy.
@Suite("Boot security in the serve loop")
struct BootSecurityServeLoopTests {
    private func posture(_ bootSecurity: BootSecuritySnapshot) -> SecurityPosture {
        SecurityPosture(
            sipEnabled: bootSecurity.sipAtDefault, rdmaDisabled: true, secureBootEnabled: true,
            authenticatedRootEnabled: true, hardenedRuntimeEnabled: true, antiDebugEnabled: true,
            coreDumpsDisabled: true, envScrubbed: true, bundleSignatureValid: true,
            binaryHash: String(repeating: "a", count: 64), bootSecurity: bootSecurity)
    }

    @Test func aRefusedPostureHoldsBeforeAnyRegistrationAndEndsOnAStop() async throws {
        let fixture = try await ServeLoopFixture.make()
        await fixture.loop.setSecurityPostureForTesting(posture(BootSecuritySnapshot(
            macOSMajorVersion: 27, sip: .enabled,
            sipConfiguration: SIPConfiguration(rawValue: 0x24), secureBoot: .permissive)))
        let task = fixture.start()

        let register = try await fixture.mock.awaitFirstRegister(timeout: .seconds(3))
        #expect(register == nil)
        #expect(await fixture.loop.coordinatorClient == nil)
        #expect(DaemonStateFile.read(from: fixture.stateFile) != nil, "the hold keeps the liveness stamp")
        #expect(await fixture.stop(task))
    }

    @Test func theDefaultPostureRegistersWithTheExactReport() async throws {
        let fixture = try await ServeLoopFixture.make()
        await fixture.loop.setSecurityPostureForTesting(posture(BootSecuritySnapshot(
            macOSMajorVersion: 27, sip: .enabled,
            sipConfiguration: SIPConfiguration(rawValue: 0), secureBoot: .full)))
        let task = fixture.start()

        let register = try await fixture.awaitRegistration()
        let capabilities = try #require(register.privacyCapabilities)
        #expect(capabilities.sipEnabled)
        #expect(capabilities.sipConfiguration == 0)
        #expect(capabilities.secureBoot == "full")
        #expect(await fixture.stop(task))
    }
}
