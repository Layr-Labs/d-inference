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

        // The loop reaches the hold (without the gate it never would), then
        // stays there: no registration, no coordinator client.
        var held = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !held, ContinuousClock.now < deadline {
            held = await fixture.loop.bootSecurityHoldActive
            if !held { try await Task.sleep(for: .milliseconds(25)) }
        }
        #expect(held)
        let register = try await fixture.mock.awaitFirstRegister(timeout: .seconds(2))
        #expect(register == nil)
        #expect(await fixture.loop.coordinatorClient == nil)
        #expect(DaemonStateFile.read(from: fixture.stateFile) != nil, "the hold keeps the liveness stamp")
        #expect(await fixture.stop(task))
        #expect(await fixture.loop.bootSecurityHoldActive == false)
    }

    @Test func aSandboxOnlyPostureHoldsAndPublishesWhy() async throws {
        let fixture = try await ServeLoopFixture.make()
        await fixture.loop.setSecurityPostureForTesting(posture(BootSecuritySnapshot(
            macOSMajorVersion: 27, sip: .enabled, sipConfiguration: SIPConfiguration(rawValue: 0),
            secureBoot: .unknown, processSandbox: .sandboxed)))
        let task = fixture.start()

        var held = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !held, ContinuousClock.now < deadline {
            held = await fixture.loop.bootSecurityHoldActive
            if !held { try await Task.sleep(for: .milliseconds(25)) }
        }
        #expect(held)
        #expect(try await fixture.mock.awaitFirstRegister(timeout: .seconds(2)) == nil)
        #expect(await fixture.loop.coordinatorClient == nil)
        // `status` and `doctor` read the service's own reason from its state, not their own process's.
        #expect(DaemonStateFile.read(from: fixture.stateFile)?.bootSecurityHold == ["process_sandbox"])
        #expect(await fixture.stop(task))
        #expect(await fixture.loop.bootSecurityHoldKinds == nil)
        // What the shutdown snapshot writes no longer names a hold (the fixture removes its files on stop).
        #expect(await fixture.loop.currentDaemonState().bootSecurityHold == nil)
    }

    @Test func anUnreadSecureBootPolicyRegistersAsUnknown() async throws {
        let fixture = try await ServeLoopFixture.make()
        await fixture.loop.setSecurityPostureForTesting(posture(BootSecuritySnapshot(
            macOSMajorVersion: 27, sip: .enabled,
            sipConfiguration: SIPConfiguration(rawValue: 0), secureBoot: .unknown)))
        let task = fixture.start()

        let register = try await fixture.awaitRegistration()
        #expect(try #require(register.privacyCapabilities).secureBoot == "unknown")
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
