import Foundation
import ProviderCore
import Testing
#if canImport(Darwin)
import Darwin
#endif

@testable import darkbloom

/// The watchdog waits for SIGTERM or SIGINT and then stops its scheduler.
/// Signals change process-wide state, so each case runs in a child process
/// that sends the signal to itself. The trap ignores the default action,
/// so a signal sent before the dispatch source is ready is harmless and the
/// sender repeats it until the wait returns.
@Suite("Watchdog signal trap")
struct WatchdogSignalTrapTests {

    @Test("SIGTERM ends the wait")
    func terminationEndsWait() async {
        await #expect(processExitsWith: .success) {
            #expect(await waitForTrappedSignal(SIGTERM))
        }
    }

    @Test("SIGINT ends the wait")
    func interruptEndsWait() async {
        await #expect(processExitsWith: .success) {
            #expect(await waitForTrappedSignal(SIGINT))
        }
    }
}

/// Starts the watchdog wait, sends `signalNumber` to this process until the
/// wait returns, and reports whether it returned within ten seconds.
private func waitForTrappedSignal(_ signalNumber: Int32) async -> Bool {
    // Ignore first, as the trap does, so an early signal cannot end the process.
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let finished = SignalWaitFlag()
    let waiter = Task {
        await WatchdogSignalTrap.waitForTermination()
        finished.set()
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !finished.value, ContinuousClock.now < deadline {
        kill(getpid(), signalNumber)
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    // A second signal after the wait returned must not resume it again.
    kill(getpid(), signalNumber)
    try? await Task.sleep(nanoseconds: 20_000_000)
    let done = finished.value
    if done { await waiter.value }
    return done
}

private final class SignalWaitFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var value: Bool { lock.withLock { done } }
    func set() { lock.withLock { done = true } }
}

/// The watchdog maps each recovery outcome to the decision it persists.
/// These cases add the update/rollback wording and the backoff arithmetic.
@Suite("Watchdog recovery outcome details")
struct WatchdogRecoveryOutcomeDetailTests {

    @Test("an issued restart with an update and a rollback still persists a restart")
    func issuedRestartWithDetails() {
        #expect(Watchdog.recordRecoveryOutcome(
            .restartIssued(updatedTo: "2.0.0", rolledBackTo: "1.9.0"), grace: 300, now: 1_000) == .restart)
        #expect(Watchdog.recordRecoveryOutcome(
            .restartIssued(updatedTo: nil, rolledBackTo: "1.9.0"), grace: 300, now: 1_000) == .restart)
    }

    @Test("a rollback backoff waits for the remaining time, never a negative time")
    func backoffRemaining() {
        #expect(Watchdog.recordRecoveryOutcome(
            .retryBackoff(until: 1_450, reason: "rollback"), grace: 300, now: 1_000)
            == .waiting(remaining: 450))
        #expect(Watchdog.recordRecoveryOutcome(
            .retryBackoff(until: 900, reason: "rollback"), grace: 300, now: 1_000)
            == .waiting(remaining: 0))
        #expect(Watchdog.recordRecoveryOutcome(.lockBusy("update"), grace: 300, now: 1_000)
            == .waiting(remaining: 0))
        #expect(Watchdog.recordRecoveryOutcome(.failed("boom"), grace: 300, now: 1_000)
            == .waiting(remaining: 0))
    }

    @Test("settings fall back to defaults when the config cannot be parsed")
    func malformedConfigFailsOpen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchdog-malformed-\(UUID().uuidString).toml")
        try Data("[provider\nauto_restart = ".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = Watchdog.settings(configPath: url.path, environment: [:])
        #expect(settings.autoRestart)
        #expect(settings.autoUpdate)
        #expect(settings.coordinatorURL == CoordinatorSettings().url)
        #expect(settings.candidateStartupTimeoutSeconds == 300)
    }
}
