import Darwin
import DarkbloomClusterSecurity
import Foundation

/// Qualification runs of the link control channel, shared by the check runner
/// and the provider's hidden `cluster link-channel` command. The secret comes
/// from standard input (one hex line), never from the command line; output
/// names interfaces and counts only, never addresses.
public enum ClusterLinkControlQualification {
    public struct Options: Sendable {
        public var interface: String
        public var localAddress: ClusterLinkIPv4Address?
        public var peerAddress: ClusterLinkIPv4Address?
        public var port: UInt16
        public var policy: ClusterLinkInterfacePolicy
        public var epoch: UUID
        public var edgeID: UUID
        public var limits = ClusterLinkControlLimits()
        /// Listener: maximum lifetime (it also ends when standard input closes).
        public var seconds: Double = 600
        public var probe = ClusterLinkControlProbe.Options()
        /// Probe: after measuring, keep sending one message every 10 ms for
        /// this long so a restart of the other end can be observed.
        public var resumeSeconds: Double = 0
        public var connectSeconds: Double = 20

        public init(interface: String, localAddress: ClusterLinkIPv4Address? = nil, peerAddress: ClusterLinkIPv4Address?,
                    port: UInt16, policy: ClusterLinkInterfacePolicy, epoch: UUID, edgeID: UUID) {
            self.interface = interface; self.localAddress = localAddress; self.peerAddress = peerAddress
            self.port = port; self.policy = policy; self.epoch = epoch; self.edgeID = edgeID
        }
    }

    public struct ListenSummary: Codable, Sendable {
        public var role = "listen"
        public var interface: String
        public var interfaceKind: String
        public var port: UInt16
        public var sessions: UInt64
        public var deliveredMessages: UInt64
        public var peerRestarts: UInt64
        public var refusals: [String: UInt64]
        public var bulkBytesReceived: Int
        public var events: [String]
    }

    public struct ProbeSummary: Codable, Sendable {
        public var role = "probe"
        public var interface: String
        public var interfaceKind: String
        public var connectMilliseconds: Double
        public var report: ClusterLinkControlProbe.Report?
        public var resume: ResumeSummary?
        public var events: [String]
        public var lastRefusal: String?
        public var connectFailure: String?
    }

    public struct ResumeSummary: Codable, Sendable {
        public var seconds: Double
        public var sent: Int
        public var sendFailures: Int
        public var disconnects: Int
        public var peerRestarts: UInt64
        public var sessions: UInt64
        /// Longest time from a disconnect to the next connected session.
        public var longestOutageMilliseconds: Double
        public var unacknowledgedAtEnd: Int
    }

    /// Reads the edge secret (one hex line) from standard input.
    public static func readSecret() throws -> Data {
        try ClusterLinkControlKey.readQualificationSecret(fromDescriptor: STDIN_FILENO)
    }

    public static func edge(options: Options, secret: Data) throws -> ClusterLinkControlEdge {
        let key = try ClusterLinkControlKey.qualification(secret: secret, epoch: options.epoch, edgeID: options.edgeID)
        return try ClusterLinkControlEdge(edgeID: options.edgeID, epoch: options.epoch, key: key,
            peerAddress: options.peerAddress, limits: options.limits)
    }

    /// Listens until standard input closes or `seconds` pass; prints one line
    /// per event and a JSON summary. `start` hosts the listener (the provider
    /// passes its own host so the listener lives in the provider process).
    public static func listen(options: Options, secret: Data, output: @escaping @Sendable (String) -> Void,
                              start: ((ClusterLinkControlListener.Configuration, @escaping ClusterLinkControlEventHandler) throws
                                      -> ClusterLinkControlListener)? = nil) throws -> ListenSummary {
        let probe = ClusterLinkControlProbe()
        let edge = try edge(options: options, secret: secret)
        let configuration = ClusterLinkControlListener.Configuration(interface: options.interface,
            localAddress: options.localAddress, port: options.port, policy: options.policy, edges: [edge])
        let handler: ClusterLinkControlEventHandler = { event, peer in
            probe.handle(event, peer: peer)
            if let line = describe(event) { output(line) }
        }
        let listener: ClusterLinkControlListener
        let port: UInt16
        if let start {
            listener = try start(configuration, handler)
            port = listener.boundPort ?? options.port
        } else {
            listener = try ClusterLinkControlListener(configuration: configuration, handler: handler)
            port = try listener.start()
        }
        output("PORT \(port)")
        output("LISTENING interface=\(options.interface) kind=\(listener.selection?.kind.rawValue ?? "?")")
        waitForStandardInputClose(seconds: options.seconds)
        let status = listener.peer(for: edge.edgeID)?.status
        let summary = ListenSummary(interface: options.interface, interfaceKind: listener.selection?.kind.rawValue ?? "?",
            port: port, sessions: status?.sessions ?? 0, deliveredMessages: status?.deliveredMessages ?? 0,
            peerRestarts: status?.peerRestarts ?? 0, refusals: listener.refusals,
            bulkBytesReceived: probe.receivedBulkBytes, events: probe.eventLog)
        listener.stop()
        return summary
    }

    /// Connects, measures, optionally runs the resume loop, prints a summary.
    public static func probe(options: Options, secret: Data, output: @escaping @Sendable (String) -> Void) throws -> ProbeSummary {
        let probe = ClusterLinkControlProbe()
        let edge = try edge(options: options, secret: secret)
        let outages = OutageClock()
        let handler: ClusterLinkControlEventHandler = { event, peer in
            probe.handle(event, peer: peer)
            outages.observe(event)
            if let line = describe(event) { output(line) }
        }
        let client = try ClusterLinkControlClient(configuration: .init(interface: options.interface,
            localAddress: options.localAddress, port: options.port, policy: options.policy, edge: edge), handler: handler)
        let started = linkNow()
        client.start()
        defer { client.stop() }
        var summary = ProbeSummary(interface: options.interface, interfaceKind: "?", connectMilliseconds: 0,
            report: nil, resume: nil, events: [], lastRefusal: nil, connectFailure: nil)
        guard client.peer.waitUntilConnected(timeout: .milliseconds(Int(options.connectSeconds * 1000))) else {
            summary.lastRefusal = client.lastRefusal.map { String(describing: $0) }
            summary.connectFailure = client.lastConnectFailure
            summary.events = probe.eventLog
            return summary
        }
        summary.connectMilliseconds = Double(linkNow() - started) / 1e6
        if let facts = try? ClusterLinkSystemInterfaceInspector().facts(forInterface: options.interface) {
            summary.interfaceKind = facts.kind.rawValue
        }
        summary.report = try probe.run(peer: client.peer, options: options.probe)
        if options.resumeSeconds > 0 {
            let end = linkNow() &+ UInt64(options.resumeSeconds * 1e9)
            var sent = 0, failures = 0
            while linkNow() < end {
                do {
                    try client.peer.send(.probe(.init(kind: .echoRequest, nonce: UInt64(sent + 1) << 32)), timeout: .seconds(1))
                    sent += 1
                } catch { failures += 1 }
                usleep(10_000)
            }
            _ = try? client.peer.waitUntilAcknowledged(timeout: .seconds(10))
            let status = client.peer.status
            summary.resume = ResumeSummary(seconds: options.resumeSeconds, sent: sent, sendFailures: failures,
                disconnects: outages.disconnects, peerRestarts: status.peerRestarts, sessions: status.sessions,
                longestOutageMilliseconds: outages.longestMilliseconds, unacknowledgedAtEnd: status.unacknowledgedMessages)
        }
        summary.events = probe.eventLog
        summary.lastRefusal = client.lastRefusal.map { String(describing: $0) }
        return summary
    }

    static func describe(_ event: ClusterLinkControlEvent) -> String? {
        switch event {
        case .connected(_, _, let resumed, let retransmitted): "EVENT connected resumed=\(resumed) retransmitted=\(retransmitted)"
        case .disconnected(_, let reason): "EVENT disconnected reason=\(reason.rawValue)"
        case .peerRestarted(_, let dropped): "EVENT peer-restarted dropped=\(dropped)"
        case .refused(_, let reason): "EVENT refused reason=\(reason)"
        case .message, .opaque: nil
        }
    }

    /// Blocks until standard input reaches end of file or `seconds` pass. A
    /// blocking read on its own thread: macOS `poll` never reports a named
    /// pipe's writer closing, so polling would miss the end.
    static func waitForStandardInputClose(seconds: Double) {
        let closed = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 256)
            while true {
                let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { break }
            }
            closed.signal()
        }
        _ = closed.wait(timeout: .now() + .nanoseconds(Int(max(0, min(seconds, 86_400)) * 1e9)))
    }

    /// Measures outages (disconnect to next connect) from events.
    final class OutageClock: @unchecked Sendable {
        private let lock = NSLock()
        private var since: UInt64?
        private(set) var disconnects = 0
        private var longest: UInt64 = 0
        var longestMilliseconds: Double { lock.withLock { Double(longest) / 1e6 } }
        func observe(_ event: ClusterLinkControlEvent) {
            lock.withLock {
                switch event {
                case .disconnected:
                    disconnects += 1
                    if since == nil { since = linkNow() }
                case .connected:
                    if let since { longest = max(longest, linkNow() - since) }
                    since = nil
                default: break
                }
            }
        }
    }
}
