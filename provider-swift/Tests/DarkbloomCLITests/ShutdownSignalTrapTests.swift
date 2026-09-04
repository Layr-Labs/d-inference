import Foundation
import Testing
@testable import ProviderCore
@testable import darkbloom

/// The serve command's SIGTERM/SIGINT trap (T1-08 phase 2). These raise a
/// real signal at the test process, so the trap must be armed first — an
/// unarmed SIGTERM takes the default action and kills the runner — and every
/// test tears the trap down (`disarmForTesting`) so a stale source cannot
/// turn the next test's signal into the second-signal exit. The production
/// escalation would exit the runner 5 s after any of these signals, so each
/// test injects its own.
@Suite("Shutdown signal trap", .serialized)
struct ShutdownSignalTrapTests {

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        var value: Bool { lock.withLock { _value } }
        func set() { lock.withLock { _value = true } }
    }

    private final class ExitRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var statuses: [Int32] = []
        var value: [Int32] { lock.withLock { statuses } }
        func record(_ status: Int32) { lock.withLock { statuses.append(status) } }
    }

    private func waitUntilArmed() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !ShutdownSignalTrap.isArmed, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(ShutdownSignalTrap.isArmed, "trap never armed")
    }

    private func awaitRelease(of waiter: Task<Void, Never>, within: Duration = .seconds(5)) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await waiter.value; return true }
            group.addTask { try? await Task.sleep(for: within); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// Whether the process's current disposition for `signo` is SIG_DFL.
    private func dispositionIsDefault(_ signo: Int32) -> Bool {
        var action = sigaction()
        sigaction(signo, nil, &action)
        return unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self) == 0
    }

    @Test("cancelling the waiter (serve task ended) releases it without a signal and restores SIG_DFL")
    func cancellationReleasesWaiter() async throws {
        defer { ShutdownSignalTrap.disarmForTesting() }
        let waiter = Task { await ShutdownSignalTrap.waitForTermination(escalation: .disabled) }
        try await waitUntilArmed()
        #expect(!dispositionIsDefault(SIGTERM), "the trap did not install its no-op disposition")
        waiter.cancel()
        #expect(await awaitRelease(of: waiter), "waiter did not release on cancellation")
        #expect(!ShutdownSignalTrap.isArmed)
        // "so a later signal takes the default action again" — actually true.
        #expect(dispositionIsDefault(SIGTERM))
        #expect(dispositionIsDefault(SIGINT))
    }

    @Test("the first SIGTERM releases the waiter (the graceful path), never kills the process")
    func firstSignalReleasesWaiter() async throws {
        defer { ShutdownSignalTrap.disarmForTesting() }
        let waiter = Task { await ShutdownSignalTrap.waitForTermination(escalation: .disabled) }
        try await waitUntilArmed()
        // Exactly one signal: a second one is the forced exit by design.
        kill(getpid(), SIGTERM)
        #expect(await awaitRelease(of: waiter), "SIGTERM did not release the waiter")
    }

    /// A wedged loop actor never runs `beginShutdownDrain`: the escalation
    /// exits with the forced status once its delay passes without the drain
    /// having started, instead of lingering until launchd's SIGKILL.
    @Test("the escalation exits when the drain has not started within its delay")
    func escalationExitsWhenDrainNeverStarts() async throws {
        defer { ShutdownSignalTrap.disarmForTesting() }
        let exits = ExitRecorder()
        let escalation = ShutdownSignalTrap.Escalation(
            delay: .milliseconds(200),
            drainStarted: { false },
            exit: { exits.record($0) })
        let waiter = Task { await ShutdownSignalTrap.waitForTermination(escalation: escalation) }
        try await waitUntilArmed()
        kill(getpid(), SIGTERM)
        #expect(await awaitRelease(of: waiter))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while exits.value.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(exits.value == [ShutdownSignalTrap.forcedExitStatus], "escalation did not exit: \(exits.value)")
    }

    @Test("the escalation stays quiet when the drain has started, and when it is disarmed")
    func escalationQuietWhenDraining() async throws {
        defer { ShutdownSignalTrap.disarmForTesting() }
        let exits = ExitRecorder()
        let drainStarted = Flag()
        let escalation = ShutdownSignalTrap.Escalation(
            delay: .milliseconds(200),
            drainStarted: { drainStarted.value },
            exit: { exits.record($0) })
        let waiter = Task { await ShutdownSignalTrap.waitForTermination(escalation: escalation) }
        try await waitUntilArmed()
        drainStarted.set()  // what beginShutdownDrain does before its first await
        kill(getpid(), SIGTERM)
        #expect(await awaitRelease(of: waiter))
        try await Task.sleep(for: .milliseconds(600))
        #expect(exits.value.isEmpty, "escalation fired on a draining process: \(exits.value)")
        ShutdownSignalTrap.disarmForTesting()

        // Disarmed (the serve task returned): no exit even without a drain.
        let waiter2 = Task { await ShutdownSignalTrap.waitForTermination(escalation: ShutdownSignalTrap.Escalation(
            delay: .milliseconds(200), drainStarted: { false }, exit: { exits.record($0) })) }
        try await waitUntilArmed()
        kill(getpid(), SIGTERM)
        #expect(await awaitRelease(of: waiter2))
        ShutdownSignalTrap.disarmEscalation()
        try await Task.sleep(for: .milliseconds(600))
        #expect(exits.value.isEmpty, "escalation fired after being disarmed: \(exits.value)")
    }

    // MARK: - runUntilTerminationSignal (the serve command's driver)

    /// SIGTERM cancels the serve task; the function returns only after the
    /// serve task finished its (uncancellable) drain, and without throwing —
    /// the trap's release and the cancellation surface as CancellationError
    /// inside the group, never as a serve failure.
    @Test("SIGTERM cancels the serve task and the driver returns after its drain, without throwing")
    func signalDrainsThenReturns() async throws {
        defer { ShutdownSignalTrap.disarmForTesting() }
        let cancelled = Flag()
        let drained = Flag()
        let exits = ExitRecorder()
        let escalation = ShutdownSignalTrap.Escalation(
            delay: .milliseconds(300),
            drainStarted: { cancelled.value },
            exit: { exits.record($0) })

        let signaller = Task {
            try await waitUntilArmed()
            kill(getpid(), SIGTERM)
        }
        defer { signaller.cancel() }

        let returnedAfterDrain = Flag()
        try await Start.runUntilTerminationSignal(escalation: escalation) {
            await withTaskCancellationHandler {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                // The drain: not cancellable, like beginShutdownDrain's task.
                await Task.detached { try? await Task.sleep(for: .milliseconds(400)) }.value
                drained.set()
            } onCancel: {
                cancelled.set()
            }
        }
        if drained.value { returnedAfterDrain.set() }
        #expect(cancelled.value, "the serve task was not cancelled by the signal")
        #expect(returnedAfterDrain.value, "the driver returned before the drain finished")
        #expect(exits.value.isEmpty, "escalation fired on a draining serve task: \(exits.value)")
    }

    /// The other direction: the serve task ends on its own (loop exit) and
    /// the driver returns without any signal.
    @Test("a serve task that returns on its own releases the driver")
    func serveExitReleasesDriver() async throws {
        defer { ShutdownSignalTrap.disarmForTesting() }
        let returned = Flag()
        try await Start.runUntilTerminationSignal(escalation: .disabled) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        returned.set()
        #expect(returned.value)
        #expect(!ShutdownSignalTrap.isArmed)
    }

    /// A serve task that ignores the cancellation (wedged loop actor): the
    /// escalation's exit hook fires while the driver is still waiting.
    @Test("a serve task that ignores cancellation trips the escalation")
    func wedgedServeTripsEscalation() async throws {
        defer { ShutdownSignalTrap.disarmForTesting() }
        let exits = ExitRecorder()
        let escalation = ShutdownSignalTrap.Escalation(
            delay: .milliseconds(200),
            drainStarted: { false },
            exit: { exits.record($0) })
        let signaller = Task {
            try await waitUntilArmed()
            kill(getpid(), SIGTERM)
        }
        defer { signaller.cancel() }
        let driver = Task {
            try await Start.runUntilTerminationSignal(escalation: escalation) {
                // Never observes cancellation for 2 s — the wedge.
                await Task.detached { try? await Task.sleep(for: .seconds(2)) }.value
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while exits.value.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(exits.value == [ShutdownSignalTrap.forcedExitStatus], "escalation did not fire on a wedged serve task")
        _ = try? await driver.value
    }
}
