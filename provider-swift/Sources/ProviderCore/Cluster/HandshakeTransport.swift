/// HandshakeTransport -- carries the 3 `ClusterHandshake` messages between two
/// cluster nodes so they can establish a `ClusterSession` before inference.
///
/// The handshake *logic* (`ClusterHandshakeInitiator`/`Responder`) is transport-
/// agnostic and already verified; this is the thin wire that moves Msg1/2/3.
/// A length-prefixed framing carries a JSON-encoded `HandshakeEnvelope`. The
/// concrete socket implementation uses `Network.framework` (`NWConnection`),
/// matching `CoordinatorClient`; an in-memory pair implementation drives the
/// full exchange in tests on one machine.
///
/// `runInitiatorHandshake` / `runResponderHandshake` are the orchestration:
/// they own the message ordering, so callers just provide the signer + roster
/// and get back a `ClusterSession`.

import Foundation

public enum HandshakeWireError: Error, Sendable {
    case encodeFailed
    case decodeFailed
    case unexpectedMessage(String)
    case channelClosed
}

/// Tagged envelope so a single byte stream can carry all three message types.
public struct HandshakeEnvelope: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case msg1, msg2, msg3 }
    public let kind: Kind
    public let msg1: ClusterHandshakeMsg1?
    public let msg2: ClusterHandshakeMsg2?
    public let msg3: ClusterHandshakeMsg3?

    static func wrap(_ m: ClusterHandshakeMsg1) -> HandshakeEnvelope { .init(kind: .msg1, msg1: m, msg2: nil, msg3: nil) }
    static func wrap(_ m: ClusterHandshakeMsg2) -> HandshakeEnvelope { .init(kind: .msg2, msg1: nil, msg2: m, msg3: nil) }
    static func wrap(_ m: ClusterHandshakeMsg3) -> HandshakeEnvelope { .init(kind: .msg3, msg1: nil, msg2: nil, msg3: m) }
}

/// A bidirectional message channel between this node and one peer. Send/recv
/// whole `HandshakeEnvelope`s (framing handled by the implementation).
public protocol HandshakeChannel: Sendable {
    func send(_ envelope: HandshakeEnvelope) async throws
    func recv() async throws -> HandshakeEnvelope
}

public enum HandshakeWire {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()

    public static func encode(_ env: HandshakeEnvelope) throws -> Data {
        guard let body = try? encoder.encode(env) else { throw HandshakeWireError.encodeFailed }
        var framed = Data()
        var len = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &len) { framed.append(contentsOf: $0) }
        framed.append(body)
        return framed
    }

    public static func decode(_ body: Data) throws -> HandshakeEnvelope {
        guard let env = try? decoder.decode(HandshakeEnvelope.self, from: body) else {
            throw HandshakeWireError.decodeFailed
        }
        return env
    }
}

// MARK: - Orchestration

public enum ClusterHandshakeRunner {
    /// Drive the initiator side (lower nodeId) to a completed session.
    public static func runInitiator(
        clusterId: String,
        localNodeId: String,
        signer: any AttestationSigner,
        roster: ClusterRosterBody,
        channel: any HandshakeChannel
    ) async throws -> ClusterSession {
        let initiator = ClusterHandshakeInitiator(
            clusterId: clusterId, localNodeId: localNodeId, signer: signer, roster: roster)
        try await channel.send(.wrap(initiator.start()))
        let env = try await channel.recv()
        guard let m2 = env.msg2 else { throw HandshakeWireError.unexpectedMessage(env.kind.rawValue) }
        let (m3, session) = try initiator.finish(m2)
        try await channel.send(.wrap(m3))
        return session
    }

    /// Drive the responder side to a completed session.
    public static func runResponder(
        localNodeId: String,
        signer: any AttestationSigner,
        roster: ClusterRosterBody,
        channel: any HandshakeChannel
    ) async throws -> ClusterSession {
        let responder = ClusterHandshakeResponder(
            localNodeId: localNodeId, signer: signer, roster: roster)
        let env1 = try await channel.recv()
        guard let m1 = env1.msg1 else { throw HandshakeWireError.unexpectedMessage(env1.kind.rawValue) }
        let m2 = try responder.respond(m1)
        try await channel.send(.wrap(m2))
        let env3 = try await channel.recv()
        guard let m3 = env3.msg3 else { throw HandshakeWireError.unexpectedMessage(env3.kind.rawValue) }
        return try responder.confirm(m3)
    }
}

// MARK: - In-memory channel (tests / single-box smoke)

/// A linked pair of in-process channels: what one sends, the other receives.
public final class InMemoryHandshakeChannelPair: Sendable {
    public let a: any HandshakeChannel
    public let b: any HandshakeChannel

    public init() {
        let aToB = HandshakeMailbox()
        let bToA = HandshakeMailbox()
        self.a = InMemoryHandshakeChannel(outbox: aToB, inbox: bToA)
        self.b = InMemoryHandshakeChannel(outbox: bToA, inbox: aToB)
    }
}

actor HandshakeMailbox {
    private var queue: [HandshakeEnvelope] = []
    private var waiters: [CheckedContinuation<HandshakeEnvelope, Never>] = []

    func put(_ e: HandshakeEnvelope) {
        if !waiters.isEmpty { waiters.removeFirst().resume(returning: e) }
        else { queue.append(e) }
    }
    func take() async -> HandshakeEnvelope {
        if !queue.isEmpty { return queue.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

struct InMemoryHandshakeChannel: HandshakeChannel {
    let outbox: HandshakeMailbox
    let inbox: HandshakeMailbox
    func send(_ envelope: HandshakeEnvelope) async throws { await outbox.put(envelope) }
    func recv() async throws -> HandshakeEnvelope { await inbox.take() }
}
