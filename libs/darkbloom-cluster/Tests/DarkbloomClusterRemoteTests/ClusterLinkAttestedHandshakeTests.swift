import CryptoKit
import Darwin
@testable import DarkbloomClusterSecurity
import Foundation
import XCTest
@testable import DarkbloomClusterRemote

/// Handshake v3: each end proves the identity key the other pinned (software
/// P-256 keys stand in for the Secure Enclave). Everyone here holds the edge
/// secret, the attacker too: the listener L and the connector C pin each
/// other, and the attacker's own key F is pinned by nobody. Loopback only.
final class ClusterLinkAttestedHandshakeTests: XCTestCase {
    let epoch = UUID()
    let edgeID = UUID()
    let secret = Data((0..<32).map { UInt8(($0 * 13 + 1) % 251) })
    let identities = LinkTestIdentities(clusterID: "fixture-cluster-attested")
    let attacker = SoftwareLinkSigner()
    let prompt: [Int32] = [151_644, 872, 198, 3_555, 20_217, 31_415, 92_653, 151_645]

    var clusterID: String { identities.clusterID }

    func limits() -> ClusterLinkControlLimits {
        var value = ClusterLinkControlLimits()
        value.heartbeatInterval = .milliseconds(100)
        value.silenceTimeout = .milliseconds(1000)
        value.handshakeTimeout = .milliseconds(800)
        value.reconnectInitialDelay = .milliseconds(10)
        value.reconnectMaximumDelay = .milliseconds(100)
        return value
    }

    func baseEdge() throws -> ClusterLinkControlEdge {
        let key = try ClusterLinkControlKey.qualification(secret: secret, epoch: epoch, edgeID: edgeID)
        return try ClusterLinkControlEdge(edgeID: edgeID, epoch: epoch, key: key, peerAddress: .loopback, limits: limits())
    }

    func listenerEdge() throws -> ClusterLinkControlEdge { try identities.asListener(baseEdge()) }
    func connectorEdge() throws -> ClusterLinkControlEdge { try identities.asConnector(baseEdge()) }
    func edgeKeyOnlyEdge() throws -> ClusterLinkControlEdge { try baseEdge().authenticatedByEdgeKeyOnly() }

    /// An end that signs as `signer` and pins `peer`, on the shared edge secret.
    func edge(signer: some ClusterLinkIdentitySigner, peer: SoftwareLinkSigner) throws -> ClusterLinkControlEdge {
        try baseEdge().authenticated(by: ClusterLinkIdentity(signer: signer, peerIdentityKey: peer.identityPublicKey,
            clusterID: clusterID))
    }

    /// The attacker's hand-rolled records: the edge key, epoch, edge and cluster ID it knows.
    func wire() throws -> LinkV3Wire {
        try LinkV3Wire(epoch: epoch, edgeID: edgeID, clusterID: clusterID, key: baseEdge().key,
            limits: limits().recordLimits())
    }

    func startListener(_ edge: ClusterLinkControlEdge, _ log: LinkEventLog) throws -> (ClusterLinkControlListener, UInt16) {
        let listener = try ClusterLinkControlListener(configuration: .init(interface: "lo0", port: 0,
            policy: .loopbackForTests, edges: [edge])) { event, _ in log.record(event) }
        return (listener, try listener.start())
    }

    func startClient(_ edge: ClusterLinkControlEdge, port: UInt16, _ log: LinkEventLog) throws -> ClusterLinkControlClient {
        let client = try ClusterLinkControlClient(configuration: .init(interface: "lo0", port: port,
            policy: .loopbackForTests, edge: edge)) { event, _ in log.record(event) }
        client.start()
        return client
    }

    func reserve() -> ClusterLinkControlMessage {
        .reserve(ClusterLinkRequestReserve(epoch: epoch, requestID: UUID(), modelID: "fixture-model",
            planSHA256: String(repeating: "d", count: 64), promptTokens: prompt, maximumOutputTokens: 32,
            deadlineMilliseconds: 30_000))
    }

    /// The prompt as the worker wire and the reservation pack it (little-endian Int32).
    var packedPrompt: Data {
        var packed = Data()
        for token in prompt { withUnsafeBytes(of: token.littleEndian) { packed.append(contentsOf: $0) } }
        return packed
    }

    /// Neither the packed prompt nor its base64 form (the reservation's JSON) is in `bytes`.
    func assertNoPrompt(in bytes: Data, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(bytes.range(of: packedPrompt), "\(context): the packed prompt", file: file, line: line)
        XCTAssertNil(bytes.range(of: Data(packedPrompt.base64EncodedString().utf8)), "\(context): the prompt's JSON form",
            file: file, line: line)
    }

    func refusals(_ listener: ClusterLinkControlListener, _ reason: String) -> UInt64 { listener.refusals[reason] ?? 0 }

    // MARK: 1–3: an impostor holding the edge secret

    /// The attacker runs the product connector with the edge secret and its own key.
    func testConnectorWithItsOwnKeyIsNotPinned() throws {
        let listenerLog = LinkEventLog(), fakeLog = LinkEventLog()
        let (listener, port) = try startListener(listenerEdge(), listenerLog)
        defer { listener.stop() }
        let fake = try startClient(edge(signer: attacker, peer: identities.listener), port: port, fakeLog)
        defer { fake.stop() }
        XCTAssertTrue(listenerLog.wait { _ in listenerLog.refusals.contains(.peerNotPinned) })
        XCTAssertFalse(fake.peer.waitUntilConnected(timeout: .milliseconds(300)))
        XCTAssertEqual(listener.peer(for: edgeID)?.status.sessions, 0)
        XCTAssertFalse(listenerLog.all.contains(where: \.isConnected))
        XCTAssertFalse(fakeLog.all.contains(where: \.isConnected))
    }

    /// A hand-rolled hello claiming C's pin, correctly tagged, signed by F
    /// over the right message (or not signed): refused at the signature. The
    /// same hello signed by C is accepted, so the layout itself is right.
    func testHelloClaimingTheConnectorsPinNeedsItsSignature() throws {
        let log = LinkEventLog()
        let (listener, port) = try startListener(listenerEdge(), log)
        defer { listener.stop() }
        let wire = try wire()
        for signer in [attacker, nil] as [SoftwareLinkSigner?] {
            let raw = try RawLinkConnector(port: port)
            let challenge = try raw.read(LinkV3Wire.challengeBytes)
            try raw.write(wire.hello(body: wire.helloBody(), challenge: challenge, connectorPin: identities.connector.pin,
                listenerPin: identities.listener.pin, signer: signer))
            XCTAssertEqual(ScriptedLinkListener.drain(raw.reader, seconds: 2).count, 0, "no accept for an impostor")
            raw.socket.close()
        }
        XCTAssertTrue(log.wait { _ in self.refusals(listener, "peerSignatureRejected") >= 2 })
        XCTAssertEqual(listener.peer(for: edgeID)?.status.sessions, 0)
        XCTAssertFalse(log.all.contains(where: \.isConnected))

        let raw = try RawLinkConnector(port: port)
        defer { raw.socket.close() }
        let challenge = try raw.read(LinkV3Wire.challengeBytes)
        let hello = wire.hello(body: wire.helloBody(), challenge: challenge, connectorPin: identities.connector.pin,
            listenerPin: identities.listener.pin, signer: identities.connector)
        try raw.write(hello)
        let accept = try raw.read(LinkV3Wire.acceptBytes)
        XCTAssertTrue(try identities.connectorIdentity().isValidPeerSignature(accept.linkBytes(LinkV3Wire.acceptSignature),
            role: .listener, epoch: epoch, edgeID: edgeID, transcript: challenge + hello + accept.linkBytes(0..<48)))
    }

    /// A hand-rolled listener with the edge secret: valid challenge and accept
    /// layouts, correct tags, the accept signed by F. The connector refuses
    /// and sends nothing after the accept; signed by L, it connects.
    func testListenerSignedByAnotherKeyIsRefused() throws {
        let wire = try wire()
        for (signer, genuine) in [(attacker, false), (identities.listener, true)] {
            let afterAccept = LinkLockedBox(Data())
            let server = try ScriptedLinkListener { socket, reader in
                let challenge = LinkV3Wire.challenge()
                guard (try? socket.writeAll(challenge, deadline: linkNow() &+ 1_000_000_000)) != nil,
                      let hello = try? reader.readExact(LinkV3Wire.helloBytes, deadline: linkNow() &+ 1_000_000_000) else { return }
                let accept = wire.accept(body: LinkV3Wire.acceptBody(), challenge: challenge, hello: hello, signer: signer)
                try? socket.writeAll(accept, deadline: linkNow() &+ 1_000_000_000)
                let rest = ScriptedLinkListener.drain(reader, seconds: genuine ? 0.3 : 1)
                afterAccept.update { $0.append(rest) }
            }
            defer { server.stop() }
            let log = LinkEventLog()
            let client = try startClient(connectorEdge(), port: server.port, log)
            if genuine {
                XCTAssertTrue(log.wait { $0.contains(where: \.isConnected) }, "the hand-rolled records are well formed")
                client.stop()
                continue
            }
            XCTAssertTrue(log.wait { _ in log.refusals.contains(.peerSignatureRejected) })
            XCTAssertEqual(client.lastRefusal, .peerSignatureRejected)
            client.stop()
            XCTAssertFalse(log.all.contains(where: \.isConnected))
            XCTAssertEqual(client.peer.status.sessions, 0)
            XCTAssertEqual(afterAccept.value.count, 0, "the connector wrote after an accept it refused")
        }
    }

    // MARK: 4: a relay terminating both legs

    /// A relay with the edge secret answers the real connector as a listener
    /// and dials the real listener as a connector, with its own key (claiming
    /// its own pin, then C's). Both real ends refuse; each queued a
    /// reservation, and the relay receives nothing past the handshake records.
    func testRelayTerminatingBothLegsIsRefusedByBothEnds() throws {
        let listenerLog = LinkEventLog(), connectorLog = LinkEventLog()
        let (listener, port) = try startListener(listenerEdge(), listenerLog)
        defer { listener.stop() }
        try XCTUnwrap(listener.peer(for: edgeID)).send(reserve())
        let wire = try wire()
        let attacker = attacker, connectorPin = identities.connector.pin, listenerPin = identities.listener.pin
        let fromConnector = LinkLockedBox([Data]()), fromListener = LinkLockedBox([Data]())
        let relay = try ScriptedLinkListener { socket, reader in
            let legs = fromListener.value.count
            // Toward the real listener: its challenge, then the relay's hello.
            if let leg = try? RawLinkConnector(port: port), let challenge = try? leg.read(LinkV3Wire.challengeBytes) {
                let hello = wire.hello(body: wire.helloBody(), challenge: challenge,
                    connectorPin: legs % 2 == 0 ? attacker.pin : connectorPin, listenerPin: listenerPin, signer: attacker)
                try? leg.write(hello)
                let received = challenge + ScriptedLinkListener.drain(leg.reader, seconds: 1)
                fromListener.update { $0.append(received) }
                leg.socket.close()
            }
            // Toward the real connector: the relay's challenge and accept.
            let challenge = LinkV3Wire.challenge()
            guard (try? socket.writeAll(challenge, deadline: linkNow() &+ 1_000_000_000)) != nil,
                  let hello = try? reader.readExact(LinkV3Wire.helloBytes, deadline: linkNow() &+ 1_000_000_000) else { return }
            try? socket.writeAll(wire.accept(body: LinkV3Wire.acceptBody(), challenge: challenge, hello: hello, signer: attacker),
                deadline: linkNow() &+ 1_000_000_000)
            let received = hello + ScriptedLinkListener.drain(reader, seconds: 1)
            fromConnector.update { $0.append(received) }
        }
        defer { relay.stop() }
        let client = try startClient(connectorEdge(), port: relay.port, connectorLog)
        try client.peer.send(reserve())
        XCTAssertTrue(connectorLog.wait { _ in connectorLog.refusals.contains(.peerSignatureRejected) })
        XCTAssertTrue(listenerLog.wait { _ in
            listenerLog.refusals.contains(.peerNotPinned) && listenerLog.refusals.contains(.peerSignatureRejected)
        })
        let deadline = Date(timeIntervalSinceNow: 3)
        while fromConnector.value.count < 2, Date() < deadline { usleep(20_000) }
        client.stop()
        relay.stop()
        XCTAssertFalse(listenerLog.all.contains(where: \.isConnected))
        XCTAssertFalse(connectorLog.all.contains(where: \.isConnected))
        XCTAssertEqual(listener.peer(for: edgeID)?.status.sessions, 0)
        XCTAssertGreaterThanOrEqual(fromListener.value.count, 2)
        XCTAssertGreaterThanOrEqual(fromConnector.value.count, 2)
        for received in fromListener.value {
            XCTAssertEqual(received.count, LinkV3Wire.challengeBytes, "the listener sent more than its challenge")
            assertNoPrompt(in: received, "listener leg")
        }
        for received in fromConnector.value {
            XCTAssertEqual(received.count, LinkV3Wire.helloBytes, "the connector sent more than its hello")
            assertNoPrompt(in: received, "connector leg")
        }
    }

    // MARK: 5, 8: the edge secret and a capture

    /// The product's own key API with the owner's edge key, every captured
    /// public key and the attacker's own ephemeral key: records opened.
    func productAPIAttempt(_ session: LinkCaptureRelay.Session) throws -> (attempts: Int, opened: Int) {
        let challenge = session.toConnector.linkBytes(0..<LinkV3Wire.challengeBytes)
        let accept = session.toConnector.linkBytes(LinkV3Wire.challengeBytes..<(LinkV3Wire.challengeBytes + LinkV3Wire.acceptBytes))
        let hello = session.toListener.linkBytes(0..<LinkV3Wire.helloBytes)
        let toConnector = Data(session.toConnector.dropFirst(LinkV3Wire.challengeBytes + LinkV3Wire.acceptBytes))
        let toListener = Data(session.toListener.dropFirst(LinkV3Wire.helloBytes))
        let transcript = LinkHandshake.transcriptSHA256(challenge: challenge, hello: hello, accept: accept)
        let key = try baseEdge().key
        XCTAssertTrue(key.isValidHandshakeTag(hello.linkBytes(LinkV3Wire.helloTag), role: .connector,
            transcript: challenge + hello.linkBytes(0..<292)), "the capture is this edge's")
        let listenerPublic = challenge.linkBytes(LinkV3Wire.challengeKey), connectorPublic = hello.linkBytes(LinkV3Wire.helloKey)
        var attempts = 0, opened = 0
        for role in [ClusterLinkControlRole.listener, .connector] {
            for peerPublic in [listenerPublic, connectorPublic] {
                var candidates = [Curve25519.KeyAgreement.PrivateKey()]
                for raw in [listenerPublic, connectorPublic] {
                    if let scalar = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) { candidates.append(scalar) }
                }
                for mine in candidates {
                    guard let records = try? LinkRecordPair(role: role, key: key, ephemeralPrivateKey: mine,
                        peerEphemeralPublicKey: peerPublic, transcriptSHA256: transcript, epoch: epoch, edgeID: edgeID,
                        limits: limits().recordLimits()) else { continue }
                    attempts += 1
                    opened += openAll(role == .connector ? toConnector : toListener, with: records)
                }
            }
        }
        return (attempts, opened)
    }

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

    /// A forwarding relay records every byte of a real attested session (two
    /// connections) carrying a reservation each way and a worker-wire prompt.
    /// With the edge secret, nothing of the capture opens and the prompt is in
    /// none of its bytes.
    func testCapturedAttestedSessionOpensNothingWithTheEdgeSecret() throws {
        let leaderLog = LinkEventLog(), followerLog = LinkEventLog()
        let (listener, port) = try startListener(listenerEdge(), leaderLog)
        defer { listener.stop() }
        let relay = try LinkCaptureRelay(target: port)
        defer { relay.stop() }
        let follower = try startClient(connectorEdge(), port: relay.port, followerLog)
        defer { follower.stop() }
        let leader = try XCTUnwrap(listener.peer(for: edgeID))
        for session in 1...2 {
            XCTAssertTrue(follower.peer.waitUntilConnected(timeout: .seconds(3)))
            XCTAssertTrue(leader.waitUntilConnected(timeout: .seconds(3)))
            try leader.send(reserve())
            try leader.sendOpaque(tag: ClusterLinkWorkerWire.tag, packedPrompt)
            try follower.peer.send(reserve())
            XCTAssertTrue(followerLog.wait { _ in followerLog.messages.count == session })
            XCTAssertTrue(followerLog.wait { $0.filter(\.isOpaque).count == session })
            XCTAssertTrue(leaderLog.wait { _ in leaderLog.messages.count == session })
            try leader.waitUntilAcknowledged(timeout: .seconds(3))
            try follower.peer.waitUntilAcknowledged(timeout: .seconds(3))
            if session == 1 {
                follower.peer.dropConnectionForTesting()
                XCTAssertTrue(followerLog.wait { _ in !followerLog.disconnects.isEmpty })
            }
        }
        for (_, message) in followerLog.messages + leaderLog.messages {
            guard case .reserve(let received) = message else { return XCTFail("a reservation") }
            XCTAssertEqual(received.promptTokenIDs, prompt)
        }
        relay.stop()
        let sessions = relay.sessions.filter { $0.toConnector.count > LinkV3Wire.challengeBytes + LinkV3Wire.acceptBytes
            && $0.toListener.count > LinkV3Wire.helloBytes }
        XCTAssertGreaterThanOrEqual(sessions.count, 2, "both connections were captured")
        for (index, session) in sessions.enumerated() {
            XCTAssertEqual(session.toConnector[session.toConnector.startIndex + 4], 3)
            assertNoPrompt(in: session.toConnector, "connection \(index) to the connector")
            assertNoPrompt(in: session.toListener, "connection \(index) to the listener")
            let frames = EdgeSecretCaptureAttempt.openedFrames(session, secret: secret, epoch: epoch, edgeID: edgeID)
            XCTAssertEqual(frames.count, 0, "connection \(index): the edge secret and the capture opened \(frames.count) frames")
            let product = try productAPIAttempt(session)
            XCTAssertGreaterThan(product.attempts, 4)
            XCTAssertEqual(product.opened, 0, "connection \(index): an owner keying through the product API opened records")
        }
    }

    /// The edge secret alone, with everything a capture shows (both pins, a
    /// real connection's signatures): it can neither dial nor answer an
    /// attested end, and it opens nothing of the capture.
    func testTheEdgeSecretAloneCanNeitherDialNorAnswer() throws {
        let leaderLog = LinkEventLog(), followerLog = LinkEventLog()
        let (listener, port) = try startListener(listenerEdge(), leaderLog)
        defer { listener.stop() }
        let relay = try LinkCaptureRelay(target: port)
        defer { relay.stop() }
        let follower = try startClient(connectorEdge(), port: relay.port, followerLog)
        defer { follower.stop() }
        XCTAssertTrue(follower.peer.waitUntilConnected(timeout: .seconds(3)))
        let leader = try XCTUnwrap(listener.peer(for: edgeID))
        try leader.send(reserve())
        XCTAssertTrue(followerLog.wait { _ in followerLog.messages.count == 1 })
        try leader.waitUntilAcknowledged(timeout: .seconds(3))
        follower.stop()
        relay.stop()
        let captured = try XCTUnwrap(relay.sessions.first)
        let capturedHello = captured.toListener.linkBytes(0..<LinkV3Wire.helloBytes)
        let capturedAccept = captured.toConnector.linkBytes(LinkV3Wire.challengeBytes..<(LinkV3Wire.challengeBytes + LinkV3Wire.acceptBytes))
        XCTAssertEqual(EdgeSecretCaptureAttempt.openedFrames(captured, secret: secret, epoch: epoch, edgeID: edgeID).count, 0)
        XCTAssertEqual(try productAPIAttempt(captured).opened, 0)
        assertNoPrompt(in: captured.toConnector, "capture")

        // Dialling: no pins; the captured pins without a signature; with the captured signature.
        let wire = try wire()
        let zeroPin = Data(count: 32)
        let pins = (capturedHello.linkBytes(LinkV3Wire.connectorPin), capturedHello.linkBytes(LinkV3Wire.listenerPin))
        XCTAssertEqual(pins.0, identities.connector.pin)
        for attempt in 0..<3 {
            let raw = try RawLinkConnector(port: port)
            let challenge = try raw.read(LinkV3Wire.challengeBytes)
            var hello = wire.hello(body: wire.helloBody(), challenge: challenge, connectorPin: attempt == 0 ? zeroPin : pins.0,
                listenerPin: attempt == 0 ? zeroPin : pins.1, signer: nil)
            if attempt == 2 {
                hello.linkReplace(LinkV3Wire.helloSignature, with: capturedHello.linkBytes(LinkV3Wire.helloSignature))
                hello = wire.retagHello(hello, challenge: challenge)
            }
            try raw.write(hello)
            XCTAssertEqual(ScriptedLinkListener.drain(raw.reader, seconds: 2).count, 0, "attempt \(attempt) got an accept")
            raw.socket.close()
        }
        XCTAssertTrue(leaderLog.wait { _ in
            self.refusals(listener, "peerNotPinned") >= 1 && self.refusals(listener, "peerSignatureRejected") >= 2
        })
        XCTAssertEqual(leader.status.sessions, 1, "only the genuine connection")

        // Answering: an accept without a signature, then with the captured one.
        let answered = LinkLockedBox(0)
        let fake = try ScriptedLinkListener { socket, reader in
            let replay = answered.value % 2 == 1
            answered.update { $0 += 1 }
            let challenge = LinkV3Wire.challenge()
            guard (try? socket.writeAll(challenge, deadline: linkNow() &+ 1_000_000_000)) != nil,
                  let hello = try? reader.readExact(LinkV3Wire.helloBytes, deadline: linkNow() &+ 1_000_000_000) else { return }
            var accept = wire.accept(body: LinkV3Wire.acceptBody(), challenge: challenge, hello: hello, signer: nil)
            if replay {
                accept.linkReplace(LinkV3Wire.acceptSignature, with: capturedAccept.linkBytes(LinkV3Wire.acceptSignature))
                accept = wire.retagAccept(accept, challenge: challenge, hello: hello)
            }
            try? socket.writeAll(accept, deadline: linkNow() &+ 1_000_000_000)
            _ = ScriptedLinkListener.drain(reader, seconds: 1)
        }
        defer { fake.stop() }
        let victimLog = LinkEventLog()
        let victim = try startClient(connectorEdge(), port: fake.port, victimLog)
        defer { victim.stop() }
        XCTAssertTrue(victimLog.wait { _ in victimLog.refusals.contains(.peerSignatureRejected) })
        let deadline = Date(timeIntervalSinceNow: 3)
        while answered.value < 3, Date() < deadline { usleep(20_000) }
        XCTAssertGreaterThanOrEqual(answered.value, 2)
        XCTAssertEqual(victim.lastRefusal, .peerSignatureRejected)
        XCTAssertFalse(victimLog.all.contains(where: \.isConnected))
    }

    // MARK: 6: a tampering relay that recomputes the tags

    func assertTamperingRefused(_ name: String, _ tampering: LinkTamperRelay.Tampering,
                                listener expectedAtListener: ClusterLinkControlRefusal?,
                                connector expectedAtConnector: ClusterLinkControlRefusal?,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let listenerLog = LinkEventLog(), connectorLog = LinkEventLog()
        let (listener, port) = try startListener(listenerEdge(), listenerLog)
        defer { listener.stop() }
        let relay = try LinkTamperRelay(target: port, wire: wire(), tampering: tampering)
        defer { relay.stop() }
        let client = try startClient(connectorEdge(), port: relay.port, connectorLog)
        defer { client.stop() }
        try client.peer.send(reserve())
        if let expectedAtListener {
            XCTAssertTrue(listenerLog.wait { _ in listenerLog.refusals.contains(expectedAtListener) },
                "\(name): listener refusals \(listenerLog.refusals)", file: file, line: line)
            XCTAssertFalse(listenerLog.all.contains(where: \.isConnected), "\(name): the listener connected", file: file, line: line)
            XCTAssertEqual(listener.peer(for: edgeID)?.status.sessions, 0, name, file: file, line: line)
        }
        if let expectedAtConnector {
            XCTAssertTrue(connectorLog.wait { _ in connectorLog.refusals.contains(expectedAtConnector) },
                "\(name): connector refusals \(connectorLog.refusals)", file: file, line: line)
        } else {
            XCTAssertTrue(connectorLog.wait(seconds: 2) { _ in !connectorLog.refusals.isEmpty }, name, file: file, line: line)
        }
        XCTAssertGreaterThan(relay.handshakes.value, 0, "\(name): the relay saw a handshake", file: file, line: line)
        XCTAssertFalse(connectorLog.all.contains(where: \.isConnected), "\(name): the connector connected", file: file, line: line)
        XCTAssertEqual(client.peer.status.sessions, 0, name, file: file, line: line)
        XCTAssertEqual(listenerLog.messages.count, 0, "\(name): a message arrived", file: file, line: line)
    }

    func testTamperedHelloSignatureByteIsRefused() throws {
        try assertTamperingRefused("hello signature byte", .init(hello: { hello in
            var changed = hello
            changed[changed.startIndex + LinkV3Wire.helloSignature.lowerBound + 7] ^= 0x01
            return changed
        }), listener: .peerSignatureRejected, connector: nil)
    }

    func testRelaysOwnConnectorKeyInTheHelloIsRefused() throws {
        try assertTamperingRefused("connector X25519 key", .init(hello: { hello in
            var changed = hello
            changed.linkReplace(LinkV3Wire.helloKey, with: LinkV3Wire.x25519())
            return changed
        }), listener: .peerSignatureRejected, connector: nil)
    }

    func testRelaysOwnListenerKeyInTheChallengeIsRefused() throws {
        try assertTamperingRefused("listener X25519 key", .init(challenge: { challenge in
            var changed = challenge
            changed.linkReplace(LinkV3Wire.challengeKey, with: LinkV3Wire.x25519())
            return changed
        }), listener: .peerSignatureRejected, connector: nil)
    }

    func testTamperedConnectorPinIsRefused() throws {
        let pin = attacker.pin
        try assertTamperingRefused("connector pin", .init(hello: { hello in
            var changed = hello
            changed.linkReplace(LinkV3Wire.connectorPin, with: pin)
            return changed
        }), listener: .peerNotPinned, connector: nil)
    }

    func testTamperedListenerPinIsRefused() throws {
        let pin = attacker.pin
        try assertTamperingRefused("listener pin", .init(hello: { hello in
            var changed = hello
            changed.linkReplace(LinkV3Wire.listenerPin, with: pin)
            return changed
        }), listener: .identityMismatch, connector: nil)
    }

    func testReflectedHelloSignatureInTheAcceptIsRefused() throws {
        try assertTamperingRefused("reflected signature", .init(accept: { accept, hello in
            var changed = accept
            changed.linkReplace(LinkV3Wire.acceptSignature, with: hello.linkBytes(LinkV3Wire.helloSignature))
            return changed
        }), listener: nil, connector: .peerSignatureRejected)
    }

    func testTamperedAcceptSignatureIsRefused() throws {
        try assertTamperingRefused("accept signature", .init(accept: { accept, _ in
            var changed = accept
            changed[changed.startIndex + LinkV3Wire.acceptSignature.upperBound - 1] ^= 0x80
            return changed
        }), listener: nil, connector: .peerSignatureRejected)
    }

    // MARK: 7: no downgrade

    func testAttestedListenerRefusesOlderHellos() throws {
        let log = LinkEventLog()
        let (listener, port) = try startListener(listenerEdge(), log)
        defer { listener.stop() }
        for (version, size) in [(UInt8(2), 196), (UInt8(1), 164)] {
            let raw = try RawLinkConnector(port: port)
            _ = try raw.read(LinkV3Wire.challengeBytes)
            try raw.write(LinkV3Wire.header("DBLH", version: version, role: 1) + LinkV3Wire.random(size - 8))
            XCTAssertEqual(ScriptedLinkListener.drain(raw.reader, seconds: 2).count, 0, "version \(version) got an accept")
            raw.socket.close()
        }
        XCTAssertTrue(log.wait { _ in self.refusals(listener, "protocolVersionMismatch") >= 2 })
        XCTAssertEqual(listener.peer(for: edgeID)?.status.sessions, 0)
        XCTAssertFalse(log.all.contains(where: \.isConnected))
    }

    func testAttestedConnectorRefusesOlderChallengesAndWritesNothing() throws {
        for (version, size) in [(UInt8(2), 72), (UInt8(1), 40)] {
            let received = LinkLockedBox(Data())
            let server = try ScriptedLinkListener { socket, reader in
                try? socket.writeAll(LinkV3Wire.header("DBLC", version: version) + LinkV3Wire.random(size - 8),
                    deadline: linkNow() &+ 1_000_000_000)
                let bytes = ScriptedLinkListener.drain(reader, seconds: 1)
                received.update { $0.append(bytes) }
            }
            let log = LinkEventLog()
            let client = try startClient(connectorEdge(), port: server.port, log)
            XCTAssertTrue(log.wait { _ in log.refusals.contains(.protocolVersionMismatch) }, "version \(version)")
            let deadline = Date(timeIntervalSinceNow: 3)
            while server.accepted < 2, Date() < deadline { usleep(20_000) }
            client.stop()
            server.stop()
            XCTAssertEqual(received.value.count, 0, "the connector wrote to a version-\(version) listener")
            XCTAssertEqual(client.lastRefusal, .protocolVersionMismatch)
            XCTAssertFalse(log.all.contains(where: \.isConnected))
        }
    }

    // MARK: 9: the attested pair

    /// Connects, carries reservations and opaque frames both ways, and every
    /// connection has fresh ephemeral keys and fresh signatures, each valid
    /// under the pinned key over that connection's records.
    func testAttestedPairConnectsAndReconnectsWithFreshKeysAndSignatures() throws {
        let leaderLog = LinkEventLog(), followerLog = LinkEventLog()
        let (listener, port) = try startListener(listenerEdge(), leaderLog)
        defer { listener.stop() }
        let relay = try LinkCaptureRelay(target: port)
        defer { relay.stop() }
        let follower = try startClient(connectorEdge(), port: relay.port, followerLog)
        defer { follower.stop() }
        let leader = try XCTUnwrap(listener.peer(for: edgeID))
        for round in 1...3 {
            XCTAssertTrue(follower.peer.waitUntilConnected(timeout: .seconds(3)))
            XCTAssertTrue(leader.waitUntilConnected(timeout: .seconds(3)))
            try leader.send(reserve())
            try leader.sendOpaque(tag: 7, Data([UInt8(round), 1, 2]))
            try follower.peer.send(reserve())
            try follower.peer.sendOpaque(tag: 9, Data([UInt8(round), 3]))
            XCTAssertTrue(followerLog.wait { _ in followerLog.messages.count == round })
            XCTAssertTrue(leaderLog.wait { _ in leaderLog.messages.count == round })
            XCTAssertTrue(followerLog.wait { $0.filter(\.isOpaque).count == round })
            XCTAssertTrue(leaderLog.wait { $0.filter(\.isOpaque).count == round })
            try leader.waitUntilAcknowledged(timeout: .seconds(3))
            try follower.peer.waitUntilAcknowledged(timeout: .seconds(3))
            if round < 3 {
                follower.peer.dropConnectionForTesting()
                XCTAssertTrue(followerLog.wait { _ in followerLog.disconnects.count == round })
            }
        }
        for (_, message) in leaderLog.messages + followerLog.messages {
            guard case .reserve(let received) = message else { return XCTFail("a reservation") }
            XCTAssertEqual(received.promptTokenIDs, prompt)
        }
        XCTAssertTrue(leaderLog.refusals.isEmpty && followerLog.refusals.isEmpty)
        relay.stop()

        let atListener = try identities.listenerIdentity(), atConnector = try identities.connectorIdentity()
        XCTAssertEqual(atListener.localPin, LinkV3Wire.pin(identities.listener.identityPublicKey))
        XCTAssertEqual(atListener.peerPin, atConnector.localPin)
        let sessions = relay.sessions.filter { $0.toConnector.count >= LinkV3Wire.challengeBytes + LinkV3Wire.acceptBytes
            && $0.toListener.count >= LinkV3Wire.helloBytes }
        XCTAssertGreaterThanOrEqual(sessions.count, 3)
        var publicKeys = Set<Data>(), signatures = Set<Data>()
        for session in sessions {
            let challenge = session.toConnector.linkBytes(0..<LinkV3Wire.challengeBytes)
            let accept = session.toConnector.linkBytes(LinkV3Wire.challengeBytes..<(LinkV3Wire.challengeBytes + LinkV3Wire.acceptBytes))
            let hello = session.toListener.linkBytes(0..<LinkV3Wire.helloBytes)
            XCTAssertEqual(hello.linkBytes(LinkV3Wire.connectorPin), atConnector.localPin)
            XCTAssertEqual(hello.linkBytes(LinkV3Wire.listenerPin), atConnector.peerPin)
            let helloSignature = hello.linkBytes(LinkV3Wire.helloSignature)
            let acceptSignature = accept.linkBytes(LinkV3Wire.acceptSignature)
            XCTAssertTrue(atListener.isValidPeerSignature(helloSignature, role: .connector, epoch: epoch, edgeID: edgeID,
                transcript: challenge + hello.linkBytes(0..<228)))
            XCTAssertTrue(atConnector.isValidPeerSignature(acceptSignature, role: .listener, epoch: epoch, edgeID: edgeID,
                transcript: challenge + hello + accept.linkBytes(0..<48)))
            // Roles are bound: neither signature verifies as the other end's.
            XCTAssertFalse(atConnector.isValidPeerSignature(helloSignature, role: .listener, epoch: epoch, edgeID: edgeID,
                transcript: challenge + hello.linkBytes(0..<228)))
            publicKeys.insert(challenge.linkBytes(LinkV3Wire.challengeKey)); publicKeys.insert(hello.linkBytes(LinkV3Wire.helloKey))
            signatures.insert(helloSignature); signatures.insert(acceptSignature)
        }
        XCTAssertEqual(publicKeys.count, 2 * sessions.count, "no public key is reused across connections or ends")
        XCTAssertEqual(signatures.count, 2 * sessions.count, "no signature is reused across connections or ends")
    }

    // MARK: 10: mode mismatch

    func testEdgeKeyOnlyConnectorIsNotPinnedByAnAttestedListener() throws {
        let listenerLog = LinkEventLog(), connectorLog = LinkEventLog()
        let (listener, port) = try startListener(listenerEdge(), listenerLog)
        defer { listener.stop() }
        let client = try startClient(edgeKeyOnlyEdge(), port: port, connectorLog)
        defer { client.stop() }
        XCTAssertTrue(listenerLog.wait { _ in listenerLog.refusals.contains(.peerNotPinned) })
        XCTAssertFalse(client.peer.waitUntilConnected(timeout: .milliseconds(300)))
        XCTAssertFalse(listenerLog.all.contains(where: \.isConnected))
        XCTAssertFalse(connectorLog.all.contains(where: \.isConnected))
    }

    func testAttestedConnectorIsRefusedByAnEdgeKeyOnlyListener() throws {
        let listenerLog = LinkEventLog(), connectorLog = LinkEventLog()
        let (listener, port) = try startListener(edgeKeyOnlyEdge(), listenerLog)
        defer { listener.stop() }
        let client = try startClient(connectorEdge(), port: port, connectorLog)
        defer { client.stop() }
        XCTAssertTrue(listenerLog.wait { _ in
            listenerLog.refusals.contains(.peerNotPinned) || connectorLog.refusals.contains(.peerNotPinned)
        }, "listener \(listenerLog.refusals), connector \(connectorLog.refusals)")
        XCTAssertFalse(client.peer.waitUntilConnected(timeout: .milliseconds(300)))
        XCTAssertFalse(listenerLog.all.contains(where: \.isConnected))
        XCTAssertFalse(connectorLog.all.contains(where: \.isConnected))
        XCTAssertEqual(listener.peer(for: edgeID)?.status.sessions, 0)
    }

    /// Two edge-key-only ends connect; their records carry no pins and no signatures.
    func testTwoEdgeKeyOnlyEndsConnect() throws {
        let listenerLog = LinkEventLog(), connectorLog = LinkEventLog()
        let (listener, port) = try startListener(edgeKeyOnlyEdge(), listenerLog)
        defer { listener.stop() }
        let relay = try LinkCaptureRelay(target: port)
        defer { relay.stop() }
        let client = try startClient(edgeKeyOnlyEdge(), port: relay.port, connectorLog)
        defer { client.stop() }
        XCTAssertTrue(client.peer.waitUntilConnected(timeout: .seconds(3)))
        try client.peer.send(.status(.init(epoch: epoch, rank: 1, state: .ready, linkReady: true)))
        XCTAssertTrue(listenerLog.wait { _ in listenerLog.messages.count == 1 })
        relay.stop()
        let session = try XCTUnwrap(relay.sessions.first)
        XCTAssertEqual(session.toListener.linkBytes(LinkV3Wire.connectorPin.lowerBound..<LinkV3Wire.helloSignature.upperBound),
            Data(count: 128))
        let accept = session.toConnector.linkBytes(LinkV3Wire.challengeBytes..<(LinkV3Wire.challengeBytes + LinkV3Wire.acceptBytes))
        XCTAssertEqual(accept.linkBytes(LinkV3Wire.acceptSignature), Data(count: 64))
    }

    /// An edge-key-only connector refuses an accept that carries a signature: the mode is its own, not the wire's.
    func testEdgeKeyOnlyConnectorRefusesASignedAccept() throws {
        let wire = try wire(), attacker = attacker
        let server = try ScriptedLinkListener { socket, reader in
            let challenge = LinkV3Wire.challenge()
            guard (try? socket.writeAll(challenge, deadline: linkNow() &+ 1_000_000_000)) != nil,
                  let hello = try? reader.readExact(LinkV3Wire.helloBytes, deadline: linkNow() &+ 1_000_000_000) else { return }
            try? socket.writeAll(wire.accept(body: LinkV3Wire.acceptBody(), challenge: challenge, hello: hello, signer: attacker),
                deadline: linkNow() &+ 1_000_000_000)
            _ = ScriptedLinkListener.drain(reader, seconds: 0.5)
        }
        defer { server.stop() }
        let log = LinkEventLog()
        let client = try startClient(edgeKeyOnlyEdge(), port: server.port, log)
        defer { client.stop() }
        XCTAssertTrue(log.wait { _ in log.refusals.contains(.peerNotPinned) })
        XCTAssertFalse(log.all.contains(where: \.isConnected))
        XCTAssertEqual(client.peer.status.sessions, 0)
    }

    /// The listener's key signs only for a connector it verified: a peer it refuses (its own key, or the
    /// connector's pin over another key's signature) never makes it sign; the genuine connector does.
    func testListenerSignsOnlyForAVerifiedConnector() throws {
        let calls = LinkLockedBox(0)
        let counting = CountingLinkSigner(signer: identities.listener, calls: calls)
        let edge = try baseEdge().authenticated(by: ClusterLinkIdentity(signer: counting,
            peerIdentityKey: identities.connector.identityPublicKey, clusterID: clusterID))
        let log = LinkEventLog()
        let (listener, port) = try startListener(edge, log)
        defer { listener.stop() }
        let fake = try startClient(self.edge(signer: attacker, peer: identities.listener), port: port, LinkEventLog())
        XCTAssertTrue(log.wait { _ in log.refusals.contains(.peerNotPinned) })
        fake.stop()
        let wire = try wire()
        let raw = try RawLinkConnector(port: port)
        let challenge = try raw.read(LinkV3Wire.challengeBytes)
        try raw.write(wire.hello(body: wire.helloBody(), challenge: challenge, connectorPin: identities.connector.pin,
            listenerPin: identities.listener.pin, signer: attacker))
        XCTAssertTrue(log.wait { _ in self.refusals(listener, "peerSignatureRejected") >= 1 })
        raw.socket.close()
        XCTAssertEqual(calls.value, 0, "the listener signed for a connector it refused")
        let client = try startClient(connectorEdge(), port: port, LinkEventLog())
        defer { client.stop() }
        XCTAssertTrue(client.peer.waitUntilConnected(timeout: .seconds(3)))
        XCTAssertGreaterThanOrEqual(calls.value, 1)
    }

    // MARK: 11: this end's key

    func testIdentityRefusesAWrongOrInvalidLocalKey() throws {
        let local = identities.connector, peer = identities.listener.identityPublicKey
        XCTAssertThrowsError(try ClusterLinkIdentity(signer: local, localIdentityKey: attacker.identityPublicKey,
            peerIdentityKey: peer, clusterID: clusterID)) { XCTAssertEqual($0 as? ClusterLinkIdentityError, .signerMismatch) }
        XCTAssertNoThrow(try ClusterLinkIdentity(signer: local, localIdentityKey: local.identityPublicKey,
            peerIdentityKey: peer, clusterID: clusterID))
        var notAPoint = Data([0x04]); notAPoint.append(Data(repeating: 0x01, count: 64))
        let invalid: [(Data, String)] = [
            (local.identityPublicKey, clusterID), (notAPoint, clusterID), (Data(peer.prefix(33)), clusterID),
            (peer, ""), (peer, "cluster\0id"), (peer, String(repeating: "c", count: 257)),
        ]
        for (peerKey, cluster) in invalid {
            XCTAssertThrowsError(try ClusterLinkIdentity(signer: local, peerIdentityKey: peerKey, clusterID: cluster)) {
                XCTAssertEqual($0 as? ClusterLinkIdentityError, .invalidIdentity)
            }
        }
    }

    /// A key that cannot sign (or is not the pinned one) is reported before
    /// anything is written: the connector reads the challenge and stops.
    func testConnectorWhoseKeyCannotSignSendsNoHello() throws {
        let local = identities.connector.identityPublicKey
        let cases: [(any ClusterLinkIdentitySigner, ClusterLinkIdentityError, ClusterLinkControlRefusal)] = [
            (FailingLinkSigner(identityPublicKey: local, failure: nil), .signerUnavailable, .localIdentityUnavailable),
            (FailingLinkSigner(identityPublicKey: local, failure: .signerUnavailable), .signerUnavailable, .localIdentityUnavailable),
            (FailingLinkSigner(identityPublicKey: local, failure: .signerLocked), .signerLocked, .localIdentityLocked),
            (ImpostorLinkSigner(identityPublicKey: local, signer: attacker), .signerMismatch, .localIdentityUnavailable),
        ]
        for (signer, identityError, refusal) in cases {
            let identity = try ClusterLinkIdentity(signer: signer, peerIdentityKey: identities.listener.identityPublicKey,
                clusterID: clusterID)
            XCTAssertThrowsError(try identity.signature(role: .connector, epoch: epoch, edgeID: edgeID, transcript: Data([1]))) {
                XCTAssertEqual($0 as? ClusterLinkIdentityError, identityError)
            }
            let received = LinkLockedBox(Data())
            let server = try ScriptedLinkListener { socket, reader in
                try? socket.writeAll(LinkV3Wire.challenge(), deadline: linkNow() &+ 1_000_000_000)
                let bytes = ScriptedLinkListener.drain(reader, seconds: 1)
                received.update { $0.append(bytes) }
            }
            let log = LinkEventLog()
            let client = try startClient(baseEdge().authenticated(by: identity), port: server.port, log)
            XCTAssertTrue(log.wait { _ in log.refusals.contains(refusal) }, "\(identityError): \(log.refusals)")
            client.stop()
            server.stop()
            XCTAssertGreaterThan(server.accepted, 0)
            XCTAssertEqual(received.value.count, 0, "\(identityError): the connector wrote a hello")
            XCTAssertEqual(client.lastRefusal, refusal)
        }
    }

    func testUndecidedEdgeIsRefusedByListenerAndClient() throws {
        XCTAssertThrowsError(try ClusterLinkControlListener(configuration: .init(interface: "lo0", port: 0,
            policy: .loopbackForTests, edges: [baseEdge()])) { _, _ in }) {
            XCTAssertEqual($0 as? ClusterLinkControlError, .invalidConfiguration)
        }
        XCTAssertThrowsError(try ClusterLinkControlClient(configuration: .init(interface: "lo0", port: 1,
            policy: .loopbackForTests, edge: baseEdge())) { _, _ in }) {
            XCTAssertEqual($0 as? ClusterLinkControlError, .invalidConfiguration)
        }
    }

    // MARK: 12: what is signed

    /// The specification's message, computed here independently.
    func expectedMessage(role: ClusterLinkControlRole, epoch: UUID, edgeID: UUID, clusterID: String, transcript: Data) -> Data {
        let cluster = Data(clusterID.utf8)
        var digested = Data("darkbloom/link-control/handshake-transcript/v3\0".utf8)
        digested.append(role.rawValue); digested.append(LinkV3Wire.uuid(epoch)); digested.append(LinkV3Wire.uuid(edgeID))
        digested.append(contentsOf: [UInt8(cluster.count >> 8), UInt8(cluster.count & 0xFF)]); digested.append(cluster)
        digested.append(transcript)
        var message = Data([0xFF]) + Data("darkbloom/link-control/handshake-signature/v3\0".utf8)
        message.append(role.rawValue)
        message.append(contentsOf: SHA256.hash(data: digested))
        return message
    }

    func testSignedMessageIsDomainSeparatedAndBindsEveryInput() {
        XCTAssertEqual(ClusterLinkHandshakeSignature.prefix,
            Data([0xFF]) + Data("darkbloom/link-control/handshake-signature/v3\0".utf8))
        let transcript = LinkV3Wire.random(LinkV3Wire.challengeBytes + 228)
        func message(role: ClusterLinkControlRole = .connector, epoch: UUID? = nil, edgeID: UUID? = nil,
                     clusterID: String? = nil, transcript signed: Data) -> Data {
            ClusterLinkHandshakeSignature.message(role: role, epoch: epoch ?? self.epoch, edgeID: edgeID ?? self.edgeID,
                clusterID: clusterID ?? self.clusterID, transcript: signed)
        }
        let base = message(transcript: transcript)
        XCTAssertEqual(base, expectedMessage(role: .connector, epoch: epoch, edgeID: edgeID, clusterID: clusterID,
            transcript: transcript))
        XCTAssertEqual(base.first, 0xFF)
        XCTAssertNil(String(data: base, encoding: .utf8), "a handshake message is never UTF-8 text")
        var variants = [base]
        variants.append(message(role: .listener, transcript: transcript))
        variants.append(message(epoch: UUID(), transcript: transcript))
        variants.append(message(edgeID: UUID(), transcript: transcript))
        variants.append(message(clusterID: clusterID + "-other", transcript: transcript))
        for index in [0, 4, 40, 72 + 72, transcript.count - 1] {
            var changed = transcript; changed[changed.startIndex + index] ^= 0x01
            variants.append(message(transcript: changed))
        }
        variants.append(message(transcript: transcript + Data([0])))
        // The cluster ID is length-prefixed: moving a byte between it and the transcript changes the message.
        variants.append(message(clusterID: "ab", transcript: Data("c".utf8)))
        variants.append(message(clusterID: "a", transcript: Data("bc".utf8)))
        XCTAssertEqual(Set(variants).count, variants.count, "every input changes the signed message")
        for _ in 0..<64 {
            let random = message(role: Bool.random() ? .listener : .connector, epoch: UUID(), edgeID: UUID(),
                clusterID: UUID().uuidString, transcript: LinkV3Wire.random(Int.random(in: 0...400)))
            XCTAssertEqual(random.first, 0xFF)
            XCTAssertNil(String(data: random, encoding: .utf8))
        }
    }
}
