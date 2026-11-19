import Foundation
import Testing
@testable import ProviderCore

/// `ProviderLoop.run()` acts on the startup security posture: a refusal holds
/// before any coordinator connection; the default registers and reports the
/// exact SIP configuration and Secure Boot policy.
/// One test at a time: startup's real collector also checks the signature of the app bundle the test host runs
/// from (Xcode's, seconds each), and several at once outlast the waits below.
@Suite("Boot security in the serve loop", .serialized)
struct BootSecurityServeLoopTests {
    private func posture(_ bootSecurity: BootSecuritySnapshot) -> SecurityPosture {
        SecurityPosture(
            sipEnabled: bootSecurity.sipAtDefault, rdmaDisabled: true, secureBootEnabled: true,
            authenticatedRootEnabled: true, hardenedRuntimeEnabled: true, antiDebugEnabled: true,
            coreDumpsDisabled: true, envScrubbed: true, bundleSignatureValid: true,
            binaryHash: String(repeating: "a", count: 64), bootSecurity: bootSecurity)
    }

    #if DEBUG
    /// Boot-settings command results for the startup collector: SIP at the default, authenticated root as `root` says
    /// (nil: csrutil doesn't answer, and the seal reads `seal`), and Secure Boot as `secureBoot` answers (nil: Full
    /// Security).
    private static func bootSettingsCommands(root: String?, seal: String,
                                             secureBoot: SecureBootAnswers? = nil) -> SecurityCommandRunner {
        SecurityCommandRunner { executable, arguments in
            if executable != "/usr/sbin/system_profiler" { secureBoot?.noteOtherCommand() }
            switch (executable, arguments) {
            case ("/usr/bin/csrutil", ["status"]):
                return SecurityCommandResult(terminationStatus: 0, stdout: "System Integrity Protection status: enabled.\n")
            case ("/usr/bin/csrutil", ["authenticated-root", "status"]):
                guard let root else { throw SecurityCommandRunner.CommandError.timedOut }
                return SecurityCommandResult(terminationStatus: 0, stdout: "Authenticated Root status: \(root)\n")
            case ("/usr/sbin/diskutil", ["info", "/"]):
                return SecurityCommandResult(terminationStatus: 0, stdout: "   Sealed:                    \(seal)\n")
            case ("/usr/sbin/system_profiler", ["-json", "SPiBridgeDataType"]):
                return secureBoot?.next() ?? Self.secureBootReport("Full Security")
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

    /// Runs `body` against a started loop, and stops the loop and its mock even when `body` throws.
    private func withCollectingLoop(root: String?, seal: String,
                                    _ body: (ServeLoopFixture) async throws -> Void) async throws {
        let (fixture, task) = try await startCollecting(root: root, seal: seal)
        do {
            try await body(fixture)
        } catch {
            _ = await fixture.stop(task)
            throw error
        }
        #expect(await fixture.stop(task))
    }

    @Test func startupCollectsADisabledRootThenHoldsWithoutConnecting() async throws {
        try await withCollectingLoop(root: "disabled", seal: "Yes") { fixture in
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
        }
    }

    @Test func startupCollectsAnEnabledRootThenRegistersIt() async throws {
        try await withCollectingLoop(root: "enabled", seal: "Yes") { fixture in
            let register = try await fixture.awaitRegistration()
            let capabilities = try #require(register.privacyCapabilities)
            #expect(capabilities.authenticatedRoot == true)
            #expect(capabilities.sipConfiguration == 0)
            #expect(capabilities.secureBoot == "full")
        }
    }

    @Test func startupCollectsAnUnreadRootThenRegistersWithoutIt() async throws {
        try await withCollectingLoop(root: nil, seal: "Broken") { fixture in
            let register = try await fixture.awaitRegistration()
            #expect(try #require(register.privacyCapabilities).authenticatedRoot == nil)
            let frame = try #require(fixture.mock.snapshot().registerFrames.first)
            #expect(String(decoding: frame, as: UTF8.self).contains("authenticated_root") == false,
                    "the field is absent on the wire")
        }
    }

    private static func secureBootReport(_ value: String) -> SecurityCommandResult {
        SecurityCommandResult(terminationStatus: 0, stdout: #"{"SPiBridgeDataType":[{"ibridge_secure_boot":"\#(value)"}]}"#)
    }

    private static let failedSecureBootReport = SecurityCommandResult(terminationStatus: 1, stderr: "system_profiler: no report\n")

    /// system_profiler's answers in order (the last one repeats), how many it gave, and how many other
    /// boot-settings commands ran.
    private final class SecureBootAnswers: @unchecked Sendable {
        private let lock = NSLock()
        private let answers: [SecurityCommandResult]
        private var given = 0
        private var others = 0
        init(_ answers: [SecurityCommandResult]) { self.answers = answers }
        func next() -> SecurityCommandResult {
            lock.withLock {
                given += 1
                return answers[min(given, answers.count) - 1]
            }
        }
        func noteOtherCommand() { lock.withLock { others += 1 } }
        var reads: Int { lock.withLock { given } }
        var otherCommands: Int { lock.withLock { others } }
    }

    /// Exactly two Secure Boot reads at startup when the first fails: the second starts 1 s after the first (with a
    /// second of slack), and a third, 2 s after that, would leave it less than a second of the 3 s budget.
    private static let twoStartupReads = SecureBootReadRetry(budget: 3, firstWait: 1, maxWait: 10, readTimeout: 1)

    /// Runs `body` against a loop that reads Secure Boot from `answers` (authenticated root enabled), and stops the
    /// loop and its mock even when `body` throws.
    private func withSecureBootLoop(_ answers: SecureBootAnswers,
                                    retry: SecureBootReadRetry = BootSecurityServeLoopTests.twoStartupReads,
                                    _ body: (ServeLoopFixture, Task<Void, Error>) async throws -> Void) async throws {
        let fixture = try await ServeLoopFixture.make()
        await fixture.loop.setBootSettingsReadingForTesting(
            commands: Self.bootSettingsCommands(root: "enabled", seal: "Yes", secureBoot: answers),
            kernelSIP: SIPConfiguration(rawValue: 0))
        await fixture.loop.setSecureBootReadRetryForTesting(retry)
        let task = fixture.start()
        do {
            try await body(fixture, task)
        } catch {
            _ = await fixture.stop(task)
            throw error
        }
        #expect(await fixture.stop(task))
    }

    @Test func startupReadsSecureBootAgainAfterAFailedReadThenRegistersFull() async throws {
        let answers = SecureBootAnswers([Self.failedSecureBootReport, Self.secureBootReport("Full Security")])
        try await withSecureBootLoop(answers) { fixture, _ in
            let capabilities = try #require(try await fixture.awaitRegistration().privacyCapabilities)
            #expect(capabilities.secureBoot == "full")
            #expect(capabilities.secureBootReadFailure == nil)
            #expect(capabilities.secureBootReadAttempts == nil)
            #expect(answers.reads == 2, "read again at startup; a policy once read isn't read before connecting")
        }
    }

    @Test func anUnreadSecureBootIsReadAgainBeforeRegisteringAndReportsWhy() async throws {
        let answers = SecureBootAnswers([Self.failedSecureBootReport])
        try await withSecureBootLoop(answers) { fixture, _ in
            let capabilities = try #require(try await fixture.awaitRegistration().privacyCapabilities)
            #expect(capabilities.secureBoot == "unknown")
            #expect(capabilities.secureBootReadFailure == "exit_status")
            #expect(capabilities.secureBootReadAttempts == 3, "two reads at startup, one before connecting")
            #expect(answers.reads == 3)
        }
    }

    @Test func aReadBeforeRegisteringReplacesAnUnreadStartupReading() async throws {
        let answers = SecureBootAnswers([Self.failedSecureBootReport, Self.failedSecureBootReport,
                                         Self.secureBootReport("Full Security")])
        try await withSecureBootLoop(answers) { fixture, _ in
            let capabilities = try #require(try await fixture.awaitRegistration().privacyCapabilities)
            #expect(capabilities.secureBoot == "full")
            #expect(capabilities.secureBootReadFailure == nil)
            #expect(capabilities.secureBootReadAttempts == nil)
        }
    }

    @Test func eachReconnectReadsAnUnreadSecureBootAgain() async throws {
        let answers = SecureBootAnswers([Self.failedSecureBootReport, Self.failedSecureBootReport,
                                         Self.failedSecureBootReport, Self.secureBootReport("Full Security")])
        try await withSecureBootLoop(answers) { fixture, _ in
            let first = try #require(try await fixture.awaitRegistration().privacyCapabilities)
            #expect(first.secureBoot == "unknown")
            #expect(first.secureBootReadAttempts == 3)
            await fixture.mock.dropActiveWebSocket()
            let snapshot = try #require(try await fixture.mock.waitForSnapshot(timeout: .seconds(15)) { $0.registers.count >= 2 })
            let second = try #require(snapshot.registers[1].privacyCapabilities)
            #expect(second.secureBoot == "full", "the reconnect read it again")
            #expect(second.secureBootReadFailure == nil)
            #expect(answers.reads == 4)
        }
    }

    @Test func aDowngradeFoundBeforeConnectingKeepsEveryConnectionFromRegistering() async throws {
        let answers = SecureBootAnswers([Self.failedSecureBootReport, Self.failedSecureBootReport,
                                         Self.secureBootReport("Reduced Security")])
        try await withSecureBootLoop(answers) { fixture, _ in
            var published = false
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while !published, ContinuousClock.now < deadline {
                published = await fixture.loop.bootSecurityHoldKinds == ["secure_boot"]
                if !published { try await Task.sleep(for: .milliseconds(25)) }
            }
            #expect(published, "the service names why it doesn't serve")
            #expect(DaemonStateFile.read(from: fixture.stateFile)?.bootSecurityHold == ["secure_boot"])
            #expect(try await fixture.mock.awaitFirstRegister(timeout: .seconds(3)) == nil)
            #expect(fixture.mock.snapshot().registerFrames.isEmpty, "no registration reached the coordinator")
            #expect(fixture.mock.snapshot().webSocketsOpened == 0, "no connection was opened")
            #expect(answers.reads == 3, "a policy once read isn't read again")
        }
    }

    @Test func aStopDuringStartupsWaitEndsTheReadsAtOnce() async throws {
        let answers = SecureBootAnswers([Self.failedSecureBootReport])
        let tenSecondWaits = SecureBootReadRetry(budget: 60, firstWait: 10, maxWait: 10, readTimeout: 1)
        try await withSecureBootLoop(answers, retry: tenSecondWaits) { fixture, task in
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while answers.reads == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
            #expect(answers.reads == 1)
            await fixture.loop.beginServingDrain(owner: .lifecycle)
            // Without the stop the next read would come 10 s after the first; the loop ends well before that.
            #expect(await ServeLoopFixture.finishes(task, within: .seconds(8)))
            #expect(answers.reads == 1)
            #expect(answers.otherCommands == 0, "no later probe ran")
            #expect(await fixture.loop.securityPosture == nil, "nothing adopted")
            #expect(fixture.mock.snapshot().registerFrames.isEmpty)
        }
    }

    @Test func aDowngradeFoundOnAPlannedReconnectEndsItsDrainAndKeepsLocalWork() async throws {
        let answers = SecureBootAnswers([Self.failedSecureBootReport, Self.failedSecureBootReport,
                                         Self.failedSecureBootReport, Self.secureBootReport("Reduced Security")])
        try await withSecureBootLoop(answers) { fixture, _ in
            let first = try #require(try await fixture.awaitRegistration().privacyCapabilities)
            #expect(first.secureBoot == "unknown")
            await fixture.loop.requestPlannedReconnect()
            var published = false
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while !published, ContinuousClock.now < deadline {
                published = await fixture.loop.bootSecurityHoldKinds == ["secure_boot"]
                if !published { try await Task.sleep(for: .milliseconds(25)) }
            }
            #expect(published, "the reconnect read the downgrade")
            #expect(answers.reads == 4)
            // The reconnect's drain ended with it: local work is admitted, the coordinator's isn't.
            #expect(await !fixture.loop.servingDrain.refusing)
            #expect(await !fixture.loop.state.refusingNewWork)
            let tracker = await fixture.loop.localResponseTracker
            let lease = try tracker.admit()
            lease.release()
            try await Task.sleep(for: .seconds(2))
            #expect(fixture.mock.snapshot().registers.count == 1, "no second registration")
        }
    }

    @Test func aDowngradeFoundOnAStartupReadHoldsWithoutConnecting() async throws {
        let answers = SecureBootAnswers([Self.failedSecureBootReport, Self.secureBootReport("Permissive Security")])
        try await withSecureBootLoop(answers) { fixture, _ in
            var held = false
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while !held, ContinuousClock.now < deadline {
                held = await fixture.loop.bootSecurityHoldActive
                if !held { try await Task.sleep(for: .milliseconds(25)) }
            }
            #expect(held)
            #expect(DaemonStateFile.read(from: fixture.stateFile)?.bootSecurityHold == ["secure_boot"])
            #expect(try await fixture.mock.awaitFirstRegister(timeout: .seconds(2)) == nil)
            #expect(await fixture.loop.coordinatorClient == nil, "no coordinator connection")
            #expect(answers.reads == 2)
        }
    }
    #endif

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
