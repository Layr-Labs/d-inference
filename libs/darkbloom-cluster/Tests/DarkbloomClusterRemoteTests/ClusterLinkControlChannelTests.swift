import CryptoKit
import Darwin
@testable import DarkbloomClusterSecurity
import Foundation
import XCTest
@testable import DarkbloomClusterRemote

/// Collects events from an edge's queue for assertions.
final class LinkEventLog: @unchecked Sendable {
    private let condition = NSCondition()
    private var events: [ClusterLinkControlEvent] = []
    var hold: DispatchSemaphore?

    func record(_ event: ClusterLinkControlEvent) {
        hold?.wait(); hold?.signal()
        condition.withLock { events.append(event); condition.broadcast() }
    }

    var all: [ClusterLinkControlEvent] { condition.withLock { events } }

    var messages: [(UInt64, ClusterLinkControlMessage)] {
        all.compactMap { if case .message(_, let id, let message) = $0 { return (id, message) }; return nil }
    }

    var refusals: [ClusterLinkControlRefusal] {
        all.compactMap { if case .refused(_, let reason) = $0 { return reason }; return nil }
    }

    var disconnects: [ClusterLinkControlDisconnect] {
        all.compactMap { if case .disconnected(_, let reason) = $0 { return reason }; return nil }
    }

    func count(_ match: (ClusterLinkControlEvent) -> Bool) -> Int { all.filter(match).count }

    @discardableResult
    func wait(seconds: Double = 5, until predicate: ([ClusterLinkControlEvent]) -> Bool) -> Bool {
        // The predicate runs without the lock, so it may read `all` itself.
        let deadline = Date(timeIntervalSinceNow: seconds)
        while true {
            let snapshot = all
            if predicate(snapshot) { return true }
            condition.lock()
            let signalled = events.count != snapshot.count || condition.wait(until: deadline)
            condition.unlock()
            if !signalled { return predicate(all) }
        }
    }
}

/// A hand-driven connector over loopback, for replay and malformed-input cases.
final class RawLinkConnector: @unchecked Sendable {
    let socket: LinkSocket
    let reader: LinkReader

    init(port: UInt16) throws {
        socket = try LinkSocket.connect(local: .loopback, peer: .loopback, port: port,
            interfaceIndex: if_nametoindex("lo0"), timeoutNanoseconds: 2_000_000_000)
        reader = LinkReader(socket: socket, capacity: 64)
    }

    func read(_ count: Int, seconds: Double = 2) throws -> Data {
        try reader.readExact(count, deadline: linkNow() &+ UInt64(seconds * 1e9))
    }

    func write(_ data: Data) throws { try socket.writeAll(data, deadline: linkNow() &+ 2_000_000_000) }

    /// True when the other end closed the connection within the time.
    func closedByPeer(seconds: Double) -> Bool {
        // Drains whatever the listener sent first (challenge, heartbeats).
        let deadline = linkNow() &+ UInt64(seconds * 1e9)
        while linkNow() < deadline {
            do { _ = try reader.readExact(1, deadline: deadline) } catch LinkSocketError.closed { return true } catch {
                return false
            }
        }
        return false
    }

    func hello(edge: ClusterLinkControlEdge, key: ClusterLinkControlKey? = nil, challenge: Data,
               epoch: UUID? = nil, incarnation: UUID = UUID()) throws -> Data {
        let limits = try edge.limits.recordLimits()
        let hello = LinkHandshake.Hello(epoch: epoch ?? edge.epoch, edgeID: edge.edgeID, nonce: LinkHandshake.randomNonce(),
            resume: .init(incarnation: incarnation, knownPeerIncarnation: nil, deliveredThrough: 0),
            maximumPlaintextBytes: UInt32(limits.maximumPlaintextBytes), maximumRecords: limits.maximumRecordsPerDirection,
            maximumCumulativeBytes: limits.maximumCumulativePlaintextBytesPerDirection)
        var bytes = LinkHandshake.helloWithoutTag(hello)
        var signed = challenge; signed.append(bytes)
        bytes.append((key ?? edge.key).handshakeTag(role: .connector, transcript: signed))
        return bytes
    }

    /// Full handshake; returns the connector's record pair.
    func handshake(edge: ClusterLinkControlEdge) throws -> LinkRecordPair {
        let challenge = try read(LinkHandshake.challengeBytes)
        let hello = try hello(edge: edge, challenge: challenge)
        try write(hello)
        let accept = try read(LinkHandshake.acceptBytes)
        let transcript = LinkHandshake.transcriptSHA256(challenge: challenge, hello: hello, accept: accept)
        return try LinkRecordPair(role: .connector, key: edge.key, transcriptSHA256: transcript, epoch: edge.epoch,
            edgeID: edge.edgeID, limits: try edge.limits.recordLimits())
    }

    func sealMessage(_ records: LinkRecordPair, id: UInt64, _ message: ClusterLinkControlMessage) throws -> Data {
        let body = try JSONEncoder().encode(message)
        return try records.sealer.seal(LinkFrame(kind: .message, messageID: id, ackThrough: 0, body: body).plaintext(),
            context: records.sealContext)
    }
}

final class ClusterLinkControlChannelTests: XCTestCase {
    let epoch = UUID()
    let edgeID = UUID()
    let secret = Data((0..<32).map { UInt8($0 * 7 + 3) })

    func limits(_ change: (inout ClusterLinkControlLimits) -> Void = { _ in }) -> ClusterLinkControlLimits {
        var value = ClusterLinkControlLimits()
        value.heartbeatInterval = .milliseconds(100)
        value.silenceTimeout = .milliseconds(1000)
        value.handshakeTimeout = .milliseconds(800)
        value.reconnectInitialDelay = .milliseconds(10)
        value.reconnectMaximumDelay = .milliseconds(100)
        change(&value)
        return value
    }

    func makeEdge(secret: Data? = nil, epoch: UUID? = nil, limits: ClusterLinkControlLimits? = nil) throws -> ClusterLinkControlEdge {
        let epoch = epoch ?? self.epoch
        let key = try ClusterLinkControlKey.qualification(secret: secret ?? self.secret, epoch: epoch, edgeID: edgeID)
        return try ClusterLinkControlEdge(edgeID: edgeID, epoch: epoch, key: key, peerAddress: .loopback,
            limits: limits ?? self.limits())
    }

    func makeListener(_ log: LinkEventLog, edge: ClusterLinkControlEdge? = nil, port: UInt16 = 0) throws
        -> (ClusterLinkControlListener, UInt16) {
        let listener = try ClusterLinkControlListener(configuration: .init(interface: "lo0", port: port,
            policy: .loopbackForTests, edges: [edge ?? makeEdge()])) { event, _ in log.record(event) }
        return (listener, try listener.start())
    }

    func makeClient(_ log: LinkEventLog, port: UInt16, edge: ClusterLinkControlEdge? = nil) throws -> ClusterLinkControlClient {
        let client = try ClusterLinkControlClient(configuration: .init(interface: "lo0", port: port,
            policy: .loopbackForTests, edge: edge ?? makeEdge())) { event, _ in log.record(event) }
        client.start()
        return client
    }

    func status(_ value: UInt16) -> ClusterLinkControlMessage {
        .status(.init(epoch: epoch, rank: value, state: .ready, linkReady: true, detail: "fixture"))
    }

    // MARK: Session

    func testTypedMessagesBothWaysAndPing() throws {
        let serverLog = LinkEventLog(), clientLog = LinkEventLog()
        let (listener, port) = try makeListener(serverLog)
        defer { listener.stop() }
        let client = try makeClient(clientLog, port: port)
        defer { client.stop() }
        XCTAssertTrue(client.peer.waitUntilConnected(timeout: .seconds(3)))
        let reserve = ClusterLinkRequestReserve(epoch: epoch, requestID: UUID(), modelID: "fixture-model",
            planSHA256: String(repeating: "a", count: 64), promptTokens: [1, -2, 70_000, Int32.max, Int32.min],
            maximumOutputTokens: 16, deadlineMilliseconds: 30_000)
        try client.peer.send(.reserve(reserve))
        for index in 0..<20 { try client.peer.send(status(UInt16(index))) }
        XCTAssertTrue(serverLog.wait { events in events.filter { if case .message = $0 { return true }; return false }.count == 21 })
        let received = serverLog.messages
        XCTAssertEqual(received.map(\.0), Array(1...21))
        guard case .reserve(let echoed) = received[0].1 else { return XCTFail("reserve first") }
        XCTAssertEqual(echoed.promptTokenIDs, [1, -2, 70_000, Int32.max, Int32.min])
        let serverPeer = try XCTUnwrap(listener.peer(for: edgeID))
        try serverPeer.send(.vote(.init(epoch: epoch, requestID: reserve.requestID, kind: .cancel, latch: 3, step: 9)))
        XCTAssertTrue(clientLog.wait { $0.contains { if case .message(_, 1, .vote) = $0 { return true }; return false } })
        let ping = try client.peer.ping()
        XCTAssertGreaterThan(ping.channelNanoseconds, 0)
        XCTAssertGreaterThanOrEqual(ping.observedNanoseconds, ping.channelNanoseconds)
        try client.peer.waitUntilAcknowledged(timeout: .seconds(3))
        XCTAssertEqual(client.peer.status.unacknowledgedMessages, 0)
    }

    func testMessageWithAnotherEpochIsRefusedLocally() throws {
        let log = LinkEventLog()
        let (listener, port) = try makeListener(log)
        defer { listener.stop() }
        let client = try makeClient(LinkEventLog(), port: port)
        defer { client.stop() }
        XCTAssertThrowsError(try client.peer.send(.status(.init(epoch: UUID(), rank: 0, state: .idle, linkReady: true)))) {
            XCTAssertEqual($0 as? ClusterLinkControlError, .wrongEpoch)
        }
    }

    // MARK: Refusals

    func testWrongKeyIsRefused() throws {
        let serverLog = LinkEventLog()
        let (listener, port) = try makeListener(serverLog)
        defer { listener.stop() }
        let client = try makeClient(LinkEventLog(), port: port, edge: try makeEdge(secret: Data(repeating: 0x42, count: 32)))
        defer { client.stop() }
        XCTAssertFalse(client.peer.waitUntilConnected(timeout: .milliseconds(600)))
        XCTAssertTrue(serverLog.wait { _ in serverLog.refusals.contains(.authenticationFailed) })
        XCTAssertEqual(listener.peer(for: edgeID)?.status.sessions, 0)
        XCTAssertEqual(client.lastRefusal, .handshakeRejected)
    }

    func testWrongEpochIsRefused() throws {
        let serverLog = LinkEventLog()
        let (listener, port) = try makeListener(serverLog)
        defer { listener.stop() }
        let client = try makeClient(LinkEventLog(), port: port, edge: try makeEdge(epoch: UUID()))
        defer { client.stop() }
        XCTAssertFalse(client.peer.waitUntilConnected(timeout: .milliseconds(600)))
        XCTAssertTrue(serverLog.wait { _ in serverLog.refusals.contains(.wrongEpoch) })
    }

    func testUnknownEdgeAndLimitsMismatchAreRefused() throws {
        let serverLog = LinkEventLog()
        let (listener, port) = try makeListener(serverLog)
        defer { listener.stop() }
        let other = UUID()
        let key = try ClusterLinkControlKey.qualification(secret: secret, epoch: epoch, edgeID: other)
        let stranger = try ClusterLinkControlEdge(edgeID: other, epoch: epoch, key: key, peerAddress: .loopback, limits: limits())
        let first = try makeClient(LinkEventLog(), port: port, edge: stranger)
        XCTAssertTrue(serverLog.wait { _ in serverLog.refusals.contains(.unknownEdge) })
        first.stop()
        let mismatch = try makeClient(LinkEventLog(), port: port, edge: try makeEdge(limits: limits { $0.maximumBodyBytes = 65_536 }))
        XCTAssertTrue(serverLog.wait { _ in serverLog.refusals.contains(.limitsMismatch) })
        mismatch.stop()
    }

    func testReplayedHelloIsRefused() throws {
        let serverLog = LinkEventLog()
        let edge = try makeEdge()
        let (listener, port) = try makeListener(serverLog, edge: edge)
        defer { listener.stop() }
        let first = try RawLinkConnector(port: port)
        let challenge = try first.read(LinkHandshake.challengeBytes)
        let hello = try first.hello(edge: edge, challenge: challenge)
        try first.write(hello)
        _ = try first.read(LinkHandshake.acceptBytes) // the genuine hello is accepted
        let replay = try RawLinkConnector(port: port)
        _ = try replay.read(LinkHandshake.challengeBytes) // a fresh nonce
        try replay.write(hello)
        XCTAssertTrue(replay.closedByPeer(seconds: 2))
        XCTAssertTrue(serverLog.wait { _ in serverLog.refusals.contains(.authenticationFailed) })
        first.socket.close(); replay.socket.close()
    }

    func testReplayedRecordEndsTheSessionAndIsDeliveredOnce() throws {
        let serverLog = LinkEventLog()
        let edge = try makeEdge()
        let (listener, port) = try makeListener(serverLog, edge: edge)
        defer { listener.stop() }
        let raw = try RawLinkConnector(port: port)
        let records = try raw.handshake(edge: edge)
        let record = try raw.sealMessage(records, id: 1, status(7))
        try raw.write(record)
        try raw.write(record) // byte-identical replay inside the session
        XCTAssertTrue(serverLog.wait { _ in serverLog.disconnects.contains(.authenticationFailed) })
        XCTAssertEqual(serverLog.messages.count, 1)

        // A record from that session replayed into a new session fails too.
        let second = try RawLinkConnector(port: port)
        let secondRecords = try second.handshake(edge: edge)
        _ = secondRecords
        XCTAssertTrue(serverLog.wait { events in events.filter { if case .connected = $0 { return true }; return false }.count == 2 })
        try second.write(record)
        XCTAssertTrue(serverLog.wait { _ in serverLog.disconnects.filter { $0 == .authenticationFailed }.count == 2 })
        XCTAssertEqual(serverLog.messages.count, 1)
        raw.socket.close(); second.socket.close()
    }

    func testOversizeFramesAreRefused() throws {
        let serverLog = LinkEventLog()
        let edge = try makeEdge(limits: limits { $0.maximumBodyBytes = 4096 })
        let (listener, port) = try makeListener(serverLog, edge: edge)
        defer { listener.stop() }
        // Locally: a body above the edge's bound is never queued.
        let client = try makeClient(LinkEventLog(), port: port, edge: edge)
        XCTAssertTrue(client.peer.waitUntilConnected(timeout: .seconds(3)))
        XCTAssertThrowsError(try client.peer.sendOpaque(tag: 1, Data(count: 5000))) {
            XCTAssertEqual($0 as? ClusterLinkControlError, .messageTooLarge)
        }
        client.stop()
        // On the wire: a record prefix announcing more than the bound ends the
        // session before anything of that size is read or allocated.
        let raw = try RawLinkConnector(port: port)
        _ = try raw.handshake(edge: edge)
        var prefix = Data([0x44, 0x42, 0x52, 0x44, 1, 1, 1, ClusterRecordType.linkControl.rawValue])
        prefix.clusterLinkAppend(UInt64(0)); prefix.clusterLinkAppend(UInt32(64 * 1024 * 1024)); prefix.append(contentsOf: [0, 0, 0, 0])
        let started = linkNow()
        try raw.write(prefix)
        XCTAssertTrue(raw.closedByPeer(seconds: 2))
        XCTAssertLessThan(linkNow() - started, 1_000_000_000)
        XCTAssertTrue(serverLog.wait { _ in serverLog.disconnects.contains(.protocolViolation) })
        raw.socket.close()
    }

    func testSlowHandshakesAreCutAndCannotStarveTheRealPeer() throws {
        let serverLog = LinkEventLog()
        let edge = try makeEdge(limits: limits { $0.maximumPendingHandshakes = 3; $0.handshakeTimeout = .milliseconds(700) })
        let (listener, port) = try makeListener(serverLog, edge: edge)
        defer { listener.stop() }
        // Five slowloris connections dribbling one byte every 100 ms.
        let slow = try (0..<5).map { _ in try RawLinkConnector(port: port) }
        let started = linkNow()
        let dribble = Thread {
            for _ in 0..<15 {
                for connection in slow { try? connection.socket.writeAll(Data([0x44]), deadline: linkNow() &+ 50_000_000) }
                usleep(100_000)
            }
        }
        dribble.start()
        usleep(150_000)
        let client = try makeClient(LinkEventLog(), port: port, edge: edge)
        defer { client.stop() }
        XCTAssertTrue(client.peer.waitUntilConnected(timeout: .seconds(2)), "the real peer still gets in")
        XCTAssertLessThan(linkNow() - started, 1_500_000_000)
        for connection in slow { XCTAssertTrue(connection.closedByPeer(seconds: 2), "slow handshake cut") }
        XCTAssertLessThan(linkNow() - started, 3_000_000_000)
        XCTAssertGreaterThan((listener.refusals["evictedPendingHandshake"] ?? 0) + (listener.refusals["handshakeTimeout"] ?? 0), 0)
        for connection in slow { connection.socket.close() }
    }

    func testSilentPeerIsDisconnected() throws {
        let serverLog = LinkEventLog()
        let edge = try makeEdge(limits: limits { $0.silenceTimeout = .milliseconds(500); $0.heartbeatInterval = .milliseconds(100) })
        let (listener, port) = try makeListener(serverLog, edge: edge)
        defer { listener.stop() }
        let raw = try RawLinkConnector(port: port)
        _ = try raw.handshake(edge: edge)
        XCTAssertTrue(serverLog.wait(seconds: 3) { _ in serverLog.disconnects.contains(.peerSilent) })
        raw.socket.close()
    }

    // MARK: Reconnect

    func testReconnectResumesExactlyOnceInOrder() throws {
        let serverLog = LinkEventLog(), clientLog = LinkEventLog()
        let (listener, port) = try makeListener(serverLog)
        defer { listener.stop() }
        let client = try makeClient(clientLog, port: port)
        defer { client.stop() }
        XCTAssertTrue(client.peer.waitUntilConnected(timeout: .seconds(3)))
        for index in 0..<300 {
            try client.peer.send(status(UInt16(index)))
            // Drops land while frames are in flight and unacknowledged; a few
            // messages are also queued while no session exists.
            if index % 50 == 25 {
                client.peer.dropConnectionForTesting()
                try client.peer.send(status(UInt16(1000 + index)))
                XCTAssertTrue(client.peer.waitUntilConnected(timeout: .seconds(3)))
            }
            if index % 50 == 40 {
                listener.peer(for: edgeID)?.dropConnectionForTesting()
                usleep(50_000)
                XCTAssertTrue(client.peer.waitUntilConnected(timeout: .seconds(3)))
            }
        }
        try client.peer.waitUntilAcknowledged(timeout: .seconds(10))
        var expected = [UInt16]()
        for index in 0..<300 { expected.append(UInt16(index)); if index % 50 == 25 { expected.append(UInt16(1000 + index)) } }
        XCTAssertTrue(serverLog.wait { _ in serverLog.messages.count == expected.count })
        let messages = serverLog.messages
        XCTAssertEqual(messages.map(\.0), Array(1...UInt64(expected.count)))
        XCTAssertEqual(messages.map { if case .status(let s) = $0.1 { return s.rank }; return 9999 }, expected)
        let status = client.peer.status
        XCTAssertGreaterThanOrEqual(status.sessions, 8)
        XCTAssertEqual(status.peerRestarts, 0)
        XCTAssertTrue(clientLog.all.contains { if case .connected(_, _, true, _) = $0 { return true }; return false })
    }

    func testListenerRestartIsReportedAndTrafficContinues() throws {
        let serverLog = LinkEventLog(), clientLog = LinkEventLog()
        let (first, port) = try makeListener(serverLog)
        var listener = first
        let client = try makeClient(clientLog, port: port)
        defer { client.stop() }
        XCTAssertTrue(client.peer.waitUntilConnected(timeout: .seconds(3)))
        try client.peer.send(status(1))
        try client.peer.waitUntilAcknowledged(timeout: .seconds(3))
        listener.stop()
        let restartedLog = LinkEventLog()
        (listener, _) = try makeListener(restartedLog, port: port)
        defer { listener.stop() }
        XCTAssertTrue(clientLog.wait { $0.contains { if case .peerRestarted = $0 { return true }; return false } })
        XCTAssertTrue(client.peer.waitUntilConnected(timeout: .seconds(3)))
        try client.peer.send(status(2))
        XCTAssertTrue(restartedLog.wait { _ in restartedLog.messages.count == 1 })
        XCTAssertEqual(client.peer.status.peerRestarts, 1)
    }

    func testRecordBudgetRollsOverToFreshKeys() throws {
        let serverLog = LinkEventLog()
        let edge = try makeEdge(limits: limits { $0.maximumRecordsPerConnection = 64 })
        let (listener, port) = try makeListener(serverLog, edge: edge)
        defer { listener.stop() }
        let client = try makeClient(LinkEventLog(), port: port, edge: edge)
        defer { client.stop() }
        XCTAssertTrue(client.peer.waitUntilConnected(timeout: .seconds(3)))
        for index in 0..<400 { try client.peer.send(status(UInt16(index))) }
        try client.peer.waitUntilAcknowledged(timeout: .seconds(10))
        XCTAssertTrue(serverLog.wait { _ in serverLog.messages.count == 400 })
        XCTAssertEqual(serverLog.messages.map(\.0), Array(1...400))
        XCTAssertGreaterThanOrEqual(client.peer.status.sessions, 6)
        XCTAssertTrue(serverLog.disconnects.contains(.rekey))
    }

    func testFullOutboxIsBackpressure() throws {
        let serverLog = LinkEventLog()
        let gate = DispatchSemaphore(value: 0)
        serverLog.hold = gate
        let edge = try makeEdge(limits: limits {
            $0.maximumUnacknowledgedMessages = 8; $0.maximumPendingEvents = 2; $0.sendTimeout = .milliseconds(300)
        })
        let (listener, port) = try makeListener(serverLog, edge: edge)
        defer { listener.stop() }
        let client = try makeClient(LinkEventLog(), port: port, edge: edge)
        defer { client.stop() }
        XCTAssertTrue(client.peer.waitUntilConnected(timeout: .seconds(3)))
        var refusedAt: Int?
        for index in 0..<64 {
            do { try client.peer.send(status(UInt16(index))) } catch {
                XCTAssertEqual(error as? ClusterLinkControlError, .backpressure)
                refusedAt = index; break
            }
        }
        XCTAssertNotNil(refusedAt, "a stalled receiver turns into backpressure, not unbounded memory")
        gate.signal()
        try client.peer.waitUntilAcknowledged(timeout: .seconds(5))
        XCTAssertTrue(serverLog.wait { _ in serverLog.messages.count == refusedAt })
    }
}

final class ClusterLinkControlPolicyTests: XCTestCase {
    struct FixedInspector: ClusterLinkInterfaceInspecting {
        let facts: ClusterLinkInterfaceFacts
        func facts(forInterface name: String) throws -> ClusterLinkInterfaceFacts { facts }
    }

    func address(_ text: String, mask: UInt32 = 0xFFFF_FF00) -> ClusterLinkInterfaceAddress {
        .init(address: ClusterLinkIPv4Address(text)!, netmask: mask)
    }

    func select(_ kind: ClusterLinkInterfaceKind, members: [String: ClusterLinkInterfaceKind]? = nil,
                addresses: [ClusterLinkInterfaceAddress]? = nil, peer: String? = "192.0.2.1",
                policy: ClusterLinkInterfacePolicy = .thunderboltOnly) throws -> ClusterLinkInterfaceSelection {
        let facts = ClusterLinkInterfaceFacts(name: "en7", index: 7, kind: kind, bridgeMembers: members,
            addresses: addresses ?? [address("192.0.2.20")])
        return try ClusterLinkInterfaceAdmission.select(interface: "en7", localAddress: nil,
            peerAddress: peer.flatMap(ClusterLinkIPv4Address.init), policy: policy, inspector: FixedInspector(facts: facts))
    }

    func refusal(_ body: () throws -> Any) -> ClusterLinkInterfaceRefusal? {
        do { _ = try body(); return nil } catch { return error as? ClusterLinkInterfaceRefusal }
    }

    func testWifiIsRefusedUnderEveryPolicy() {
        for policy in [ClusterLinkInterfacePolicy.thunderboltOnly, .thunderboltOrWired, .loopbackForTests] {
            XCTAssertEqual(refusal { try select(.wifi, policy: policy) }, .wifi)
            XCTAssertEqual(refusal { try select(.bridge, members: ["en1": .thunderbolt, "en0": .wifi], policy: policy) }, .wifi)
        }
    }

    func testThunderboltPortsAndThunderboltBridgesAreAdmitted() throws {
        XCTAssertEqual(try select(.thunderbolt).local.address, ClusterLinkIPv4Address("192.0.2.20"))
        XCTAssertEqual(try select(.thunderboltBridge, members: ["en1": .thunderbolt, "en6": .thunderbolt, "en2": .thunderbolt]).kind,
                       .thunderboltBridge)
        XCTAssertEqual(refusal { try select(.bridge) }, .bridgeMembersUnknown)
        XCTAssertEqual(refusal { try select(.bridge, members: ["en1": .thunderbolt, "en10": .wiredEthernet]) }, .bridgeMemberNotThunderbolt)
        XCTAssertEqual(refusal { try select(.wiredEthernet) }, .notThunderbolt(.wiredEthernet))
        XCTAssertNoThrow(try select(.wiredEthernet, policy: .thunderboltOrWired))
        XCTAssertEqual(refusal { try select(.loopback) }, .loopbackRequiresTestPolicy)
        XCTAssertEqual(refusal { try select(.thunderbolt, policy: .loopbackForTests) }, .testPolicyRequiresLoopback)
    }

    func testAddressingForTodaysLinkAndLinkSetupV2() throws {
        // Today: Internet Sharing's subnet on the port, plus a link-local alias.
        let today = [address("169.254.10.20", mask: 0xFFFF_0000), address("192.0.2.20")]
        XCTAssertEqual(try select(.thunderbolt, addresses: today).local.address, ClusterLinkIPv4Address("192.0.2.20"))
        // Link setup v2: the fixed 10.219/16 address wins over anything else.
        let v2 = [address("169.254.10.20", mask: 0xFFFF_0000), address("10.219.4.7", mask: 0xFFFF_0000)]
        XCTAssertEqual(try select(.thunderbolt, addresses: v2, peer: "10.219.9.1").local.address, ClusterLinkIPv4Address("10.219.4.7"))
        // Per-edge /30 (N Macs): the address on the peer's subnet is chosen.
        let edges = [address("10.219.0.1", mask: 0xFFFF_FFFC), address("10.219.0.5", mask: 0xFFFF_FFFC)]
        XCTAssertEqual(try select(.thunderbolt, addresses: edges, peer: "10.219.0.6").local.address, ClusterLinkIPv4Address("10.219.0.5"))
        XCTAssertEqual(refusal { try select(.thunderbolt, addresses: v2, peer: "192.0.2.1") }, .peerNotOnLink)
        XCTAssertEqual(refusal { try select(.thunderbolt, addresses: []) }, .noUsableAddress)
        let facts = ClusterLinkInterfaceFacts(name: "en7", index: 7, kind: .thunderbolt, bridgeMembers: nil, addresses: today)
        XCTAssertEqual(refusal { try ClusterLinkInterfaceAdmission.select(interface: "en7",
            localAddress: ClusterLinkIPv4Address("10.0.0.1"), peerAddress: nil, policy: .thunderboltOnly,
            inspector: FixedInspector(facts: facts)) }, .addressNotOnInterface)
        XCTAssertEqual(refusal { try ClusterLinkInterfaceAdmission.select(interface: "en7; rm", localAddress: nil,
            peerAddress: nil, policy: .thunderboltOnly, inspector: FixedInspector(facts: facts)) }, .invalidInterfaceName)
    }

    func testCarrierIsTheInterfaceThatReachesTheLeadersAddress() {
        let shared = address("192.0.2.1"), alias = address("169.254.10.20", mask: 0xFFFF_0000)
        let leader = ClusterLinkIPv4Address("192.0.2.20")!
        // Today's second Mac: the port holds only a link-local alias, the bridge holds Internet Sharing's subnet.
        XCTAssertEqual(ClusterLinkInterfaceAdmission.carrier(reaching: leader,
            candidates: [(name: "en6", addresses: [alias]), (name: "bridge0", addresses: [shared, alias])]), "bridge0")
        // A port with its own address on the subnet wins over its bridge (link setup v2, today's first Mac).
        XCTAssertEqual(ClusterLinkInterfaceAdmission.carrier(reaching: leader,
            candidates: [(name: "en7", addresses: [address("192.0.2.30")]), (name: "bridge0", addresses: [shared])]), "en7")
        // A listener's own address is on its own subnet.
        XCTAssertEqual(ClusterLinkInterfaceAdmission.carrier(reaching: leader,
            candidates: [(name: "en7", addresses: [address("192.0.2.20")])]), "en7")
        // Nothing reaches it: no carrier (the caller falls back and admission names the refusal).
        XCTAssertNil(ClusterLinkInterfaceAdmission.carrier(reaching: ClusterLinkIPv4Address("10.219.9.1")!,
            candidates: [(name: "en6", addresses: [alias]), (name: "bridge0", addresses: [shared])]))
        XCTAssertNil(ClusterLinkInterfaceAdmission.carrier(reaching: leader, candidates: []))
    }

    func testAddressParsingIsStrictAndRedacted() {
        XCTAssertNil(ClusterLinkIPv4Address("192.0.2"))
        XCTAssertNil(ClusterLinkIPv4Address("192.0.02.1"))
        XCTAssertNil(ClusterLinkIPv4Address("256.1.1.1"))
        XCTAssertNil(ClusterLinkIPv4Address(" 1.2.3.4"))
        XCTAssertEqual(ClusterLinkIPv4Address("10.219.4.7")?.dottedDecimal, "10.219.4.7")
        XCTAssertEqual("\(ClusterLinkIPv4Address("10.219.4.7")!)", "ipv4(redacted)")
    }

    func testSystemInspectorClassifiesLoopback() throws {
        let facts = try ClusterLinkSystemInterfaceInspector().facts(forInterface: "lo0")
        XCTAssertEqual(facts.kind, .loopback)
        XCTAssertTrue(facts.addresses.contains { $0.address == .loopback })
        XCTAssertThrowsError(try ClusterLinkSystemInterfaceInspector().facts(forInterface: "nonexistent9"))
    }
}

final class ClusterLinkControlKeyAndMessageTests: XCTestCase {
    func testNativeDerivedKeysAgreeAndAreDomainSeparated() throws {
        let a = Curve25519.KeyAgreement.PrivateKey(), b = Curve25519.KeyAgreement.PrivateKey()
        let transcript = Data(SHA256.hash(data: Data("transcript".utf8)))
        let ka = try ClusterLinkControlKey.nativeDerived(privateKey: a, peerPublicKey: b.publicKey.rawRepresentation,
            transcriptSHA256: transcript)
        let kb = try ClusterLinkControlKey.nativeDerived(privateKey: b, peerPublicKey: a.publicKey.rawRepresentation,
            transcriptSHA256: transcript)
        let message = Data("hello".utf8)
        XCTAssertEqual(ka.handshakeTag(role: .connector, transcript: message), kb.handshakeTag(role: .connector, transcript: message))
        XCTAssertTrue(kb.isValidHandshakeTag(ka.handshakeTag(role: .listener, transcript: message), role: .listener, transcript: message))
        XCTAssertFalse(kb.isValidHandshakeTag(ka.handshakeTag(role: .listener, transcript: message), role: .connector, transcript: message))
        let other = try ClusterLinkControlKey.nativeDerived(privateKey: a, peerPublicKey: b.publicKey.rawRepresentation,
            transcriptSHA256: Data(SHA256.hash(data: Data("other".utf8))))
        XCTAssertNotEqual(other.handshakeTag(role: .connector, transcript: message), ka.handshakeTag(role: .connector, transcript: message))
        XCTAssertThrowsError(try ClusterLinkControlKey.nativeDerived(privateKey: a, peerPublicKey: Data(repeating: 0, count: 32),
            transcriptSHA256: transcript))
        XCTAssertThrowsError(try ClusterLinkControlKey.nativeDerived(privateKey: a, peerPublicKey: b.publicKey.rawRepresentation,
            transcriptSHA256: Data(count: 31)))
        XCTAssertEqual("\(ka)", "ClusterLinkControlKey(redacted)")
    }

    func testQualificationKeyIsBoundToEpochAndEdge() throws {
        let secret = Data(repeating: 9, count: 32), epoch = UUID(), edge = UUID()
        let base = try ClusterLinkControlKey.qualification(secret: secret, epoch: epoch, edgeID: edge)
        let otherEpoch = try ClusterLinkControlKey.qualification(secret: secret, epoch: UUID(), edgeID: edge)
        let otherEdge = try ClusterLinkControlKey.qualification(secret: secret, epoch: epoch, edgeID: UUID())
        let message = Data("m".utf8)
        let tag = base.handshakeTag(role: .connector, transcript: message)
        XCTAssertFalse(otherEpoch.isValidHandshakeTag(tag, role: .connector, transcript: message))
        XCTAssertFalse(otherEdge.isValidHandshakeTag(tag, role: .connector, transcript: message))
        XCTAssertThrowsError(try ClusterLinkControlKey.qualification(secret: Data(repeating: 9, count: 31), epoch: epoch, edgeID: edge))
        XCTAssertThrowsError(try ClusterLinkControlKey.qualification(secret: Data(count: 32), epoch: epoch, edgeID: edge))
    }

    func testSecretIsReadFromAPipe() throws {
        var ends: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&ends), 0)
        let hex = (0..<32).map { String(format: "%02X", $0) }.joined() + "\n"
        _ = hex.withCString { Darwin.write(ends[1], $0, strlen($0)) }
        Darwin.close(ends[1])
        let secret = try ClusterLinkControlKey.readQualificationSecret(fromDescriptor: ends[0])
        Darwin.close(ends[0])
        XCTAssertEqual(secret, Data((0..<32).map { UInt8($0) }))
        XCTAssertThrowsError(try ClusterLinkControlKey.decodeHexSecret(Array("abcd".utf8)))
        XCTAssertThrowsError(try ClusterLinkControlKey.decodeHexSecret(Array(String(repeating: "zz", count: 32).utf8)))
    }

    func testMessageCodecIsStrict() throws {
        let epoch = UUID(), request = UUID()
        let all: [ClusterLinkControlMessage] = [
            .leaseRenew(.init(epoch: epoch, leaseID: UUID(), renewal: 4, ttlMilliseconds: 30_000)),
            .reserve(.init(epoch: epoch, requestID: request, modelID: "m", planSHA256: "p", promptTokens: [5, 6],
                           maximumOutputTokens: 8, deadlineMilliseconds: 1000)),
            .start(.init(epoch: epoch, requestID: request, mode: "pipeline", maximumOutputTokens: 8, seed: 7)),
            .requestEvent(.init(epoch: epoch, requestID: request, rank: 1, kind: .admitted)),
            .decision(.init(epoch: epoch, requestID: request, step: 3, ownerRank: 0, bytes: Data([1, 2, 3]))),
            .vote(.init(epoch: epoch, requestID: request, kind: .stop, latch: 1, step: 3)),
            .barrier(.init(epoch: epoch, name: "loaded", generation: 1, rank: 1, phase: .arrive)),
            .agreement(.init(epoch: epoch, topic: "plan", generation: 1, rank: 0, digestSHA256: Data(count: 32))),
            .status(.init(epoch: epoch, rank: 1, state: .serving, modelID: "m", activeRequestID: request, linkReady: true)),
            .probe(.init(kind: .echoRequest, nonce: 9)),
        ]
        for message in all {
            let data = try JSONEncoder().encode(message)
            XCTAssertEqual(try JSONDecoder().decode(ClusterLinkControlMessage.self, from: data), message)
            XCTAssertNoThrow(try message.validate(maximumPromptTokens: 16))
        }
        let unknown = #"{"kind":"launchMissiles","probe":{}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(ClusterLinkControlMessage.self, from: Data(unknown.utf8)))
        let extra = String(decoding: try JSONEncoder().encode(all[9]), as: UTF8.self).dropLast() + #","status":{}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(ClusterLinkControlMessage.self, from: Data(extra.utf8)))
        let big = ClusterLinkControlMessage.decision(.init(epoch: epoch, requestID: request, step: 1, ownerRank: 0, bytes: Data(count: 257)))
        XCTAssertThrowsError(try big.validate(maximumPromptTokens: 16))
        let long = ClusterLinkControlMessage.reserve(.init(epoch: epoch, requestID: request, modelID: "m", planSHA256: "p",
            promptTokens: Array(repeating: 1, count: 17), maximumOutputTokens: 1, deadlineMilliseconds: 1))
        XCTAssertThrowsError(try long.validate(maximumPromptTokens: 16))
    }

    func testFramesAndHandshakeRecordsAreStrict() throws {
        let frame = LinkFrame(kind: .message, messageID: 5, ackThrough: 4, body: Data("{}".utf8))
        XCTAssertEqual(try LinkFrame.parse(frame.plaintext(), maximumBodyBytes: 64), frame)
        XCTAssertThrowsError(try LinkFrame.parse(LinkFrame(kind: .message, messageID: 0, ackThrough: 0, body: Data([1])).plaintext(),
                                                 maximumBodyBytes: 64))
        XCTAssertThrowsError(try LinkFrame.parse(LinkFrame(kind: .ping, messageID: 3, ackThrough: 0, body: Data(count: 16)).plaintext(),
                                                 maximumBodyBytes: 64))
        XCTAssertThrowsError(try LinkFrame.parse(frame.plaintext(), maximumBodyBytes: 1))
        var corrupted = frame.plaintext(); corrupted[1] = 99
        XCTAssertThrowsError(try LinkFrame.parse(corrupted, maximumBodyBytes: 64))
        XCTAssertThrowsError(try LinkHandshake.parseChallenge(Data(count: 40)))
        XCTAssertThrowsError(try LinkHandshake.parseHello(Data(count: 164)))
        XCTAssertThrowsError(try LinkHandshake.parseAccept(Data(count: 79)))
        let resume = LinkHandshake.Resume(incarnation: UUID(), knownPeerIncarnation: nil, deliveredThrough: 12)
        var accept = LinkHandshake.acceptWithoutTag(resume); accept.append(Data(count: 32))
        XCTAssertEqual(try LinkHandshake.parseAccept(accept).0, resume)
    }

    func testReliabilityBookkeeping() throws {
        var outbox = LinkOutbox(maximumMessages: 3, maximumBytes: 10)
        XCTAssertTrue(outbox.canAccept(bytes: 100)) // one message always fits an empty outbox
        _ = outbox.append(kind: .message, body: Data(count: 4))
        _ = outbox.append(kind: .message, body: Data(count: 4))
        XCTAssertFalse(outbox.canAccept(bytes: 4))
        XCTAssertEqual(try outbox.acknowledge(through: 1), 1)
        XCTAssertThrowsError(try outbox.acknowledge(through: 3))
        XCTAssertEqual(outbox.pending.map(\.id), [2])
        XCTAssertEqual(outbox.dropAll(), 1)
        var inbox = LinkInbox()
        XCTAssertEqual(inbox.verdict(for: 7), .deliver)
        inbox.markDelivered(7)
        XCTAssertEqual(inbox.verdict(for: 7), .duplicate)
        XCTAssertEqual(inbox.verdict(for: 9), .gap)
        XCTAssertEqual(inbox.deliveredThrough, 7)
    }

    func testBarrierAndAgreementTrackers() throws {
        let epoch = UUID()
        var barrier = ClusterLinkBarrierTracker(name: "loaded", generation: 2, expectedRanks: [0, 1, 2])
        XCTAssertFalse(try barrier.arrive(.init(epoch: epoch, name: "loaded", generation: 2, rank: 0, phase: .arrive)))
        XCTAssertFalse(try barrier.arrive(.init(epoch: epoch, name: "loaded", generation: 2, rank: 2, phase: .arrive)))
        XCTAssertThrowsError(try barrier.arrive(.init(epoch: epoch, name: "loaded", generation: 1, rank: 1, phase: .arrive)))
        XCTAssertTrue(try barrier.arrive(.init(epoch: epoch, name: "loaded", generation: 2, rank: 1, phase: .arrive)))
        var agreement = ClusterLinkAgreementTracker(topic: "plan", generation: 1, expectedRanks: [0, 1])
        let digest = Data(SHA256.hash(data: Data("plan".utf8)))
        XCTAssertEqual(try agreement.record(.init(epoch: epoch, topic: "plan", generation: 1, rank: 1, digestSHA256: digest)), .waiting)
        XCTAssertEqual(try agreement.record(.init(epoch: epoch, topic: "plan", generation: 1, rank: 0, digestSHA256: digest)), .agreed)
        var split = ClusterLinkAgreementTracker(topic: "plan", generation: 1, expectedRanks: [0, 1])
        _ = try split.record(.init(epoch: epoch, topic: "plan", generation: 1, rank: 0, digestSHA256: digest))
        XCTAssertEqual(try split.record(.init(epoch: epoch, topic: "plan", generation: 1, rank: 1, digestSHA256: Data(count: 32))),
                       .mismatch(rank: 1))
    }

    func testEdgeIDIsDeterministicAndOrderFree() {
        let one = ClusterLinkControlEdge.derivedEdgeID(firstMember: "pinA", firstInterface: "en7", secondMember: "pinB", secondInterface: "en6")
        let two = ClusterLinkControlEdge.derivedEdgeID(firstMember: "pinB", firstInterface: "en6", secondMember: "pinA", secondInterface: "en7")
        let three = ClusterLinkControlEdge.derivedEdgeID(firstMember: "pinA", firstInterface: "en5", secondMember: "pinB", secondInterface: "en6")
        XCTAssertEqual(one, two)
        XCTAssertNotEqual(one, three)
    }
}
