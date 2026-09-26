import ArgumentParser
import Foundation
import Darwin
import Testing
@testable import darkbloom
@testable import ProviderCore

@Suite("Graceful lifecycle CLI")
struct ServiceDrainTests {
    @Test func explicitForceAndDeadlineParsing() throws {
        let stop = try Stop.parse(["--timeout", "12", "--force"])
        #expect(stop.drain.timeout == 12)
        #expect(stop.drain.force)
        let restart = try Restart.parse([])
        #expect(restart.drain.timeout == 600)
        #expect(!restart.drain.force)
        #expect(restart.startupTimeout == 180)
        #expect(throws: (any Error).self) { _ = try Stop.parse(["--timeout", "-1"]) }
        #expect(throws: (any Error).self) { _ = try Restart.parse(["--startup-timeout", "0"]) }
    }

    @Test func deadlineFailureIsNotPermissionToKill() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = ProviderDrainRequest(target: try #require(ProcessIdentity.current()), timeoutSeconds: 0)
        let mailbox = LifecycleMailbox(identity: request.target, directory: root)
        try mailbox.writeStatus(.init(requestID: request.id, outcome: .timedOut, remaining: 2))
        await #expect(throws: (any Error).self) { try await ServiceDrain.wait(request: request, mailbox: mailbox) }
        #expect(request.target.isCurrent())
    }

    @Test func matchingDrainedReceiptIsRequired() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = ProviderDrainRequest(target: try #require(ProcessIdentity.current()), timeoutSeconds: 1)
        let mailbox = LifecycleMailbox(identity: request.target, directory: root)
        try mailbox.writeStatus(.init(requestID: "old-command", outcome: .drained))
        let writer = Task {
            try await Task.sleep(nanoseconds: 30_000_000)
            try mailbox.writeStatus(.init(requestID: request.id, outcome: .drained, coordinatorAcknowledged: true))
        }
        let result = try await ServiceDrain.wait(request: request, mailbox: mailbox)
        try await writer.value
        #expect(result.requestID == request.id)
        #expect(result.coordinatorAcknowledged)
    }
}


@Test func restartRequiresNewProcessAndFreshExplicitAuthorization() {
    let old = ProcessIdentity(pid: 1, startTimeMicros: 100)
    let new = ProcessIdentity(pid: 1, startTimeMicros: 200)
    var state = DaemonState(pid: 1, processIdentity: new, version: "test", writtenAt: 1000, startedAt: 900,
        trust: .init(trustLevel: "self_signed", status: "online", reason: "verified", receivedAt: 990,
            authorization: .init(appAttestAvailable: true, path: "app_attest", expiresAt: 1010, sessionID: "fresh", machineID: "machine")))
    #expect(ServiceDrain.restartReady(state: state, previous: old, now: 1000, isCurrent: { _ in true }))
    #expect(!ServiceDrain.restartReady(state: state, previous: new, now: 1000, isCurrent: { _ in true }))
    #expect(!ServiceDrain.restartReady(state: state, previous: old, now: 1011, isCurrent: { _ in true }))
    state.trust?.authorization = nil
    state.trust?.trustLevel = "hardware"
    #expect(!ServiceDrain.restartReady(state: state, previous: old, now: 1000, isCurrent: { _ in true }))
    state.trust?.authorization = .init(appAttestAvailable: false, path: "legacy", sessionID: "new-legacy", machineID: "")
    #expect(ServiceDrain.restartReady(state: state, previous: old, now: 1000, isCurrent: { _ in true }))
    state.trust?.receivedAt = 800
    #expect(!ServiceDrain.restartReady(state: state, previous: old, now: 1000, isCurrent: { _ in true }))
}


@Test func scheduledIdleCommandCannotReopenAtNextWindow() async {
    await #expect(processExitsWith: .success) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("DARKBLOOM_STATE_FILE", root.appendingPathComponent("daemon.json").path, 1)
        let identity = try #require(ProcessIdentity.current())
        let mailbox = LifecycleMailbox(identity: identity)
        let request = ProviderDrainRequest(target: identity, timeoutSeconds: 1)
        try mailbox.writeRequest(request)
        actor Result { var completed = false; func finish() { completed = true } }
        let result = Result()
        let start = try Start.parse([])
        let waiting = Task {
            _ = try await start.waitOutsideSchedule(seconds: 0.01, coordinatorURL: "http://127.0.0.1:0")
            await result.finish()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while mailbox.readStatus()?.requestID != request.id, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 40_000_000)
        let keptClosed = !(await result.completed)
        let acknowledged = mailbox.readStatus()?.outcome == .drained
        waiting.cancel()
        _ = try? await waiting.value
        try? FileManager.default.removeItem(at: root)
        exit(keptClosed && acknowledged ? 0 : 1)
    }
}

@Test func signalBeforeScheduleHandlerInstallationDisarmsRecovery() async {
    await #expect(processExitsWith: .success) {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let start = try Start.parse([])
        let signals = ProviderSignalHandler { _ = await ProviderTermination.shared.request() }
        _ = kill(getpid(), SIGTERM)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await !ProviderTermination.shared.terminationRequested, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await start.installIdleScheduleTerminationHandler(disarmRecovery: {
            try Data("disarmed".utf8).write(to: marker)
        })
        let exited = try await start.waitOutsideSchedule(seconds: 30, coordinatorURL: "http://127.0.0.1:0")
        withExtendedLifetime(signals) {}
        let disarmed = (try? Data(contentsOf: marker)) == Data("disarmed".utf8)
        try? FileManager.default.removeItem(at: marker)
        exit(exited && disarmed ? 0 : 1)
    }
}


@Suite("Lifecycle recovery rollback")
struct LifecycleRecoveryRollbackTests {
    @Test func failedPublicationRestoresPriorRecovery() {
        struct Failure: Error {}
        var calls: [String] = []
        #expect(throws: Failure.self) {
            try ServiceDrain.publishWithRecoveryRollback(disable: { calls.append("disable") },
                publish: { calls.append("publish"); throw Failure() }, restore: { calls.append("restore") })
        }
        #expect(calls == ["disable", "publish", "restore"])
    }
    @Test func partialDisableFailureRestoresAndDoesNotPublish() {
        struct Failure: Error {}
        var calls: [String] = []
        #expect(throws: Failure.self) {
            try ServiceDrain.publishWithRecoveryRollback(disable: { calls.append("disable"); throw Failure() },
                publish: { calls.append("publish") }, restore: { calls.append("restore") })
        }
        #expect(calls == ["disable", "restore"])
    }
    @Test func publishedTimeoutDoesNotRearmDuringDrain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try #require(ProcessIdentity.current())
        let request = ProviderDrainRequest(target: identity, timeoutSeconds: 0)
        let mailbox = LifecycleMailbox(identity: identity, directory: root)
        var restored = false
        try ServiceDrain.publishWithRecoveryRollback(disable: {}, publish: {
            try mailbox.writeRequest(request)
        }, restore: { restored = true })
        try mailbox.writeStatus(.init(requestID: request.id, outcome: .timedOut, remaining: 1))
        await #expect(throws: (any Error).self) { try await ServiceDrain.wait(request: request, mailbox: mailbox) }
        #expect(!restored)
    }
    @Test func startAndUpdateExposeExplicitReplacementPolicy() throws {
        let start = try Start.parse(["--timeout", "50", "--force", "--model", "chosen"])
        #expect(start.drain.timeout == 50 && start.drain.force)
        let update = try Update.parse(["--check-only"])
        #expect(update.drain.timeout == 600 && !update.drain.force)
    }
}

@Test func restartAcceptsExplicitOwnerScopeButNotBareOnlineStatus() {
    let identity = ProcessIdentity(pid: 2, startTimeMicros: 20)
    var state = DaemonState(pid: 2, processIdentity: identity, version: "test", writtenAt: 1000, startedAt: 900,
        trust: .init(trustLevel: "none", status: "online", reason: "owner", receivedAt: 999,
            authorization: .init(appAttestAvailable: false, path: "self_route", sessionID: "new-session", machineID: "")))
    #expect(ServiceDrain.restartReady(state: state, previous: nil, now: 1000, isCurrent: { _ in true }))
    state.trust?.authorization = nil
    #expect(!ServiceDrain.restartReady(state: state, previous: nil, now: 1000, isCurrent: { _ in true }))
}

@Test func idleTerminationPersistsCleanMarkerBeforeAcknowledging() async {
    await #expect(processExitsWith: .success) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = try #require(ProcessIdentity.current())
        ProviderProcessRun.begin(directory: root, version: "test", processStartMicros: identity.startTimeMicros)
        let start = try Start.parse([])
        await start.installIdleScheduleTerminationHandler(disarmRecovery: {})
        let acknowledged = await ProviderTermination.shared.request()
        let record = ProviderRunMarker(directory: root).read()
        let nextExit = ProviderRunMarker.previousExit(record, processStartMicros: identity.startTimeMicros + 1)
        try? FileManager.default.removeItem(at: root)
        exit(acknowledged && record?.state == .clean && nextExit == .clean ? 0 : 1)
    }
}
