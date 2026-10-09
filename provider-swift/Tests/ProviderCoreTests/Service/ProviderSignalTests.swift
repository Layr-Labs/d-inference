import Foundation
import Darwin
import Testing
@testable import ProviderCore

/// Signals change process-wide state, so each case runs in a child process
/// that sends the signal to itself.
@Suite("Provider termination signals")
struct ProviderSignalTests {
    @Test func sigtermRunsAsyncDrainInARealProcess() async {
        await #expect(processExitsWith: .success) {
            exit(await drainRuns(after: SIGTERM) ? 0 : 1)
        }
    }

    @Test("a hangup runs the same drain for a provider started by hand")
    func sighupRunsAsyncDrainInARealProcess() async {
        await #expect(processExitsWith: .success) {
            startAsIfByHand()
            exit(await drainRuns(after: SIGHUP) ? 0 : 1)
        }
    }

    @Test("a provider started with hangups ignored keeps ignoring them, and SIGTERM still drains it")
    func ignoredHangupStaysIgnored() async {
        await #expect(processExitsWith: .success) {
            startAsIfByHand()
            signal(SIGHUP, SIG_IGN)
            let hangupDrained = await drainRuns(after: SIGHUP, within: .milliseconds(500))
            let stillIgnored = ProviderStopSignals.isIgnored(SIGHUP)
            let terminationDrained = await drainRuns(after: SIGTERM)
            exit(!hangupDrained && stillIgnored && terminationDrained ? 0 : 1)
        }
    }

    @Test("the launchd job leaves a hangup with its default action")
    func launchdJobDoesNotTakeHangup() async {
        await #expect(processExitsWith: .success) {
            startAsIfByHand()
            setenv("XPC_SERVICE_NAME", LaunchAgent.label, 1)
            let handler = ProviderSignalHandler {}
            // The default action is the address 0. Read it as a number, as
            // `isIgnored` does, never as an optional function pointer.
            var hangup = sigaction()
            sigaction(SIGHUP, nil, &hangup)
            let hangupIsDefault = withUnsafeBytes(of: hangup.__sigaction_u) { $0.load(as: UInt.self) } == 0
            let terminationIsTaken = ProviderStopSignals.isIgnored(SIGTERM)
            withExtendedLifetime(handler) {}
            exit(hangupIsDefault && terminationIsTaken ? 0 : 1)
        }
    }

    @Test("a later handler in the same process still takes the hangup")
    func laterHandlerStillTakesHangup() async {
        await #expect(processExitsWith: .success) {
            startAsIfByHand()
            // A handler that goes away leaves the signals it took ignored.
            _ = ProviderSignalHandler {}
            exit(await drainRuns(after: SIGHUP) ? 0 : 1)
        }
    }

    // An ignored signal stays ignored across exec. The next three cases cover
    // a provider that replaces its own image, as an in-place update does.

    @Test("a hangup the handler took has its default action again in a re-executed image")
    func takenHangupIsDefaultAcrossExec() async {
        await #expect(processExitsWith: .signal(SIGHUP)) {
            startAsIfByHand()
            let handler = ProviderSignalHandler {}
            // Without this the case would pass for a handler that never took the hangup.
            guard ProviderStopSignals.isIgnored(SIGHUP) else { exit(3) }
            ProviderStopSignals.withHangupAsAtStart { execShellThatHangsItselfUp() }
            withExtendedLifetime(handler) {}
            exit(2)  // The exec failed.
        }
    }

    @Test("a provider started with hangups ignored still ignores them after re-executing")
    func ignoredHangupStaysIgnoredAcrossExec() async {
        await #expect(processExitsWith: .success) {
            startAsIfByHand()
            signal(SIGHUP, SIG_IGN)
            let handler = ProviderSignalHandler {}
            ProviderStopSignals.withHangupAsAtStart { execShellThatHangsItselfUp() }
            withExtendedLifetime(handler) {}
            exit(2)  // The exec failed.
        }
    }

    @Test("when re-executing fails, a hangup still drains")
    func failedExecLeavesHangupDraining() async {
        await #expect(processExitsWith: .success) {
            startAsIfByHand()
            let marker = newDrainMarker()
            let handler = installDrain(markedBy: marker)
            var defaultDuringExec = false
            ProviderStopSignals.withHangupAsAtStart {
                // An exec that fails returns here.
                defaultDuringExec = !ProviderStopSignals.isIgnored(SIGHUP)
            }
            _ = kill(getpid(), SIGHUP)
            let drained = await drainCompletes(markedBy: marker)
            withExtendedLifetime(handler) {}
            exit(defaultDuringExec && drained ? 0 : 1)
        }
    }
}

/// A child inherits its hangup disposition, signal mask and environment from
/// the test runner, which may itself run under `nohup` or launchd.
private func startAsIfByHand() {
    signal(SIGHUP, SIG_DFL)
    var hangup = sigset_t()
    sigemptyset(&hangup)
    sigaddset(&hangup, SIGHUP)
    pthread_sigmask(SIG_UNBLOCK, &hangup, nil)
    unsetenv("XPC_SERVICE_NAME")
}

/// Replaces this process with a shell that sends itself a hangup and then
/// exits 0. The shell reaches that exit only if it started with hangups
/// ignored; otherwise the hangup ends it. Returns only if the exec fails.
private func execShellThatHangsItselfUp() {
    let command = ["/bin/sh", "-c", "kill -HUP $$; exit 0"]
    var arguments: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) }
    arguments.append(nil)
    execv("/bin/sh", &arguments)
}

/// Installs the handler, sends `signo` to this process and reports whether the
/// asynchronous drain ran to completion within `limit`.
private func drainRuns(after signo: Int32, within limit: Duration = .seconds(3)) async -> Bool {
    let marker = newDrainMarker()
    let handler = installDrain(markedBy: marker)
    _ = kill(getpid(), signo)
    let drained = await drainCompletes(markedBy: marker, within: limit)
    withExtendedLifetime(handler) {}
    return drained
}

private func newDrainMarker() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

private func installDrain(markedBy marker: URL) -> ProviderSignalHandler {
    ProviderSignalHandler {
        // Accepted work can finish asynchronously after the signal; the
        // process does not exit at the signal boundary.
        try? await Task.sleep(nanoseconds: 100_000_000)
        try? Data("drained".utf8).write(to: marker)
    }
}

private func drainCompletes(markedBy marker: URL, within limit: Duration = .seconds(3)) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: limit)
    while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    let drained = (try? Data(contentsOf: marker)) == Data("drained".utf8)
    try? FileManager.default.removeItem(at: marker)
    return drained
}
