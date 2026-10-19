import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// `ServiceDrain.wait` reads the drain status that the running provider
/// writes to its lifecycle mailbox. The target here is this test process,
/// and the mailbox is a temporary folder, so no provider is involved.
@Suite("Service drain wait")
struct ServiceDrainWaitTests {
    private func mailboxFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("drain-\(UUID().uuidString)")
    }

    @Test("a busy provider ends the wait with the unfinished count")
    func busyEndsWait() async throws {
        let root = mailboxFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = ProviderDrainRequest(target: try #require(ProcessIdentity.current()), timeoutSeconds: 5)
        let mailbox = LifecycleMailbox(identity: request.target, directory: root)
        try mailbox.writeStatus(.init(requestID: request.id, outcome: .busy, remaining: 2))
        do {
            _ = try await ServiceDrain.wait(request: request, mailbox: mailbox)
            Issue.record("a busy provider must not count as drained")
        } catch {
            let text = String(describing: error)
            #expect(text.contains("Drain did not complete: 2 unfinished request(s)"))
            #expect(text.contains("coordinator acknowledgement false"))
        }
    }

    @Test("a forced outcome is a completed drain")
    func forcedCompletes() async throws {
        let root = mailboxFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = ProviderDrainRequest(
            target: try #require(ProcessIdentity.current()), timeoutSeconds: 5, force: true)
        let mailbox = LifecycleMailbox(identity: request.target, directory: root)
        try mailbox.writeStatus(.init(requestID: request.id, outcome: .forced, remaining: 1))
        let status = try await ServiceDrain.wait(request: request, mailbox: mailbox)
        #expect(status.outcome == .forced)
        #expect(status.remaining == 1)
    }

    @Test("a drain that waits for the coordinator acknowledgement completes when it arrives")
    func drainingThenDrained() async throws {
        let root = mailboxFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = ProviderDrainRequest(target: try #require(ProcessIdentity.current()), timeoutSeconds: 5)
        let mailbox = LifecycleMailbox(identity: request.target, directory: root)
        try mailbox.writeStatus(.init(requestID: request.id, outcome: .draining, remaining: 0))
        let writer = Task {
            try await Task.sleep(nanoseconds: 400_000_000)
            try mailbox.writeStatus(.init(
                requestID: request.id, outcome: .drained, remaining: 0, coordinatorAcknowledged: true))
        }
        let status = try await ServiceDrain.wait(request: request, mailbox: mailbox)
        try await writer.value
        #expect(status.outcome == .drained)
        #expect(status.coordinatorAcknowledged)
    }

    @Test("a target process that no longer exists ends the wait without a restart")
    func exitedTarget() async throws {
        let root = mailboxFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = try #require(ProcessIdentity.current())
        // Same PID, other start time: the identity of a process that has exited.
        let gone = ProcessIdentity(pid: current.pid, startTimeMicros: current.startTimeMicros &+ 1)
        let request = ProviderDrainRequest(target: gone, timeoutSeconds: 5)
        let mailbox = LifecycleMailbox(identity: gone, directory: root)
        do {
            _ = try await ServiceDrain.wait(request: request, mailbox: mailbox)
            Issue.record("an exited provider must not count as drained")
        } catch {
            #expect(String(describing: error).contains("Provider exited before confirming its drain."))
        }
    }

    @Test("a cancelled wait stops at once")
    func cancelledWait() async throws {
        let root = mailboxFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = ProviderDrainRequest(target: try #require(ProcessIdentity.current()), timeoutSeconds: 5)
        let mailbox = LifecycleMailbox(identity: request.target, directory: root)
        let waiting = Task { try await ServiceDrain.wait(request: request, mailbox: mailbox) }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { _ = try await waiting.value }
    }

    @Test("a zero restart timeout reports that authorization was not confirmed")
    func restartTimeout() async {
        do {
            try await ServiceDrain.waitForRestart(previous: nil, timeout: 0)
            Issue.record("a zero timeout cannot confirm a restart")
        } catch {
            #expect(String(describing: error).contains(
                "Restart launched, but fresh authorization was not confirmed within 0s."))
        }
    }

    @Test("a freshly authorized new process completes the restart wait")
    func restartConfirmed() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardOutputContent]
        ) {
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            let now = Date().timeIntervalSince1970
            sandbox.writeState(try CLICommandSandbox.runningState(
                now: now,
                trust: .init(
                    trustLevel: "self_signed", status: "online", reason: "legacy", receivedAt: now - 1,
                    authorization: .init(
                        appAttestAvailable: false, path: "legacy", sessionID: "session-2", machineID: ""))))
            try await ServiceDrain.waitForRestart(
                previous: ProcessIdentity(pid: 1, startTimeMicros: 1), timeout: 5)
        }
        #expect(decodedText(result.standardOutputContent)
            .contains("Provider restarted and freshly authorized (legacy).\n"))
    }

    @Test("drain options accept the full timeout range and reject values outside it")
    func drainOptionRange() throws {
        #expect(try Stop.parse(["--timeout", "0"]).drain.timeout == 0)
        #expect(try Stop.parse(["--timeout", "3600"]).drain.timeout == 3600)
        #expect(throws: (any Error).self) { _ = try Stop.parse(["--timeout", "3601"]) }
    }
}
