import CryptoKit
import Darwin
@testable import DarkbloomClusterSecurity
import Foundation
import XCTest
@testable import DarkbloomClusterRemote

/// Independent review checks for handshake v2 (CLUSTER-PRIV): an attacker with
/// the edge secret file and a full capture, using the product's own key API
/// with every captured public key and its own ephemeral key, opens nothing; a
/// record of one connection is refused on the next.
final class ClusterLinkSecReviewTests: XCTestCase {
    let epoch = UUID()
    let edgeID = UUID()
    let secret = Data((0..<32).map { UInt8(($0 * 7 + 3) % 251) })
    let prompt: [Int32] = [151_644, 872, 198, 3_555, 20_217, 31_415, 92_653, 151_645]

    func limits() -> ClusterLinkControlLimits {
        var value = ClusterLinkControlLimits()
        value.heartbeatInterval = .milliseconds(100)
        value.silenceTimeout = .milliseconds(1000)
        value.handshakeTimeout = .milliseconds(800)
        value.reconnectInitialDelay = .milliseconds(10)
        value.reconnectMaximumDelay = .milliseconds(100)
        return value
    }

    func makeEdge() throws -> ClusterLinkControlEdge {
        let key = try ClusterLinkControlKey.qualification(secret: secret, epoch: epoch, edgeID: edgeID)
        return try ClusterLinkControlEdge(edgeID: edgeID, epoch: epoch, key: key, peerAddress: .loopback, limits: limits())
    }

    /// Opens what it can of one direction's record stream with one record pair.
    func openAll(_ stream: Data, with records: LinkRecordPair) -> Int {
        var opened = 0, rest = stream
        let prefixBytes = ClusterAuthenticatedRecordChannel.framingPrefixBytes
        while rest.count >= prefixBytes {
            guard let total = try? ClusterAuthenticatedRecordChannel.boundedRecordByteCount(fromPrefix: Data(rest.prefix(prefixBytes)),
                      maximumPlaintextBytes: records.limits.maximumPlaintextBytes), rest.count >= total,
                  (try? records.opener.open(Data(rest.prefix(total)), expecting: records.openContext)) != nil else { break }
            opened += 1
            rest = Data(rest.dropFirst(total))
        }
        return opened
    }

    func testOwnerWithSecretAndCaptureOpensNothingThroughTheProductAPI() throws {
        let leaderLog = LinkEventLog(), followerLog = LinkEventLog()
        let listener = try ClusterLinkControlListener(configuration: .init(interface: "lo0", port: 0,
            policy: .loopbackForTests, edges: [makeEdge()])) { event, _ in leaderLog.record(event) }
        let port = try listener.start()
        defer { listener.stop() }
        let relay = try LinkCaptureRelay(target: port)
        defer { relay.stop() }
        let follower = try ClusterLinkControlClient(configuration: .init(interface: "lo0", port: relay.port,
            policy: .loopbackForTests, edge: makeEdge())) { event, _ in followerLog.record(event) }
        follower.start()
        defer { follower.stop() }
        let leader = try XCTUnwrap(listener.peer(for: edgeID))
        XCTAssertTrue(follower.peer.waitUntilConnected(timeout: .seconds(3)))
        XCTAssertTrue(leader.waitUntilConnected(timeout: .seconds(3)))
        try leader.send(.reserve(ClusterLinkRequestReserve(epoch: epoch, requestID: UUID(), modelID: "fixture-model",
            planSHA256: String(repeating: "c", count: 64), promptTokens: prompt, maximumOutputTokens: 16,
            deadlineMilliseconds: 30_000)))
        XCTAssertTrue(followerLog.wait { _ in followerLog.messages.count == 1 })
        try leader.waitUntilAcknowledged(timeout: .seconds(3))
        relay.stop()
        let session = try XCTUnwrap(relay.sessions.first)
        let challenge = Data(session.toConnector.prefix(LinkHandshake.challengeBytes))
        let accept = Data(session.toConnector.dropFirst(LinkHandshake.challengeBytes).prefix(LinkHandshake.acceptBytes))
        let hello = Data(session.toListener.prefix(LinkHandshake.helloBytes))
        let toConnector = Data(session.toConnector.dropFirst(LinkHandshake.challengeBytes + LinkHandshake.acceptBytes))
        let toListener = Data(session.toListener.dropFirst(LinkHandshake.helloBytes))
        XCTAssertGreaterThan(toConnector.count, 0)
        let transcript = LinkHandshake.transcriptSHA256(challenge: challenge, hello: hello, accept: accept)
        let listenerPublic = try LinkHandshake.parseChallenge(challenge)
        let connectorPublic = try LinkHandshake.parseHello(hello).0.ephemeralPublicKey
        // The owner's edge key, from the file, through the product's API: valid for the handshake tags...
        let ownerKey = try ClusterLinkControlKey.qualification(secret: secret, epoch: epoch, edgeID: edgeID)
        XCTAssertTrue(ownerKey.isValidHandshakeTag(Data(hello.suffix(32)), role: .connector,
            transcript: challenge + hello.prefix(LinkHandshake.helloBytes - 32)), "the capture is this edge's")
        let recordLimits = try limits().recordLimits()
        // ...but every keying it can try (its own ephemeral key against either captured public key, either role,
        // or a captured public key used as if it were a private scalar) opens no record of either direction.
        var attempts = 0
        for role in [ClusterLinkControlRole.listener, .connector] {
            for peerPublic in [listenerPublic, connectorPublic] {
                var candidates = [Curve25519.KeyAgreement.PrivateKey()]
                for raw in [listenerPublic, connectorPublic] {
                    if let scalar = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) { candidates.append(scalar) }
                }
                for mine in candidates {
                    guard let records = try? LinkRecordPair(role: role, key: ownerKey, ephemeralPrivateKey: mine,
                        peerEphemeralPublicKey: peerPublic, transcriptSHA256: transcript, epoch: epoch, edgeID: edgeID,
                        limits: recordLimits) else { continue }
                    attempts += 1
                    XCTAssertEqual(openAll(role == .connector ? toConnector : toListener, with: records), 0,
                        "an owner keying (role \(role)) opened a record")
                }
            }
        }
        XCTAssertGreaterThan(attempts, 4)
    }

    /// A record sealed on one connection is refused on the next one of the same edge.
    func testRecordOfAnEarlierConnectionIsRefused() throws {
        let log = LinkEventLog()
        let edge = try makeEdge()
        let listener = try ClusterLinkControlListener(configuration: .init(interface: "lo0", port: 0,
            policy: .loopbackForTests, edges: [edge])) { event, _ in log.record(event) }
        let port = try listener.start()
        defer { listener.stop() }
        let status = ClusterLinkControlMessage.status(.init(epoch: epoch, rank: 1, state: .ready, linkReady: true))
        let first = try RawLinkConnector(port: port)
        let firstRecords = try first.handshake(edge: edge)
        let old = try first.sealMessage(firstRecords, id: 1, status)
        first.socket.close()
        XCTAssertTrue(log.wait { _ in !log.disconnects.isEmpty })
        let second = try RawLinkConnector(port: port)
        defer { second.socket.close() }
        _ = try second.handshake(edge: edge)
        try second.write(old)
        XCTAssertTrue(log.wait { _ in log.disconnects.contains(.authenticationFailed) })
        XCTAssertEqual(log.messages.count, 0, "the replayed record was delivered")
    }
}
