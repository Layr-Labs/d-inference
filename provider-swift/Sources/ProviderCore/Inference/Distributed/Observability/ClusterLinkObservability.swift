import DarkbloomClusterRemote
import Foundation

// The follower's status mirrored to the leader over the link control channel
// (PROD-PLAN S24, C13), as both members of a pair run it.
//
// The follower member reports what it is doing with the rank it serves for
// the leader (idle, serving a session, failed), its memory and thermal state
// and its newest incidents, every two seconds while the edge is up. The
// leader keeps the newest status per rank, writes it for `cluster status`,
// records an incident when the follower reports a failure or goes silent,
// and mirrors the follower's own incidents into its log so one Mac shows the
// pair's whole story.

/// Leader side: the board, its file and the incidents it implies.
final class ClusterFollowerStatusMonitor: @unchecked Sendable {
    static let checkInterval: Duration = .seconds(2)

    private let observability: ClusterObservability
    private let clusterID: String
    private let modelID: String
    private let board: ClusterLinkStatusBoard
    private let queue = DispatchQueue(label: "darkbloom.link-status.monitor")
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var stopping = false
    private var lastWrite: Double = 0

    init(observability: ClusterObservability, clusterID: String, modelID: String,
         staleAfterSeconds: Double = ClusterLinkStatusBoard.defaultStaleAfterSeconds) {
        self.observability = observability
        self.clusterID = ClusterObservability.field(clusterID)
        self.modelID = modelID
        board = ClusterLinkStatusBoard(staleAfterSeconds: staleAfterSeconds)
    }

    deinit { timer?.cancel() }

    /// The link edge's events, as the leader's handler sees them. Cheap: the
    /// work is queued.
    func handle(_ event: ClusterLinkControlEvent) {
        switch event {
        case .message(_, _, .status(let status)):
            queue.async { self.receive(status) }
        case .disconnected(_, let reason):
            queue.async { self.disconnected(reason) }
        default:
            break
        }
    }

    func start() {
        lock.withLock {
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2), leeway: .milliseconds(200))
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source
            source.resume()
        }
    }

    func stop() {
        let value = lock.withLock { () -> DispatchSourceTimer? in
            stopping = true
            defer { timer = nil }
            return timer
        }
        value?.cancel()
        queue.sync { writeFile(force: true) }
    }

    var entries: [ClusterLinkStatusBoard.Entry] { board.entries() }

    private var isStopping: Bool { lock.withLock { stopping } }

    private func receive(_ status: ClusterLinkStatusMirror) {
        for transition in board.receive(status) { record(transition) }
        writeFile(force: false)
    }

    private func tick() {
        for transition in board.checkStaleness() { record(transition) }
        writeFile(force: false)
    }

    private func disconnected(_ reason: ClusterLinkControlDisconnect) {
        guard !isStopping, reason != .localShutdown, reason != .superseded, reason != .rekey else { return }
        observability.record(.init(severity: reason == .peerClosed ? .info : .warn, source: "link",
            stateCode: .linkEdgeDown, reason: reason == .peerClosed ? nil : .peerLost,
            message: "The link control edge to the follower went down (\(reason.rawValue))",
            deploymentID: clusterID, modelID: modelID, rank: 1))
        writeFile(force: true)
    }

    private func record(_ transition: ClusterLinkStatusBoard.Transition) {
        switch transition {
        case .firstSeen(let rank):
            clusterObservabilityLog(.info, "follower status mirrored", ["rank": "\(rank)"])
        case .stateChanged(let rank, _, let to, let detail) where to == .failed:
            let explanation = ClusterFailureClassifier.classify(message: detail.isEmpty ? "the follower reported failed" : detail)
            observability.record(.init(severity: .error, source: "follower", stateCode: .followerFailed,
                explanation: explanation, deploymentID: clusterID, modelID: modelID, rank: Int(rank)))
        case .stateChanged:
            break
        case .becameStale(let rank, let silent):
            guard !isStopping else { return }
            observability.record(.init(severity: .warn, source: "leader", stateCode: .followerStatusStale,
                reason: .peerLost, message: "Rank \(rank)'s mirrored status stopped arriving \(Int(silent)) s ago",
                deploymentID: clusterID, modelID: modelID, rank: Int(rank)))
        case .recovered(let rank):
            clusterObservabilityLog(.info, "follower status resumed", ["rank": "\(rank)"])
        case .incidents(let rank, let epoch, let list):
            for incident in list {
                let severity = ClusterIncidentSeverity(rawValue: incident.severity) ?? .error
                observability.record(.init(severity: severity, source: "follower", stateCode: Self.code(incident.stateCode),
                    reasonCode: incident.reasonCode.map(Self.code), guidanceCode: incident.guidanceCode.map(Self.code),
                    message: "[rank \(rank)] " + incident.message, deploymentID: clusterID, modelID: modelID,
                    rank: Int(rank), origin: Self.code("follower:\(epoch):\(incident.seq)")))
            }
        }
    }

    /// The leader rewrites the file on every change, and at most once a
    /// second otherwise, so `cluster status` sees the age move.
    private func writeFile(force: Bool) {
        let now = Date().timeIntervalSince1970
        guard force || now - lastWrite >= 1 else { return }
        lastWrite = now
        do {
            try ClusterLinkStatusBoardFile(updatedAt: now, entries: board.entries()).write(to: observability.followerStatusFile)
        } catch {
            clusterObservabilityLog(.warning, "follower status file not written", ["error": "\(error)"])
        }
    }

    /// A code the incident log accepts (printable ASCII, bounded).
    static func code(_ value: String) -> String { ClusterObservability.field(value) }
}

/// Follower side: what this member's rank is doing, published to the leader.
final class ClusterFollowerStatusReporter: @unchecked Sendable {
    private let observability: ClusterObservability
    private let modelID: String
    private let lock = NSLock()
    private var state: ClusterLinkStatusMirror.State = .idle
    private var detail = ""
    private var served: UInt64 = 0
    private var publisher: ClusterLinkStatusPublisher?

    init(observability: ClusterObservability, modelID: String) {
        self.observability = observability; self.modelID = modelID
    }

    /// Starts publishing on the edge (the follower's `client.peer`).
    func start(peer: ClusterLinkControlPeer, epoch: UUID, rank: UInt16) {
        let created = ClusterLinkStatusPublisher(peer: peer, epoch: epoch, rank: rank) { [weak self] in
            self?.snapshot() ?? .init(state: .idle)
        }
        lock.withLock { publisher = created }
        created.start()
    }

    func stop() {
        let value = lock.withLock { () -> ClusterLinkStatusPublisher? in defer { publisher = nil }; return publisher }
        value?.stop()
    }

    /// A state change: published at once, besides the periodic status.
    func note(_ next: ClusterLinkStatusMirror.State, _ text: String = "") {
        let publish = lock.withLock { () -> ClusterLinkStatusPublisher? in
            if next == .idle, state == .serving { served += 1 }
            state = next; detail = String(text.prefix(240))
            return publisher
        }
        publish?.publishNow()
    }

    /// Records an incident on this Mac (it reaches the leader with the next status).
    func recordIncident(_ stateCode: ClusterIncidentStateCode, error: String, severity: ClusterIncidentSeverity = .error) {
        let explanation = ClusterFailureClassifier.classify(message: error)
        observability.record(.init(severity: severity, source: "follower", stateCode: stateCode,
            explanation: explanation, modelID: modelID, rank: 1))
        lock.withLock { publisher }?.publishNow()
    }

    private func snapshot() -> ClusterLinkStatusSnapshot {
        let (epoch, incidents) = observability.linkSummaries()
        return lock.withLock {
            .init(state: state, modelID: modelID, linkReady: true, detail: detail, requestsServed: served,
                  incidentEpoch: epoch, incidents: incidents)
        }
    }
}
