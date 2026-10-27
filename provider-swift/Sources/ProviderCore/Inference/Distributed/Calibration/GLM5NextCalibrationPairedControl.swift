import Foundation
import DarkbloomClusterRemote
import DarkbloomClusterSecurity

/// A retained actual encrypted channel, never a caller-supplied receive closure.
/// The event queue only enqueues bounded deliveries; it performs no peer waits.
final class GLM5NextCalibrationPairedControl: @unchecked Sendable {
    typealias W = GLM5NextCalibrationDispatchWire
    static let port: UInt16 = 47_424
    private let afterTerminalContextSample: (@Sendable () throws -> Void)?
    // Observation only; exposes no peer handle and accepts no status evidence.
    var transportObservationForTests: ClusterLinkControlPeerStatus? { peer?.status }
    private let completed: GLM5NextCalibrationInstalledQuote.Completed
    private let sessionID: UUID
    private let pairing: GLM5NextCalibrationPeerQuoteDocument.Pair
    private let condition = NSCondition()
    private let sending = NSLock()
    private var listener: ClusterLinkControlListener?
    private var client: ClusterLinkControlClient?
    private var peer: ClusterLinkControlPeer?
    private var frozen: ClusterLinkControlPeerStatus?
    private var sawConnected = false, admittedConnection = false
    private var queue: [(packet: W.Packet, bytes: Int)] = []
    private var delivered: UInt64 = 1
    private var terminalExpected: Data?
    private var terminalAckReceived = false, terminalAckConsumed = false
    private var expectedPeerClosed = false, retiredClose = false
    private var queuedBytes = 0, receivedBytes = 0, sentBytes = 0
    private var incoming: UInt64 = 1, outgoing: UInt64 = 1
    private var poisoned = false
    private var cancelHandler: (@Sendable () -> Void)?
    var boundPort: UInt16? { listener?.boundPort }
    /// Observation only; none of these values can authorize retirement.
    var terminalObservation: (received: Bool, consumed: Bool, peerClosed: Bool, poisoned: Bool) {
        condition.withLock { (terminalAckReceived, terminalAckConsumed, expectedPeerClosed, poisoned) }
    }
    /// Observation only: queued authenticated kind, not exact-digest admission.
    /// The real terminal exchange must still validate and consume this packet.
    var queuedResultAcknowledgment: Bool {
        condition.withLock { queue.contains { $0.packet.kind == .resultAck } }
    }
    private final class Box: @unchecked Sendable { weak var value: GLM5NextCalibrationPairedControl? }

    static func open(completed: GLM5NextCalibrationInstalledQuote.Completed, sessionID: UUID,
                     peerAddress: ClusterLinkIPv4Address) throws -> GLM5NextCalibrationPairedControl {
        let physical = completed.pair.record.link.localInterface
        guard let carrier = ClusterLinkSystemInterfaceInspector.carrierInterface(forPort: physical, reaching: peerAddress) else {
            throw W.invalid("paired control carrier unavailable")
        }
        return try Self(completed: completed, sessionID: sessionID, peerAddress: peerAddress,
            interface: carrier, port: port, policy: .thunderboltOnly)
    }
    /// Actual sockets/encryption, fixture pair secrets and actual peer identities.
    /// No raw peer or authenticated-byte injection. Never callable from CLI.
    static func isolatedLoopbackTests(completed: GLM5NextCalibrationInstalledQuote.Completed,
                                     sessionID: UUID, port: UInt16,
                                     afterTerminalContextSample: (@Sendable () throws -> Void)? = nil) throws -> GLM5NextCalibrationPairedControl {
        try Self(completed: completed, sessionID: sessionID, peerAddress: ClusterLinkIPv4Address("127.0.0.1")!,
            interface: "lo0", port: port, policy: .loopbackForTests,
            afterTerminalContextSample: afterTerminalContextSample)
    }
    private init(completed: GLM5NextCalibrationInstalledQuote.Completed, sessionID: UUID,
                 peerAddress: ClusterLinkIPv4Address, interface: String, port: UInt16,
                 policy: ClusterLinkInterfacePolicy,
                 afterTerminalContextSample: (@Sendable () throws -> Void)? = nil) throws {
        guard sessionID != W.zero else { throw W.invalid("zero dispatch session") }
        self.afterTerminalContextSample = afterTerminalContextSample
        self.completed = completed; self.sessionID = sessionID
        let rank = completed.authorized.request.selection.rank
        pairing = try GLM5NextCalibrationPeerQuoteDocument.pair(completed.pair, identity: completed.authorized.identity, rank: rank)
        let pair = completed.pair
        let p = ClusterSetupLinkExchange.Pairing(localPin: ClusterMemberPin.of(uncompressedKey: pair.localIdentity),
            peerPin: ClusterMemberPin.of(uncompressedKey: pair.peerIdentity), clusterID: pair.clusterID,
            linkEpoch: pair.record.link.linkEpoch, edgeID: pair.record.link.edgeID,
            secretFile: pair.record.link.secretFile, secret: try pair.linkSecret())
        // Reuse the EXISTING setup-exchange key/domain/epoch derivation. This
        // dedicated socket never enters Responder.commandTag or Session.request.
        let inherited = try ClusterSetupLinkExchange.edge(p, peerAddress: peerAddress)
        var limits = inherited.limits
        limits.maximumBodyBytes = W.maximumBytes + 2
        limits.maximumPendingEvents = 32; limits.maximumPendingHandshakes = 2
        limits.maximumUnacknowledgedMessages = 32; limits.maximumUnacknowledgedBytes = 8 << 20
        limits.writeTimeout = .seconds(2); limits.sendTimeout = .seconds(2)
        let edge = try ClusterLinkControlEdge(edgeID: inherited.edgeID, epoch: inherited.epoch,
            key: inherited.key, peerAddress: peerAddress, limits: limits)
        let box = Box()
        let handler: ClusterLinkControlEventHandler = { event, peer in box.value?.event(event, peer: peer) }
        if rank == 0 {
            let value = try ClusterLinkControlListener(configuration: .init(interface: interface,
                port: port, policy: policy, edges: [edge]), handler: handler)
            listener = value; peer = value.peer(for: edge.edgeID)
        } else {
            let value = try ClusterLinkControlClient(configuration: .init(interface: interface,
                port: port, policy: policy, edge: edge), handler: handler)
            client = value; peer = value.peer
        }
        box.value = self
        if let listener { _ = try listener.start() } else { client?.start() }
    }
    deinit { listener?.stop(); client?.stop() }
    func requireContext(completed actual: GLM5NextCalibrationInstalledQuote.Completed, sessionID: UUID) throws {
        guard self.sessionID == sessionID, actual.authorized.identity == completed.authorized.identity,
              actual.authorized.document == completed.authorized.document, actual.responseData == completed.responseData,
              actual.pinnedVocabularySize == completed.pinnedVocabularySize,
              actual.installedExecutable == completed.installedExecutable, actual.worker == completed.worker,
              actual.metallib == completed.metallib, actual.modelDirectory == completed.modelDirectory,
              actual.environment == completed.environment, actual.pair.clusterID == completed.pair.clusterID,
              actual.pair.record == completed.pair.record, actual.pair.localIdentity == completed.pair.localIdentity,
              actual.pair.peerIdentity == completed.pair.peerIdentity else { throw W.invalid("paired channel belongs to another Completed/session") }
        try actual.pair.requireUnchanged(); try completed.pair.requireUnchanged()
    }
    func onFailure(_ body: @escaping @Sendable () -> Void) {
        let failed = condition.withLock { cancelHandler = body; return poisoned }
        if failed { body() }
    }
    func invalidate() {
        let value = condition.withLock { () -> (Bool, (@Sendable () -> Void)?) in
            if poisoned { return (false, nil) }
            poisoned = true; condition.broadcast(); return (true, cancelHandler)
        }
        guard value.0 else { return }
        value.1?()
        // A protocol failure must also fence the OTHER owner promptly. Never
        // join a socket reader from its own ordered event callback queue.
        DispatchQueue.global().async { [self] in listener?.stop(); client?.stop() }
    }
    func close() { invalidate(); listener?.stop(); client?.stop() }
    private func event(_ event: ClusterLinkControlEvent, peer observed: ClusterLinkControlPeer?) {
        var fail = false, stopExpected = false
        var failedHandler: (@Sendable () -> Void)?
        condition.lock()
        do {
            switch event {
            case .connected(let edge, _, let resumed, _):
                guard observed === peer, edge == pairing.edgeID, !resumed,
                      !sawConnected, observed?.status.sessions == 1 else { throw W.invalid("replacement finite connection") }
                sawConnected = true
                if frozen == nil { frozen = observed?.status }
            case .opaque(let edge, let id, let tag, let bytes):
                guard !poisoned, !expectedPeerClosed, !retiredClose, observed === peer,
                      edge == pairing.edgeID, tag == W.tag, bytes.count <= W.maximumBytes,
                      queue.count < 32, queuedBytes + bytes.count <= 8 << 20,
                      receivedBytes + bytes.count <= 8 << 20, id == delivered else { throw W.invalid("finite delivery context/budget") }
                try requireFrozenIdentityLocked()
                let packet = try W.decode(W.Packet.self, bytes)
                try W.validate(packet, expected: header(rank: 1 - completed.authorized.request.selection.rank,
                    sequence: delivered), now: Int64(Date().timeIntervalSince1970))
                // Validate on the actual ordered authenticated delivery event,
                // before a subsequent shutdown can change the peer's status.
                if let expected = terminalExpected {
                    try validateTerminalPacketLocked(packet, expected: expected)
                }
                queue.append((packet, bytes.count)); queuedBytes += bytes.count
                receivedBytes += bytes.count; delivered += 1; condition.broadcast()
            case .disconnected(let edge, let reason):
                guard observed === peer, edge == pairing.edgeID else { throw W.invalid("foreign finite disconnect") }
                if retiredClose && reason == .localShutdown { break }
                guard reason == .peerClosed, terminalExpected != nil, terminalAckReceived,
                      !poisoned else { throw W.invalid("operational finite disconnect") }
                try requireFrozenIdentityLocked()
                expectedPeerClosed = true; stopExpected = true; condition.broadcast()
            case .peerRestarted, .message: throw W.invalid("finite protocol/connection replacement")
            case .refused: break // Unauthenticated strangers cannot poison a valid admitted session.
            }
        } catch {
            fail = !poisoned
            if fail { poisoned = true; failedHandler = cancelHandler; condition.broadcast() }
        }
        condition.unlock()
        if fail {
            failedHandler?()
            DispatchQueue.global().async { [self] in listener?.stop(); client?.stop() }
        } else if stopExpected {
            // Never reconnect a retired context. Join endpoint threads away
            // from their ordered event queue; already queued evidence is retained.
            DispatchQueue.global().async { [self] in listener?.stop(); client?.stop() }
        }
    }
    /// Caller holds condition. Connected is deliberately not required here:
    /// ordered delivery may precede its lifecycle event while core status has
    /// already changed. Generation/incarnation/peer replacement still fails.
    private func requireFrozenIdentityLocked() throws {
        guard let peer else { throw W.invalid("replaced finite connection") }
        try requireFrozenIdentityLocked(peer.status)
    }
    private func requireFrozenIdentityLocked(_ status: ClusterLinkControlPeerStatus) throws {
        guard let frozen, status.sessions == frozen.sessions,
              status.peerIncarnation == frozen.peerIncarnation,
              status.peerRestarts == frozen.peerRestarts else { throw W.invalid("replaced finite connection") }
    }
    private func validateTerminalPacketLocked(_ packet: W.Packet, expected: Data) throws {
        guard !terminalAckReceived else { throw W.invalid("message after terminal acknowledgment") }
        if packet.kind == .cancel { _ = try W.decode(W.Empty.self, packet.payload); return }
        guard packet.kind == .resultAck, packet.payload == expected else { throw W.invalid("terminal acknowledgment differs") }
        terminalAckReceived = true
    }
    func connect(deadline: UInt64) throws {
        guard let peer else { throw W.invalid("paired peer unavailable") }
        while !peer.waitUntilConnected(timeout: .milliseconds(100)) {
            guard DispatchTime.now().uptimeNanoseconds < deadline,
                  !condition.withLock({ poisoned }) else { throw W.invalid("paired connect deadline") }
        }
        try completed.requireUnchanged(deadline: deadline)
        try condition.withLock {
            guard !admittedConnection, !poisoned, peer.status.connected, peer.status.sessions == 1,
                  peer.status.peerIncarnation != nil else { throw W.invalid("paired connection changed") }
            if frozen == nil { frozen = peer.status }
            try requireFrozenIdentityLocked()
            admittedConnection = true
        }
        try requireCurrent(pair: completed.pair)
    }
    func requireCurrent(pair: GLM5NextCalibrationInstalledPair) throws {
        try pair.requireUnchanged(); try completed.pair.requireUnchanged()
        guard pair.record == completed.pair.record, pair.localIdentity == completed.pair.localIdentity,
              pair.peerIdentity == completed.pair.peerIdentity, pair.clusterID == completed.pair.clusterID else { throw W.invalid("wrong retained pair") }
        try condition.withLock {
            guard !poisoned, let peer, let frozen, peer.status.connected,
                  peer.status.sessions == frozen.sessions, peer.status.peerIncarnation == frozen.peerIncarnation,
                  peer.status.peerRestarts == frozen.peerRestarts else { throw W.invalid("stale paired connection") }
        }
    }
    private func header(rank: Int, sequence: UInt64) throws -> W.Header {
        guard let peer, let frozen, let remote = frozen.peerIncarnation else { throw W.invalid("unconnected dispatch") }
        let request = completed.authorized.request
        return W.Header(version: 1, purpose: "finiteCalibration", pair: pairing, sessionID: sessionID,
            epoch: request.selection.epoch, requestID: request.authorization.requestID,
            expiresUnixSeconds: request.selection.expiresUnixSeconds, rank: rank,
            senderIncarnation: rank == request.selection.rank ? peer.incarnation : remote,
            receiverIncarnation: rank == request.selection.rank ? remote : peer.incarnation,
            connectionGeneration: 1, sequence: sequence)
    }
    func send(_ kind: W.Kind, _ bytes: Data, deadline: UInt64) throws {
        sending.lock(); defer { sending.unlock() }
        try requireCurrent(pair: completed.pair)
        guard !condition.withLock({ terminalExpected != nil }) else { throw W.invalid("terminal channel cannot operate") }
        let rank = completed.authorized.request.selection.rank
        let packet = W.Packet(header: try header(rank: rank, sequence: outgoing), kind: kind, payload: bytes)
        try W.validate(packet, expected: packet.header, now: Int64(Date().timeIntervalSince1970))
        let data = try W.canonical(packet)
        guard sentBytes + data.count <= 8 << 20, let peer else { throw W.invalid("dispatch send budget") }
        _ = try peer.sendOpaque(tag: W.tag, data, timeout: remaining(deadline))
        sentBytes += data.count; outgoing += 1
        try requireCurrent(pair: completed.pair)
    }
    /// Driver only. Operational receive NEVER permits a disconnected context.
    func receive(deadline: UInt64) throws -> W.Packet? {
        try requireCurrent(pair: completed.pair)
        condition.lock()
        while queue.isEmpty && !poisoned {
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline { condition.unlock(); return nil }
            _ = condition.wait(until: Date(timeIntervalSinceNow: Double(deadline - now) / 1e9))
        }
        guard !poisoned, terminalExpected == nil, !queue.isEmpty else {
            condition.unlock(); throw W.invalid("paired channel lost/terminal")
        }
        let item = queue.removeFirst()
        let packet = item.packet
        queuedBytes -= item.bytes
        condition.unlock()
        try requireCurrent(pair: completed.pair)
        guard packet.header.sequence == incoming else { invalidate(); throw W.invalid("dispatch consumption replay") }
        incoming += 1
        return packet
    }
    /// The driver arms this ONLY after both validated retirements and local
    /// ownership drain. No operational read/send is admitted after arming.
    /// The test observer may pause consumption, never supply evidence.
    func exchangeTerminalAcknowledgment(_ expected: Data, deadline: UInt64,
                                       beforeConsuming: () throws -> Void) throws -> Bool {
        _ = try W.decode(W.Digest.self, expected)
        sending.lock()
        do {
            try requireCurrent(pair: completed.pair)
            try condition.withLock {
                guard !poisoned, terminalExpected == nil else { throw W.invalid("terminal exchange already used") }
                terminalExpected = expected
                for item in queue { try validateTerminalPacketLocked(item.packet, expected: expected) }
            }
            let packet = W.Packet(header: try header(rank: completed.authorized.request.selection.rank,
                sequence: outgoing), kind: .resultAck, payload: expected)
            try W.validate(packet, expected: packet.header, now: Int64(Date().timeIntervalSince1970))
            let data = try W.canonical(packet)
            guard sentBytes + data.count <= 8 << 20, let peer else { throw W.invalid("terminal send budget") }
            _ = try peer.sendOpaque(tag: W.tag, data, timeout: remaining(deadline))
            sentBytes += data.count; outgoing += 1
            sending.unlock()
        } catch { sending.unlock(); invalidate(); throw error }
        do {
            try condition.withLock {
                while !terminalAckReceived && !poisoned {
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard now < deadline else { throw W.invalid("terminal acknowledgment deadline") }
                    _ = condition.wait(until: Date(timeIntervalSinceNow: Double(deadline - now) / 1e9))
                }
                guard !poisoned else { throw W.invalid("terminal channel poisoned") }
            }
            try beforeConsuming()
            try requireTerminalContext()
            let cancelled = try condition.withLock { () throws -> Bool in
                var cancelled = false
                while !queue.isEmpty {
                    let item = queue.removeFirst()
                    let packet = item.packet
                    queuedBytes -= item.bytes
                    guard packet.header.sequence == incoming else { throw W.invalid("terminal consumption replay") }
                    incoming += 1
                    if packet.kind == .cancel {
                        _ = try W.decode(W.Empty.self, packet.payload); cancelled = true
                    } else {
                        guard packet.kind == .resultAck, packet.payload == expected, queue.isEmpty,
                              !terminalAckConsumed else { throw W.invalid("terminal consumption differs") }
                        terminalAckConsumed = true
                    }
                }
                guard terminalAckConsumed else { throw W.invalid("terminal acknowledgment unconsumed") }
                return cancelled
            }
            guard let peer else { throw W.invalid("terminal peer missing") }
            // A post-consumption ping flushes the reverse-direction ack too.
            // Its pong is reader-level only; app consumption above is mandatory.
            do { _ = try peer.ping(timeout: remaining(deadline)) }
            catch {
                // The other retired owner can already have closed. This is
                // allowed ONLY for its expected shutdown, with our queued ack
                // actually acknowledged below; cable errors still fail.
                try requireTerminalContext(requirePeerClosed: true)
            }
            try peer.waitUntilAcknowledged(timeout: remaining(deadline))
            try requireTerminalContext()
            return cancelled
        } catch { invalidate(); throw error }
    }
    private func requireTerminalContext(requirePeerClosed: Bool = false) throws {
        try completed.pair.requireUnchanged()
        try condition.withLock { try requireTerminalContextLocked(requirePeerClosed: requirePeerClosed) }
    }
    private func requireTerminalContextLocked(requirePeerClosed: Bool = false) throws {
        guard !poisoned, terminalExpected != nil, terminalAckReceived, !retiredClose,
              let peer else { throw W.invalid("terminal context unavailable") }
        // One observation for this decision: a valid close may occur while
        // the ordered disconnect callback is waiting for our condition lock.
        let status = peer.status
        try requireFrozenIdentityLocked(status)
        let closed = expectedPeerClosed || (!status.connected && status.lastDisconnect == .peerClosed)
        // Schedule only: never supply a status, completion, digest or verdict.
        // Runs under condition; the test must not call terminalObservation here.
        try afterTerminalContextSample?()
        guard (status.connected || closed), !requirePeerClosed || closed else {
            throw W.invalid("terminal transport lost")
        }
    }
    /// Linearizes the app's retired outcome with ordered lifecycle/protocol
    /// failure. It authorizes no IO, mint or caller-supplied completion.
    func authenticateTerminalRetirement(_ recordOutcome: () -> Void) throws {
        try completed.pair.requireUnchanged()
        try condition.withLock {
            try requireTerminalContextLocked()
            guard terminalAckConsumed else { throw W.invalid("terminal acknowledgment unconsumed") }
            recordOutcome()
        }
    }
    /// Expected local shutdown is distinct from invalidate(). The app has
    /// consumed its strict ack, confirmed delivery, and durably retired its fence.
    func closeRetired() throws {
        try requireTerminalContext()
        try condition.withLock {
            try requireTerminalContextLocked()
            guard terminalAckConsumed else { throw W.invalid("unconsumed terminal close") }
            retiredClose = true
        }
        listener?.stop(); client?.stop()
    }
    private func remaining(_ deadline: UInt64) throws -> Duration {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline > now else { throw W.invalid("dispatch deadline") }
        return .nanoseconds(Int64(min(deadline - now, 2_000_000_000)))
    }
}
