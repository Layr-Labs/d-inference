import Foundation

/// Measurement and diagnostic responder for the link control channel. Install
/// `handle` as the event handler on both ends; the measuring end calls `run`.
/// Used by the check runners and the provider's qualification command; it
/// carries no inference data.
public final class ClusterLinkControlProbe: @unchecked Sendable {
    public static let bulkTag: UInt16 = 0xB01C

    public struct Options: Sendable {
        /// Back-to-back pings, then one run per gap in `pingGapsMicroseconds`.
        public var pings = 2000
        public var spacedPings = 300
        public var pingGapsMicroseconds: [UInt32] = [1000, 10_000]
        public var typedEchoes = 500
        public var bulkFrames = 256
        public var bulkFrameBytes = 1024 * 1024
        public var reverseBulk = true
        public init() {}
    }

    public struct Latency: Codable, Sendable, Equatable {
        public let label: String
        public let count: Int
        public let gapMicroseconds: UInt32
        public let minimumMicroseconds: Double
        public let p50Microseconds: Double
        public let p90Microseconds: Double
        public let p99Microseconds: Double
        public let maximumMicroseconds: Double

        init(label: String, gap: UInt32, nanoseconds: [UInt64]) {
            let sorted = nanoseconds.sorted()
            func q(_ p: Double) -> Double {
                guard !sorted.isEmpty else { return 0 }
                return Double(sorted[min(sorted.count - 1, Int(p * Double(sorted.count)))]) / 1000
            }
            self.label = label; count = sorted.count; gapMicroseconds = gap
            minimumMicroseconds = Double(sorted.first ?? 0) / 1000
            p50Microseconds = q(0.50); p90Microseconds = q(0.90); p99Microseconds = q(0.99)
            maximumMicroseconds = Double(sorted.last ?? 0) / 1000
        }
    }

    public struct Throughput: Codable, Sendable, Equatable {
        public let direction: String
        public let frames: Int
        public let frameBytes: Int
        public let seconds: Double
        public let megabytesPerSecond: Double
    }

    public struct Report: Codable, Sendable {
        public var latency: [Latency] = []
        public var throughput: [Throughput] = []
        public var peerRestarts: UInt64 = 0
        public var sessions: UInt64 = 0
    }

    private let lock = NSCondition()
    private var echoWaiters: [UInt64: DispatchSemaphore] = [:]
    private var bulkReceived = 0
    private var bulkBytes = 0
    private var bulkDoneNonce: UInt64?
    private var events: [String] = []

    public init() {}

    /// Opaque bytes received with the bulk tag so far.
    public var receivedBulkBytes: Int { lock.withLock { bulkBytes } }
    /// A bounded log of connection events, for check output (no addresses).
    public var eventLog: [String] { lock.withLock { events } }

    public func handle(_ event: ClusterLinkControlEvent, peer: ClusterLinkControlPeer?) {
        switch event {
        case .message(_, _, .probe(let probe)):
            switch probe.kind {
            case .echoRequest:
                _ = try? peer?.send(.probe(.init(kind: .echoReply, nonce: probe.nonce)))
            case .echoReply:
                lock.withLock { echoWaiters.removeValue(forKey: probe.nonce) }?.signal()
            case .bulkRequest:
                guard let peer else { return }
                let count = Int(min(probe.count, 65_536)), bytes = Int(probe.bytes), nonce = probe.nonce
                Thread.detachNewThread {
                    let payload = Data(repeating: 0x5A, count: bytes)
                    for _ in 0..<count { guard (try? peer.sendOpaque(tag: Self.bulkTag, payload, timeout: .seconds(30))) != nil else { return } }
                    _ = try? peer.send(.probe(.init(kind: .bulkDone, nonce: nonce)), timeout: .seconds(30))
                }
            case .bulkDone:
                lock.withLock { bulkDoneNonce = probe.nonce; lock.broadcast() }
            }
        case .opaque(_, _, let tag, let data) where tag == Self.bulkTag:
            lock.withLock { bulkReceived += 1; bulkBytes += data.count; lock.broadcast() }
        case .connected(_, _, let resumed, let retransmitted):
            log("connected resumed=\(resumed) retransmitted=\(retransmitted)")
        case .disconnected(_, let reason):
            log("disconnected \(reason.rawValue)")
        case .peerRestarted(_, let dropped):
            log("peer restarted dropped=\(dropped)")
        case .refused(_, let reason):
            log("refused \(reason)")
        default:
            break
        }
    }

    private func log(_ line: String) {
        lock.withLock { if events.count < 256 { events.append(line) } }
    }

    /// Small-frame round trips (pings answered by the peer's reader), typed
    /// message round trips (JSON, reliable stream, both event queues) and 1 MB
    /// throughput, in that order.
    public func run(peer: ClusterLinkControlPeer, options: Options) throws -> Report {
        var report = Report()
        // Warm the path before quoting anything.
        for _ in 0..<50 { _ = try peer.ping() }
        var channel = [UInt64](), observed = [UInt64]()
        for _ in 0..<options.pings {
            let result = try peer.ping()
            channel.append(result.channelNanoseconds); observed.append(result.observedNanoseconds)
        }
        report.latency.append(.init(label: "ping-64B-back-to-back", gap: 0, nanoseconds: channel))
        report.latency.append(.init(label: "ping-64B-back-to-back-observed", gap: 0, nanoseconds: observed))
        for gap in options.pingGapsMicroseconds where options.spacedPings > 0 {
            var spaced = [UInt64]()
            for _ in 0..<options.spacedPings {
                usleep(gap)
                spaced.append(try peer.ping().channelNanoseconds)
            }
            report.latency.append(.init(label: "ping-64B-spaced", gap: gap, nanoseconds: spaced))
        }
        var typed = [UInt64]()
        for index in 0..<options.typedEchoes {
            let nonce = UInt64(index + 1) << 20 | UInt64.random(in: 0..<(1 << 20))
            let semaphore = DispatchSemaphore(value: 0)
            lock.withLock { echoWaiters[nonce] = semaphore }
            let started = DispatchTime.now().uptimeNanoseconds
            try peer.send(.probe(.init(kind: .echoRequest, nonce: nonce)))
            guard semaphore.wait(timeout: .now() + 5) == .success else { throw ClusterLinkControlError.timedOut }
            typed.append(DispatchTime.now().uptimeNanoseconds - started)
        }
        if options.typedEchoes > 0 {
            report.latency.append(.init(label: "typed-message-echo", gap: 0, nanoseconds: typed))
        }
        if options.bulkFrames > 0 {
            let payload = Data(repeating: 0xA5, count: options.bulkFrameBytes)
            let started = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<options.bulkFrames { try peer.sendOpaque(tag: Self.bulkTag, payload, timeout: .seconds(30)) }
            try peer.waitUntilAcknowledged(timeout: .seconds(120))
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
            report.throughput.append(.init(direction: "to-peer", frames: options.bulkFrames, frameBytes: options.bulkFrameBytes,
                seconds: seconds, megabytesPerSecond: Double(options.bulkFrames * options.bulkFrameBytes) / seconds / 1e6))
            if options.reverseBulk {
                let nonce = UInt64.random(in: 1..<UInt64.max)
                let before = lock.withLock { bulkReceived }
                let started = DispatchTime.now().uptimeNanoseconds
                try peer.send(.probe(.init(kind: .bulkRequest, nonce: nonce, count: UInt32(options.bulkFrames),
                    bytes: UInt32(options.bulkFrameBytes))))
                let deadline = Date(timeIntervalSinceNow: 120)
                lock.lock()
                while bulkDoneNonce != nonce || bulkReceived - before < options.bulkFrames {
                    guard lock.wait(until: deadline) else { lock.unlock(); throw ClusterLinkControlError.timedOut }
                }
                lock.unlock()
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
                report.throughput.append(.init(direction: "from-peer", frames: options.bulkFrames, frameBytes: options.bulkFrameBytes,
                    seconds: seconds, megabytesPerSecond: Double(options.bulkFrames * options.bulkFrameBytes) / seconds / 1e6))
            }
        }
        let status = peer.status
        report.peerRestarts = status.peerRestarts; report.sessions = status.sessions
        return report
    }
}
