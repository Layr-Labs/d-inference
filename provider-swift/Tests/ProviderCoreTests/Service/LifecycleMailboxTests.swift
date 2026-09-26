import Foundation
import Testing
@testable import ProviderCore

@Suite("Lifecycle mailbox")
struct LifecycleMailboxTests {
    @Test func roundTripIsPrivateAndBoundToExactProcess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try #require(ProcessIdentity.current())
        let mailbox = LifecycleMailbox(identity: identity, directory: root)
        let request = ProviderDrainRequest(target: identity, timeoutSeconds: 600)
        try mailbox.writeRequest(request)
        #expect(mailbox.readRequest() == request)
        #expect(request.isValid(for: identity))
        #expect(!request.isValid(for: .init(pid: identity.pid, startTimeMicros: identity.startTimeMicros + 1)))
        #expect(!request.isValid(for: identity, now: request.createdAt + 4000))
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let other = LifecycleMailbox(identity: .init(pid: identity.pid, startTimeMicros: identity.startTimeMicros + 1), directory: root)
        #expect(other.readRequest() == nil)
        try mailbox.writeStatus(.init(requestID: request.id, outcome: .timedOut, remaining: 3))
        #expect(mailbox.readStatus()?.remaining == 3)
    }

    @Test func switchClaimSurvivesNextMonitorAndConcurrentPublication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try #require(ProcessIdentity.current())
        let firstMonitor = LifecycleMailbox(identity: identity, directory: root)
        let nextMonitor = LifecycleMailbox(identity: identity, directory: root)
        let old = ProviderModelSwitchRequest(target: identity, models: ["old"], timeoutSeconds: 0)
        let new = ProviderModelSwitchRequest(target: identity, models: ["new"], timeoutSeconds: 0)
        let stop = ProviderDrainRequest(target: identity, timeoutSeconds: 1)
        try firstMonitor.writeRequest(stop)
        try firstMonitor.writeSwitchRequest(old)
        var publicationError: (any Error)?
        let claimed = firstMonitor.claimSwitchRequest {
            // A new CLI can publish while the previous claim is being read.
            // Cleaning up the old claim must leave this new request untouched.
            do { try nextMonitor.writeSwitchRequest(new) }
            catch { publicationError = error }
        }
        if let publicationError { throw publicationError }
        #expect(claimed == old)
        #expect(nextMonitor.claimSwitchRequest() == new)
        #expect(firstMonitor.claimSwitchRequest() == nil)
        #expect(nextMonitor.claimSwitchRequest() == nil)
        #expect(nextMonitor.readRequest() == stop)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.contains("switch-") })
    }

    @Test func switchClaimRejectsUnsafeFilesWithoutTouchingTheirTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try #require(ProcessIdentity.current())
        let mailbox = LifecycleMailbox(identity: identity, directory: root)
        let request = ProviderModelSwitchRequest(target: identity, models: ["new"], timeoutSeconds: 0)
        try mailbox.writeSwitchRequest(request)
        let path = root.appendingPathComponent("\(identity.pid)-\(identity.startTimeMicros).switch-request.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        #expect(mailbox.claimSwitchRequest() == nil)
        let target = root.appendingPathComponent("target.json")
        try JSONEncoder().encode(request).write(to: target)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
        #expect(mailbox.claimSwitchRequest() == nil)
        #expect(try JSONDecoder().decode(ProviderModelSwitchRequest.self, from: Data(contentsOf: target)) == request)
    }

    @Test func rejectsSharedDirectoryAndInvalidDeadlines() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root.path)
        let identity = try #require(ProcessIdentity.current())
        let mailbox = LifecycleMailbox(identity: identity, directory: root)
        #expect(throws: (any Error).self) { try mailbox.writeRequest(.init(target: identity, timeoutSeconds: 2)) }
        #expect(!ProviderDrainRequest(target: identity, timeoutSeconds: -1).isValid(for: identity))
        #expect(!ProviderDrainRequest(target: identity, timeoutSeconds: 3601).isValid(for: identity))
    }
}


@Test func lifecycleTelemetryContainsOnlyBoundedOperationalFields() throws {
    let status = ProviderDrainStatus(requestID: "private-control-id", outcome: .timedOut, remaining: 2, deadline: 1234)
    let json = try #require(JSONSerialization.jsonObject(with: ProviderDrainTelemetry.data(status)) as? [String: Any])
    #expect(Set(json.keys) == ["operation", "reason", "in_flight", "coordinator_acknowledged"])
    #expect(json["reason"] as? String == "timedOut")
    #expect(json["in_flight"] as? Int == 2)
}


@Test func daemonStateRoundTripsLifecycleCommandIdentity() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("daemon.json")
    let lifecycle = ProviderDrainStatus(requestID: "command", outcome: .draining, remaining: 2, deadline: 2000)
    DaemonStateFile.write(DaemonState(pid: 1, version: "test", writtenAt: 1000, startedAt: 900, lifecycle: lifecycle), to: path)
    #expect(DaemonStateFile.read(from: path)?.lifecycle == lifecycle)
}
