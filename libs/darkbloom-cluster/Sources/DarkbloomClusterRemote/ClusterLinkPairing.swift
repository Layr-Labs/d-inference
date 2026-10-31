import CryptoKit
import Darwin
import DarkbloomClusterSecurity
import Foundation

/// Runs one pairing ceremony (PROD-PLAN S17) over the link control channel.
///
/// Before pairing, the two Macs share no key, so the ceremony's own edge is
/// keyed by a fixed, public label: the channel gives it framing, ordered and
/// acknowledged delivery, the Thunderbolt-only interface policy and the
/// listener's DoS-safe admission, and nothing else. Every value it carries is
/// public; authenticity comes from the code both people compare and from the
/// Secure Enclave signatures, and the edge secret both Macs key their later
/// link control channel with comes out of the X25519 agreement inside the
/// ceremony and never crosses the cable.
///
/// The listener runs inside the provider binary (as the link control host
/// does), so macOS asks about it at most once, for the binary the owner
/// already approved. The connector only dials.
public enum ClusterLinkPairing {
    public static let defaultPort: UInt16 = 47_421
    static let messageTag: UInt16 = 0x5031
    static let bootstrapEpoch = UUID(uuidString: "d4a2c81e-5b7f-4c3a-9e61-0f2b8a7d3c11")!
    static let bootstrapEdge = UUID(uuidString: "7e19b0c4-2d86-4f5e-a3b8-61c9d0e4f2a7")!
    static let bootstrapLabel = Data("darkbloom/cluster-pairing/bootstrap-edge/v1 (public)".utf8)

    /// The ceremony edge's key: a public value, see above.
    static func bootstrapKey() throws -> ClusterLinkControlKey {
        try ClusterLinkControlKey.qualification(secret: Data(SHA256.hash(data: bootstrapLabel)), epoch: bootstrapEpoch,
            edgeID: bootstrapEdge)
    }

    public struct Options: Sendable {
        public var role: ClusterPairingRole
        public var interface: String
        public var localAddress: ClusterLinkIPv4Address?
        /// Connector: the listener's address on the link. Listener: nil (any source on the interface).
        public var peerAddress: ClusterLinkIPv4Address?
        public var port: UInt16 = ClusterLinkPairing.defaultPort
        public var policy: ClusterLinkInterfacePolicy = .thunderboltOnly
        /// From the start of the run to the second confirmation.
        public var lifetimeSeconds: Double = ClusterPairingPolicy.codeLifetimeSeconds
        public var limits: ClusterLinkControlLimits
        /// Finding each other without an address (ClusterLinkPairingDiscovery).
        public var discovery: Discovery = .off
        /// `.find`: how long this Mac looks for a listening Mac before it listens itself.
        public var searchSeconds: Double = 2.5

        public enum Discovery: Sendable, Equatable {
            /// Only the address given (the connector) or nothing (the listener).
            case off
            /// A listener also answers probes, so the other Mac needs no address.
            case answer
            /// No address given: dial the Mac that answers a probe; when none
            /// does, listen (answering probes). If both Macs end up listening,
            /// the one with the lower address stops and dials the other.
            case find
        }

        public init(role: ClusterPairingRole, interface: String, localAddress: ClusterLinkIPv4Address? = nil,
                    peerAddress: ClusterLinkIPv4Address? = nil) {
            self.role = role; self.interface = interface; self.localAddress = localAddress; self.peerAddress = peerAddress
            var limits = ClusterLinkControlLimits()
            limits.maximumBodyBytes = 64 * 1024
            limits.maximumUnacknowledgedBytes = 1 << 20
            limits.maximumUnacknowledgedMessages = 64
            limits.maximumPendingEvents = 64
            limits.handshakeTimeout = .seconds(5)
            limits.connectTimeout = .seconds(3)
            self.limits = limits
        }
    }

    /// How the run talks to the person at this Mac. Every callback may come
    /// from any thread; `respond` may be called from any thread, once.
    public struct Callbacks: Sendable {
        public var progress: @Sendable (Progress) -> Void
        public var askConfirmation: @Sendable (_ code: String, _ peer: ClusterPairingPeer,
                                               _ respond: @escaping @Sendable (Bool) -> Void) -> Void
        public var peerDecided: @Sendable (_ accepted: Bool) -> Void

        public init(progress: @escaping @Sendable (Progress) -> Void = { _ in },
                    askConfirmation: @escaping @Sendable (String, ClusterPairingPeer, @escaping @Sendable (Bool) -> Void) -> Void,
                    peerDecided: @escaping @Sendable (Bool) -> Void = { _ in }) {
            self.progress = progress; self.askConfirmation = askConfirmation; self.peerDecided = peerDecided
        }
    }

    public enum Progress: Sendable, Equatable {
        /// Looking for a listening Mac on this interface (discovery `.find`).
        case searching(interface: String)
        /// Listener: bound; the interface and port to give the other Mac.
        case listening(interface: String, port: UInt16)
        case dialing
        case connected
        /// A refused connection or dial, by kind (no address).
        case refused(String)
        case storing
    }

    /// A stored pairing.
    public struct Result: Sendable {
        public let outcome: ClusterPairingOutcome
        public let record: ClusterPairingRecord
        public let store: URL
    }

    /// Runs until the ceremony completes, fails or expires. The store holds
    /// the result (or, after any failure, exactly what it held before).
    public static func run(options: Options, participant: ClusterPairingParticipant, hooks: ClusterPairingHooks,
                           store: ClusterPairingStore, callbacks: Callbacks,
                           inspector: any ClusterLinkInterfaceInspecting = ClusterLinkSystemInterfaceInspector())
        -> Swift.Result<Result, ClusterPairingError> {
        do { try store.checkGate() } catch let error as ClusterPairingError { return .failure(error) } catch { return .failure(.persistenceFailed) }
        if options.discovery == .find, options.peerAddress == nil {
            return runFinding(options: options, participant: participant, hooks: hooks, store: store, callbacks: callbacks,
                              inspector: inspector)
        }
        if options.role == .connector, options.peerAddress == nil { return .failure(.transport) }
        let driver = Driver(options: options, participant: participant, hooks: hooks, store: store, callbacks: callbacks)
        return driver.run(inspector: inspector)
    }

    /// Discovery `.find` with no address: dial the one Mac that answers, else
    /// listen; a listener that hears a listener with a lower address stops
    /// before any code is shown and dials it instead.
    static func runFinding(options: Options, participant: ClusterPairingParticipant, hooks: ClusterPairingHooks,
                           store: ClusterPairingStore, callbacks: Callbacks,
                           inspector: any ClusterLinkInterfaceInspecting) -> Swift.Result<Result, ClusterPairingError> {
        let selection: ClusterLinkInterfaceSelection
        do {
            selection = try ClusterLinkInterfaceAdmission.select(interface: options.interface, localAddress: options.localAddress,
                peerAddress: nil, policy: options.policy, inspector: inspector)
        } catch {
            store.audit("ceremony_failed", ["reason": "listen_refused"])
            callbacks.progress(.refused((error as? ClusterLinkInterfaceRefusal).map { "\($0)" } ?? "interfaceRefused"))
            return .failure(.transport)
        }
        let started = DispatchTime.now().uptimeNanoseconds
        func remaining() -> Double { options.lifetimeSeconds - Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9 }
        func dial(_ found: ClusterLinkPairingDiscovery.Found) -> Swift.Result<Result, ClusterPairingError> {
            var connector = options
            connector.role = .connector
            connector.peerAddress = found.address
            connector.port = found.port
            connector.discovery = .off
            connector.lifetimeSeconds = max(1, remaining())
            store.audit("listener_found", ["interface": selection.interface])
            return Driver(options: connector, participant: participant, hooks: hooks, store: store, callbacks: callbacks)
                .run(inspector: inspector)
        }
        callbacks.progress(.searching(interface: selection.interface))
        let found = ClusterLinkPairingDiscovery.find(selection: selection, port: options.port,
                                                     seconds: min(options.searchSeconds, max(0, remaining())))
        if found.count > 1 {
            store.audit("ceremony_failed", ["reason": "several_listeners"])
            callbacks.progress(.refused("severalListeners"))
            return .failure(.transport)
        }
        if let only = found.first { return dial(only) }
        var listener = options
        listener.role = .listener
        listener.peerAddress = nil
        listener.localAddress = selection.local.address
        listener.lifetimeSeconds = max(1, remaining())
        let driver = Driver(options: listener, participant: participant, hooks: hooks, store: store, callbacks: callbacks)
        let result = driver.run(inspector: inspector)
        if let other = driver.yieldedTo { return dial(other) }
        return result
    }

    /// One run: the channel endpoint, the session, the timers. Every session
    /// step runs on `queue`, in order.
    final class Driver: @unchecked Sendable {
        let options: Options
        let participant: ClusterPairingParticipant
        let hooks: ClusterPairingHooks
        let store: ClusterPairingStore
        let callbacks: Callbacks
        let queue = DispatchQueue(label: "darkbloom.cluster-pairing")
        let finished = DispatchSemaphore(value: 0)
        // Owned by `queue`.
        var session: ClusterPairingSession?
        var peer: ClusterLinkControlPeer?
        var commit: ClusterPairingStore.Commit?
        var result: Swift.Result<Result, ClusterPairingError>?
        var offers = ClusterPairingOfferBucket()
        var askedPerson = false
        /// Discovery `.find`: the listener with a lower address this one stopped for.
        var yieldedTo: ClusterLinkPairingDiscovery.Found?
        var responder: ClusterLinkPairingDiscovery.Responder?

        init(options: Options, participant: ClusterPairingParticipant, hooks: ClusterPairingHooks, store: ClusterPairingStore,
             callbacks: Callbacks) {
            self.options = options; self.participant = participant; self.hooks = hooks; self.store = store; self.callbacks = callbacks
        }

        func run(inspector: any ClusterLinkInterfaceInspecting) -> Swift.Result<Result, ClusterPairingError> {
            let edge: ClusterLinkControlEdge
            do {
                edge = try ClusterLinkControlEdge(edgeID: bootstrapEdge, epoch: bootstrapEpoch, key: try bootstrapKey(),
                    peerAddress: options.role == .connector ? options.peerAddress : nil, limits: options.limits)
            } catch { return .failure(.transport) }
            let handler: ClusterLinkControlEventHandler = { [weak self] event, peer in self?.event(event, peer) }
            var listener: ClusterLinkControlListener?
            var client: ClusterLinkControlClient?
            store.audit("ceremony_started", ["role": options.role.rawValue, "interface": options.interface])
            switch options.role {
            case .listener:
                do {
                    let created = try ClusterLinkControlListener(configuration: .init(interface: options.interface,
                        localAddress: options.localAddress, port: options.port, policy: options.policy, edges: [edge]),
                        inspector: inspector, handler: handler)
                    let port = try created.start()
                    listener = created
                    queue.sync { peer = created.peer(for: bootstrapEdge) }
                    callbacks.progress(.listening(interface: created.selection?.interface ?? options.interface, port: port))
                    if options.discovery != .off, let selection = created.selection { startResponder(selection, tcpPort: port) }
                } catch {
                    store.audit("ceremony_failed", ["reason": "listen_refused"])
                    callbacks.progress(.refused((error as? ClusterLinkInterfaceRefusal).map { "\($0)" } ?? "bindFailed"))
                    return .failure(.transport)
                }
            case .connector:
                do {
                    let created = try ClusterLinkControlClient(configuration: .init(interface: options.interface,
                        localAddress: options.localAddress, port: options.port, policy: options.policy, edge: edge),
                        inspector: inspector, handler: handler)
                    client = created
                    queue.sync { peer = created.peer }
                    callbacks.progress(.dialing)
                    created.start()
                } catch {
                    store.audit("ceremony_failed", ["reason": "dial_refused"])
                    return .failure(.transport)
                }
            }
            queue.asyncAfter(deadline: .now() + options.lifetimeSeconds) { [self] in
                guard result == nil else { return }
                if session != nil { drive { $0.fail(.expired) } } else { finish(.failure(.expired)) }
            }
            finished.wait()
            // Let the last message (committed or abort) reach the other Mac before the channel closes.
            let last = queue.sync { peer }
            try? last?.waitUntilAcknowledged(timeout: .seconds(3))
            responder?.stop()
            listener?.stop()
            client?.stop()
            return queue.sync { result ?? .failure(.transport) }
        }

        /// Answers probes while listening (best effort: a listener whose
        /// responder cannot open still pairs with a typed address). With
        /// `.find`, two listeners that hear each other: the higher address
        /// keeps listening, the lower one stops (before any code) and dials.
        private func startResponder(_ selection: ClusterLinkInterfaceSelection, tcpPort: UInt16) {
            let local = selection.local.address
            let created = ClusterLinkPairingDiscovery.Responder(selection: selection, udpPort: options.port, tcpPort: tcpPort,
                announce: options.discovery == .find) { [weak self] other in
                guard let self, ClusterLinkPairingDiscovery.shouldYield(local: local, other: other.address) else { return }
                self.queue.async {
                    guard self.result == nil, self.session == nil, !self.askedPerson else { return }
                    self.yieldedTo = other
                    self.store.audit("yielded_to_listener", ["interface": selection.interface])
                    self.finish(.failure(.transport))
                }
            }
            do { try created.start(); responder = created } catch {
                store.audit("discovery_unavailable", ["interface": selection.interface])
            }
        }

        // MARK: Channel events (any thread) -> queue

        private func event(_ event: ClusterLinkControlEvent, _ eventPeer: ClusterLinkControlPeer?) {
            queue.async { [self] in
                guard result == nil else { return }
                switch event {
                case .connected:
                    callbacks.progress(.connected)
                    if options.role == .connector, session == nil { startConnector() }
                case .peerRestarted:
                    // A new process at the other end: what it had sent is gone. Once this Mac stored the
                    // pairing it waits for the tagged `committed` (or the commit wait) instead: a connection
                    // anyone on the link can open must not undo it.
                    guard let current = session, !current.isFinished, !current.hasPersisted else { return }
                    if options.role == .listener, !current.codeShown { session = nil } else { drive { $0.fail(.peerAborted) } }
                case .disconnected(_, let reason):
                    if reason == .peerClosed, let current = session, !current.isFinished, !current.hasPersisted { drive { $0.fail(.transport) } }
                case .refused(_, let reason):
                    callbacks.progress(.refused("\(reason)"))
                case .opaque(_, _, let tag, let bytes):
                    guard tag == messageTag else { return }
                    received(bytes)
                case .message:
                    break
                }
            }
        }

        /// Runs one session transition and carries out its steps. Steps may
        /// drive further transitions; each sees the session as just updated.
        private func drive(_ transition: (inout ClusterPairingSession) -> [ClusterPairingStep]) {
            guard var current = session else { return }
            let steps = transition(&current)
            session = current
            apply(steps)
        }

        private func startConnector() {
            do {
                session = try ClusterPairingSession(role: .connector, participant: participant, hooks: hooks)
                drive { $0.start() }
            } catch { finish(.failure(.identityUnavailable)) }
        }

        private func received(_ bytes: Data) {
            let message: ClusterPairingMessage
            do { message = try ClusterPairingMessage.decode(bytes) } catch {
                if session != nil { drive { $0.fail(.malformedMessage) } }
                return
            }
            if options.role == .listener, message.kind == .offer {
                admitOffer(message)
                return
            }
            drive { $0.receive(message) }
        }

        /// Listener: one ceremony at a time, a rate limit, and the lockout.
        private func admitOffer(_ message: ClusterPairingMessage) {
            func refuse(_ error: ClusterPairingError, retryAfter: Double? = nil) {
                var refusal = ClusterPairingMessage(kind: .refused)
                refusal.reason = error.wireReason
                refusal.retryAfterEpochSeconds = retryAfter
                send(refusal)
                store.audit("offer_refused", ["reason": error.wireReason])
            }
            if let current = session, current.codeShown, !current.isFinished { refuse(.busy); return }
            do { try store.checkGate() } catch let ClusterPairingError.lockedOut(until) {
                refuse(.lockedOut(untilEpochSeconds: until), retryAfter: until); return
            } catch { refuse(.busy); return }
            guard offers.allow(nowNanoseconds: DispatchTime.now().uptimeNanoseconds) else { refuse(.rateLimited); return }
            do {
                session = try ClusterPairingSession(role: .listener, participant: participant, hooks: hooks)
                store.audit("offer_received", ["peer_pin": String((message.identityKey.map(ClusterPairingPin.of) ?? "").prefix(16))])
                drive { $0.receive(message) }
            } catch { finish(.failure(.identityUnavailable)) }
        }

        // MARK: Steps (queue)

        private func apply(_ steps: [ClusterPairingStep]) {
            for step in steps {
                guard result == nil else { return }
                switch step {
                case .send(let message):
                    send(message)
                case .showCode(let code, let peerInfo):
                    askedPerson = true
                    store.audit("code_shown", ["peer_pin": String(peerInfo.pin.prefix(16))])
                    callbacks.askConfirmation(code, peerInfo) { [weak self] accept in
                        guard let self else { return }
                        self.queue.async {
                            guard self.result == nil, self.session != nil else { return }
                            self.store.audit(accept ? "confirmed_here" : "declined_here", [:])
                            self.drive { $0.decide(accept: accept) }
                        }
                    }
                case .peerDecided(let accepted):
                    store.audit(accepted ? "confirmed_there" : "declined_there", [:])
                    callbacks.peerDecided(accepted)
                case .persist(let outcome):
                    callbacks.progress(.storing)
                    let edgeID = ClusterLinkControlEdge.derivedEdgeID(firstMember: outcome.localPin, firstInterface: outcome.localInterface,
                        secondMember: outcome.peer.pin, secondInterface: outcome.peer.interface)
                    let stored: Bool
                    do { commit = try store.commit(outcome, edgeID: edgeID); stored = true } catch { stored = false }
                    drive { $0.localPersisted(stored) }
                    if stored, result == nil {
                        queue.asyncAfter(deadline: .now() + ClusterPairingPolicy.commitWaitSeconds) { [self] in
                            guard result == nil, session != nil else { return }
                            drive { $0.fail(.transport) }
                        }
                    }
                case .rollback:
                    if let commit { store.rollback(commit) }
                    commit = nil
                case .completed(let outcome):
                    store.recordSuccess()
                    store.audit("pair_completed", ["peer_pin": String(outcome.peer.pin.prefix(16)), "cluster": outcome.clusterID,
                                                   "generation": String(outcome.generation)])
                    guard let loaded = try? store.load(), let record = loaded.pairing(peerPin: outcome.peer.pin) else {
                        finish(.failure(.persistenceFailed)); return
                    }
                    finish(.success(Result(outcome: outcome, record: record, store: store.directory)))
                case .failed(let error):
                    if error.countsAsFailedAttempt { store.recordFailure(error) }
                    else { store.audit("ceremony_failed", ["reason": error.wireReason]) }
                    // A listener whose offer failed before the code was shown keeps listening.
                    if options.role == .listener, !askedPerson, !error.countsAsFailedAttempt, error != .identityUnavailable {
                        session = nil
                        continue
                    }
                    finish(.failure(error))
                }
            }
        }

        private func send(_ message: ClusterPairingMessage) {
            guard let peer, let bytes = try? message.encoded() else { return }
            _ = try? peer.sendOpaque(tag: messageTag, bytes, timeout: .seconds(5))
        }

        private func finish(_ value: Swift.Result<Result, ClusterPairingError>) {
            guard result == nil else { return }
            result = value
            finished.signal()
        }
    }
}

extension ClusterLinkPairing {
    /// The link interface to pair over when none is named: the one interface
    /// with IPv4 that the Thunderbolt-only policy admits (and, for a
    /// connector, whose subnet holds the listener's address). Nil when there
    /// is none or more than one; the command then asks for `--interface`.
    public static func automaticInterface(reaching peer: ClusterLinkIPv4Address? = nil,
                                          inspector: any ClusterLinkInterfaceInspecting = ClusterLinkSystemInterfaceInspector()) -> String? {
        var names = Set<String>()
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            if let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) {
                names.insert(String(cString: entry.pointee.ifa_name))
            }
            cursor = entry.pointee.ifa_next
        }
        let admitted = names.sorted().filter { name in
            (try? ClusterLinkInterfaceAdmission.select(interface: name, localAddress: nil, peerAddress: peer,
                                                       policy: .thunderboltOnly, inspector: inspector)) != nil
        }
        return admitted.count == 1 ? admitted[0] : nil
    }
}
