import CryptoKit
import Darwin
@testable import DarkbloomClusterSecurity
import Foundation
import XCTest
@testable import DarkbloomClusterRemote

/// A TCP relay on loopback between a connector and a listener that records
/// both directions of every connection, as a capture of the cable would.
final class LinkCaptureRelay: @unchecked Sendable {
    struct Session { var toListener = Data(); var toConnector = Data() }

    private let lock = NSLock()
    private var recorded: [Session] = []
    private var sockets: [LinkSocket] = []
    private var running = true
    private let listening: LinkSocket
    private let target: UInt16
    let port: UInt16

    init(target: UInt16) throws {
        self.target = target
        (listening, port) = try LinkSocket.listen(address: .loopback, port: 0, interfaceIndex: if_nametoindex("lo0"), backlog: 8)
        let thread = Thread { [self] in acceptLoop() }
        thread.start()
    }

    var sessions: [Session] { lock.withLock { recorded } }

    func stop() {
        let open: [LinkSocket] = lock.withLock { running = false; return sockets }
        for socket in open { socket.shutdown() }
        listening.shutdown()
    }

    private func acceptLoop() {
        while lock.withLock({ running }) {
            do { try LinkSocket.waitFor(fd: listening.fd, events: Int16(POLLIN), deadline: linkNow() &+ 100_000_000) }
            catch LinkSocketError.timedOut { continue } catch { return }
            guard let accepted = try? listening.accept() else { continue }
            let inbound = accepted.0
            guard let outbound = try? LinkSocket.connect(local: .loopback, peer: .loopback, port: target,
                interfaceIndex: if_nametoindex("lo0"), timeoutNanoseconds: 2_000_000_000) else { inbound.close(); continue }
            let index: Int = lock.withLock {
                recorded.append(Session()); sockets += [inbound, outbound]
                return recorded.count - 1
            }
            pump(from: inbound, to: outbound, session: index, toListener: true)
            pump(from: outbound, to: inbound, session: index, toListener: false)
        }
    }

    private func pump(from source: LinkSocket, to sink: LinkSocket, session: Int, toListener: Bool) {
        let thread = Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count: Int
                do {
                    count = try buffer.withUnsafeMutableBytes {
                        try source.readSome(into: $0.baseAddress!, count: $0.count, deadline: linkNow() &+ 30_000_000_000)
                    }
                } catch { break }
                guard count > 0 else { break }
                let chunk = Data(buffer[0..<count])
                lock.withLock {
                    if toListener { recorded[session].toListener.append(chunk) } else { recorded[session].toConnector.append(chunk) }
                }
                do { try sink.writeAll(chunk, deadline: linkNow() &+ 5_000_000_000) } catch { break }
            }
            sink.shutdownWrite()
        }
        thread.start()
    }
}

/// What someone holding only an edge secret file and a capture of the cable
/// can compute from public code: the edge key, then each connection's keys
/// from the handshake records seen in the clear (0.10.12's key schedule; the
/// transcript under either version's label). Returns the frames it can open.
enum EdgeSecretCaptureAttempt {
    static func hkdf(_ key: SymmetricKey, salt: String, info: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data(salt.utf8), info: info, outputByteCount: 32)
    }

    static func hkdf(_ key: SymmetricKey, salt: Data, info: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt, info: info, outputByteCount: 32)
    }

    static func uuidBytes(_ value: UUID) -> Data { withUnsafeBytes(of: value.uuid) { Data($0) } }

    static func sha256(_ parts: [Data]) -> Data {
        var hasher = SHA256()
        for part in parts { hasher.update(data: part) }
        return Data(hasher.finalize())
    }

    static func openedFrames(_ session: LinkCaptureRelay.Session, secret: Data, epoch: UUID, edgeID: UUID) -> [Data] {
        let toConnector = session.toConnector, toListener = session.toListener
        guard toConnector.count >= 8, toListener.count >= 8 else { return [] }
        // Record sizes by the version byte in the capture: 1 (0.10.12), 2 (ephemeral keys).
        let version = toConnector[toConnector.startIndex + 4]
        let challengeBytes = version == 1 ? 40 : 72, helloBytes = version == 1 ? 164 : 196, acceptBytes = 80
        guard toConnector.count >= challengeBytes + acceptBytes, toListener.count >= helloBytes else { return [] }
        let challenge = Data(toConnector.prefix(challengeBytes))
        let accept = Data(toConnector.dropFirst(challengeBytes).prefix(acceptBytes))
        let hello = Data(toListener.prefix(helloBytes))
        // The record limits travel in the hello, just before its tag.
        let at = helloBytes - 32 - 20
        guard let limits = try? ClusterRecordLimits(maximumPlaintextBytes: Int(hello.clusterLinkUInt32(at: at)),
            maximumRecordsPerDirection: hello.clusterLinkUInt64(at: at + 4),
            maximumCumulativePlaintextBytesPerDirection: hello.clusterLinkUInt64(at: at + 12)) else { return [] }
        var bound = uuidBytes(epoch); bound.append(uuidBytes(edgeID))
        let master = hkdf(SymmetricKey(data: secret), salt: "darkbloom/link-control/qualification-secret/v1\0", info: bound)
        let base = hkdf(master, salt: "darkbloom/link-control/key/v1\0", info: Data("session-base".utf8))
        for label in ["v1", "v2"] {
            let transcript = sha256([Data("darkbloom/link-control/transcript/\(label)\0".utf8), challenge, hello, accept])
            let domain = Data("darkbloom/link-control/session/\(label)\0".utf8)
            var info = domain; info.append(bound)
            let session = hkdf(base, salt: transcript, info: info)
            let connectorToListener = hkdf(session, salt: domain, info: Data("connector-to-listener".utf8))
            let listenerToConnector = hkdf(session, salt: domain, info: Data("listener-to-connector".utf8))
            let opened = open(Data(toConnector.dropFirst(challengeBytes + acceptBytes)), key: listenerToConnector, sender: 0,
                    epoch: epoch, edgeID: edgeID, transcript: transcript, limits: limits)
                + open(Data(toListener.dropFirst(helloBytes)), key: connectorToListener, sender: 1,
                    epoch: epoch, edgeID: edgeID, transcript: transcript, limits: limits)
            if !opened.isEmpty { return opened }
        }
        return []
    }

    /// The records of one direction, in order, as the receiving end opens them.
    static func open(_ stream: Data, key: SymmetricKey, sender: UInt8, epoch: UUID, edgeID: UUID, transcript: Data,
                     limits: ClusterRecordLimits) -> [Data] {
        let plan = sha256([Data("darkbloom/link-control/edge/v1\0".utf8), uuidBytes(edgeID)])
        let expectation = sha256([Data("darkbloom/link-control/frame/v1\0".utf8), uuidBytes(edgeID), Data([sender])])
        guard let binding = try? ClusterRecordBinding(epoch: epoch, planSHA256: plan, membershipTranscriptSHA256: transcript),
              let context = try? ClusterRecordContext(requestID: nil, type: .linkControl, expectationSHA256: expectation),
              let opener = try? ClusterAuthenticatedRecordChannel(sessionKey: key, binding: binding, localRank: Int(1 - sender),
                  limits: limits) else { return [] }
        var frames = [Data](), rest = stream
        let prefixBytes = ClusterAuthenticatedRecordChannel.framingPrefixBytes
        while rest.count >= prefixBytes {
            guard let total = try? ClusterAuthenticatedRecordChannel.boundedRecordByteCount(fromPrefix: Data(rest.prefix(prefixBytes)),
                      maximumPlaintextBytes: limits.maximumPlaintextBytes), rest.count >= total,
                  let plaintext = try? opener.open(Data(rest.prefix(total)), expecting: context) else { break }
            frames.append(plaintext)
            rest = Data(rest.dropFirst(total))
        }
        return frames
    }
}

/// The link's session keys must not follow from the edge secret: both Macs
/// keep that secret in a file their owner can read, and the cable can be
/// captured. Version 1 of the handshake derived every key from the secret and
/// the handshake records, which cross the cable in the clear.
final class ClusterLinkSessionKeyTests: XCTestCase {
    let epoch = UUID()
    let edgeID = UUID()
    let secret = Data((0..<32).map { UInt8(($0 * 11 + 5) % 251) })
    /// A prompt as the leader sends it to rank 1 in a reservation.
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

    func reserve() -> ClusterLinkControlMessage {
        .reserve(ClusterLinkRequestReserve(epoch: epoch, requestID: UUID(), modelID: "fixture-model",
            planSHA256: String(repeating: "b", count: 64), promptTokens: prompt, maximumOutputTokens: 64,
            deadlineMilliseconds: 30_000))
    }

    /// The prompt as the worker wire packs it (little-endian Int32).
    var packedPrompt: Data {
        var packed = Data()
        for token in prompt { withUnsafeBytes(of: token.littleEndian) { packed.append(contentsOf: $0) } }
        return packed
    }

    /// The report's proof of concept: the leader (listener) sends rank 1 a
    /// reservation with its prompt and a worker-wire payload, over two
    /// connections of one edge (a reconnect between them). With the edge
    /// secret and the captured bytes, no frame of either connection opens.
    func testCapturedReservationDoesNotDecryptWithTheEdgeSecret() throws {
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

        for session in 1...2 {
            XCTAssertTrue(follower.peer.waitUntilConnected(timeout: .seconds(3)))
            XCTAssertTrue(leader.waitUntilConnected(timeout: .seconds(3)))
            try leader.send(reserve())
            try leader.sendOpaque(tag: ClusterLinkWorkerWire.tag, packedPrompt)
            XCTAssertTrue(followerLog.wait { _ in followerLog.messages.count == session })
            XCTAssertTrue(followerLog.wait { events in
                events.filter { if case .opaque = $0 { return true }; return false }.count == session
            })
            try leader.waitUntilAcknowledged(timeout: .seconds(3))
            if session == 1 {
                follower.peer.dropConnectionForTesting()
                XCTAssertTrue(followerLog.wait { _ in !followerLog.disconnects.isEmpty })
            }
        }
        // The follower got both reservations whole: the capture holds them.
        for (_, message) in followerLog.messages {
            guard case .reserve(let received) = message else { return XCTFail("a reservation") }
            XCTAssertEqual(received.promptTokenIDs, prompt)
        }
        relay.stop()
        let sessions = relay.sessions
        XCTAssertGreaterThanOrEqual(sessions.count, 2, "both connections were captured")

        for (index, session) in sessions.enumerated() {
            XCTAssertNil(session.toConnector.range(of: packedPrompt), "connection \(index): the prompt crossed in the clear")
            let frames = EdgeSecretCaptureAttempt.openedFrames(session, secret: secret, epoch: epoch, edgeID: edgeID)
            let prompts = frames.filter { frame in
                guard let parsed = try? LinkFrame.parse(frame, maximumBodyBytes: limits().maximumBodyBytes) else { return false }
                if parsed.body.range(of: packedPrompt) != nil { return true }
                if parsed.kind == .message, let message = try? JSONDecoder().decode(ClusterLinkControlMessage.self, from: parsed.body),
                   case .reserve(let opened) = message, opened.promptTokenIDs == prompt { return true }
                return false
            }
            XCTAssertEqual(frames.count, 0, "connection \(index): the edge secret and the capture opened \(frames.count) frames")
            XCTAssertEqual(prompts.count, 0, "connection \(index): the edge secret and the capture recovered the prompt")
        }
    }

    /// Rekey per connection: every connection of one edge (first connect,
    /// reconnects) carries two fresh, canonical public keys.
    func testEveryConnectionUsesFreshEphemeralKeys() throws {
        let listener = try ClusterLinkControlListener(configuration: .init(interface: "lo0", port: 0,
            policy: .loopbackForTests, edges: [makeEdge()])) { _, _ in }
        let port = try listener.start()
        defer { listener.stop() }
        let relay = try LinkCaptureRelay(target: port)
        defer { relay.stop() }
        let log = LinkEventLog()
        let client = try ClusterLinkControlClient(configuration: .init(interface: "lo0", port: relay.port,
            policy: .loopbackForTests, edge: makeEdge())) { event, _ in log.record(event) }
        client.start()
        defer { client.stop() }
        for round in 1...3 {
            XCTAssertTrue(client.peer.waitUntilConnected(timeout: .seconds(3)))
            XCTAssertTrue(log.wait { events in events.filter { if case .connected = $0 { return true }; return false }.count == round })
            if round < 3 { client.peer.dropConnectionForTesting() }
        }
        relay.stop()
        let sessions = relay.sessions.filter { $0.toConnector.count >= LinkHandshake.challengeBytes
            && $0.toListener.count >= LinkHandshake.helloBytes }
        XCTAssertGreaterThanOrEqual(sessions.count, 3)
        var keys = Set<Data>()
        for session in sessions {
            let listenerKey = Data(session.toConnector.dropFirst(40).prefix(32))
            let connectorKey = Data(session.toListener.dropFirst(72).prefix(32))
            XCTAssertEqual(session.toConnector[session.toConnector.startIndex + 4], LinkHandshake.version)
            XCTAssertTrue(nativeCanonicalX25519PublicKey(listenerKey) && nativeCanonicalX25519PublicKey(connectorKey))
            keys.insert(listenerKey); keys.insert(connectorKey)
        }
        XCTAssertEqual(keys.count, 2 * sessions.count, "no public key is reused across connections or ends")
    }

    /// Both tags cover both public keys: a key changed after it was tagged
    /// (the connector's in the hello, the listener's in the challenge the
    /// connector tagged) is refused before anything is keyed.
    func testTamperedEphemeralKeysAreRefused() throws {
        let log = LinkEventLog()
        let edge = try makeEdge()
        let listener = try ClusterLinkControlListener(configuration: .init(interface: "lo0", port: 0,
            policy: .loopbackForTests, edges: [edge])) { event, _ in log.record(event) }
        let port = try listener.start()
        defer { listener.stop() }
        for tamperChallenge in [false, true] {
            let raw = try RawLinkConnector(port: port)
            var challenge = try raw.read(LinkHandshake.challengeBytes)
            if tamperChallenge { challenge.replaceSubrange((challenge.startIndex + 40)..<(challenge.startIndex + 72),
                with: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation) }
            var hello = try raw.hello(edge: edge, challenge: challenge)
            if !tamperChallenge {
                hello.replaceSubrange((hello.startIndex + 72)..<(hello.startIndex + 104),
                    with: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
            }
            try raw.write(hello)
            XCTAssertTrue(raw.closedByPeer(seconds: 2))
            raw.socket.close()
        }
        XCTAssertTrue(log.wait { _ in (listener.refusals["authenticationFailed"] ?? 0) >= 2 })
        XCTAssertEqual(listener.peer(for: edgeID)?.status.sessions, 0)
    }

    /// Per-direction counters: a record sent ahead of its turn ends the
    /// session and nothing is delivered.
    func testReorderedRecordsEndTheSession() throws {
        let log = LinkEventLog()
        let edge = try makeEdge()
        let listener = try ClusterLinkControlListener(configuration: .init(interface: "lo0", port: 0,
            policy: .loopbackForTests, edges: [edge])) { event, _ in log.record(event) }
        let port = try listener.start()
        defer { listener.stop() }
        let raw = try RawLinkConnector(port: port)
        defer { raw.socket.close() }
        let records = try raw.handshake(edge: edge)
        let status = ClusterLinkControlMessage.status(.init(epoch: epoch, rank: 1, state: .ready, linkReady: true))
        let first = try raw.sealMessage(records, id: 1, status)
        let second = try raw.sealMessage(records, id: 2, status)
        try raw.write(second)
        try raw.write(first)
        XCTAssertTrue(log.wait { _ in log.disconnects.contains(.authenticationFailed) })
        XCTAssertEqual(log.messages.count, 0)
    }

    /// The key schedule itself: both ends agree; another connection's
    /// ephemeral key gives other keys under the same transcript; a peer key
    /// that is all zero, non-canonical, of low order or this end's own is refused.
    func testSessionKeysNeedTheEphemeralAgreement() throws {
        let key = try ClusterLinkControlKey.qualification(secret: secret, epoch: epoch, edgeID: edgeID)
        let transcript = Data(SHA256.hash(data: Data("transcript".utf8)))
        let listener = Curve25519.KeyAgreement.PrivateKey(), connector = Curve25519.KeyAgreement.PrivateKey()
        let atListener = try key.sessionKeys(ephemeralPrivateKey: listener, peerEphemeralPublicKey: connector.publicKey.rawRepresentation,
            transcriptSHA256: transcript, epoch: epoch, edgeID: edgeID)
        let atConnector = try key.sessionKeys(ephemeralPrivateKey: connector, peerEphemeralPublicKey: listener.publicKey.rawRepresentation,
            transcriptSHA256: transcript, epoch: epoch, edgeID: edgeID)
        func bytes(_ value: SymmetricKey) -> Data { value.withUnsafeBytes { Data($0) } }
        XCTAssertEqual(bytes(atListener.connectorToListener), bytes(atConnector.connectorToListener))
        XCTAssertEqual(bytes(atListener.listenerToConnector), bytes(atConnector.listenerToConnector))
        XCTAssertNotEqual(bytes(atListener.connectorToListener), bytes(atListener.listenerToConnector))
        let other = try key.sessionKeys(ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey(),
            peerEphemeralPublicKey: listener.publicKey.rawRepresentation, transcriptSHA256: transcript, epoch: epoch, edgeID: edgeID)
        XCTAssertNotEqual(bytes(other.connectorToListener), bytes(atListener.connectorToListener))
        let otherEdgeKey = try ClusterLinkControlKey.qualification(secret: Data(repeating: 0x5A, count: 32), epoch: epoch, edgeID: edgeID)
        let withOtherEdgeKey = try otherEdgeKey.sessionKeys(ephemeralPrivateKey: listener,
            peerEphemeralPublicKey: connector.publicKey.rawRepresentation, transcriptSHA256: transcript, epoch: epoch, edgeID: edgeID)
        XCTAssertNotEqual(bytes(withOtherEdgeKey.connectorToListener), bytes(atListener.connectorToListener))
        // Low order: 0 and 1 (and the canonical form of p - 1); non-canonical: p itself.
        var one = Data(count: 32); one[0] = 1
        var pMinusOne = Data(repeating: 0xff, count: 32); pMinusOne[0] = 0xec; pMinusOne[31] = 0x7f
        var p = Data(repeating: 0xff, count: 32); p[0] = 0xed; p[31] = 0x7f
        for bad in [Data(count: 32), one, pMinusOne, p, Data(count: 31), listener.publicKey.rawRepresentation] {
            XCTAssertThrowsError(try key.sessionKeys(ephemeralPrivateKey: listener, peerEphemeralPublicKey: bad,
                transcriptSHA256: transcript, epoch: epoch, edgeID: edgeID))
        }
        XCTAssertThrowsError(try key.sessionKeys(ephemeralPrivateKey: listener, peerEphemeralPublicKey: connector.publicKey.rawRepresentation,
            transcriptSHA256: Data(count: 31), epoch: epoch, edgeID: edgeID))
    }

    /// No downgrade: a listener refuses a version-1 hello, whatever its tag,
    /// and closes before it sends anything that keys a session.
    func testListenerRefusesTheVersionOneHandshake() throws {
        let log = LinkEventLog()
        let edge = try makeEdge()
        let listener = try ClusterLinkControlListener(configuration: .init(interface: "lo0", port: 0,
            policy: .loopbackForTests, edges: [edge])) { event, _ in log.record(event) }
        let port = try listener.start()
        defer { listener.stop() }
        let raw = try RawLinkConnector(port: port)
        defer { raw.socket.close() }
        let head = try raw.read(8)
        let challenge = head + (try raw.read(head[head.startIndex + 4] == 1 ? 32 : 64))
        // Version 1's hello, correctly tagged under the edge key over what this connector read.
        let recordLimits = try edge.limits.recordLimits()
        var hello = Data("DBLH".utf8); hello.append(contentsOf: [1, ClusterLinkControlRole.connector.rawValue, 0, 0])
        hello.append(EdgeSecretCaptureAttempt.uuidBytes(epoch)); hello.append(EdgeSecretCaptureAttempt.uuidBytes(edgeID))
        hello.append(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        hello.append(EdgeSecretCaptureAttempt.uuidBytes(UUID())); hello.append(Data(count: 16))
        hello.clusterLinkAppend(UInt64(0))
        hello.clusterLinkAppend(UInt32(recordLimits.maximumPlaintextBytes))
        hello.clusterLinkAppend(recordLimits.maximumRecordsPerDirection)
        hello.clusterLinkAppend(recordLimits.maximumCumulativePlaintextBytesPerDirection)
        hello.append(edge.key.handshakeTag(role: .connector, transcript: challenge + hello))
        XCTAssertEqual(hello.count, 164)
        try raw.write(hello)
        XCTAssertTrue(raw.closedByPeer(seconds: 2), "the listener closes the version-1 handshake")
        XCTAssertTrue(log.wait { _ in listener.refusals["protocolVersionMismatch"] != nil })
        XCTAssertEqual(listener.peer(for: edgeID)?.status.sessions, 0)
    }

    /// No downgrade: a connector facing a version-1 listener stops at the
    /// challenge's version byte, says why, and sends no hello.
    func testConnectorRefusesAVersionOneListener() throws {
        let (server, port) = try LinkSocket.listen(address: .loopback, port: 0, interfaceIndex: if_nametoindex("lo0"), backlog: 8)
        defer { server.close() }
        final class Received: @unchecked Sendable {
            let lock = NSLock(); var bytes = 0; var connections = 0
        }
        let received = Received()
        let stop = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        Thread {
            while stop.wait(timeout: .now()) == .timedOut {
                guard (try? LinkSocket.waitFor(fd: server.fd, events: Int16(POLLIN), deadline: linkNow() &+ 50_000_000)) != nil,
                      let accepted = try? server.accept() else { continue }
                received.lock.withLock { received.connections += 1 }
                var challenge = Data("DBLC".utf8); challenge.append(contentsOf: [1, 0, 0, 0])
                challenge.append(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
                try? accepted.0.writeAll(challenge, deadline: linkNow() &+ 1_000_000_000)
                var buffer = [UInt8](repeating: 0, count: 512)
                while let count = try? buffer.withUnsafeMutableBytes({
                    try accepted.0.readSome(into: $0.baseAddress!, count: $0.count, deadline: linkNow() &+ 1_000_000_000)
                }), count > 0 {
                    received.lock.withLock { received.bytes += count }
                }
                accepted.0.close()
            }
            done.signal()
        }.start()
        let client = try ClusterLinkControlClient(configuration: .init(interface: "lo0", port: port,
            policy: .loopbackForTests, edge: makeEdge())) { _, _ in }
        client.start()
        let deadline = Date(timeIntervalSinceNow: 3)
        while received.lock.withLock({ received.connections }) < 2, Date() < deadline { usleep(20_000) }
        client.stop()
        stop.signal()
        _ = done.wait(timeout: .now() + 3)
        XCTAssertGreaterThanOrEqual(received.lock.withLock { received.connections }, 1)
        XCTAssertEqual(received.lock.withLock { received.bytes }, 0, "no hello is sent to a version-1 listener")
        XCTAssertEqual(client.lastRefusal.map { "\($0)" }, "protocolVersionMismatch")
        XCTAssertFalse(client.peer.status.connected)
    }
}
