import Foundation
import Testing
@testable import ProviderCore

/// CPU-only: a manual clock, scripted Mac-wide signals and a fake GPU seam
/// drive every keep-warm decision; no Metal device is created.
@Suite("GPU keep-warm scheduling")
struct GPUKeepWarmTests {

    private final class Harness: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = ContinuousClock.now
        private var busyNow = false
        private var idleSince: ContinuousClock.Instant
        private var loaded = true
        private var pending: [@Sendable () -> Void] = []
        private(set) var submissions = 0
        var failSubmissions = false
        var completeImmediately = false

        init(idleFor: Duration = .seconds(60)) { idleSince = instant - idleFor }

        var now: ContinuousClock.Instant { lock.withLock { instant } }
        func advance(_ duration: Duration) { lock.withLock { instant += duration } }
        func setBusy() { lock.withLock { busyNow = true } }
        func setIdle() { lock.withLock { busyNow = false; idleSince = instant } }
        func setModelLoaded(_ value: Bool) { lock.withLock { loaded = value } }
        func completePending() {
            let completions = lock.withLock { () -> [@Sendable () -> Void] in
                defer { pending.removeAll() }
                return pending
            }
            completions.forEach { $0() }
        }

        func make(_ policy: GPUKeepWarm.Policy) -> GPUKeepWarm {
            GPUKeepWarm(
                policy: policy,
                signals: .init(
                    busy: { [self] in lock.withLock { busyNow } },
                    idleFor: { [self] duration in lock.withLock { !busyNow && instant - idleSince >= duration } },
                    modelLoaded: { [self] in lock.withLock { loaded } }),
                submitter: Submitter(harness: self),
                now: { [self] in now })
        }

        fileprivate func submit(_ completed: @escaping @Sendable () -> Void) -> Bool {
            let immediate = lock.withLock { () -> Bool? in
                guard !failSubmissions else { return nil }
                submissions += 1
                if !completeImmediately { pending.append(completed) }
                return completeImmediately
            }
            guard let immediate else { return false }
            if immediate { completed() }
            return true
        }
    }

    private struct Submitter: GPUWakeSubmitting {
        let harness: Harness
        func submit(completed: @escaping @Sendable () -> Void) -> Bool { harness.submit(completed) }
    }

    private static let both = GPUKeepWarm.Policy(wakeOnAccept: true, idleHeartbeat: true)

    @Test("both modes are opt-in and each environment key is independent")
    func policyIsOptIn() {
        let wake = GPUKeepWarm.Policy.wakeOnAcceptEnvironmentKey
        let heartbeat = GPUKeepWarm.Policy.idleHeartbeatEnvironmentKey
        #expect(GPUKeepWarm.Policy(environment: [:]) == .init())
        #expect(!GPUKeepWarm.Policy(environment: [:]).isEnabled)
        for value in ["1", " TRUE ", "on", "Yes"] {
            #expect(GPUKeepWarm.Policy(environment: [wake: value]) == .init(wakeOnAccept: true))
            #expect(GPUKeepWarm.Policy(environment: [heartbeat: value]) == .init(idleHeartbeat: true))
        }
        for value in ["0", "false", "off", "", "2", "enabled"] {
            #expect(!GPUKeepWarm.Policy(environment: [wake: value, heartbeat: value]).isEnabled)
        }
    }

    @Test("both opt-ins reach the launchd provider job")
    func optInsReachTheProviderJob() {
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(GPUKeepWarm.Policy.wakeOnAcceptEnvironmentKey))
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(GPUKeepWarm.Policy.idleHeartbeatEnvironmentKey))
    }

    @Test("disabled modes never submit")
    func disabledModesSubmitNothing() async {
        let harness = Harness()
        let keepWarm = harness.make(.init())
        #expect(keepWarm.requestAccepted() == .disabled)
        #expect(keepWarm.heartbeatTick() == .disabled)
        await keepWarm.runHeartbeat(sleep: { _ in Issue.record("a disabled heartbeat must not loop") })
        #expect(harness.submissions == 0)
    }

    @Test("wake-on-accept wakes an idle Mac once per burst")
    func wakeOnAcceptCoalescesABurst() {
        let harness = Harness()
        let keepWarm = harness.make(.init(wakeOnAccept: true))
        #expect(keepWarm.requestAccepted() == .submitted)
        #expect(keepWarm.requestAccepted() == .inFlight)
        harness.completePending()
        harness.advance(.milliseconds(249))
        #expect(keepWarm.requestAccepted() == .tooSoon)
        harness.advance(.milliseconds(1))
        #expect(keepWarm.requestAccepted() == .submitted)
        #expect(harness.submissions == 2)
    }

    @Test("wake-on-accept skips while another request keeps the GPU busy")
    func wakeOnAcceptSkipsBusyMac() {
        let harness = Harness()
        harness.setBusy()
        let keepWarm = harness.make(.init(wakeOnAccept: true))
        #expect(keepWarm.requestAccepted() == .busy)
        #expect(harness.submissions == 0)
    }

    @Test("the heartbeat needs a loaded model, an idle Mac and its idle threshold")
    func heartbeatGates() {
        let harness = Harness()
        let keepWarm = harness.make(.init(idleHeartbeat: true))
        harness.setModelLoaded(false)
        #expect(keepWarm.heartbeatTick() == .noModelLoaded)
        harness.setModelLoaded(true)
        harness.setBusy()
        #expect(keepWarm.heartbeatTick() == .busy)
        harness.setIdle()
        harness.advance(.milliseconds(1_999))
        #expect(keepWarm.heartbeatTick() == .notIdleLongEnough)
        harness.advance(.milliseconds(1))
        #expect(keepWarm.heartbeatTick() == .submitted)
        harness.completePending()
        harness.advance(.milliseconds(1_499))
        #expect(keepWarm.heartbeatTick() == .tooSoon)
        harness.advance(.milliseconds(1))
        #expect(keepWarm.heartbeatTick() == .submitted)
        #expect(harness.submissions == 2)
    }

    @Test("at most one keep-warm command is in flight; a failed submit releases it")
    func oneCommandInFlight() {
        let harness = Harness()
        let keepWarm = harness.make(Self.both)
        #expect(keepWarm.heartbeatTick() == .submitted)
        harness.advance(.seconds(30))
        #expect(keepWarm.heartbeatTick() == .inFlight)
        #expect(keepWarm.requestAccepted() == .inFlight)
        harness.completePending()
        harness.failSubmissions = true
        #expect(keepWarm.heartbeatTick() == .submitFailed)
        harness.failSubmissions = false
        harness.advance(.seconds(2))
        #expect(keepWarm.heartbeatTick() == .submitted)
        #expect(harness.submissions == 2)
    }

    @Test("the heartbeat stops after its idle bound until the next accepted request")
    func heartbeatIdleBound() {
        let harness = Harness()
        harness.completeImmediately = true
        let keepWarm = harness.make(.init(idleHeartbeat: true))
        harness.advance(GPUKeepWarm.heartbeatMaxIdle)
        #expect(keepWarm.heartbeatTick() == .idleBoundReached)
        #expect(keepWarm.requestAccepted() == .disabled)
        #expect(keepWarm.heartbeatTick() == .submitted)
    }

    @Test("the heartbeat loop ticks once per interval and ends on cancellation")
    func heartbeatLoopIsBoundedAndCancellable() async {
        let harness = Harness()
        harness.completeImmediately = true
        let keepWarm = harness.make(.init(idleHeartbeat: true))
        let sleeps = Counter()
        await keepWarm.runHeartbeat(sleep: { duration in
            #expect(duration == GPUKeepWarm.heartbeatInterval)
            guard sleeps.increment() <= 4 else { throw CancellationError() }
            harness.advance(duration)
        })
        #expect(harness.submissions == 4)

        let task = Task { await keepWarm.runHeartbeat() }
        task.cancel()
        await task.value
        #expect(harness.submissions == 4)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() -> Int { lock.withLock { value += 1; return value } }
    }
}
