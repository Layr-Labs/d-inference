import CryptoKit
import DarkbloomClusterSecurity
import Foundation

// Link control channel (PROD-PLAN S06): one authenticated, encrypted TCP
// session per link edge, over the Thunderbolt link's IPv4, hosted by the
// provider process so the one firewall / Local Network approval belongs to the
// signed provider binary and never to a per-build worker.
//
// Ported in concept from the owner's oMLX rank control plane
// (`omlx/cluster/control_plane.py`: persistent per-rank socket, mutual HMAC
// handshake OC2C/OC2H/OC2A, per-frame sequence and authentication, OC2B small
// decisions, OC2R barrier), with the survey's changes: typed Codable messages
// instead of pickle, the secret never on a command line, keys from the native
// key derivation, frames encrypted (prompt token IDs cross this channel), and
// nothing control-like on RDMA.
//
// Shape for N members (PROD-PLAN-NMAC 2.2-2.3): the unit is one edge (two
// members over one cable, a per-edge key, epoch and edge ID). The head hosts
// one listener per link interface; each listener admits one live session per
// configured edge; a member reaches the head over its direct edge. Addressing
// is whatever the link layer assigned to that interface (today's Internet
// Sharing subnet, link setup v2's 10.219/16, or per-edge /30 subnets).

/// Closed failures; never carry an address, key or payload.
public enum ClusterLinkControlError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidMessage
    case wrongEpoch
    case messageTooLarge
    case backpressure
    case closed
    case notConnected
    case timedOut
    case protocolViolation
    case malformedHandshake
}

/// Why a session ended.
public enum ClusterLinkControlDisconnect: String, Sendable, Equatable, Codable {
    case peerClosed, peerSilent, superseded, rekey, protocolViolation, authenticationFailed
    case transportError, writeTimeout, localShutdown
}

/// Why a connection was refused before or during the handshake, or a dial failed.
public enum ClusterLinkControlRefusal: Sendable, Equatable {
    case unexpectedSource
    case evictedPendingHandshake
    case handshakeTimeout
    case malformedHandshake
    case unknownEdge
    case wrongEpoch
    case limitsMismatch
    case authenticationFailed
    case serverAuthenticationFailed
    case handshakeRejected
    case connectFailed
    case interface(ClusterLinkInterfaceRefusal)
}

/// Delivered in order on the edge's own serial queue. The handler may call
/// `send` on the peer; it must not wait for long (a slow handler stops the
/// edge's reader once the bounded event queue is full).
public enum ClusterLinkControlEvent: Sendable {
    case connected(edgeID: UUID, peerIncarnation: UUID, resumed: Bool, retransmitted: Int)
    case disconnected(edgeID: UUID, reason: ClusterLinkControlDisconnect)
    case peerRestarted(edgeID: UUID, droppedUnacknowledged: Int)
    case message(edgeID: UUID, id: UInt64, ClusterLinkControlMessage)
    case opaque(edgeID: UUID, id: UInt64, tag: UInt16, Data)
    case refused(edgeID: UUID?, reason: ClusterLinkControlRefusal)
}

public typealias ClusterLinkControlEventHandler = @Sendable (ClusterLinkControlEvent, ClusterLinkControlPeer?) -> Void

/// Bounds and timing of one edge. Both ends must use the same frame and
/// per-connection budgets (they are bound into the record keys and checked in
/// the handshake); timing may differ.
public struct ClusterLinkControlLimits: Sendable, Equatable {
    public var maximumBodyBytes = 4 * 1024 * 1024
    /// Per connection; the connection rolls over to fresh keys before either cap.
    public var maximumRecordsPerConnection: UInt64 = ClusterRecordLimits.hardMaximumRecords
    public var maximumBytesPerConnection: UInt64 = ClusterRecordLimits.hardMaximumCumulativePlaintextBytes
    public var maximumUnacknowledgedMessages = 4096
    public var maximumUnacknowledgedBytes = 64 * 1024 * 1024
    public var maximumPromptTokens = 1_048_576
    public var maximumPendingHandshakes = 8
    public var maximumPendingEvents = 4096
    public var handshakeTimeout: Duration = .seconds(2)
    public var connectTimeout: Duration = .seconds(2)
    public var heartbeatInterval: Duration = .seconds(1)
    public var silenceTimeout: Duration = .seconds(5)
    public var writeTimeout: Duration = .seconds(10)
    public var frameTimeout: Duration = .seconds(10)
    public var sendTimeout: Duration = .seconds(10)
    public var acknowledgementDelay: Duration = .milliseconds(5)
    public var reconnectInitialDelay: Duration = .milliseconds(20)
    public var reconnectMaximumDelay: Duration = .seconds(1)

    public init() {}

    func validate() throws {
        guard (64...(ClusterRecordLimits.hardMaximumPlaintextBytes - LinkFrame.headerBytes)).contains(maximumBodyBytes),
              maximumRecordsPerConnection >= 64, maximumRecordsPerConnection <= ClusterRecordLimits.hardMaximumRecords,
              maximumBytesPerConnection >= UInt64(4 * (maximumBodyBytes + LinkFrame.headerBytes)),
              maximumBytesPerConnection <= ClusterRecordLimits.hardMaximumCumulativePlaintextBytes,
              maximumUnacknowledgedMessages >= 1, maximumUnacknowledgedBytes >= maximumBodyBytes,
              maximumPromptTokens >= 1, maximumPendingHandshakes >= 1, maximumPendingEvents >= 1,
              [handshakeTimeout, connectTimeout, heartbeatInterval, silenceTimeout, writeTimeout, frameTimeout,
               sendTimeout, acknowledgementDelay, reconnectInitialDelay, reconnectMaximumDelay].allSatisfy({ $0 > .zero }),
              silenceTimeout > heartbeatInterval else { throw ClusterLinkControlError.invalidConfiguration }
    }

    func recordLimits() throws -> ClusterRecordLimits {
        try ClusterRecordLimits(maximumPlaintextBytes: maximumBodyBytes + LinkFrame.headerBytes,
            maximumRecordsPerDirection: maximumRecordsPerConnection,
            maximumCumulativePlaintextBytesPerDirection: maximumBytesPerConnection)
    }
}

extension Duration {
    var clusterLinkNanoseconds: UInt64 {
        let parts = components
        guard parts.seconds >= 0 else { return 0 }
        return UInt64(parts.seconds) &* 1_000_000_000 &+ UInt64(parts.attoseconds / 1_000_000_000)
    }
}

/// One link edge: two members over one cable.
public struct ClusterLinkControlEdge: Sendable {
    public let edgeID: UUID
    public let epoch: UUID
    public let key: ClusterLinkControlKey
    /// Listener: the only source address admitted for this edge (nil admits any
    /// source on the bound interface). Connector: the address it dials.
    public let peerAddress: ClusterLinkIPv4Address?
    public let limits: ClusterLinkControlLimits

    public init(edgeID: UUID, epoch: UUID, key: ClusterLinkControlKey, peerAddress: ClusterLinkIPv4Address?,
                limits: ClusterLinkControlLimits = .init()) throws {
        guard LinkHandshake.uuidBytes(edgeID) != Data(repeating: 0, count: 16),
              LinkHandshake.uuidBytes(epoch) != Data(repeating: 0, count: 16) else {
            throw ClusterLinkControlError.invalidConfiguration
        }
        try limits.validate()
        self.edgeID = edgeID; self.epoch = epoch; self.key = key; self.peerAddress = peerAddress; self.limits = limits
    }

    /// Deterministic edge ID from both members' pins and the interfaces at
    /// each end of the cable, independent of argument order (NMAC 2.2: edges
    /// are keyed by the sorted (pin, interface) pairs).
    public static func derivedEdgeID(firstMember: String, firstInterface: String,
                                     secondMember: String, secondInterface: String) -> UUID {
        let ends = [firstMember + "\u{1F}" + firstInterface, secondMember + "\u{1F}" + secondInterface].sorted()
        var hasher = SHA256()
        hasher.update(data: Data("darkbloom/link-control/edge-id/v1\0".utf8))
        hasher.update(data: Data(ends[0].utf8)); hasher.update(data: Data([0]))
        hasher.update(data: Data(ends[1].utf8))
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = bytes[6] & 0x0F | 0x80 // version 8 (custom)
        bytes[8] = bytes[8] & 0x3F | 0x80 // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// Round trip of one ping: `channel` is measured where the pong is read (both
/// seals and opens, framing, kernel, TCP and the cable); `observed` adds the
/// wake-up of the thread that asked.
public struct ClusterLinkPingResult: Sendable, Equatable {
    public let channelNanoseconds: UInt64
    public let observedNanoseconds: UInt64
}

public struct ClusterLinkControlPeerStatus: Sendable, Equatable {
    public let connected: Bool
    public let peerIncarnation: UUID?
    public let sessions: UInt64
    public let sentMessages: UInt64
    public let deliveredMessages: UInt64
    public let unacknowledgedMessages: Int
    public let retransmittedMessages: UInt64
    public let duplicatesDropped: UInt64
    public let peerRestarts: UInt64
    public let lastDisconnect: ClusterLinkControlDisconnect?
}

/// One connected TCP session of an edge. The socket is shut down from any
/// thread; it is closed once, by `ClusterLinkControlPeer.connectionEnded`,
/// while holding the peer's write lock, after its reader has stopped.
final class LinkConnection: @unchecked Sendable {
    let socket: LinkSocket
    let records: LinkRecordPair
    let peerIncarnation: UUID
    let limits: ClusterLinkControlLimits
    private let lock = NSLock()
    private var endReason: ClusterLinkControlDisconnect?
    private var closed = false
    let ended = DispatchSemaphore(value: 0)

    init(socket: LinkSocket, records: LinkRecordPair, peerIncarnation: UUID, limits: ClusterLinkControlLimits) {
        self.socket = socket; self.records = records; self.peerIncarnation = peerIncarnation; self.limits = limits
    }

    /// First reason wins; shuts the socket down so blocked IO returns.
    func end(_ reason: ClusterLinkControlDisconnect) {
        lock.withLock { if endReason == nil { endReason = reason } }
        socket.shutdown()
    }

    var reason: ClusterLinkControlDisconnect? { lock.withLock { endReason } }
    var isOpen: Bool { lock.withLock { !closed && endReason == nil } }

    func markClosed() { lock.withLock { closed = true } }

    static func sealedBytes(body: Int) -> Int {
        ClusterAuthenticatedRecordChannel.framingPrefixBytes + LinkFrame.headerBytes + body
            + ClusterAuthenticatedRecordChannel.tagBytes
    }

    /// Whether one more frame of `body` bytes fits this connection's record
    /// budget, leaving room for a goodbye.
    func fits(body: Int) -> Bool {
        let status = records.sealer.status
        let plaintext = UInt64(LinkFrame.headerBytes + body)
        return status.sealedRecords + 2 < limits.maximumRecordsPerConnection
            && status.sealedPlaintextBytes + plaintext + UInt64(LinkFrame.headerBytes + 1) <= limits.maximumBytesPerConnection
    }

    /// Caller holds the peer's write lock.
    func write(_ frame: LinkFrame, deadline: UInt64) throws {
        guard isOpen else { throw LinkSocketError.closed }
        let record = try records.sealer.seal(frame.plaintext(), context: records.sealContext)
        try socket.writeAll(record, deadline: deadline)
    }

    /// Reader thread only. Waits up to `idleDeadline` for the next frame to
    /// start, then `frameTimeout` for the rest of it; length is validated
    /// against the bound before anything is allocated.
    func readFrame(reader: LinkReader, idleDeadline: UInt64) throws -> LinkFrame {
        let prefix = try reader.readExact(ClusterAuthenticatedRecordChannel.framingPrefixBytes, deadline: idleDeadline)
        let total: Int
        do {
            total = try ClusterAuthenticatedRecordChannel.boundedRecordByteCount(fromPrefix: prefix,
                maximumPlaintextBytes: records.limits.maximumPlaintextBytes)
        } catch { throw ClusterLinkControlError.protocolViolation }
        let rest = try reader.readExact(total - prefix.count, deadline: linkNow() &+ limits.frameTimeout.clusterLinkNanoseconds)
        var record = prefix; record.append(rest)
        let plaintext: Data
        do { plaintext = try records.opener.open(record, expecting: records.openContext) } catch {
            throw ClusterLinkRecordFailure.authentication
        }
        return try LinkFrame.parse(plaintext, maximumBodyBytes: limits.maximumBodyBytes)
    }
}

enum ClusterLinkRecordFailure: Error { case authentication }

/// One end of one edge: the reliable message stream, the current connection
/// (if any) and the application's handle. It outlives connections, so a
/// reconnect resumes the stream; a new local process is a new incarnation.
///
/// Locking: `writeLock` orders every frame write and message-ID assignment;
/// `state` guards everything else and is never held during IO. A reader thread
/// never blocks on `writeLock` (it only tries it, and defers to the
/// maintenance thread otherwise), so two ends whose send buffers are full
/// still drain each other.
public final class ClusterLinkControlPeer: @unchecked Sendable {
    public let edgeID: UUID
    public let role: ClusterLinkControlRole
    /// This end's incarnation: a fresh value per process (per peer object).
    public let incarnation = UUID()
    let edge: ClusterLinkControlEdge
    private let handler: ClusterLinkControlEventHandler
    private let deliveryQueue: DispatchQueue
    private let deliverySlots: DispatchSemaphore
    private let writeLock = NSLock()
    private let state = NSCondition()

    private var outbox: LinkOutbox
    private var inbox = LinkInbox()
    private var knownPeerIncarnation: UUID?
    private var connection: LinkConnection?
    private var closed = false
    private var lastSentAt: UInt64 = 0
    private var pendingAckDeadline: UInt64?
    private var deliveredSinceAck = 0
    private var deferredPongs: [Data] = []
    private var pingWaiters: [UInt64: PingWaiter] = [:]
    private var nextPingToken: UInt64 = 1
    private var sessions: UInt64 = 0
    private var sentMessages: UInt64 = 0
    private var deliveredMessages: UInt64 = 0
    private var retransmitted: UInt64 = 0
    private var duplicates: UInt64 = 0
    private var peerRestarts: UInt64 = 0
    private var lastDisconnect: ClusterLinkControlDisconnect?
    private var maintenanceStarted = false

    private final class PingWaiter: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        var channelNanoseconds: UInt64?
    }

    init(edge: ClusterLinkControlEdge, role: ClusterLinkControlRole, handler: @escaping ClusterLinkControlEventHandler) {
        self.edge = edge; edgeID = edge.edgeID; self.role = role; self.handler = handler
        outbox = LinkOutbox(maximumMessages: edge.limits.maximumUnacknowledgedMessages,
                            maximumBytes: edge.limits.maximumUnacknowledgedBytes)
        deliveryQueue = DispatchQueue(label: "darkbloom.link-control.events")
        deliverySlots = DispatchSemaphore(value: edge.limits.maximumPendingEvents)
    }

    // MARK: Application API

    /// Queues one typed message for exactly-once, in-order delivery and writes
    /// it now when a session is up. Blocks while the outbox is full (up to the
    /// send timeout) and while the socket is full (up to the write timeout,
    /// after which the session is torn down and the message resent later).
    @discardableResult
    public func send(_ message: ClusterLinkControlMessage, timeout: Duration? = nil) throws -> UInt64 {
        if let epoch = message.epoch, epoch != edge.epoch { throw ClusterLinkControlError.wrongEpoch }
        try message.validate(maximumPromptTokens: edge.limits.maximumPromptTokens)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(message)
        return try sendSequenced(kind: .message, body: body, timeout: timeout)
    }

    /// Queues one opaque payload (2-byte tag + bytes) with the same delivery
    /// guarantees as `send`.
    @discardableResult
    public func sendOpaque(tag: UInt16, _ bytes: Data, timeout: Duration? = nil) throws -> UInt64 {
        var body = Data(capacity: bytes.count + 2)
        body.clusterLinkAppend(tag); body.append(bytes)
        return try sendSequenced(kind: .opaque, body: body, timeout: timeout)
    }

    /// One unsequenced ping answered by the peer's reader thread.
    public func ping(paddingBytes: Int = 0, timeout: Duration = .seconds(2)) throws -> ClusterLinkPingResult {
        guard paddingBytes >= 0, paddingBytes + LinkFrame.pingBodyBytes <= edge.limits.maximumBodyBytes else {
            throw ClusterLinkControlError.messageTooLarge
        }
        let waiter = PingWaiter()
        let token: UInt64 = state.withLock {
            let token = nextPingToken; nextPingToken += 1
            pingWaiters[token] = waiter
            return token
        }
        defer { state.withLock { _ = pingWaiters.removeValue(forKey: token) } }
        var body = Data(capacity: LinkFrame.pingBodyBytes + paddingBytes)
        let sentAt = linkNow()
        body.clusterLinkAppend(token); body.clusterLinkAppend(sentAt)
        if paddingBytes > 0 { body.append(Data(count: paddingBytes)) }
        writeLock.lock()
        let current = state.withLock { connection }
        guard let current, current.isOpen else { writeLock.unlock(); throw ClusterLinkControlError.notConnected }
        do { try writeFrame(kind: .ping, id: 0, body: body, on: current) } catch {
            writeLock.unlock(); current.end(.transportError); throw ClusterLinkControlError.notConnected
        }
        writeLock.unlock()
        guard waiter.semaphore.wait(timeout: .now() + .nanoseconds(Int(timeout.clusterLinkNanoseconds))) == .success,
              let channel = state.withLock({ waiter.channelNanoseconds }) else {
            throw ClusterLinkControlError.timedOut
        }
        return .init(channelNanoseconds: channel, observedNanoseconds: linkNow() - sentAt)
    }

    /// Waits until every queued message has been acknowledged by the peer.
    public func waitUntilAcknowledged(timeout: Duration) throws {
        let deadline = Date(timeIntervalSinceNow: Double(timeout.clusterLinkNanoseconds) / 1e9)
        state.lock(); defer { state.unlock() }
        while outbox.count > 0 {
            guard !closed else { throw ClusterLinkControlError.closed }
            guard state.wait(until: deadline) else { throw ClusterLinkControlError.timedOut }
        }
    }

    /// Waits until a session is up.
    public func waitUntilConnected(timeout: Duration) -> Bool {
        let deadline = Date(timeIntervalSinceNow: Double(timeout.clusterLinkNanoseconds) / 1e9)
        state.lock(); defer { state.unlock() }
        while connection == nil || connection?.isOpen == false {
            if closed || !state.wait(until: deadline) { return false }
        }
        return true
    }

    public var status: ClusterLinkControlPeerStatus {
        state.withLock {
            .init(connected: connection?.isOpen == true, peerIncarnation: knownPeerIncarnation, sessions: sessions,
                  sentMessages: sentMessages, deliveredMessages: deliveredMessages,
                  unacknowledgedMessages: outbox.count, retransmittedMessages: retransmitted,
                  duplicatesDropped: duplicates, peerRestarts: peerRestarts, lastDisconnect: lastDisconnect)
        }
    }

    /// Testing: ends the current session as if the cable had dropped.
    func dropConnectionForTesting() {
        state.withLock { connection }?.end(.transportError)
    }

    // MARK: Sending

    private func sendSequenced(kind: LinkFrameKind, body: Data, timeout: Duration?) throws -> UInt64 {
        guard body.count <= edge.limits.maximumBodyBytes else { throw ClusterLinkControlError.messageTooLarge }
        let wait = (timeout ?? edge.limits.sendTimeout).clusterLinkNanoseconds
        let deadline = Date(timeIntervalSinceNow: Double(wait) / 1e9)
        while true {
            state.lock()
            while !closed, !outbox.canAccept(bytes: body.count) {
                guard state.wait(until: deadline) else { state.unlock(); throw ClusterLinkControlError.backpressure }
            }
            guard !closed else { state.unlock(); throw ClusterLinkControlError.closed }
            state.unlock()
            // Never wait for acknowledgements while holding the write lock.
            writeLock.lock()
            state.lock()
            guard !closed else { state.unlock(); writeLock.unlock(); throw ClusterLinkControlError.closed }
            guard outbox.canAccept(bytes: body.count) else { state.unlock(); writeLock.unlock(); continue }
            let id = outbox.append(kind: kind, body: body)
            sentMessages += 1
            let current = connection
            state.unlock()
            if let current, current.isOpen {
                do { try writeFrame(kind: kind, id: id, body: body, on: current) } catch {
                    current.end(error is ClusterLinkRollover ? .rekey : .transportError)
                }
            }
            writeLock.unlock()
            return id
        }
    }

    /// Caller holds `writeLock`. Every frame carries the current acknowledgement.
    private func writeFrame(kind: LinkFrameKind, id: UInt64, body: Data, on current: LinkConnection) throws {
        guard current.fits(body: body.count) else {
            // Fresh keys before the per-connection record budget runs out: say
            // goodbye, end the session, and the message is resent on the next one.
            let ack = state.withLock { inbox.deliveredThrough }
            try? current.write(LinkFrame(kind: .goodbye, messageID: 0, ackThrough: ack,
                body: Data([LinkGoodbyeReason.rekey.rawValue])), deadline: linkNow() &+ 100_000_000)
            throw ClusterLinkRollover()
        }
        let ack: UInt64 = state.withLock {
            pendingAckDeadline = nil; deliveredSinceAck = 0; lastSentAt = linkNow()
            return inbox.deliveredThrough
        }
        try current.write(LinkFrame(kind: kind, messageID: id, ackThrough: ack, body: body),
            deadline: linkNow() &+ edge.limits.writeTimeout.clusterLinkNanoseconds)
    }

    /// Reader thread: write a small control frame only if the write lock is
    /// free and the socket has room now; otherwise leave it to maintenance.
    private func tryWriteControl(kind: LinkFrameKind, body: Data, on current: LinkConnection) -> Bool {
        guard writeLock.try() else { return false }
        defer { writeLock.unlock() }
        guard current.isOpen else { return true }
        guard current.socket.sendSpace() >= LinkConnection.sealedBytes(body: body.count) + 64 else { return false }
        do { try writeFrame(kind: kind, id: 0, body: body, on: current) } catch {
            current.end(error is ClusterLinkRollover ? .rekey : .transportError)
        }
        return true
    }

    // MARK: Sessions

    func resumeInfo() -> LinkHandshake.Resume {
        state.withLock {
            .init(incarnation: incarnation, knownPeerIncarnation: knownPeerIncarnation,
                  deliveredThrough: knownPeerIncarnation == nil ? 0 : inbox.deliveredThrough)
        }
    }

    /// Installs a freshly authenticated connection: resolves resume or peer
    /// restart, supersedes any previous session, starts the reader, then
    /// retransmits every unacknowledged message before new sends proceed.
    @discardableResult
    func attach(_ new: LinkConnection, peer resume: LinkHandshake.Resume) -> Bool {
        writeLock.lock()
        state.lock()
        guard !closed else {
            state.unlock(); writeLock.unlock()
            new.end(.localShutdown); new.socket.close(); new.markClosed(); new.ended.signal()
            return false
        }
        let previousPeer = knownPeerIncarnation
        let restarted = previousPeer != nil && previousPeer != resume.incarnation
        var dropped = 0
        if restarted {
            dropped = outbox.dropAll()
            peerRestarts += 1
            failPingWaitersLocked()
        }
        if previousPeer != resume.incarnation { inbox.startNewStream() }
        if !restarted, resume.knownPeerIncarnation == incarnation {
            do { try outbox.acknowledge(through: resume.deliveredThrough) } catch {
                state.unlock(); writeLock.unlock()
                new.end(.protocolViolation); new.socket.close(); new.markClosed(); new.ended.signal()
                return false
            }
        }
        knownPeerIncarnation = resume.incarnation
        let previous = connection
        connection = new
        sessions += 1
        let pending = Array(outbox.pending)
        retransmitted += UInt64(pending.count)
        pendingAckDeadline = nil; deliveredSinceAck = 0
        // Lifecycle events go on the queue before the new reader can deliver
        // a message, and never wait for a slot while a lock is held.
        if restarted { enqueueLifecycle(.peerRestarted(edgeID: edgeID, droppedUnacknowledged: dropped)) }
        enqueueLifecycle(.connected(edgeID: edgeID, peerIncarnation: resume.incarnation,
                                    resumed: previousPeer == resume.incarnation, retransmitted: pending.count))
        if !maintenanceStarted {
            maintenanceStarted = true
            let thread = Thread { [weak self] in self?.maintenanceLoop() }
            thread.name = "darkbloom.link-control.maintenance"
            thread.start()
        }
        state.broadcast()
        state.unlock()
        previous?.end(.superseded)
        let reader = Thread { [weak self] in self?.readLoop(new) }
        reader.name = "darkbloom.link-control.reader"
        reader.qualityOfService = .userInteractive
        reader.start()
        for entry in pending {
            guard new.isOpen else { break }
            do { try writeFrame(kind: entry.kind, id: entry.id, body: entry.body, on: new) } catch {
                new.end(error is ClusterLinkRollover ? .rekey : .transportError); break
            }
        }
        writeLock.unlock()
        return true
    }

    private func readLoop(_ current: LinkConnection) {
        let reader = LinkReader(socket: current.socket)
        let silence = edge.limits.silenceTimeout.clusterLinkNanoseconds
        var reason: ClusterLinkControlDisconnect = .transportError
        do {
            while true {
                let frame = try current.readFrame(reader: reader, idleDeadline: linkNow() &+ silence)
                if let ended = try process(frame, on: current) { reason = ended; break }
            }
        } catch LinkSocketError.timedOut {
            reason = .peerSilent
        } catch LinkSocketError.closed {
            reason = .peerClosed
        } catch ClusterLinkRecordFailure.authentication {
            reason = .authenticationFailed
        } catch ClusterLinkControlError.protocolViolation, ClusterLinkControlError.invalidMessage,
                ClusterLinkControlError.wrongEpoch {
            reason = .protocolViolation
        } catch {
            reason = .transportError
        }
        connectionEnded(current, reason: reason)
    }

    /// Returns a disconnect reason when the frame ends the session.
    private func process(_ frame: LinkFrame, on current: LinkConnection) throws -> ClusterLinkControlDisconnect? {
        var decoded: (ClusterLinkControlMessage?, UInt16, Data)?
        if frame.kind.isSequenced {
            let verdict = state.withLock { inbox.verdict(for: frame.messageID) }
            if verdict == .deliver {
                if frame.kind == .message {
                    let message: ClusterLinkControlMessage
                    do { message = try JSONDecoder().decode(ClusterLinkControlMessage.self, from: frame.body) } catch {
                        throw ClusterLinkControlError.invalidMessage
                    }
                    try message.validate(maximumPromptTokens: edge.limits.maximumPromptTokens)
                    if let epoch = message.epoch, epoch != edge.epoch { throw ClusterLinkControlError.wrongEpoch }
                    decoded = (message, 0, Data())
                } else {
                    decoded = (nil, frame.body.clusterLinkUInt16(at: 0), frame.body.subdata(in: (frame.body.startIndex + 2)..<frame.body.endIndex))
                }
            }
        }
        var deliverNow = false
        var replyPong = false
        var ackNow = false
        var completed: PingWaiter?
        var goodbye: LinkGoodbyeReason?
        try state.withLock {
            guard connection === current else { return } // superseded: drop silently
            if frame.ackThrough > 0 || frame.kind == .ack {
                let removed = try outbox.acknowledge(through: frame.ackThrough)
                if removed > 0 { state.broadcast() }
            }
            switch frame.kind {
            case .heartbeat, .ack: break
            case .ping: replyPong = true
            case .pong:
                let token = frame.body.clusterLinkUInt64(at: 0)
                let sentAt = frame.body.clusterLinkUInt64(at: 8)
                if let waiter = pingWaiters[token] {
                    waiter.channelNanoseconds = linkNow() &- sentAt
                    completed = waiter
                }
            case .goodbye:
                goodbye = LinkGoodbyeReason(rawValue: frame.body[frame.body.startIndex]) ?? .shutdown
            case .message, .opaque:
                switch inbox.verdict(for: frame.messageID) {
                case .gap: throw ClusterLinkControlError.protocolViolation
                case .duplicate: duplicates += 1
                case .deliver:
                    guard decoded != nil else { throw ClusterLinkControlError.protocolViolation }
                    inbox.markDelivered(frame.messageID)
                    deliveredMessages += 1
                    deliverNow = true
                    deliveredSinceAck += 1
                    if deliveredSinceAck >= 32 { ackNow = true }
                    if pendingAckDeadline == nil {
                        pendingAckDeadline = linkNow() &+ edge.limits.acknowledgementDelay.clusterLinkNanoseconds
                        state.broadcast()
                    }
                }
            }
        }
        completed?.semaphore.signal()
        if replyPong {
            let echo = frame.body.prefix(LinkFrame.pingBodyBytes)
            if !tryWriteControl(kind: .pong, body: Data(echo), on: current) {
                state.withLock { deferredPongs.append(Data(echo)); state.broadcast() }
            }
        }
        if ackNow, !tryWriteControl(kind: .ack, body: Data(), on: current) {
            state.withLock { pendingAckDeadline = linkNow(); state.broadcast() }
        }
        if deliverNow, let decoded {
            if let message = decoded.0 {
                deliver(.message(edgeID: edgeID, id: frame.messageID, message))
            } else {
                deliver(.opaque(edgeID: edgeID, id: frame.messageID, tag: decoded.1, decoded.2))
            }
        }
        if let goodbye {
            switch goodbye {
            case .rekey: return .rekey
            case .superseded: return .superseded
            case .protocolViolation: return .protocolViolation
            case .shutdown: return .peerClosed
            }
        }
        return nil
    }

    /// Reader thread, once per connection.
    func connectionEnded(_ current: LinkConnection, reason: ClusterLinkControlDisconnect) {
        current.end(reason)
        writeLock.lock()
        let wasCurrent: Bool = state.withLock {
            let match = connection === current
            if match {
                connection = nil
                lastDisconnect = current.reason ?? reason
                failPingWaitersLocked()
                state.broadcast()
            }
            return match
        }
        current.records.invalidate()
        current.socket.close()
        current.markClosed()
        writeLock.unlock()
        if wasCurrent { enqueueLifecycle(.disconnected(edgeID: edgeID, reason: current.reason ?? reason)) }
        current.ended.signal()
    }

    private func failPingWaitersLocked() {
        for waiter in pingWaiters.values { waiter.semaphore.signal() }
    }

    /// Heartbeats while idle, delayed acknowledgements, deferred pongs.
    private func maintenanceLoop() {
        let heartbeat = edge.limits.heartbeatInterval.clusterLinkNanoseconds
        while true {
            state.lock()
            if closed { state.unlock(); return }
            let now = linkNow()
            var deadline = UInt64.max
            if let current = connection, current.isOpen {
                deadline = min(deadline, lastSentAt &+ heartbeat)
                if let ack = pendingAckDeadline { deadline = min(deadline, ack) }
                if !deferredPongs.isEmpty { deadline = now }
            }
            if deadline > now {
                if deadline == UInt64.max { state.wait() } else {
                    _ = state.wait(until: Date(timeIntervalSinceNow: Double(deadline - now) / 1e9))
                }
                state.unlock()
                continue
            }
            let current = connection
            let pongs = deferredPongs; deferredPongs.removeAll()
            let ackDue = pendingAckDeadline.map { $0 <= now } ?? false
            let heartbeatDue = now &- lastSentAt >= heartbeat
            state.unlock()
            guard let current, current.isOpen else { continue }
            writeLock.lock()
            do {
                for pong in pongs { try writeFrame(kind: .pong, id: 0, body: pong, on: current) }
                let stillDue = state.withLock { pendingAckDeadline != nil }
                if ackDue, stillDue { try writeFrame(kind: .ack, id: 0, body: Data(), on: current) }
                let idle = state.withLock { linkNow() &- lastSentAt >= heartbeat }
                if heartbeatDue, idle { try writeFrame(kind: .heartbeat, id: 0, body: Data(), on: current) }
            } catch {
                current.end(error is ClusterLinkRollover ? .rekey : .transportError)
            }
            writeLock.unlock()
        }
    }

    /// Rare events (connect, disconnect, restart): queued without a slot.
    private func enqueueLifecycle(_ event: ClusterLinkControlEvent) {
        deliveryQueue.async { [handler] in handler(event, self) }
    }

    private func deliver(_ event: ClusterLinkControlEvent) {
        deliverySlots.wait()
        deliveryQueue.async { [handler, deliverySlots] in
            handler(event, self)
            deliverySlots.signal()
        }
    }

    /// Ends the session with a goodbye and stops the edge for good.
    func close() {
        writeLock.lock()
        let current: LinkConnection? = state.withLock {
            closed = true
            failPingWaitersLocked()
            state.broadcast()
            return connection
        }
        if let current, current.isOpen {
            try? current.write(LinkFrame(kind: .goodbye, messageID: 0, ackThrough: 0,
                body: Data([LinkGoodbyeReason.shutdown.rawValue])), deadline: linkNow() &+ 200_000_000)
        }
        writeLock.unlock()
        current?.end(.localShutdown)
    }
}

struct ClusterLinkRollover: Error {}
