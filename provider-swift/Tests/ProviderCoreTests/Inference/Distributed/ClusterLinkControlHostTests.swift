import DarkbloomClusterRemote
import DarkbloomClusterSecurity
import Foundation
import Testing
@testable import ProviderCore

/// The provider hosts the link control listener in its own process (S06).
/// Loopback only: no Thunderbolt interface or peer Mac is involved here.
@Suite(.serialized) struct ClusterLinkControlHostTests {
    struct WifiInspector: ClusterLinkInterfaceInspecting {
        func facts(forInterface name: String) throws -> ClusterLinkInterfaceFacts {
            .init(name: name, index: 1, kind: .wifi, bridgeMembers: nil,
                  addresses: [.init(address: ClusterLinkIPv4Address("192.0.2.20")!, netmask: 0xFFFF_FF00)])
        }
    }

    final class Inbox: @unchecked Sendable {
        let condition = NSCondition()
        var messages: [ClusterLinkControlMessage] = []
        func record(_ event: ClusterLinkControlEvent) {
            guard case .message(_, _, let message) = event else { return }
            condition.withLock { messages.append(message); condition.broadcast() }
        }
        func wait(count: Int) -> Bool {
            let deadline = Date(timeIntervalSinceNow: 5)
            condition.lock(); defer { condition.unlock() }
            while messages.count < count { if !condition.wait(until: deadline) { return false } }
            return true
        }
    }

    func edge(epoch: UUID, edgeID: UUID) throws -> ClusterLinkControlEdge {
        let key = try ClusterLinkControlKey.qualification(secret: Data(repeating: 0x5C, count: 32), epoch: epoch, edgeID: edgeID)
        return try ClusterLinkControlEdge(edgeID: edgeID, epoch: epoch, key: key, peerAddress: .loopback)
    }

    @Test func hostsTheListenerInThisProcessAndCarriesTypedMessages() throws {
        let epoch = UUID(), edgeID = UUID()
        let host = ClusterLinkControlHost()
        let inbox = Inbox()
        let listener = try host.start(.init(interface: "lo0", port: 0, policy: .loopbackForTests,
            edges: [edge(epoch: epoch, edgeID: edgeID)])) { event, _ in inbox.record(event) }
        guard case .listening(let interface, let kind, let port) = host.state else {
            Issue.record("host is not listening"); return
        }
        #expect(interface == "lo0" && kind == .loopback && port == listener.boundPort)
        let client = try ClusterLinkControlClient(configuration: .init(interface: "lo0", port: port,
            policy: .loopbackForTests, edge: edge(epoch: epoch, edgeID: edgeID))) { _, _ in }
        client.start()
        defer { client.stop() }
        #expect(client.peer.waitUntilConnected(timeout: .seconds(3)))
        let request = UUID()
        try client.peer.send(.requestEvent(.init(epoch: epoch, requestID: request, rank: 1, kind: .admitted)))
        try client.peer.send(.status(.init(epoch: epoch, rank: 1, state: .ready, linkReady: true)))
        #expect(inbox.wait(count: 2))
        #expect(inbox.messages.first == .requestEvent(.init(epoch: epoch, requestID: request, rank: 1, kind: .admitted)))
        #expect(host.peer(for: edgeID)?.status.sessions == 1)
        host.stop()
        #expect(host.state == .stopped)
    }

    @Test func refusesWifiAndStaysStopped() throws {
        let epoch = UUID(), edgeID = UUID()
        let host = ClusterLinkControlHost(inspector: WifiInspector())
        #expect(throws: ClusterLinkInterfaceRefusal.wifi) {
            try host.start(.init(interface: "en1", port: 0, edges: [edge(epoch: epoch, edgeID: edgeID)])) { _, _ in }
        }
        #expect(host.state == .refused("wifi"))
        #expect(host.peer(for: edgeID) == nil)
    }

    @Test func qualificationOptionsNeverTakeASecretAndValidateInputs() throws {
        var request = ClusterLinkChannelQualificationRequest(epoch: UUID().uuidString, edge: UUID().uuidString)
        request.loopbackForTests = true
        let options = try ClusterLinkControlHost.qualificationOptions(request)
        #expect(options.interface == "lo0" && options.policy == .loopbackForTests)
        request.peerAddress = "192.0.2"
        #expect(throws: ClusterLinkChannelQualificationError.self) { try ClusterLinkControlHost.qualificationOptions(request) }
        var unnamed = ClusterLinkChannelQualificationRequest(epoch: "not-a-uuid", edge: UUID().uuidString)
        unnamed.interface = "en7"
        #expect(throws: ClusterLinkChannelQualificationError.self) { try ClusterLinkControlHost.qualificationOptions(unnamed) }
        #expect(ClusterLinkControlHost.listenInterface(forDevice: "en7") == nil)
    }
}
