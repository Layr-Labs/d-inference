import Foundation
import Testing
@testable import ProviderCore

@Suite("Standalone lifecycle commands")
struct StandaloneLifecycleControlTests {
    @Test func localProviderPublishesControlAndDrainsBeforeReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = StandaloneServer(config: .init(port: 0))
        let lease = try server.responseTracker.admit()
        let state = root.appendingPathComponent("state.json")
        let mailbox = LifecycleMailbox(identity: try #require(ProcessIdentity.current()), directory: root.appendingPathComponent("lifecycle"))
        await server.startLifecycleControl(stateFile: state)
        let request = ProviderDrainRequest(target: mailbox.identity, timeoutSeconds: 3)
        try mailbox.writeRequest(request)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while mailbox.readStatus()?.outcome != .draining && ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(mailbox.readStatus()?.remaining == 1)
        #expect(throws: (any Error).self) { try server.responseTracker.admit() }
        lease.release()
        while mailbox.readStatus()?.outcome != .drained && ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(mailbox.readStatus()?.requestID == request.id)
        #expect(mailbox.readStatus()?.outcome == .drained)
        #expect(DaemonStateFile.read(from: state)?.processIdentity == mailbox.identity)
        await server.stop()
    }
}
