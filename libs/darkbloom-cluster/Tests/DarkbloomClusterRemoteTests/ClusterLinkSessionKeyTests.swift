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
/// transcript under every version's label). Returns the frames it can open.
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

    /// Record sizes and the offset of the hello's limits, by the version byte in the capture:
    /// 1 (0.10.12), 2 (ephemeral keys), 3 (attested: pins and signatures).
    static func layout(version: UInt8) -> (challenge: Int, hello: Int, accept: Int, limits: Int)? {
        switch version {
        case 1: return (40, 164, 80, 112)
        case 2: return (72, 196, 80, 144)
        case 3: return (72, 324, 144, 144)
        default: return nil
        }
    }

    static func openedFrames(_ session: LinkCaptureRelay.Session, secret: Data, epoch: UUID, edgeID: UUID) -> [Data] {
        let toConnector = session.toConnector, toListener = session.toListener
        guard toConnector.count >= 8, toListener.count >= 8,
              let sizes = layout(version: toConnector[toConnector.startIndex + 4]) else { return [] }
        guard toConnector.count >= sizes.challenge + sizes.accept, toListener.count >= sizes.hello else { return [] }
        let challenge = Data(toConnector.prefix(sizes.challenge))
        let accept = Data(toConnector.dropFirst(sizes.challenge).prefix(sizes.accept))
        let hello = Data(toListener.prefix(sizes.hello))
        let at = sizes.limits
        guard let limits = try? ClusterRecordLimits(maximumPlaintextBytes: Int(hello.clusterLinkUInt32(at: at)),
            maximumRecordsPerDirection: hello.clusterLinkUInt64(at: at + 4),
            maximumCumulativePlaintextBytesPerDirection: hello.clusterLinkUInt64(at: at + 12)) else { return [] }
        var bound = uuidBytes(epoch); bound.append(uuidBytes(edgeID))
        let master = hkdf(SymmetricKey(data: secret), salt: "darkbloom/link-control/qualification-secret/v1\0", info: bound)
        let base = hkdf(master, salt: "darkbloom/link-control/key/v1\0", info: Data("session-base".utf8))
        for label in ["v1", "v2", "v3"] {
            let transcript = sha256([Data("darkbloom/link-control/transcript/\(label)\0".utf8), challenge, hello, accept])
            let domain = Data("darkbloom/link-control/session/\(label)\0".utf8)
            var info = domain; info.append(bound)
            let session = hkdf(base, salt: transcript, info: info)
            let connectorToListener = hkdf(session, salt: domain, info: Data("connector-to-listener".utf8))
            let listenerToConnector = hkdf(session, salt: domain, info: Data("listener-to-connector".utf8))
            let opened = open(Data(toConnector.dropFirst(sizes.challenge + sizes.accept)), key: listenerToConnector, sender: 0,
                    epoch: epoch, edgeID: edgeID, transcript: transcript, limits: limits)
                + open(Data(toListener.dropFirst(sizes.hello)), key: connectorToListener, sender: 1,
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
/// the handshake records, which cross the cable in the clear. Every session
/// here is attested (software identities); versions 1 and 2 are refused.
final class ClusterLinkSessionKeyTests: XCTestCase {
    let epoch = UUID()
    let edgeID = UUID()
    let secret = Data((0..<32).map { UInt8(($0 * 11 + 5) % 251) })
    let identities = LinkTestIdentities()
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

    /// The undecided edge both ends share; each end adds its own identity.
    func makeEdge(limits: ClusterLinkControlLimits? = nil) throws -> ClusterLinkControlEdge {
        let key = try ClusterLinkControlKey.qualification(secret: secret, epoch: epoch, edgeID: edgeID)
        return try ClusterLinkControlEdge(edgeID: edgeID, epoch: epoch, key: key, peerAddress: .loopback,
            limits: limits ?? self.limits())
    }

    func listenerEdge(limits: ClusterLinkControlLimits? = nil) throws -> ClusterLinkControlEdge {
        try identities.asListener(makeEdge(limits: limits))
    }

    func connectorEdge(limits: ClusterLinkControlLimits? = nil) throws -> ClusterLinkControlEdge {
        try identities.asConnector(makeEdge(limits: limits))
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
            policy: .loopbackForTests, edges: [listenerEdge()])) { event, _ in leaderLog.record(event) }
        let port = try listener.start()
        defer { listener.stop() }
        let relay = try LinkCaptureRelay(target: port)
        defer { relay.stop() }
        let follower = try ClusterLinkControlClient(configuration: .init(interface: "lo0", port: relay.port,
            policy: .loopbackForTests, edge: connectorEdge())) { event, _ in followerLog.record(event) }
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
            policy: .loopbackForTests, edges: [listenerEdge()])) { _, _ in }
        let port = try listener.start()
        defer { listener.stop() }
        let relay = try LinkCaptureRelay(target: port)
        defer { relay.stop() }
        let log = LinkEventLog()
        let client = try ClusterLinkControlClient(configuration: .init(interface: "lo0", port: relay.port,
            policy: .loopbackForTests, edge: connectorEdge())) { event, _ in log.record(event) }
        client.start()
        defer { client.stop() }
        for round in 1...3 {
            XCTAssertTrue(client.peer.waitUntilConnected(timeout: .seconds(3)))
            XCTAssertTrue(log.wait { events in events.filter(\.isConnected).count == round })
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

    /// Rollover is a new connection too: past the record budget the edge says
    /// goodbye and reconnects with a full handshake, so with fresh public keys;
    /// the edge secret opens none of the connections either.
    func testRecordBudgetRolloverMakesFreshKeys() throws {
        var rolling = limits()
        rolling.maximumRecordsPerConnection = 64
        let serverLog = LinkEventLog()
        let listener = try ClusterLinkControlListener(configuration: .init(interface: "lo0", port: 0,
            policy: .loopbackForTests, edges: [listenerEdge(limits: rolling)])) { event, _ in serverLog.record(event) }
        let port = try listener.start()
        defer { listener.stop() }
        let relay = try LinkCaptureRelay(target: port)
        defer { relay.stop() }
        let client = try ClusterLinkControlClient(configuration: .init(interface: "lo0", port: relay.port,
            policy: .loopbackForTests, edge: connectorEdge(limits: rolling))) { _, _ in }
        client.start()
        defer { client.stop() }
        XCTAssertTrue(client.peer.waitUntilConnected(timeout: .seconds(3)))
        for index in 0..<200 {
            try client.peer.send(.status(.init(epoch: epoch, rank: UInt16(index), state: .ready, linkReady: true)))
        }
        try client.peer.waitUntilAcknowledged(timeout: .seconds(10))
        XCTAssertTrue(serverLog.wait { _ in serverLog.messages.count == 200 })
        XCTAssertTrue(serverLog.disconnects.contains(.rekey) || client.peer.status.sessions >= 3)
        relay.stop()
        let sessions = relay.sessions.filter { $0.toConnector.count >= LinkHandshake.challengeBytes
            && $0.toListener.count >= LinkHandshake.helloBytes }
        XCTAssertGreaterThanOrEqual(sessions.count, 3, "the budget of 64 records rolled over")
        var keys = Set<Data>()
        for session in sessions {
            keys.insert(Data(session.toConnector.dropFirst(40).prefix(32)))
            keys.insert(Data(session.toListener.dropFirst(72).prefix(32)))
            XCTAssertEqual(EdgeSecretCaptureAttempt.openedFrames(session, secret: secret, epoch: epoch, edgeID: edgeID).count, 0)
        }
        XCTAssertEqual(keys.count, 2 * sessions.count)
    }

    /// A correctly tagged, signed handshake whose public key is of low order
    /// or this end's own: the listener keys nothing and attaches no session.
    func testListenerRefusesATaggedHelloWithABadPublicKey() throws {
        let log = LinkEventLog()
        let listener = try ClusterLinkControlListener(configuration: .init(interface: "lo0", port: 0,
            policy: .loopbackForTests, edges: [listenerEdge()])) { event, _ in log.record(event) }
        let port = try listener.start()
        defer { listener.stop() }
        let connector = try connectorEdge()
        var one = Data(count: 32); one[0] = 1
        for reflect in [false, true] {
            let raw = try RawLinkConnector(port: port)
            let challenge = try raw.read(LinkHandshake.challengeBytes)
            let publicKey = reflect ? challenge.linkBytes(LinkV3Wire.challengeKey) : one
            try raw.write(try raw.hello(edge: connector, challenge: challenge, publicKey: publicKey))
            XCTAssertTrue(raw.closedByPeer(seconds: 2))
            raw.socket.close()
        }
        XCTAssertTrue(log.wait { _ in (listener.refusals["handshakeRejected"] ?? 0) >= 2 })
        XCTAssertEqual(listener.peer(for: edgeID)?.status.sessions, 0)
        XCTAssertFalse(log.all.contains(where: \.isConnected))
    }

    /// The mirror: a listener holding the edge key and the listener's own
    /// signing key, whose challenge carries a low-order public key, with a
    /// valid accept. The connector never connects.
    func testConnectorRefusesAListenerWithABadPublicKey() throws {
        let edge = try connectorEdge()
        let listenerIdentity = try identities.listenerIdentity()
        var one = Data(count: 32); one[0] = 1
        let lowOrder = one
        let (edgeEpoch, id, key) = (epoch, edgeID, edge.key)
        let server = try ScriptedLinkListener { socket, reader in
            let challenge = LinkV3Wire.challenge(listenerKey: lowOrder)
            guard (try? socket.writeAll(challenge, deadline: linkNow() &+ 1_000_000_000)) != nil,
                  let hello = try? reader.readExact(LinkV3Wire.helloBytes, deadline: linkNow() &+ 1_000_000_000),
                  let signature = try? listenerIdentity.signature(role: .listener, epoch: edgeEpoch, edgeID: id,
                      transcript: challenge + hello + LinkV3Wire.acceptBody()) else { return }
            var accept = LinkV3Wire.acceptBody() + signature
            accept.append(key.handshakeTag(role: .listener, transcript: challenge + hello + accept))
            try? socket.writeAll(accept, deadline: linkNow() &+ 1_000_000_000)
            _ = ScriptedLinkListener.drain(reader, seconds: 0.2)
        }
        defer { server.stop() }
        let log = LinkEventLog()
        let client = try ClusterLinkControlClient(configuration: .init(interface: "lo0", port: server.port,
            policy: .loopbackForTests, edge: edge)) { event, _ in log.record(event) }
        client.start()
        XCTAssertFalse(client.peer.waitUntilConnected(timeout: .milliseconds(800)))
        client.stop()
        XCTAssertGreaterThan(client.attempts, 0)
        XCTAssertEqual(client.peer.status.sessions, 0)
        XCTAssertFalse(log.all.contains(where: \.isConnected))
    }

    /// Both tags cover both public keys: a key changed after it was tagged
    /// (the connector's in the hello, the listener's in the challenge the
    /// connector tagged) is refused before anything is keyed.
    func testTamperedEphemeralKeysAreRefused() throws {
        let log = LinkEventLog()
        let listener = try ClusterLinkControlListener(configuration: .init(interface: "lo0", port: 0,
            policy: .loopbackForTests, edges: [listenerEdge()])) { event, _ in log.record(event) }
        let port = try listener.start()
        defer { listener.stop() }
        let edge = try connectorEdge()
        for tamperChallenge in [false, true] {
            let raw = try RawLinkConnector(port: port)
            var challenge = try raw.read(LinkHandshake.challengeBytes)
            if tamperChallenge { challenge.linkReplace(LinkV3Wire.challengeKey, with: LinkV3Wire.x25519()) }
            var hello = try raw.hello(edge: edge, challenge: challenge)
            if !tamperChallenge { hello.linkReplace(LinkV3Wire.helloKey, with: LinkV3Wire.x25519()) }
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
        let listener = try ClusterLinkControlListener(configuration: .init(interface: "lo0", port: 0,
            policy: .loopbackForTests, edges: [listenerEdge()])) { event, _ in log.record(event) }
        let port = try listener.start()
        defer { listener.stop() }
        let raw = try RawLinkConnector(port: port)
        defer { raw.socket.close() }
        let records = try raw.handshake(edge: connectorEdge())
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

    /// No downgrade: a listener refuses a version-1 or version-2 hello,
    /// whatever its tag, and closes before it sends anything that keys a session.
    func testListenerRefusesOlderHandshakeVersions() throws {
        let log = LinkEventLog()
        let edge = try listenerEdge()
        let listener = try ClusterLinkControlListener(configuration: .init(interface: "lo0", port: 0,
            policy: .loopbackForTests, edges: [edge])) { event, _ in log.record(event) }
        let port = try listener.start()
        defer { listener.stop() }
        for version: UInt8 in [1, 2] {
            let raw = try RawLinkConnector(port: port)
            defer { raw.socket.close() }
            let head = try raw.read(8)
            let challenge = head + (try raw.read(LinkHandshake.challengeBytes - 8))
            // That version's hello, correctly tagged under the edge key over what this connector read.
            var hello = LinkV3Wire.helloBody(version: version, epoch: epoch, edgeID: edgeID,
                connectorKey: LinkV3Wire.x25519(), limits: try edge.limits.recordLimits())
            if version == 1 { hello.removeSubrange((hello.startIndex + 72)..<(hello.startIndex + 104)) }
            hello.append(edge.key.handshakeTag(role: .connector, transcript: challenge + hello))
            XCTAssertEqual(hello.count, version == 1 ? 164 : 196)
            try raw.write(hello)
            XCTAssertTrue(raw.closedByPeer(seconds: 2), "the listener closes the version-\(version) handshake")
        }
        XCTAssertTrue(log.wait { _ in (listener.refusals["protocolVersionMismatch"] ?? 0) >= 2 })
        XCTAssertEqual(listener.peer(for: edgeID)?.status.sessions, 0)
        XCTAssertFalse(log.all.contains(where: \.isConnected))
    }

    /// No downgrade: a connector facing a version-1 or version-2 listener
    /// stops at the challenge's version byte, says why, and sends no hello.
    func testConnectorRefusesOlderListenerVersions() throws {
        for version: UInt8 in [1, 2] {
            let received = LinkLockedBox(Data())
            let server = try ScriptedLinkListener { socket, reader in
                let challenge = LinkV3Wire.header("DBLC", version: version) + LinkV3Wire.random(32)
                    + (version == 1 ? Data() : LinkV3Wire.x25519())
                try? socket.writeAll(challenge, deadline: linkNow() &+ 1_000_000_000)
                let bytes = ScriptedLinkListener.drain(reader, seconds: 1)
                received.update { $0.append(bytes) }
            }
            let client = try ClusterLinkControlClient(configuration: .init(interface: "lo0", port: server.port,
                policy: .loopbackForTests, edge: connectorEdge())) { _, _ in }
            client.start()
            let deadline = Date(timeIntervalSinceNow: 3)
            while server.accepted < 2, Date() < deadline { usleep(20_000) }
            client.stop()
            server.stop()
            XCTAssertGreaterThanOrEqual(server.accepted, 1)
            XCTAssertEqual(received.value.count, 0, "no hello is sent to a version-\(version) listener")
            XCTAssertEqual(client.lastRefusal, .protocolVersionMismatch)
            XCTAssertFalse(client.peer.status.connected)
        }
    }
}
