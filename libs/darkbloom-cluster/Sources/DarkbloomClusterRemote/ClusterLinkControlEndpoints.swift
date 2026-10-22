import Darwin
import DarkbloomClusterSecurity
import Foundation

/// Accepts link control sessions on one interface address for a fixed set of
/// edges. Admission is DoS-safe: sources outside the configured peers are
/// closed before a byte is read; at most `maximumPendingHandshakes`
/// unauthenticated connections exist at once (the oldest is evicted for a
/// new one); each must authenticate within the handshake timeout with
/// fixed-size records; an authenticated session supersedes the edge's previous
/// one (one live peer per edge); unauthenticated input never touches a live
/// session.
public final class ClusterLinkControlListener: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var interface: String
        /// Nil picks the interface's preferred address (see `ClusterLinkInterfaceAdmission`).
        public var localAddress: ClusterLinkIPv4Address?
        public var port: UInt16
        public var policy: ClusterLinkInterfacePolicy
        public var edges: [ClusterLinkControlEdge]

        public init(interface: String, localAddress: ClusterLinkIPv4Address? = nil, port: UInt16,
                    policy: ClusterLinkInterfacePolicy = .thunderboltOnly, edges: [ClusterLinkControlEdge]) {
            self.interface = interface; self.localAddress = localAddress; self.port = port
            self.policy = policy; self.edges = edges
        }
    }

    public static let defaultPort: UInt16 = 47_420

    private let configuration: Configuration
    private let inspector: any ClusterLinkInterfaceInspecting
    private let handler: ClusterLinkControlEventHandler
    private let peers: [UUID: ClusterLinkControlPeer]
    private let allowedSources: Set<ClusterLinkIPv4Address>?
    private let maximumPending: Int
    private let handshakeTimeout: UInt64
    private let lock = NSLock()
    private var listening: LinkSocket?
    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1
    private var running = false
    private var pending: [UInt64: (socket: LinkSocket, started: UInt64)] = [:]
    private var nextPending: UInt64 = 1
    private var refusalCounts: [String: UInt64] = [:]
    private var acceptFinished: DispatchSemaphore?
    private let eventQueue = DispatchQueue(label: "darkbloom.link-control.listener-events")
    private var selectionStorage: ClusterLinkInterfaceSelection?
    /// The interface and address the listener bound, once started.
    public var selection: ClusterLinkInterfaceSelection? { lock.withLock { selectionStorage } }
    private var boundPortStorage: UInt16?
    /// The bound port once started.
    public var boundPort: UInt16? { lock.withLock { boundPortStorage } }

    public init(configuration: Configuration,
                inspector: any ClusterLinkInterfaceInspecting = ClusterLinkSystemInterfaceInspector(),
                handler: @escaping ClusterLinkControlEventHandler) throws {
        guard !configuration.edges.isEmpty,
              Set(configuration.edges.map(\.edgeID)).count == configuration.edges.count else {
            throw ClusterLinkControlError.invalidConfiguration
        }
        self.configuration = configuration; self.inspector = inspector; self.handler = handler
        var peers = [UUID: ClusterLinkControlPeer]()
        for edge in configuration.edges { peers[edge.edgeID] = ClusterLinkControlPeer(edge: edge, role: .listener, handler: handler) }
        self.peers = peers
        let addresses = configuration.edges.map(\.peerAddress)
        allowedSources = addresses.contains(where: { $0 == nil }) ? nil : Set(addresses.compactMap { $0 })
        maximumPending = configuration.edges.map(\.limits.maximumPendingHandshakes).min() ?? 8
        handshakeTimeout = configuration.edges.map(\.limits.handshakeTimeout.clusterLinkNanoseconds).min() ?? 2_000_000_000
    }

    deinit { stop() }

    public func peer(for edgeID: UUID) -> ClusterLinkControlPeer? { peers[edgeID] }

    /// Refusals so far, by reason, for diagnostics.
    public var refusals: [String: UInt64] { lock.withLock { refusalCounts } }

    /// Binds (after the interface policy admits the interface) and starts
    /// accepting. Returns the bound port.
    @discardableResult
    public func start() throws -> UInt16 {
        guard lock.withLock({ !running && listening == nil }) else { throw ClusterLinkControlError.invalidConfiguration }
        let selected = try ClusterLinkInterfaceAdmission.select(interface: configuration.interface,
            localAddress: configuration.localAddress, peerAddress: nil, policy: configuration.policy,
            inspector: inspector)
        if configuration.policy != .loopbackForTests {
            for case let peer? in configuration.edges.map(\.peerAddress) where !selected.local.contains(peer) {
                throw ClusterLinkInterfaceRefusal.peerNotOnLink
            }
        }
        let (socket, port) = try LinkSocket.listen(address: selected.local.address, port: configuration.port,
            interfaceIndex: selected.index, backlog: Int32(max(4, maximumPending)))
        var pipeEnds: [Int32] = [-1, -1]
        guard pipe(&pipeEnds) == 0 else { socket.close(); throw LinkSocketError.system(errno) }
        for end in pipeEnds { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        try? LinkSocket.setNonblocking(pipeEnds[0])
        let finished = DispatchSemaphore(value: 0)
        lock.withLock {
            listening = socket; wakeRead = pipeEnds[0]; wakeWrite = pipeEnds[1]
            running = true; selectionStorage = selected; acceptFinished = finished; boundPortStorage = port
        }
        let thread = Thread { [weak self] in
            self?.acceptLoop()
            finished.signal()
        }
        thread.name = "darkbloom.link-control.accept"
        thread.start()
        return port
    }

    /// Stops accepting, ends every session with a goodbye, waits for the
    /// accept thread (bounded).
    public func stop() {
        let state: (Int32, DispatchSemaphore?, [LinkSocket]) = lock.withLock {
            let wasRunning = running
            running = false
            let sockets = pending.values.map(\.socket)
            pending.removeAll()
            return (wasRunning ? wakeWrite : -1, acceptFinished, sockets)
        }
        if state.0 >= 0 { var byte: UInt8 = 1; _ = Darwin.write(state.0, &byte, 1) }
        for socket in state.2 { socket.shutdown() }
        _ = state.1?.wait(timeout: .now() + 2)
        lock.withLock {
            listening?.close(); listening = nil
            if wakeRead >= 0 { Darwin.close(wakeRead) }
            if wakeWrite >= 0 { Darwin.close(wakeWrite) }
            wakeRead = -1; wakeWrite = -1; acceptFinished = nil
        }
        for peer in peers.values { peer.close() }
    }

    private func acceptLoop() {
        guard let (socket, wake) = lock.withLock({ listening.map { ($0, wakeRead) } }) else { return }
        while lock.withLock({ running }) {
            var entries = [pollfd(fd: socket.fd, events: Int16(POLLIN), revents: 0),
                           pollfd(fd: wake, events: Int16(POLLIN), revents: 0)]
            let ready = poll(&entries, 2, -1)
            if ready < 0 { if errno == EINTR { continue }; return }
            if entries[1].revents != 0 { return }
            while true {
                let accepted: (LinkSocket, ClusterLinkIPv4Address)?
                do { accepted = try socket.accept() } catch { break }
                guard let (connection, source) = accepted else { break }
                admit(connection, source: source)
            }
        }
    }

    private func admit(_ connection: LinkSocket, source: ClusterLinkIPv4Address) {
        if let allowedSources, !allowedSources.contains(source) {
            connection.close()
            refuse(.unexpectedSource, edge: nil)
            return
        }
        var evicted: LinkSocket?
        let id: UInt64? = lock.withLock {
            guard running else { return nil }
            if pending.count >= maximumPending, let oldest = pending.min(by: { $0.value.started < $1.value.started }) {
                evicted = oldest.value.socket
                pending.removeValue(forKey: oldest.key)
            }
            let id = nextPending; nextPending += 1
            pending[id] = (connection, linkNow())
            return id
        }
        if let evicted { evicted.shutdown(); refuse(.evictedPendingHandshake, edge: nil) }
        guard let id else { connection.close(); return }
        let thread = Thread { [weak self] in
            guard let self else { connection.close(); return }
            self.handshake(id: id, connection: connection, source: source)
        }
        thread.name = "darkbloom.link-control.handshake"
        thread.start()
    }

    private func handshake(id: UInt64, connection: LinkSocket, source: ClusterLinkIPv4Address) {
        defer { lock.withLock { _ = pending.removeValue(forKey: id) } }
        let deadline = linkNow() &+ handshakeTimeout
        var edgeID: UUID?
        do {
            let challenge = LinkHandshake.challenge(nonce: LinkHandshake.randomNonce())
            try connection.writeAll(challenge, deadline: deadline)
            // Exact-size read: nothing beyond the hello is consumed here.
            let reader = LinkReader(socket: connection, capacity: 128)
            let helloBytes = try reader.readExact(LinkHandshake.helloBytes, deadline: deadline)
            let (hello, tag) = try LinkHandshake.parseHello(helloBytes)
            edgeID = hello.edgeID
            guard let peer = peers[hello.edgeID] else { throw ClusterLinkControlRefusal.unknownEdge }
            guard hello.epoch == peer.edge.epoch else { throw ClusterLinkControlRefusal.wrongEpoch }
            if let expected = peer.edge.peerAddress, expected != source { throw ClusterLinkControlRefusal.unexpectedSource }
            let limits = try peer.edge.limits.recordLimits()
            guard hello.maximumPlaintextBytes == UInt32(limits.maximumPlaintextBytes),
                  hello.maximumRecords == limits.maximumRecordsPerDirection,
                  hello.maximumCumulativeBytes == limits.maximumCumulativePlaintextBytesPerDirection else {
                throw ClusterLinkControlRefusal.limitsMismatch
            }
            var signed = challenge; signed.append(helloBytes.prefix(LinkHandshake.helloBytes - 32))
            guard peer.edge.key.isValidHandshakeTag(tag, role: .connector, transcript: signed) else {
                throw ClusterLinkControlRefusal.authenticationFailed
            }
            var accept = LinkHandshake.acceptWithoutTag(peer.resumeInfo())
            var covered = challenge; covered.append(helloBytes); covered.append(accept)
            accept.append(peer.edge.key.handshakeTag(role: .listener, transcript: covered))
            try connection.writeAll(accept, deadline: deadline)
            let transcript = LinkHandshake.transcriptSHA256(challenge: challenge, hello: helloBytes, accept: accept)
            let records = try LinkRecordPair(role: .listener, key: peer.edge.key, transcriptSHA256: transcript,
                epoch: peer.edge.epoch, edgeID: peer.edgeID, limits: limits)
            guard lock.withLock({ running && pending[id] != nil }) else { throw ClusterLinkControlRefusal.evictedPendingHandshake }
            lock.withLock { _ = pending.removeValue(forKey: id) }
            peer.attach(LinkConnection(socket: connection, records: records, peerIncarnation: hello.resume.incarnation,
                limits: peer.edge.limits), peer: hello.resume)
        } catch let refusal as ClusterLinkControlRefusal {
            connection.close(); refuse(refusal, edge: edgeID)
        } catch LinkSocketError.timedOut {
            connection.close(); refuse(.handshakeTimeout, edge: edgeID)
        } catch ClusterLinkControlError.malformedHandshake {
            connection.close(); refuse(.malformedHandshake, edge: edgeID)
        } catch {
            connection.close(); refuse(.handshakeRejected, edge: edgeID)
        }
    }

    private func refuse(_ reason: ClusterLinkControlRefusal, edge: UUID?) {
        let key = String(describing: reason)
        let count: UInt64 = lock.withLock {
            refusalCounts[key, default: 0] += 1
            return refusalCounts[key]!
        }
        // 1, 2, 4, 8, ...: a flood cannot flood the event handler.
        guard count & (count - 1) == 0 else { return }
        eventQueue.async { [handler] in handler(.refused(edgeID: edge, reason: reason), nil) }
    }
}

extension ClusterLinkControlRefusal: Error {}

/// Dials one edge's listener and keeps the session up: reconnects with
/// exponential backoff (immediately after a rekey or supersede), resuming the
/// reliable stream on the same peer object.
public final class ClusterLinkControlClient: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var interface: String
        public var localAddress: ClusterLinkIPv4Address?
        public var port: UInt16
        public var policy: ClusterLinkInterfacePolicy
        public var edge: ClusterLinkControlEdge

        public init(interface: String, localAddress: ClusterLinkIPv4Address? = nil, port: UInt16,
                    policy: ClusterLinkInterfacePolicy = .thunderboltOnly, edge: ClusterLinkControlEdge) {
            self.interface = interface; self.localAddress = localAddress; self.port = port
            self.policy = policy; self.edge = edge
        }
    }

    public let peer: ClusterLinkControlPeer
    private let configuration: Configuration
    private let target: ClusterLinkIPv4Address
    private let inspector: any ClusterLinkInterfaceInspecting
    private let handler: ClusterLinkControlEventHandler
    private let lock = NSLock()
    private var running = false
    private var lastRefusalValue: ClusterLinkControlRefusal?
    private var connectAttempts: UInt64 = 0
    private var connectFailure: String?
    private let wake = DispatchSemaphore(value: 0)
    private var finished: DispatchSemaphore?
    private let eventQueue = DispatchQueue(label: "darkbloom.link-control.client-events")

    public init(configuration: Configuration,
                inspector: any ClusterLinkInterfaceInspecting = ClusterLinkSystemInterfaceInspector(),
                handler: @escaping ClusterLinkControlEventHandler) throws {
        guard let target = configuration.edge.peerAddress else { throw ClusterLinkControlError.invalidConfiguration }
        self.configuration = configuration; self.target = target; self.inspector = inspector; self.handler = handler
        peer = ClusterLinkControlPeer(edge: configuration.edge, role: .connector, handler: handler)
    }

    deinit { stop() }

    public var lastRefusal: ClusterLinkControlRefusal? { lock.withLock { lastRefusalValue } }
    public var attempts: UInt64 { lock.withLock { connectAttempts } }
    /// Why the last dial failed, by kind: `timedOut` (no answer: a firewall
    /// that drops, or no route), `refused` (nothing listening), `unreachable`
    /// (EHOSTUNREACH: the owner's oMLX lesson reads this, on every attempt
    /// while another process gets through, as a Local Network denial), or an
    /// errno. Nil after a successful dial.
    public var lastConnectFailure: String? { lock.withLock { connectFailure } }

    public func start() {
        let done = DispatchSemaphore(value: 0)
        let begin: Bool = lock.withLock {
            guard !running else { return false }
            running = true; finished = done
            return true
        }
        guard begin else { return }
        let thread = Thread { [weak self] in
            self?.connectLoop()
            done.signal()
        }
        thread.name = "darkbloom.link-control.connect"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Ends the session with a goodbye and stops reconnecting.
    public func stop() {
        let done: DispatchSemaphore? = lock.withLock {
            guard running else { return nil }
            running = false
            return finished
        }
        wake.signal()
        peer.close()
        _ = done?.wait(timeout: .now() + 3)
    }

    private var isRunning: Bool { lock.withLock { running } }

    private func connectLoop() {
        let limits = configuration.edge.limits
        let initial = limits.reconnectInitialDelay.clusterLinkNanoseconds
        let maximum = limits.reconnectMaximumDelay.clusterLinkNanoseconds
        var delay = initial
        while isRunning {
            var immediate = false
            do {
                let selected = try ClusterLinkInterfaceAdmission.select(interface: configuration.interface,
                    localAddress: configuration.localAddress, peerAddress: target, policy: configuration.policy,
                    inspector: inspector)
                lock.withLock { connectAttempts += 1 }
                let socket: LinkSocket
                do {
                    socket = try LinkSocket.connect(local: selected.local.address, peer: target, port: configuration.port,
                        interfaceIndex: selected.index, timeoutNanoseconds: limits.connectTimeout.clusterLinkNanoseconds)
                } catch {
                    let kind: String
                    switch error as? LinkSocketError {
                    case .timedOut?: kind = "timedOut"
                    case .system(ECONNREFUSED)?: kind = "refused"
                    case .system(EHOSTUNREACH)?: kind = "unreachable"
                    case .system(ENETUNREACH)?: kind = "networkUnreachable"
                    case .system(let code)?: kind = "errno \(code)"
                    default: kind = "other"
                    }
                    lock.withLock { connectFailure = kind }
                    throw ClusterLinkControlRefusal.connectFailed
                }
                lock.withLock { connectFailure = nil }
                let (connection, resume) = try handshake(socket)
                note(nil)
                if peer.attach(connection, peer: resume) {
                    let started = linkNow()
                    connection.ended.wait()
                    if linkNow() &- started > 1_000_000_000 { delay = initial }
                    if let reason = connection.reason, reason == .rekey || reason == .superseded { immediate = true }
                }
            } catch let refusal as ClusterLinkControlRefusal {
                note(refusal)
            } catch let refusal as ClusterLinkInterfaceRefusal {
                note(.interface(refusal))
            } catch {
                note(.handshakeRejected)
            }
            guard isRunning else { break }
            if immediate { continue }
            let jitter = UInt64.random(in: 0...(delay / 4 + 1))
            _ = wake.wait(timeout: .now() + .nanoseconds(Int(min(delay + jitter, 60_000_000_000))))
            delay = min(maximum, delay * 2)
        }
    }

    private func handshake(_ socket: LinkSocket) throws -> (LinkConnection, LinkHandshake.Resume) {
        let edge = configuration.edge
        let deadline = linkNow() &+ edge.limits.handshakeTimeout.clusterLinkNanoseconds
        do {
            let reader = LinkReader(socket: socket, capacity: 64)
            let challenge: Data
            do { challenge = try reader.readExact(LinkHandshake.challengeBytes, deadline: deadline) } catch {
                throw ClusterLinkControlRefusal.handshakeRejected
            }
            _ = try LinkHandshake.parseChallenge(challenge)
            let limits = try edge.limits.recordLimits()
            let hello = LinkHandshake.Hello(epoch: edge.epoch, edgeID: edge.edgeID, nonce: LinkHandshake.randomNonce(),
                resume: peer.resumeInfo(), maximumPlaintextBytes: UInt32(limits.maximumPlaintextBytes),
                maximumRecords: limits.maximumRecordsPerDirection,
                maximumCumulativeBytes: limits.maximumCumulativePlaintextBytesPerDirection)
            var helloBytes = LinkHandshake.helloWithoutTag(hello)
            var signed = challenge; signed.append(helloBytes)
            helloBytes.append(edge.key.handshakeTag(role: .connector, transcript: signed))
            try socket.writeAll(helloBytes, deadline: deadline)
            let acceptBytes: Data
            do { acceptBytes = try reader.readExact(LinkHandshake.acceptBytes, deadline: deadline) } catch {
                throw ClusterLinkControlRefusal.handshakeRejected
            }
            let (resume, tag) = try LinkHandshake.parseAccept(acceptBytes)
            var covered = challenge; covered.append(helloBytes); covered.append(acceptBytes.prefix(LinkHandshake.acceptBytes - 32))
            guard edge.key.isValidHandshakeTag(tag, role: .listener, transcript: covered) else {
                throw ClusterLinkControlRefusal.serverAuthenticationFailed
            }
            let transcript = LinkHandshake.transcriptSHA256(challenge: challenge, hello: helloBytes, accept: acceptBytes)
            let records = try LinkRecordPair(role: .connector, key: edge.key, transcriptSHA256: transcript,
                epoch: edge.epoch, edgeID: edge.edgeID, limits: limits)
            return (LinkConnection(socket: socket, records: records, peerIncarnation: resume.incarnation,
                limits: edge.limits), resume)
        } catch {
            socket.close()
            if error is ClusterLinkControlRefusal { throw error }
            if case ClusterLinkControlError.malformedHandshake = error { throw ClusterLinkControlRefusal.malformedHandshake }
            throw ClusterLinkControlRefusal.handshakeRejected
        }
    }

    /// Reports a refusal only when it changes, so an outage is one event.
    private func note(_ refusal: ClusterLinkControlRefusal?) {
        let changed: Bool = lock.withLock {
            defer { lastRefusalValue = refusal }
            return lastRefusalValue != refusal
        }
        guard changed, let refusal else { return }
        eventQueue.async { [handler, edgeID = configuration.edge.edgeID] in
            handler(.refused(edgeID: edgeID, reason: refusal), nil)
        }
    }
}
