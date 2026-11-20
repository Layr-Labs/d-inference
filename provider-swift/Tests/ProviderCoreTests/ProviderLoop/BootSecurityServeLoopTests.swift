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
    /// How long a check waits for something the loop must do (hold, register, end). Only a failure waits this long:
    /// each wait ends as soon as its condition holds. Startup's real collector verifies the test host's bundle
    /// signature, which on a 4- or 8-vCPU CI Mac beside other test processes took past the earlier 15 s
    /// (runs 44681845693, 44689655059). Windows in which something must NOT happen keep their own short bounds.
    static let settle: Duration = .seconds(60)

    private func posture(_ bootSecurity: BootSecuritySnapshot) -> SecurityPosture {
        SecurityPosture(
            sipEnabled: bootSecurity.sipAtDefault, rdmaDisabled: true, secureBootEnabled: true,
            authenticatedRootEnabled: true, hardenedRuntimeEnabled: true, antiDebugEnabled: true,
            coreDumpsDisabled: true, envScrubbed: true, bundleSignatureValid: true,
            binaryHash: String(repeating: "a", count: 64), bootSecurity: bootSecurity)
    }

    #if DEBUG
    /// Boot-settings command results for the startup collector: SIP at the default, authenticated root as `root` says
    /// (nil: csrutil doesn't answer, and the seal reads `seal`), and Secure Boot as `secureBoot` answers (nil:
    /// `Full Security`).
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
            let deadline = ContinuousClock.now.advanced(by: Self.settle)
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
            let snapshot = try #require(try await fixture.mock.waitForSnapshot(timeout: Self.settle) { $0.registers.count >= 2 })
            let second = try #require(snapshot.registers[1].privacyCapabilities)
            #expect(second.secureBoot == "full", "the reconnect read it again")
            #expect(second.secureBootReadFailure == nil)
            #expect(answers.reads == 4)
        }
    }

    @Test func aDowngradeFoundBeforeConnectingEndsServingAndHolds() async throws {
        let answers = SecureBootAnswers([Self.failedSecureBootReport, Self.failedSecureBootReport,
                                         Self.secureBootReport("Reduced Security")])
        try await withSecureBootLoop(answers) { fixture, task in
            try await Self.awaitLateHold(fixture)
            #expect(DaemonStateFile.read(from: fixture.stateFile)?.bootSecurityHold == ["secure_boot"])
            #expect(try await fixture.mock.awaitFirstRegister(timeout: .seconds(2)) == nil)
            #expect(fixture.mock.snapshot().registerFrames.isEmpty, "no registration reached the coordinator")
            #expect(fixture.mock.snapshot().webSocketsOpened == 0, "no connection was opened")
            #expect(answers.reads == 3, "a policy once read isn't read again")
            let tracker = await fixture.loop.localResponseTracker
            #expect(throws: (any Error).self, "no local work is admitted") { try tracker.admit().release() }
            #expect(await !ServeLoopFixture.finishes(task, within: .seconds(1)), "the service holds, it doesn't exit")
            // A stop (here the termination path) ends the hold. Its drain needs no coordinator session, and it
            // finishes before the loop returns.
            let stopped = Task { await fixture.loop.drainAndShutdown(timeoutSeconds: 10) }
            #expect(await ServeLoopFixture.finishes(task, within: Self.settle), "a stop ends the hold")
            #expect(await fixture.loop.lifecycleStatus.outcome == .drained, "its drain finished first")
            #expect(await stopped.value, "the stop drained cleanly")
        }
    }

    @Test func aStopDuringStartupsWaitEndsTheReadsAtOnce() async throws {
        let answers = SecureBootAnswers([Self.failedSecureBootReport])
        let tenSecondWaits = SecureBootReadRetry(budget: 60, firstWait: 10, maxWait: 10, readTimeout: 1)
        try await withSecureBootLoop(answers, retry: tenSecondWaits) { fixture, task in
            let deadline = ContinuousClock.now.advanced(by: Self.settle)
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

    @Test func aDowngradeFoundOnAPlannedReconnectEndsServingAndHolds() async throws {
        let answers = SecureBootAnswers([Self.failedSecureBootReport, Self.failedSecureBootReport,
                                         Self.failedSecureBootReport, Self.secureBootReport("Reduced Security")])
        try await withSecureBootLoop(answers) { fixture, task in
            let first = try #require(try await fixture.awaitRegistration().privacyCapabilities)
            #expect(first.secureBoot == "unknown")
            await fixture.loop.requestPlannedReconnect()
            try await Self.awaitLateHold(fixture, within: Self.settle)
            #expect(answers.reads == 4)
            // A later planned reconnect starts nothing, and the hold goes on.
            await fixture.loop.requestPlannedReconnect()
            #expect(await !ServeLoopFixture.finishes(task, within: .seconds(2)))
            #expect(await fixture.loop.bootSecurityHoldActive)
            #expect(fixture.mock.snapshot().registers.count == 1, "no second registration")
        }
    }

    @Test func aRefusalDuringAnUpdateDrainHoldsUntilAStop() async throws {
        let answers = SecureBootAnswers([Self.failedSecureBootReport, Self.failedSecureBootReport,
                                         Self.failedSecureBootReport, Self.secureBootReport("Reduced Security")])
        try await withSecureBootLoop(answers) { fixture, task in
            #expect(try #require(try await fixture.awaitRegistration().privacyCapabilities).secureBoot == "unknown")
            // An update drain is open when the reconnect reads the downgrade.
            await fixture.loop.beginServingDrain(owner: .update)
            await fixture.mock.dropActiveWebSocket()
            try await Self.awaitLateHold(fixture, within: Self.settle)
            #expect(DaemonStateFile.read(from: fixture.stateFile)?.lifecycle?.outcome == .serving,
                    "the update's drain isn't reported while the service holds")
            #expect(await !ServeLoopFixture.finishes(task, within: .seconds(2)), "an update's drain doesn't end the hold")
            // A stop (or an update's restart) does, once its drain has drained.
            let identity = try #require(ProcessIdentity.current())
            let stopped = await fixture.loop.drainForLifecycle(
                request: ProviderDrainRequest(target: identity, timeoutSeconds: 5))
            #expect(stopped.outcome == .drained)
            #expect(await ServeLoopFixture.finishes(task, within: Self.settle))
            #expect(fixture.mock.snapshot().registers.count == 1)
        }
    }

    @Test func aRefusalBeforeConnectingClosesLocalAdmissionAtOnceAndForGood() async throws {
        let fixture = try await ServeLoopFixture.make()
        await fixture.loop.setBootSettingsReadingForTesting(
            commands: Self.bootSettingsCommands(root: "enabled", seal: "Yes",
                                                secureBoot: SecureBootAnswers([Self.secureBootReport("Reduced Security")])),
            kernelSIP: SIPConfiguration(rawValue: 0))
        await fixture.loop.setSecurityPostureForTesting(posture(BootSecuritySnapshot(
            macOSMajorVersion: 27, sip: .enabled, sipConfiguration: SIPConfiguration(rawValue: 0), secureBoot: .unknown)))
        await #expect(throws: RegistrationRefused.self) {
            _ = try await fixture.loop.privacyCapabilitiesBeforeConnecting()
        }
        // The refusal alone, before any teardown: no local work is admitted, and no drain's resume reopens it.
        let tracker = await fixture.loop.localResponseTracker
        #expect(throws: (any Error).self) { try tracker.admit().release() }
        tracker.setAccepting(true)
        #expect(throws: (any Error).self, "a resume doesn't reopen it") { try tracker.admit().release() }
        await #expect(throws: (any Error).self, "nor does a model reservation start") {
            try await fixture.loop.throwIfRefusingNewLocalWork()
        }
        // The mirrors the quote and heartbeat paths read close with it, and a resume's write doesn't reopen them.
        let state = await fixture.loop.state
        let model = "org/any-model"
        #expect(state.refusingNewWork && state.refusingDarkbloomWork && state.refusingNewWork(forModel: model))
        state.refusingNewWork = false
        #expect(state.refusingNewWork && state.refusingDarkbloomWork && state.refusingNewWork(forModel: model),
                "a resume doesn't reopen the quote or heartbeat mirrors")
        #expect(await fixture.loop.refusalLiveness != nil, "the state's stamp is refreshed from the refusal on")
        await fixture.loop.endRefusalLivenessForTesting()
        _ = await fixture.stop(Task<Void, Error> {})
    }

    @Test func theHoldBeginsOnlyOnceTheAppAttestWorkerHasStopped() async throws {
        let answers = SecureBootAnswers([Self.failedSecureBootReport, Self.failedSecureBootReport,
                                         Self.secureBootReport("Reduced Security")])
        let gate = Gate()
        defer { gate.open() }
        try await withSecureBootLoop(answers) { fixture, _ in
            await fixture.loop.setAppAttestWorkerRetirementForTesting(Task { await gate.wait(); return true })
            var refused = false
            let deadline = ContinuousClock.now.advanced(by: Self.settle)
            while !refused, ContinuousClock.now < deadline {
                refused = await fixture.loop.registrationRefused
                if !refused { try await Task.sleep(for: .milliseconds(25)) }
            }
            #expect(refused)
            try await Task.sleep(for: .seconds(3))
            #expect(await !fixture.loop.bootSecurityHoldActive, "the hold waits for the worker to stop")
            gate.open()
            try await Self.awaitLateHold(fixture)
        }
    }

    @Test func aStopWhoseDrainTimesOutKeepsTheHoldAndTheNextStopEndsIt() async throws {
        let answers = SecureBootAnswers([Self.failedSecureBootReport, Self.failedSecureBootReport,
                                         Self.secureBootReport("Reduced Security")])
        try await withSecureBootLoop(answers) { fixture, task in
            try await Self.awaitLateHold(fixture)
            let identity = try #require(ProcessIdentity.current())
            // The App Attest worker doesn't retire: the stop's drain times out, and the service keeps holding.
            await fixture.loop.setAppAttestWorkerRetirementForTesting(Task { false })
            let first = await fixture.loop.drainForLifecycle(request: ProviderDrainRequest(target: identity, timeoutSeconds: 5))
            #expect(first.outcome == .timedOut)
            #expect(await !ServeLoopFixture.finishes(task, within: .seconds(3)), "a stop that didn't drain leaves it holding")
            #expect(await fixture.loop.bootSecurityHoldActive)
            // The next stop drains, and ends the hold.
            await fixture.loop.setAppAttestWorkerRetirementForTesting(nil)
            let second = await fixture.loop.drainForLifecycle(request: ProviderDrainRequest(target: identity, timeoutSeconds: 5))
            #expect(second.outcome == .drained)
            #expect(await ServeLoopFixture.finishes(task, within: Self.settle))
        }
    }

    @Test func aCancellationDuringAStopsDrainWaitsForThatDrain() async throws {
        let answers = SecureBootAnswers([Self.failedSecureBootReport, Self.failedSecureBootReport,
                                         Self.secureBootReport("Reduced Security")])
        let gate = Gate()
        defer { gate.open() }
        try await withSecureBootLoop(answers) { fixture, task in
            try await Self.awaitLateHold(fixture)
            await fixture.loop.setAppAttestWorkerRetirementForTesting(Task { await gate.wait(); return true })
            let identity = try #require(ProcessIdentity.current())
            let stop = Task {
                await fixture.loop.drainForLifecycle(request: ProviderDrainRequest(target: identity, timeoutSeconds: 10))
            }
            var draining = false
            let deadline = ContinuousClock.now.advanced(by: Self.settle)
            while !draining, ContinuousClock.now < deadline {
                draining = await fixture.loop.servingDrain.owner == .lifecycle
                if !draining { try await Task.sleep(for: .milliseconds(20)) }
            }
            #expect(draining, "the stop's drain began")
            task.cancel()
            #expect(await !ServeLoopFixture.finishes(task, within: .seconds(3)), "the loop waits for the stop's drain")
            gate.open()
            #expect(await ServeLoopFixture.finishes(task, within: Self.settle))
            #expect(await stop.value.outcome == .drained)
        }
    }

    @Test func nativeOwnersStillPendingWhenTheHoldEndsEndTheLoopAsAStopThatNeedsARestart() async throws {
        let answers = SecureBootAnswers([Self.failedSecureBootReport, Self.failedSecureBootReport,
                                         Self.secureBootReport("Reduced Security")])
        try await withSecureBootLoop(answers) { fixture, task in
            // The teardown and the end of the hold both find native owners pending.
            await fixture.loop.setNativeOwnersRetiredForTesting([false])
            try await Self.awaitLateHold(fixture)
            #expect(await !fixture.loop.modelSlots.isEmpty, "their models stay loaded while the service holds")
            // A scheduled window ends (a cancellation, no stop): the loop doesn't return as if serving could resume.
            task.cancel()
            let ended = await ServeLoopFixture.finishes(task, within: Self.settle)
            #expect(ended)
            // Only a task that has ended is awaited: a loop that went on would fail here, not hang the run.
            if ended {
                await #expect(throws: InferenceError.self, "a process restart is needed") { try await task.value }
            }
        }
    }

    @Test func aStopThatRetiresPendingNativeOwnersRunsTheUnloadTheTeardownSkipped() async throws {
        let answers = SecureBootAnswers([Self.failedSecureBootReport, Self.failedSecureBootReport,
                                         Self.secureBootReport("Reduced Security")])
        try await withSecureBootLoop(answers) { fixture, task in
            // Pending at the teardown, retired by the end of the hold.
            await fixture.loop.setNativeOwnersRetiredForTesting([false, true])
            try await Self.awaitLateHold(fixture)
            #expect(await !fixture.loop.modelSlots.isEmpty, "their models stay loaded while the service holds")
            let identity = try #require(ProcessIdentity.current())
            let stopped = await fixture.loop.drainForLifecycle(
                request: ProviderDrainRequest(target: identity, timeoutSeconds: 5))
            #expect(stopped.outcome == .drained)
            let ended = await ServeLoopFixture.finishes(task, within: Self.settle)
            #expect(ended)
            #expect(await fixture.loop.modelSlots.isEmpty, "the unload the teardown skipped ran")
            if ended { await #expect(throws: Never.self, "the loop returns normally") { try await task.value } }
        }
    }

    /// Opens once; `wait()` returns after that.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        func open() { lock.withLock { opened = true } }
        func wait() async {
            while !lock.withLock({ opened }) { try? await Task.sleep(for: .milliseconds(20)) }
        }
    }

    /// Waits for the hold that follows a refusal found before connecting: its kinds published and the hold active.
    private static func awaitLateHold(_ fixture: ServeLoopFixture, within timeout: Duration = BootSecurityServeLoopTests.settle) async throws {
        var held = false
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !held, ContinuousClock.now < deadline {
            let active = await fixture.loop.bootSecurityHoldActive
            let kinds = await fixture.loop.bootSecurityHoldKinds
            held = active && kinds == ["secure_boot"]
            if !held { try await Task.sleep(for: .milliseconds(25)) }
        }
        #expect(held, "the service holds for Secure Boot")
    }

    @Test func aDowngradeFoundOnAStartupReadHoldsWithoutConnecting() async throws {
        let answers = SecureBootAnswers([Self.failedSecureBootReport, Self.secureBootReport("Permissive Security")])
        try await withSecureBootLoop(answers) { fixture, _ in
            var held = false
            let deadline = ContinuousClock.now.advanced(by: Self.settle)
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
        let deadline = ContinuousClock.now.advanced(by: Self.settle)
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
        let deadline = ContinuousClock.now.advanced(by: Self.settle)
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
        let deadline = ContinuousClock.now.advanced(by: Self.settle)
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
