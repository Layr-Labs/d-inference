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

    /// Boot-settings command results for the startup collector: SIP and Secure Boot at the default, and authenticated
    /// root as `root` says (nil: csrutil doesn't answer, and the seal reads `seal`).
    private static func bootSettingsCommands(root: String?, seal: String) -> SecurityCommandRunner {
        SecurityCommandRunner { executable, arguments in
            switch (executable, arguments) {
            case ("/usr/bin/csrutil", ["status"]):
                return SecurityCommandResult(terminationStatus: 0, stdout: "System Integrity Protection status: enabled.\n")
            case ("/usr/bin/csrutil", ["authenticated-root", "status"]):
                guard let root else { throw SecurityCommandRunner.CommandError.timedOut }
                return SecurityCommandResult(terminationStatus: 0, stdout: "Authenticated Root status: \(root)\n")
            case ("/usr/sbin/diskutil", ["info", "/"]):
                return SecurityCommandResult(terminationStatus: 0, stdout: "   Sealed:                    \(seal)\n")
            case ("/usr/sbin/system_profiler", ["-json", "SPiBridgeDataType"]):
                return SecurityCommandResult(terminationStatus: 0,
                                             stdout: #"{"SPiBridgeDataType":[{"ibridge_secure_boot":"Full Security"}]}"#)
            default:
                throw SecurityCommandRunner.CommandError.timedOut
            }
        }
    }

    /// Startup collects its posture with the real collector on these results: the serve loop's own startup path.
    private func startCollecting(root: String?, seal: String) async throws -> (ServeLoopFixture, Task<Void, Error>) {
        let fixture = try await ServeLoopFixture.make()
        await fixture.loop.setBootSettingsReadingForTesting(
            commands: Self.bootSettingsCommands(root: root, seal: seal), kernelSIP: SIPConfiguration(rawValue: 0))
        return (fixture, fixture.start())
    }

    @Test func startupCollectsADisabledRootThenHoldsWithoutConnecting() async throws {
        let (fixture, task) = try await startCollecting(root: "disabled", seal: "Yes")
        var held = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !held, ContinuousClock.now < deadline {
            held = await fixture.loop.bootSecurityHoldActive
            if !held { try await Task.sleep(for: .milliseconds(25)) }
        }
        #expect(held)
        #expect(DaemonStateFile.read(from: fixture.stateFile)?.bootSecurityHold == ["authenticated_root"])
        #expect(try await fixture.mock.awaitFirstRegister(timeout: .seconds(2)) == nil)
        #expect(fixture.mock.snapshot().registerFrames.isEmpty, "no registration reached the coordinator")
        #expect(await fixture.loop.coordinatorClient == nil, "no coordinator connection")
        #expect(await fixture.stop(task))
    }

    @Test func startupCollectsAnEnabledRootThenRegistersIt() async throws {
        let (fixture, task) = try await startCollecting(root: "enabled", seal: "Yes")
        let register = try await fixture.awaitRegistration()
        let capabilities = try #require(register.privacyCapabilities)
        #expect(capabilities.authenticatedRoot == true)
        #expect(capabilities.sipConfiguration == 0)
        #expect(capabilities.secureBoot == "full")
        #expect(await fixture.stop(task))
    }

    @Test func startupCollectsAnUnreadRootThenRegistersWithoutIt() async throws {
        let (fixture, task) = try await startCollecting(root: nil, seal: "Broken")
        let register = try await fixture.awaitRegistration()
        #expect(try #require(register.privacyCapabilities).authenticatedRoot == nil)
        let frame = try #require(fixture.mock.snapshot().registerFrames.first)
        #expect(String(decoding: frame, as: UTF8.self).contains("authenticated_root") == false, "the field is absent on the wire")
        #expect(await fixture.stop(task))
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

    @Test func anAuthenticatedRootOffPostureHoldsAndPublishesWhy() async throws {
        let fixture = try await ServeLoopFixture.make()
        await fixture.loop.setSecurityPostureForTesting(posture(BootSecuritySnapshot(
            macOSMajorVersion: 27, sip: .enabled, sipConfiguration: SIPConfiguration(rawValue: 0),
            secureBoot: .full, authenticatedRoot: false)))
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
        #expect(DaemonStateFile.read(from: fixture.stateFile)?.bootSecurityHold == ["authenticated_root"])
        #expect(await fixture.stop(task))
    }

    @Test func anEnabledAuthenticatedRootRegistersAsTrue() async throws {
        let fixture = try await ServeLoopFixture.make()
        await fixture.loop.setSecurityPostureForTesting(posture(BootSecuritySnapshot(
            macOSMajorVersion: 27, sip: .enabled, sipConfiguration: SIPConfiguration(rawValue: 0),
            secureBoot: .full, authenticatedRoot: true)))
        let task = fixture.start()

        let register = try await fixture.awaitRegistration()
        #expect(try #require(register.privacyCapabilities).authenticatedRoot == true)
        #expect(await fixture.stop(task))
    }

    @Test func anUnreadAuthenticatedRootRegistersWithoutTheField() async throws {
        let fixture = try await ServeLoopFixture.make()
        await fixture.loop.setSecurityPostureForTesting(posture(BootSecuritySnapshot(
            macOSMajorVersion: 27, sip: .enabled, sipConfiguration: SIPConfiguration(rawValue: 0),
            secureBoot: .full, authenticatedRoot: nil)))
        let task = fixture.start()

        let register = try await fixture.awaitRegistration()
        let capabilities = try #require(register.privacyCapabilities)
        #expect(capabilities.authenticatedRoot == nil, "unread is left out, and serving continues")
        #expect(capabilities.secureBoot == "full")
        #expect(await fixture.stop(task))
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
