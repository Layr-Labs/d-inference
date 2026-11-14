import CryptoKit
import Darwin
@testable import DarkbloomClusterSecurity
import Foundation
import XCTest
@testable import DarkbloomClusterRemote

/// A software P-256 key standing in for a Mac's Secure Enclave identity key.
/// Kept as raw bytes so the signer stays a plain `Sendable` value.
struct SoftwareLinkSigner: ClusterLinkIdentitySigner {
    let privateKey: Data
    /// DER, as the Secure Enclave returns it, or raw r‖s.
    let der: Bool

    init(der: Bool = true) {
        privateKey = P256.Signing.PrivateKey().rawRepresentation
        self.der = der
    }

    private var key: P256.Signing.PrivateKey { try! P256.Signing.PrivateKey(rawRepresentation: privateKey) }
    var identityPublicKey: Data { key.publicKey.x963Representation }
    var pin: Data { LinkV3Wire.pin(identityPublicKey) }

    func linkSignature(for message: Data) throws -> Data {
        let signature = try key.signature(for: message)
        return der ? signature.derRepresentation : signature.rawRepresentation
    }

    /// Raw r‖s, as a hand-rolled peer puts it on the wire.
    func rawSignature(for message: Data) -> Data { try! key.signature(for: message).rawRepresentation }
}

/// A signer whose key cannot sign: a Secure Enclave refusal (`failure` nil:
/// an error the identity layer does not know), or a Mac not yet unlocked.
struct FailingLinkSigner: ClusterLinkIdentitySigner {
    struct OpaqueFailure: Error {}
    let identityPublicKey: Data
    let failure: ClusterLinkIdentityError?

    func linkSignature(for message: Data) throws -> Data { throw failure ?? OpaqueFailure() }
}

/// Claims one key and signs with another: a signer that is not the key this end is pinned as.
struct ImpostorLinkSigner: ClusterLinkIdentitySigner {
    let identityPublicKey: Data
    let signer: SoftwareLinkSigner

    func linkSignature(for message: Data) throws -> Data { try signer.linkSignature(for: message) }
}

/// The two attested ends of one edge, software keys: listener L and connector C.
struct LinkTestIdentities: Sendable {
    static let defaultClusterID = "fixture-cluster"
    let listener: SoftwareLinkSigner
    let connector: SoftwareLinkSigner
    let clusterID: String

    init(listener: SoftwareLinkSigner = .init(), connector: SoftwareLinkSigner = .init(der: false),
         clusterID: String = Self.defaultClusterID) {
        self.listener = listener; self.connector = connector; self.clusterID = clusterID
    }

    func listenerIdentity() throws -> ClusterLinkIdentity {
        try ClusterLinkIdentity(signer: listener, peerIdentityKey: connector.identityPublicKey, clusterID: clusterID)
    }

    func connectorIdentity() throws -> ClusterLinkIdentity {
        try ClusterLinkIdentity(signer: connector, peerIdentityKey: listener.identityPublicKey, clusterID: clusterID)
    }

    /// An edge as the listener configures it; an already decided edge is kept.
    func asListener(_ edge: ClusterLinkControlEdge) throws -> ClusterLinkControlEdge {
        edge.authentication == nil ? edge.authenticated(by: try listenerIdentity()) : edge
    }

    /// An edge as the connector configures it; an already decided edge is kept.
    func asConnector(_ edge: ClusterLinkControlEdge) throws -> ClusterLinkControlEdge {
        edge.authentication == nil ? edge.authenticated(by: try connectorIdentity()) : edge
    }
}

extension Data {
    /// Bytes at offsets relative to the start, whatever this value's indices.
    func linkBytes(_ range: Range<Int>) -> Data { Data(self[(startIndex + range.lowerBound)..<(startIndex + range.upperBound)]) }

    mutating func linkReplace(_ range: Range<Int>, with bytes: Data) {
        precondition(bytes.count == range.count)
        replaceSubrange((startIndex + range.lowerBound)..<(startIndex + range.upperBound), with: bytes)
    }
}

/// Handshake v3 records laid out from the specification, not the library's
/// encoder, for peers that misbehave on purpose. Its context is what anyone
/// holding the edge secret knows: the edge key, epoch, edge and cluster ID.
struct LinkV3Wire: Sendable {
    static let version: UInt8 = LinkHandshake.version
    static let challengeBytes = 72, helloBytes = 324, acceptBytes = 144
    static let challengeKey = 40..<72
    static let helloKey = 72..<104
    static let helloLimits = 144..<164
    static let connectorPin = 164..<196, listenerPin = 196..<228, helloSignature = 228..<292, helloTag = 292..<324
    static let acceptSignature = 48..<112, acceptTag = 112..<144

    let epoch: UUID
    let edgeID: UUID
    let clusterID: String
    let key: ClusterLinkControlKey
    let limits: ClusterRecordLimits

    static func uuid(_ value: UUID?) -> Data {
        guard let value else { return Data(count: 16) }
        return withUnsafeBytes(of: value.uuid) { Data($0) }
    }

    static func random(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255) }) }

    static func x25519() -> Data { Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation }

    /// `ClusterPairingPin`, computed from its definition.
    static func pin(_ identityKey: Data) -> Data {
        Data(SHA256.hash(data: Data("darkbloom/cluster-member-pin/v1\0".utf8) + identityKey))
    }

    static func header(_ magic: String, version: UInt8, role: UInt8 = 0) -> Data {
        Data(magic.utf8) + Data([version, role, 0, 0])
    }

    static func challenge(version: UInt8 = version, listenerKey: Data = x25519()) -> Data {
        header("DBLC", version: version) + random(32) + listenerKey
    }

    /// Bytes 0..<164 of a hello: as version 2, under this version byte.
    static func helloBody(version: UInt8 = version, epoch: UUID, edgeID: UUID, connectorKey: Data,
                          incarnation: UUID = UUID(), knownListenerIncarnation: UUID? = nil, delivered: UInt64 = 0,
                          limits: ClusterRecordLimits) -> Data {
        var body = header("DBLH", version: version, role: ClusterLinkControlRole.connector.rawValue)
        body.append(uuid(epoch)); body.append(uuid(edgeID)); body.append(random(32)); body.append(connectorKey)
        body.append(uuid(incarnation)); body.append(uuid(knownListenerIncarnation))
        body.clusterLinkAppend(delivered)
        body.clusterLinkAppend(UInt32(limits.maximumPlaintextBytes))
        body.clusterLinkAppend(limits.maximumRecordsPerDirection)
        body.clusterLinkAppend(limits.maximumCumulativePlaintextBytesPerDirection)
        precondition(body.count == connectorPin.lowerBound)
        return body
    }

    /// Bytes 0..<48 of an accept.
    static func acceptBody(incarnation: UUID = UUID(), knownConnectorIncarnation: UUID? = nil, delivered: UInt64 = 0) -> Data {
        var body = header("DBLA", version: version)
        body.append(uuid(incarnation)); body.append(uuid(knownConnectorIncarnation))
        body.clusterLinkAppend(delivered)
        return body
    }

    func helloBody(connectorKey: Data = x25519()) -> Data {
        Self.helloBody(epoch: epoch, edgeID: edgeID, connectorKey: connectorKey, limits: limits)
    }

    func sign(_ signer: SoftwareLinkSigner, role: ClusterLinkControlRole, transcript: Data) -> Data {
        signer.rawSignature(for: ClusterLinkHandshakeSignature.message(role: role, epoch: epoch, edgeID: edgeID,
            clusterID: clusterID, transcript: transcript))
    }

    /// Pins, the connector's signature (nil: all zero) and the tag after a hello body.
    func hello(body: Data, challenge: Data, connectorPin: Data, listenerPin: Data, signer: SoftwareLinkSigner?) -> Data {
        var hello = body + connectorPin + listenerPin
        hello.append(signer.map { sign($0, role: .connector, transcript: challenge + hello) } ?? Data(count: 64))
        return retagHello(hello, challenge: challenge)
    }

    /// The listener's signature (nil: all zero) and the tag after an accept body.
    func accept(body: Data, challenge: Data, hello: Data, signer: SoftwareLinkSigner?) -> Data {
        var accept = body
        accept.append(signer.map { sign($0, role: .listener, transcript: challenge + hello + body) } ?? Data(count: 64))
        return retagAccept(accept, challenge: challenge, hello: hello)
    }

    /// The connector's tag over `challenge ‖ hello[..<helloTag]`, recomputed with the edge key.
    func retagHello(_ hello: Data, challenge: Data) -> Data {
        let covered = hello.linkBytes(0..<Self.helloTag.lowerBound)
        return covered + key.handshakeTag(role: .connector, transcript: challenge + covered)
    }

    /// The listener's tag over `challenge ‖ hello ‖ accept[..<acceptTag]`, recomputed with the edge key.
    func retagAccept(_ accept: Data, challenge: Data, hello: Data) -> Data {
        let covered = accept.linkBytes(0..<Self.acceptTag.lowerBound)
        return covered + key.handshakeTag(role: .listener, transcript: challenge + hello + covered)
    }
}

/// A loopback listener that runs `script` on each accepted connection, one at
/// a time: a hand-rolled peer for a real connector to dial.
final class ScriptedLinkListener: @unchecked Sendable {
    let port: UInt16
    private let server: LinkSocket
    private let lock = NSLock()
    private var running = true
    private var acceptedCount = 0
    private let done = DispatchSemaphore(value: 0)

    init(script: @escaping @Sendable (LinkSocket, LinkReader) -> Void) throws {
        (server, port) = try LinkSocket.listen(address: .loopback, port: 0, interfaceIndex: if_nametoindex("lo0"), backlog: 8)
        Thread { [self] in
            while lock.withLock({ running }) {
                guard (try? LinkSocket.waitFor(fd: server.fd, events: Int16(POLLIN), deadline: linkNow() &+ 50_000_000)) != nil,
                      let accepted = try? server.accept() else { continue }
                lock.withLock { acceptedCount += 1 }
                script(accepted.0, LinkReader(socket: accepted.0, capacity: 64))
                accepted.0.close()
            }
            done.signal()
        }.start()
    }

    var accepted: Int { lock.withLock { acceptedCount } }

    func stop() {
        lock.withLock { running = false }
        _ = done.wait(timeout: .now() + 5)
        server.close()
    }

    /// Bytes the peer sends until it closes or the time runs out.
    static func drain(_ reader: LinkReader, seconds: Double) -> Data {
        var received = Data()
        let deadline = linkNow() &+ UInt64(seconds * 1e9)
        while let byte = try? reader.readExact(1, deadline: deadline) { received.append(byte) }
        return received
    }
}

/// Thread-safe byte and value collector for hand-rolled peers.
final class LinkLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}

/// Between a real connector and a real listener, holding the edge secret:
/// changes the handshake records it forwards and recomputes both tags, so
/// only the signatures and pins can catch the change. Forwards nothing else.
final class LinkTamperRelay: @unchecked Sendable {
    struct Tampering: Sendable {
        /// The challenge toward the connector.
        var challenge: (@Sendable (Data) -> Data)?
        /// The hello toward the listener, before its tag is recomputed over the listener's own challenge.
        var hello: (@Sendable (Data) -> Data)?
        /// The accept toward the connector, given the connector's hello, before its tag is recomputed.
        var accept: (@Sendable (_ accept: Data, _ hello: Data) -> Data)?
    }

    private let scripted: ScriptedLinkListener
    /// Hellos forwarded to the listener.
    let handshakes: LinkLockedBox<Int>
    var port: UInt16 { scripted.port }

    init(target: UInt16, wire: LinkV3Wire, tampering: Tampering) throws {
        let handshakes = LinkLockedBox(0)
        self.handshakes = handshakes
        scripted = try ScriptedLinkListener { connector, connectorReader in
            guard let listener = try? LinkSocket.connect(local: .loopback, peer: .loopback, port: target,
                interfaceIndex: if_nametoindex("lo0"), timeoutNanoseconds: 2_000_000_000) else { return }
            defer { listener.close() }
            let listenerReader = LinkReader(socket: listener, capacity: 64)
            let deadline = linkNow() &+ 2_000_000_000
            guard let challenge = try? listenerReader.readExact(LinkV3Wire.challengeBytes, deadline: deadline) else { return }
            let towardConnector = tampering.challenge?(challenge) ?? challenge
            guard (try? connector.writeAll(towardConnector, deadline: deadline)) != nil,
                  let hello = try? connectorReader.readExact(LinkV3Wire.helloBytes, deadline: deadline) else { return }
            let towardListener = wire.retagHello(tampering.hello?(hello) ?? hello, challenge: challenge)
            guard (try? listener.writeAll(towardListener, deadline: deadline)) != nil else { return }
            handshakes.update { $0 += 1 }
            guard let accept = try? listenerReader.readExact(LinkV3Wire.acceptBytes, deadline: deadline) else { return }
            let changed = wire.retagAccept(tampering.accept?(accept, hello) ?? accept, challenge: towardConnector, hello: hello)
            guard (try? connector.writeAll(changed, deadline: deadline)) != nil else { return }
            // Holds both legs until the connector gives up on this connection.
            _ = ScriptedLinkListener.drain(connectorReader, seconds: 1)
        }
    }

    func stop() { scripted.stop() }
}
