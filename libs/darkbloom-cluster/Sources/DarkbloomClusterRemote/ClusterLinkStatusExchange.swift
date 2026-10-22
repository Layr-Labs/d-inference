import Darwin
import DarkbloomClusterProcess
import Foundation

// Follower status mirrored to the leader over the link control channel
// (PROD-PLAN S24, C13).
//
// The follower member publishes a small status every couple of seconds (state,
// model, active request, free and wired memory, thermal state, its newest
// incidents) as the link edge's typed `.status` message; the leader keeps the
// newest one per rank on a board, notices when it stops arriving or reports a
// failure, and shows it in `darkbloom cluster status`. Nothing here is a
// readiness proof or a lease: the rank lease and the collective guard decide
// failure; this is what an operator reads.
//
// The edge delivers every message exactly once, retransmitting across
// reconnects, so the publisher sends only while a session is up: a status
// queued during an outage would arrive stale.

/// What the member itself knows; the publisher adds memory, time and sequence.
public struct ClusterLinkStatusSnapshot: Sendable, Equatable {
    public var state: ClusterLinkStatusMirror.State
    public var modelID: String?
    public var activeRequestID: UUID?
    public var linkReady: Bool
    public var detail: String
    public var requestsServed: UInt64?
    public var incidentEpoch: String?
    public var incidents: [ClusterLinkIncidentSummary]

    public init(state: ClusterLinkStatusMirror.State, modelID: String? = nil, activeRequestID: UUID? = nil,
                linkReady: Bool = true, detail: String = "", requestsServed: UInt64? = nil,
                incidentEpoch: String? = nil, incidents: [ClusterLinkIncidentSummary] = []) {
        self.state = state; self.modelID = modelID; self.activeRequestID = activeRequestID; self.linkReady = linkReady
        self.detail = detail; self.requestsServed = requestsServed; self.incidentEpoch = incidentEpoch
        self.incidents = incidents
    }
}

/// This Mac's memory and thermal state, read without privileges.
public enum ClusterHostSample {
    public struct Value: Sendable, Equatable {
        public let freeBytes: UInt64?
        public let wiredBytes: UInt64?
        public let physicalBytes: UInt64
        public let thermalState: String
        public init(freeBytes: UInt64?, wiredBytes: UInt64?, physicalBytes: UInt64, thermalState: String) {
            self.freeBytes = freeBytes; self.wiredBytes = wiredBytes; self.physicalBytes = physicalBytes
            self.thermalState = thermalState
        }
    }

    public static func now() -> Value {
        .init(freeBytes: freeBytes(), wiredBytes: ClusterOrphanWiredGuard.wiredBytes(),
              physicalBytes: ProcessInfo.processInfo.physicalMemory, thermalState: thermal(ProcessInfo.processInfo.thermalState))
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    /// Free plus speculative pages (what vm_stat calls free), in bytes.
    static func freeBytes() -> UInt64? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var page: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(mach_host_self(), &page) == KERN_SUCCESS, page > 0 else { return nil }
        return (UInt64(statistics.free_count) + UInt64(statistics.speculative_count)) * UInt64(page)
    }
}

/// Sends this member's status on one link edge while a session is up.
public final class ClusterLinkStatusPublisher: @unchecked Sendable {
    public static let defaultInterval: Duration = .seconds(2)

    private let epoch: UUID
    private let rank: UInt16
    private let interval: Duration
    private let send: @Sendable (ClusterLinkControlMessage) throws -> Void
    private let isConnected: @Sendable () -> Bool
    private let snapshot: @Sendable () -> ClusterLinkStatusSnapshot
    private let sample: @Sendable () -> ClusterHostSample.Value
    private let queue = DispatchQueue(label: "darkbloom.link-status.publisher")
    private let lock = NSLock()
    private let started = Date()
    private var timer: DispatchSourceTimer?
    private var sequence: UInt64 = 0
    private var sent: UInt64 = 0
    private var failed: UInt64 = 0
    private var skipped: UInt64 = 0

    /// `send` is the edge's `peer.send` (with a short timeout); `isConnected`
    /// its `peer.status.connected`.
    public init(epoch: UUID, rank: UInt16, interval: Duration = defaultInterval,
                send: @escaping @Sendable (ClusterLinkControlMessage) throws -> Void,
                isConnected: @escaping @Sendable () -> Bool,
                snapshot: @escaping @Sendable () -> ClusterLinkStatusSnapshot,
                sample: @escaping @Sendable () -> ClusterHostSample.Value = { ClusterHostSample.now() }) {
        self.epoch = epoch; self.rank = rank; self.interval = interval; self.send = send
        self.isConnected = isConnected; self.snapshot = snapshot; self.sample = sample
    }

    /// For a peer whose `send` takes a timeout: a status that cannot be queued
    /// within 200 ms is dropped (the next one replaces it).
    public convenience init(peer: ClusterLinkControlPeer, epoch: UUID, rank: UInt16, interval: Duration = defaultInterval,
                            snapshot: @escaping @Sendable () -> ClusterLinkStatusSnapshot) {
        self.init(epoch: epoch, rank: rank, interval: interval,
                  send: { message in _ = try peer.send(message, timeout: .milliseconds(200)) },
                  isConnected: { peer.status.connected && peer.status.unacknowledgedMessages < 64 },
                  snapshot: snapshot)
    }

    deinit { timer?.cancel() }

    public func start() {
        lock.withLock {
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            let nanoseconds = max(Int(interval.components.seconds) * 1_000_000_000
                + Int(interval.components.attoseconds / 1_000_000_000), 50_000_000)
            source.schedule(deadline: .now(), repeating: .nanoseconds(nanoseconds), leeway: .milliseconds(100))
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source
            source.resume()
        }
    }

    /// Sends a status now (a state change), in addition to the periodic ones.
    public func publishNow() { queue.async { [weak self] in self?.tick() } }

    public func stop() {
        let value = lock.withLock { () -> DispatchSourceTimer? in defer { timer = nil }; return timer }
        value?.cancel()
        queue.sync {}
    }

    public var counters: (sent: UInt64, failed: UInt64, skipped: UInt64) { lock.withLock { (sent, failed, skipped) } }

    /// The message this publisher would send now (tests, and the leader's own view).
    public func makeMessage() -> ClusterLinkStatusMirror {
        let value = snapshot(), host = sample()
        let next = lock.withLock { () -> UInt64 in sequence += 1; return sequence }
        // The edge refuses a status whose text exceeds its byte bounds: cut by UTF-8 bytes.
        return .init(epoch: epoch, rank: rank, state: value.state,
                     modelID: value.modelID.map { ClusterIncidentLog.bounded(ClusterIncidentLog.printable($0), 256) },
                     activeRequestID: value.activeRequestID, freeMemoryBytes: host.freeBytes, wiredMemoryBytes: host.wiredBytes,
                     linkReady: value.linkReady, detail: ClusterIncidentLog.bounded(ClusterIncidentLog.printable(value.detail), 240),
                     sequence: next,
                     sentAt: Date().timeIntervalSince1970, uptimeSeconds: UInt64(max(0, Date().timeIntervalSince(started))),
                     thermalState: host.thermalState, physicalMemoryBytes: host.physicalBytes,
                     requestsServed: value.requestsServed, incidentEpoch: value.incidentEpoch,
                     incidents: value.incidents.isEmpty ? nil : Array(value.incidents.suffix(ClusterLinkStatusMirror.maximumIncidents)))
    }

    private func tick() {
        guard lock.withLock({ timer != nil }), isConnected() else { lock.withLock { skipped += 1 }; return }
        do { try send(.status(makeMessage())); lock.withLock { sent += 1 } }
        catch { lock.withLock { failed += 1 } }
    }
}

/// The leader's view of the other members' mirrored status.
public final class ClusterLinkStatusBoard: @unchecked Sendable {
    public static let defaultStaleAfterSeconds: Double = 10

    /// One rank's newest status as the leader received it.
    public struct Entry: Codable, Sendable, Equatable {
        public let status: ClusterLinkStatusMirror
        /// The leader's clock when it arrived, seconds since 1970.
        public let receivedAt: Double
        public let stale: Bool
        /// Seconds since it arrived, at the time the entry was read.
        public let ageSeconds: Double
    }

    public enum Transition: Sendable, Equatable {
        case firstSeen(rank: UInt16)
        case stateChanged(rank: UInt16, from: ClusterLinkStatusMirror.State, to: ClusterLinkStatusMirror.State, detail: String)
        case becameStale(rank: UInt16, silentSeconds: Double)
        case recovered(rank: UInt16)
        /// Incidents the member recorded that this board had not seen yet.
        case incidents(rank: UInt16, epoch: String, [ClusterLinkIncidentSummary])
    }

    private struct Held { var status: ClusterLinkStatusMirror; var receivedAt: Double; var stale: Bool }

    private let staleAfter: Double
    private let clock: @Sendable () -> Double
    private let lock = NSLock()
    private var held: [UInt16: Held] = [:]
    /// Highest incident sequence seen per (rank, incident epoch).
    private var seenIncidents: [String: UInt64] = [:]

    public init(staleAfterSeconds: Double = defaultStaleAfterSeconds,
                clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        staleAfter = staleAfterSeconds; self.clock = clock
    }

    /// Takes one status; an older or repeated sequence from the same rank is ignored.
    @discardableResult
    public func receive(_ status: ClusterLinkStatusMirror) -> [Transition] {
        let now = clock()
        return lock.withLock {
            var transitions: [Transition] = []
            if let previous = held[status.rank] {
                if let old = previous.status.sequence, let new = status.sequence, new <= old,
                   previous.status.uptimeSeconds ?? 0 <= status.uptimeSeconds ?? 0 { return [] }
                if previous.stale { transitions.append(.recovered(rank: status.rank)) }
                if previous.status.state != status.state {
                    transitions.append(.stateChanged(rank: status.rank, from: previous.status.state, to: status.state,
                                                     detail: status.detail))
                }
            } else {
                transitions.append(.firstSeen(rank: status.rank))
            }
            held[status.rank] = .init(status: status, receivedAt: now, stale: false)
            if let epoch = status.incidentEpoch, let incidents = status.incidents, !incidents.isEmpty {
                let key = "\(status.rank):\(epoch)"
                let last = seenIncidents[key] ?? 0
                let fresh = incidents.filter { $0.seq > last }.sorted { $0.seq < $1.seq }
                if let newest = fresh.last {
                    seenIncidents[key] = newest.seq
                    transitions.append(.incidents(rank: status.rank, epoch: epoch, fresh))
                }
            }
            return transitions
        }
    }

    /// Marks ranks whose status stopped arriving; returns each newly stale rank once.
    @discardableResult
    public func checkStaleness() -> [Transition] {
        let now = clock()
        return lock.withLock {
            var transitions: [Transition] = []
            for (rank, value) in held where !value.stale && now - value.receivedAt > staleAfter {
                held[rank]?.stale = true
                transitions.append(.becameStale(rank: rank, silentSeconds: now - value.receivedAt))
            }
            return transitions.sorted { "\($0)" < "\($1)" }
        }
    }

    public func entries() -> [Entry] {
        let now = clock()
        return lock.withLock {
            held.keys.sorted().compactMap { rank in
                held[rank].map { value in
                    Entry(status: value.status, receivedAt: value.receivedAt,
                          stale: value.stale || now - value.receivedAt > staleAfter,
                          ageSeconds: max(0, (now - value.receivedAt) * 10).rounded() / 10)
                }
            }
        }
    }

    /// Forgets a rank (its session ended).
    public func remove(rank: UInt16) { lock.withLock { _ = held.removeValue(forKey: rank) } }
}

/// The file the leader writes for `cluster status` (owner-only, atomic).
public struct ClusterLinkStatusBoardFile: Codable, Sendable, Equatable {
    public static let schemaName = "darkbloom_follower_status_v1"
    public let schema: String
    public let updatedAt: Double
    public let entries: [ClusterLinkStatusBoard.Entry]

    public init(updatedAt: Double, entries: [ClusterLinkStatusBoard.Entry]) {
        schema = Self.schemaName; self.updatedAt = updatedAt; self.entries = entries
    }

    public static func defaultFile(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".darkbloom/cluster/follower-status.json")
    }

    public func write(to file: URL) throws {
        try ClusterIncidentLog.makePrivateDirectory(file.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = try encoder.encode(self); bytes.append(10)
        try ClusterIncidentLog.writeAtomically(bytes, to: file)
    }

    public static func read(_ file: URL) -> ClusterLinkStatusBoardFile? {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= 256 * 1024 else { return nil }
        var bytes = Data(count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        guard count == Int(info.st_size), let value = try? JSONDecoder().decode(Self.self, from: bytes),
              value.schema == schemaName else { return nil }
        return value
    }
}

extension ClusterIncidentFeed {
    /// The newest records as a member mirrors them (at most four, open ones first).
    public func linkSummaries(limit: Int = ClusterLinkStatusMirror.maximumIncidents) -> [ClusterLinkIncidentSummary] {
        incidents.suffix(limit).map {
            ClusterLinkIncidentSummary(seq: $0.seq, ts: $0.ts, severity: $0.severity.rawValue, stateCode: $0.stateCode,
                reasonCode: $0.reasonCode, guidanceCode: $0.guidanceCode,
                message: ClusterIncidentLog.bounded($0.message, ClusterLinkIncidentSummary.maximumMessageBytes))
        }
    }
}
