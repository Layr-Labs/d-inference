import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
import DarkbloomClusterSecurity

// The follower rank reached over the link control channel instead of SSH
// (PROD-PLAN S08).
//
// On the leader, `ClusterLinkWorkerEndpoint` is the pair's rank-1 endpoint.
// On the follower, `ClusterLinkWorkerServer` wraps the follower's own
// `ClusterRemoteWorkerEndpoint` (a local owner that launches the worker) and
// relays between it and the link. What crosses the link is what rank 1 needs:
// worker commands in (reserve with its prompt tokens, start, cancel, keep-warm,
// shutdown), worker events out (ready, admitted, finished, retired, ...), the
// bootstrap rounds of the follower's owner to the leader's relay, the rank
// lease, and the follower's cleanup and release proofs. The link authenticates
// and encrypts every message, so prompt token IDs never travel in the clear.
//
// No host uptime crosses the link: a deadline travels as the time remaining
// and is rebased on the receiving Mac's clock.
//
// The follower enforces the rank lease itself: the leader renews it on the
// link (every `ClusterWorkerLease.renewNanoseconds`, TTL
// `ClusterWorkerLease.ttlNanoseconds`); when renewals stop (the leader
// stopped, died or lost the link for longer than the TTL) the server fences
// its local endpoint, whose owner fences the worker; the worker ends itself
// within its own lease in any case. The follower then reports cleanup and the
// owner's release, which the leader receives if the link comes back.

/// An endpoint that also proves its owner's release, the way the installed
/// session waits for it.
public protocol ClusterOwnedWorkerEndpoint: ClusterWorkerEndpoint {
    var ownerRetirementDeadlineUptimeNanoseconds: UInt64 { get }
    var ownerDeviceLeaseReleasedObserved: Bool { get }
    var ownerTermination: ClusterWorkerProcessTermination? { get }
    func waitUntilOwnerReleased(deadline: UInt64) async -> Bool
}

/// Sends one worker-wire message on the link edge. Delivery is exactly once
/// and in order while both processes live (the link control channel's
/// guarantee); a send may block while the outbox is full.
public protocol ClusterLinkWorkerTransport: AnyObject, Sendable {
    func send(_ bytes: Data) throws
}

/// The worker wire on a link control peer, as tagged opaque messages.
public final class ClusterLinkPeerWorkerTransport: ClusterLinkWorkerTransport, @unchecked Sendable {
    public let peer: ClusterLinkControlPeer
    public init(peer: ClusterLinkControlPeer) { self.peer = peer }
    public func send(_ bytes: Data) throws { _ = try peer.sendOpaque(tag: ClusterLinkWorkerWire.tag, bytes) }
}

public enum ClusterLinkWorkerError: Error, Equatable, Sendable {
    case invalid(String)
}

/// One message of the worker wire. Closed: each kind has exactly its fields.
public struct ClusterLinkWorkerWire: Codable, Sendable, Equatable {
    /// The opaque tag of the worker wire on a link edge.
    public static let tag: UInt16 = 0x5708
    /// A command crosses base64-encoded in `worker`: the largest worker
    /// command (`ClusterWorkerLimits.commandBytes`, a reservation with a
    /// `wirePromptTokens` prompt) is 4/3 of it, with room for the other fields.
    public static let maximumBytes = 12 * 1024 * 1024
    public static let version = 1

    public enum Kind: String, Codable, Sendable {
        // Leader to follower.
        case open, command, renew, fence, bootstrapReply
        // Follower to leader.
        case accepted, refused, invalidated, event, bootstrapRound, cleanup, released
        var fromLeader: Bool { [.open, .command, .renew, .fence, .bootstrapReply].contains(self) }
    }

    public var version: Int
    public var kind: Kind
    /// The membership epoch of the session.
    public var epoch: UUID
    /// The leader endpoint's session: every message of one endpoint names it.
    public var session: UUID
    /// Per direction, from 0, strictly one more each message of a session.
    public var sequence: UInt64
    public var clusterID: String?
    public var rank: Int?
    public var planSHA256: String?
    public var bootstrapProfile: String?
    public var nativeStart: Data?
    /// One rank's bounded credential line, only in open, carried exclusively
    /// inside the authenticated encrypted link-control message. Never logged.
    public var dataPlaneTrust: Data?
    public var remainingNanoseconds: UInt64?
    public var deliveryRemainingNanoseconds: UInt64?
    /// A worker command or event, in the worker codec's own encoding.
    public var worker: Data?
    public var bootstrapSequence: UInt64?
    public var bootstrapBytes: Data?
    public var ownerIncarnation: UUID?
    public var ownerLease: UUID?
    public var detail: String?
    public var termination: String?
    public var status: Int32?
    public var releasedCleanly: Bool?

    init(kind: Kind, epoch: UUID, session: UUID, sequence: UInt64) {
        version = Self.version; self.kind = kind; self.epoch = epoch; self.session = session; self.sequence = sequence
    }

    private var presentFields: Set<String> {
        var set = Set<String>()
        if clusterID != nil { set.insert("clusterID") }
        if rank != nil { set.insert("rank") }
        if planSHA256 != nil { set.insert("planSHA256") }
        if bootstrapProfile != nil { set.insert("bootstrapProfile") }
        if nativeStart != nil { set.insert("nativeStart") }
        if dataPlaneTrust != nil { set.insert("dataPlaneTrust") }
        if remainingNanoseconds != nil { set.insert("remainingNanoseconds") }
        if deliveryRemainingNanoseconds != nil { set.insert("deliveryRemainingNanoseconds") }
        if worker != nil { set.insert("worker") }
        if bootstrapSequence != nil { set.insert("bootstrapSequence") }
        if bootstrapBytes != nil { set.insert("bootstrapBytes") }
        if ownerIncarnation != nil { set.insert("ownerIncarnation") }
        if ownerLease != nil { set.insert("ownerLease") }
        if detail != nil { set.insert("detail") }
        if termination != nil { set.insert("termination") }
        if status != nil { set.insert("status") }
        if releasedCleanly != nil { set.insert("releasedCleanly") }
        return set
    }

    /// Exactly the fields each kind carries, within their bounds.
    func validate() throws {
        func fail(_ reason: String) -> ClusterLinkWorkerError { .invalid(reason) }
        guard version == Self.version else { throw fail("Worker wire version differs") }
        let required: Set<String>, optional: Set<String>
        switch kind {
        case .open:
            required = ["clusterID", "rank", "planSHA256", "remainingNanoseconds"]
            optional = ["bootstrapProfile", "nativeStart", "dataPlaneTrust"]
        case .command:
            required = ["worker", "deliveryRemainingNanoseconds"]; optional = ["remainingNanoseconds"]
        case .renew: required = ["remainingNanoseconds"]; optional = []
        case .accepted, .cleanup: required = []; optional = []
        case .fence: required = []; optional = ["detail"]
        case .refused, .invalidated: required = ["detail"]; optional = []
        case .event: required = ["worker"]; optional = []
        case .bootstrapRound: required = ["bootstrapSequence", "bootstrapBytes", "ownerIncarnation", "ownerLease"]; optional = []
        case .bootstrapReply: required = ["bootstrapSequence", "bootstrapBytes"]; optional = []
        case .released: required = ["releasedCleanly"]; optional = ["termination", "status", "detail"]
        }
        let present = presentFields
        guard required.isSubset(of: present), present.isSubset(of: required.union(optional)) else {
            throw fail("Worker wire fields differ for \(kind.rawValue)")
        }
        if let clusterID { guard (1...128).contains(clusterID.utf8.count), clusterID.utf8.allSatisfy({ (33...126).contains($0) }) else { throw fail("Cluster label differs") } }
        if let rank { guard (0...1).contains(rank) else { throw fail("Rank outside a pair") } }
        if let planSHA256 { guard planSHA256.utf8.count == 64, planSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw fail("Plan digest differs") } }
        if let bootstrapProfile { guard ClusterOwnerBootstrapProfile(rawValue: bootstrapProfile) != nil else { throw fail("Unknown bootstrap profile") } }
        if let nativeStart { guard (1...3072).contains(nativeStart.count) else { throw fail("Native start exceeds its bound") } }
        if let dataPlaneTrust {
            guard (1...4096).contains(dataPlaneTrust.count),
                  let trust = try? ClusterWorkerCodec.decodeDataPlaneTrust(dataPlaneTrust),
                  trust.membershipEpoch == epoch, trust.rank == rank else {
                throw fail("Data-plane credential differs from the open epoch/rank or exceeds its bound")
            }
        }
        for value in [remainingNanoseconds, deliveryRemainingNanoseconds].compactMap({ $0 }) {
            guard value > 0, value <= ClusterWorkerLimits.deadlineNanoseconds else { throw fail("Duration outside its bound") }
        }
        if kind == .open || kind == .renew, let remaining = remainingNanoseconds {
            guard remaining <= ClusterWorkerLease.maximumNanoseconds else { throw fail("Lease grant exceeds its bound") }
        }
        if let worker { guard !worker.isEmpty, worker.count <= ClusterWorkerLimits.commandBytes else { throw fail("Worker payload exceeds its bound") } }
        if let bootstrapSequence { guard bootstrapSequence < UInt64(ClusterOwnerBootstrapProfile.maximumRounds) else { throw fail("Bootstrap round outside its bound") } }
        if let bootstrapBytes { guard (1...131_072).contains(bootstrapBytes.count) else { throw fail("Bootstrap payload exceeds its bound") } }
        if let detail { guard detail.utf8.count <= 256, !detail.utf8.contains(0) else { throw fail("Detail exceeds its bound") } }
        if let termination {
            guard ["launchFailed", "exited", "signalled"].contains(termination), (termination == "launchFailed") == (status == nil) else {
                throw fail("Owner termination differs")
            }
        } else { guard status == nil else { throw fail("Status without a termination") } }
    }

    /// The follower's invalidation when its owner said nothing.
    static let genericInvalidation = "follower endpoint invalidated"

    /// The owner's last non-empty diagnostic line as plain printable ASCII,
    /// at most 200 bytes (the wire's detail bound is 256); nil when there is
    /// none. Crosses the link encrypted, like every worker-wire message.
    static func ownerReason(_ tail: Data) -> String? {
        let text = String(decoding: tail.suffix(4096), as: UTF8.self)
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map({ $0.trimmingCharacters(in: .whitespaces) }).filter { !$0.isEmpty }
        // The worker's own last word, not the exit echo that follows it: the
        // forced-exit and force-cancel acknowledgements say only that it ended.
        let echo = ["darkbloom-forced-exit-v1", "darkbloom-force-cancel-v1"]
        let prefix = "darkbloom-worker-tail-v1 "
        guard var line = lines.last(where: { line in !echo.contains(where: { line.contains($0) }) }) ?? lines.last else { return nil }
        if line.hasPrefix(prefix) { line = String(line.dropFirst(prefix.count)) }
        let ascii = String(String.UnicodeScalarView(line.unicodeScalars.map { (32...126).contains($0.value) ? $0 : "?" }))
        return ascii.isEmpty ? nil : String(ascii.prefix(200))
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw ClusterLinkWorkerError.invalid("Worker wire exceeds its bound") }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else { throw ClusterLinkWorkerError.invalid("Worker wire exceeds its bound") }
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw ClusterLinkWorkerError.invalid("Malformed worker wire") }
        try value.validate()
        return value
    }

    var ownerTermination: ClusterWorkerProcessTermination? {
        switch termination {
        case "launchFailed": .launchFailed
        case "exited": status.map { .exited($0) }
        case "signalled": status.map { .signalled($0) }
        default: nil
        }
    }

    mutating func setOwnerTermination(_ value: ClusterWorkerProcessTermination?) {
        switch value {
        case .launchFailed?: termination = "launchFailed"; status = nil
        case .exited(let code)?: termination = "exited"; status = code
        case .signalled(let signal)?: termination = "signalled"; status = signal
        case nil: termination = nil; status = nil
        }
    }

    // MARK: Worker commands without host uptime

    /// A command for the other Mac: its reservation deadline becomes the time
    /// remaining (`remainingNanoseconds`), the reservation itself carries a
    /// sentinel that the receiver replaces.
    static func command(_ command: ClusterWorkerCommand, requestID: UUID?, epoch: UUID, session: UUID,
                        sequence: UInt64, now: UInt64, deliveryDeadline: UInt64) throws -> Self {
        guard deliveryDeadline > now else { throw ClusterWorkerOwnerError.deadline }
        var wire = Self(kind: .command, epoch: epoch, session: session, sequence: sequence)
        wire.deliveryRemainingNanoseconds = min(deliveryDeadline - now, ClusterWorkerLimits.deadlineNanoseconds)
        var sent = command
        if case .reserve(let r) = command {
            guard r.deadlineUptimeNanoseconds > now else { throw ClusterWorkerOwnerError.deadline }
            wire.remainingNanoseconds = min(r.deadlineUptimeNanoseconds - now, ClusterWorkerLimits.deadlineNanoseconds)
            sent = .reserve(.init(profileID: r.profileID, promptTokenIDs: r.promptTokenIDs, stopTokenIDs: r.stopTokenIDs,
                outputCount: r.outputCount, chunkSize: r.chunkSize, deadlineUptimeNanoseconds: 1,
                // The sampling and the route cross with the reservation: both ranks get them.
                capacityLimitBytes: r.capacityLimitBytes, sampling: r.sampling, route: r.route,mimoImages:r.mimoImages, stillImages:r.stillImages,
                glmMedia: r.glmMedia))
        }
        wire.worker = try ClusterWorkerCodec.encode(ClusterWorkerCommandFrame(membershipEpoch: epoch, sequence: sequence,
            requestID: requestID, command: sent))
        return wire
    }

    /// The command on this Mac's clock, and its delivery deadline.
    func localCommand(now: UInt64) throws -> (command: ClusterWorkerCommand, requestID: UUID?, deliveryDeadline: UInt64) {
        guard kind == .command, let worker, let delivery = deliveryRemainingNanoseconds else { throw ClusterLinkWorkerError.invalid("No worker command") }
        let frame = try ClusterWorkerCodec.decodeCommand(worker)
        guard frame.membershipEpoch == epoch else { throw ClusterLinkWorkerError.invalid("Inner epoch differs") }
        let end = now.addingReportingOverflow(delivery)
        guard !end.overflow else { throw ClusterLinkWorkerError.invalid("Delivery duration overflow") }
        guard case .reserve(let r) = frame.command else {
            guard remainingNanoseconds == nil else { throw ClusterLinkWorkerError.invalid("Duration on a command without a deadline") }
            return (frame.command, frame.requestID, end.partialValue)
        }
        guard let remaining = remainingNanoseconds, r.deadlineUptimeNanoseconds == 1 else {
            throw ClusterLinkWorkerError.invalid("A reservation must cross without a host uptime")
        }
        let deadline = now.addingReportingOverflow(remaining)
        guard !deadline.overflow else { throw ClusterLinkWorkerError.invalid("Reservation duration overflow") }
        return (.reserve(.init(profileID: r.profileID, promptTokenIDs: r.promptTokenIDs, stopTokenIDs: r.stopTokenIDs,
            outputCount: r.outputCount, chunkSize: r.chunkSize, deadlineUptimeNanoseconds: deadline.partialValue,
            capacityLimitBytes: r.capacityLimitBytes, sampling: r.sampling, route: r.route,mimoImages:r.mimoImages, stillImages:r.stillImages,
            glmMedia: r.glmMedia)), frame.requestID, end.partialValue)
    }
}

/// The leader's endpoint for a follower rank reached over the link control
/// channel. The pair uses it like any other endpoint.
public final class ClusterLinkWorkerEndpoint: ClusterOwnedWorkerEndpoint, @unchecked Sendable {
    /// Past the last lease the leader granted: the follower's own owner
    /// retirement allowance, and slack for the link to deliver its proof.
    public static let retirementAllowanceNanoseconds: UInt64 =
        ClusterRemoteWorkerEndpoint.standardOwnerRetirementAllowanceNanoseconds + 10_000_000_000

    public let expectedIdentity: ClusterWorkerIdentity
    public let expectedProfile: ClusterWorkerProfile
    public let rank: Int
    public let executionPlanSHA256: String
    public let clusterID: String
    /// Names every message of this endpoint on the link.
    public let session = UUID()
    private let transport: any ClusterLinkWorkerTransport
    private let bootstrapRelay: (any ClusterOwnerBootstrapExchange)?
    private let lock = NSLock()
    private let arrivals = DispatchSemaphore(value: 0)
    private let wake = DispatchSemaphore(value: 0)
    private let nativeEnded = DispatchGroup()
    private let ownerEnded = DispatchGroup()
    private let notifications = DispatchQueue(label: "darkbloom.link-worker.invalidation")
    private let bootstrapQueue = DispatchQueue(label: "darkbloom.link-worker.bootstrap")
    private var handler: (@Sendable () -> Void)?
    private var notified = false
    private var invalid = false
    private var fenceRequested = false
    private var fenceSent = false
    private var cleanup = false
    private var released = false
    private var releasedCleanly = false
    private var accepted = false
    private var refusal: String?
    /// What the follower last said about its own endpoint (S24): why it was
    /// invalidated, or how its owner ended without its worker's cleanup.
    private var followerDetail: String?
    private var ready: ClusterWorkerReady?
    private var terminationValue: ClusterWorkerProcessTermination?
    private var incoming: [ClusterWorkerEventFrame] = []
    private var outgoing: [ClusterLinkWorkerWire] = []
    private var queuedCommands = 0
    private var nextOutgoing: UInt64 = 0
    private var nextIncoming: UInt64 = 0
    private var nextNativeEvent: UInt64 = 0
    private var nextBootstrap: UInt64 = 0
    private var bootstrapBusy = false
    private var leaseDeadline: UInt64
    private var nextRenewalAt: UInt64
    private var renewalsSent: UInt64 = 0
    private var writerStopped = false
    private var renewalsSuspended = false
    /// Why the follower was declared lost (its link closed for good or its
    /// process restarted); nil while it is not.
    private var loss: String?
    /// Why this endpoint fenced the follower, as the fence tells it (S24).
    private var fenceReason: String?
    private var refusedWires = 0
    private var lastRefusedWire: String?
    /// Each wait group is left exactly once: by its proof, by the loss, or
    /// past the follower's last possible proof.
    private var nativeEndedLeft = false
    private var ownerEndedLeft = false
    private var proofCeilingPassed = false
    private let retirementAllowance: UInt64
    /// Checks only: the leader goes silent on the lease while the link stays up.
    func suspendRenewalsForTesting() { lock.withLock { renewalsSuspended = true } }

    public var readiness: ClusterWorkerReady? { lock.withLock { invalid ? nil : ready } }
    public var nativeCleanupObserved: Bool { lock.withLock { cleanup } }
    public var ownerDeviceLeaseReleasedObserved: Bool { lock.withLock { released && releasedCleanly } }
    public var ownerTermination: ClusterWorkerProcessTermination? { lock.withLock { terminationValue } }
    public var localLifetimeDeadlineUptimeNanoseconds: UInt64 { lock.withLock { leaseDeadline } }
    public var ownerRetirementDeadlineUptimeNanoseconds: UInt64 {
        lock.withLock { leaseDeadline }.addingReportingOverflow(retirementAllowance).partialValue
    }
    /// What this endpoint knows for the incident of an unresolved stop (S24).
    public var diagnosticSummary: String {
        lock.withLock {
            "rank \(rank) link endpoint: fence \(fenceSent ? "sent" : fenceRequested ? "requested" : "not requested")"
                + (fenceReason.map { " (\($0))" } ?? "") + "; cleanup proof \(cleanup ? "received" : "missing")"
                + "; release proof \(released ? (releasedCleanly ? "received" : "received without the owner's proof") : "missing")"
                + "; refused follower messages \(refusedWires)" + (lastRefusedWire.map { " (last: \($0))" } ?? "")
                + (followerDetail.map { "; the follower said: \($0)" } ?? "")
                + (proofCeilingPassed ? "; the follower's proof ceiling passed" : "")
        }
    }
    /// Why the follower refused the open, if it did.
    public var refusalReason: String? { lock.withLock { refusal } }
    /// Why the follower was declared lost, if it was (`linkLost`).
    public var lossReason: String? { lock.withLock { loss } }
    /// Why the follower's rank ended, in the follower's words (its owner's or
    /// worker's last diagnostic line, plain ASCII, bounded), if it said (S24).
    public var followerReason: String? { lock.withLock { followerDetail } }
    public var renewals: UInt64 { lock.withLock { renewalsSent } }

    /// Opens the session at once: the follower launches its owner when the
    /// open arrives. `lifetimeDeadlineUptimeNanoseconds` is the first rank-lease
    /// grant, on this Mac's clock.
    public init(transport: any ClusterLinkWorkerTransport, clusterID: String, expectedIdentity: ClusterWorkerIdentity,
                profile: ClusterWorkerProfile, rank: Int, executionPlanSHA256: String,
                lifetimeDeadlineUptimeNanoseconds: UInt64, bootstrapRelay: (any ClusterOwnerBootstrapExchange)?,
                dataPlaneTrust: Data? = nil,
                retirementAllowanceNanoseconds: UInt64 = ClusterLinkWorkerEndpoint.retirementAllowanceNanoseconds,
                router: ClusterLinkWorkerRouter? = nil) throws {
        let now = DispatchTime.now().uptimeNanoseconds
        guard lifetimeDeadlineUptimeNanoseconds > now,
              lifetimeDeadlineUptimeNanoseconds - now <= ClusterWorkerLease.maximumNanoseconds else {
            throw ClusterLinkWorkerError.invalid("Invalid first lease grant")
        }
        _ = try ClusterOwnerBinding(clusterID: clusterID, ownerIncarnation: UUID(), leaseID: UUID(),
            identity: expectedIdentity, profile: profile, rank: rank, executionPlanSHA256: executionPlanSHA256)
        if let bootstrapRelay {
            guard bootstrapRelay.identity == expectedIdentity, bootstrapRelay.executionPlanSHA256 == executionPlanSHA256,
                  bootstrapRelay.deadlineUptimeNanoseconds <= lifetimeDeadlineUptimeNanoseconds,
                  !bootstrapRelay.profile.carriesNativeStart || bootstrapRelay.nativeStart(rank: rank)?.rank == rank else {
                throw ClusterLinkWorkerError.invalid("Bootstrap relay configuration differs")
            }
        }
        self.transport = transport; self.clusterID = clusterID; self.expectedIdentity = expectedIdentity
        expectedProfile = profile; self.rank = rank; self.executionPlanSHA256 = executionPlanSHA256
        self.bootstrapRelay = bootstrapRelay
        retirementAllowance = retirementAllowanceNanoseconds
        leaseDeadline = lifetimeDeadlineUptimeNanoseconds
        nextRenewalAt = now + ClusterWorkerLease.renewNanoseconds
        var open = ClusterLinkWorkerWire(kind: .open, epoch: expectedIdentity.membershipEpoch, session: session, sequence: 0)
        open.clusterID = clusterID; open.rank = rank; open.planSHA256 = executionPlanSHA256
        open.remainingNanoseconds = lifetimeDeadlineUptimeNanoseconds - now
        open.dataPlaneTrust = dataPlaneTrust
        if let bootstrapRelay {
            open.bootstrapProfile = bootstrapRelay.profile.rawValue
            open.nativeStart = bootstrapRelay.profile.carriesNativeStart ? bootstrapRelay.nativeStart(rank: rank)?.canonicalBytes : nil
        }
        _ = try open.encoded()
        outgoing.append(open)
        nativeEnded.enter(); ownerEnded.enter()
        // Registered before the open is written, so no reply can miss it.
        router?.register(self)
        let writer = Thread { [weak self] in self?.writeLoop() }
        writer.name = "darkbloom.link-worker.writer"
        writer.start()
    }

    deinit { lock.withLock { writerStopped = true }; wake.signal() }

    public func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        let call = lock.withLock { self.handler = handler; return notificationLocked() }
        if let call { notifications.async(execute: call) }
    }
    private func notificationLocked() -> (@Sendable () -> Void)? {
        guard invalid, !notified, let handler else { return nil }; notified = true; return handler
    }
    private func fail(reason: String? = nil) {
        let call = lock.withLock { () -> (@Sendable () -> Void)? in
            invalid = true; ready = nil
            if let reason, fenceReason == nil { fenceReason = String(decoding: Data(reason.utf8.prefix(250)), as: UTF8.self) }
            if !cleanup { fenceRequested = true }
            return notificationLocked()
        }
        bootstrapRelay?.cancel()
        wake.signal(); arrivals.signal()
        if let call { notifications.async(execute: call) }
    }

    /// Called under Pair/Request locks: validates and queues only.
    public func sendWorkerCommand(_ command: ClusterWorkerCommand, requestID: UUID?, deadline: UInt64) throws {
        try lock.withLock {
            let now = DispatchTime.now().uptimeNanoseconds
            guard !invalid, !cleanup, deadline > now, queuedCommands < 16 else { throw ClusterWorkerOwnerError.closed }
            // Sequenced when written; encoded now so a bad command fails here.
            let wire = try ClusterLinkWorkerWire.command(command, requestID: requestID, epoch: expectedIdentity.membershipEpoch,
                session: session, sequence: 0, now: now, deliveryDeadline: deadline)
            _ = try wire.encoded()
            outgoing.append(wire); queuedCommands += 1
        }
        wake.signal()
    }

    public func receiveWorkerEvent(until deadline: UInt64, cancelled: () -> Bool) throws -> ClusterWorkerEventFrame {
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if cancelled() { throw ClusterWorkerOwnerError.cancelled }
            if let event = lock.withLock({ incoming.isEmpty ? nil : incoming.removeFirst() }) { return event }
            if lock.withLock({ invalid || cleanup }) { throw ClusterWorkerOwnerError.closed }
            _ = arrivals.wait(timeout: .init(uptimeNanoseconds: min(deadline, DispatchTime.now().uptimeNanoseconds + 50_000_000)))
        }
        throw ClusterWorkerOwnerError.deadline
    }

    public func requestNativeCleanup() { fail() }
    public func requestNativeCleanup(reason: String) { fail(reason: reason) }
    private func leaveNativeEnded() {
        let leave = lock.withLock { () -> Bool in if nativeEndedLeft { return false }; nativeEndedLeft = true; return true }
        if leave { nativeEnded.leave() }
    }
    private func leaveOwnerEnded() {
        let leave = lock.withLock { () -> Bool in if ownerEndedLeft { return false }; ownerEndedLeft = true; return true }
        if leave { ownerEnded.leave() }
    }
    /// No proof can arrive any more (the follower's process is gone for good,
    /// or its last possible proof is past): every wait on this endpoint ends
    /// now. Nothing is claimed: cleanup and release stay unobserved.
    func endWaits() { leaveNativeEnded(); leaveOwnerEnded() }
    public func waitForNativeCleanup() { nativeEnded.wait() }
    public func waitUntilNativeCleanup() async {
        await withCheckedContinuation { c in nativeEnded.notify(queue: .global()) { c.resume() } }
    }

    /// The follower's report that its owner released the device, or that it
    /// launched nothing. False at the deadline grants nothing.
    public func waitForOwnerReleased(deadline: UInt64) -> Bool {
        let finished = ownerEnded.wait(timeout: .init(uptimeNanoseconds: deadline)) == .success
        return finished && lock.withLock { cleanup && released && releasedCleanly }
    }
    public func waitUntilOwnerReleased(deadline: UInt64) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: self.waitForOwnerReleased(deadline: deadline)) }
        }
    }

    /// The follower process restarted or the edge was closed for good: its
    /// session is gone. The request in flight fails at once (the endpoint is
    /// invalid, which the pair observes), and nothing waits any longer for a
    /// proof that cannot arrive: the cleanup and release waits return now,
    /// unproven. Ownership stays unresolved on this side (the session is
    /// quarantined, `nativeCleanupObserved` and the release stay false); the
    /// follower's Mac ends the rank by its own lease and its own owner, and a
    /// new open there is refused while that owner holds the device. A proof
    /// that still arrives (the link came back) is recorded as usual.
    public func linkLost(reason: String = "the follower's process restarted or the link closed for good") {
        lock.withLock { if !released, loss == nil { loss = reason } }
        fail(reason: reason)
        endWaits()
    }

    // MARK: Link

    private func writeLoop() {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            let work = lock.withLock { () -> (ClusterLinkWorkerWire?, Bool) in
                if writerStopped || released { return (nil, true) }
                // A failed endpoint whose fence went out keeps nothing to send
                // once the follower's last possible proof is past.
                if invalid && fenceSent && outgoing.isEmpty,
                   now >= leaseDeadline.addingReportingOverflow(retirementAllowance).partialValue {
                    proofCeilingPassed = true; return (nil, true)
                }
                if invalid && !fenceSent && fenceRequested && !cleanup {
                    fenceSent = true
                    // The fence goes before any queued command: nothing more is wanted.
                    outgoing.removeAll(where: { $0.kind == .command }); queuedCommands = 0
                    var fence = ClusterLinkWorkerWire(kind: .fence, epoch: expectedIdentity.membershipEpoch, session: session, sequence: 0)
                    fence.detail = fenceReason // The follower's incident names the cause (S24).
                    outgoing.append(fence)
                }
                // The rank lease is renewed only while this endpoint keeps the
                // follower: never once it failed, fenced or saw cleanup.
                if !invalid && !cleanup && !renewalsSuspended && now >= nextRenewalAt {
                    var renew = ClusterLinkWorkerWire(kind: .renew, epoch: expectedIdentity.membershipEpoch, session: session, sequence: 0)
                    renew.remainingNanoseconds = ClusterWorkerLease.ttlNanoseconds
                    // Before queued commands: a renewal must not wait behind a long reserve.
                    outgoing.insert(renew, at: outgoing.isEmpty || nextOutgoing > 0 ? 0 : 1)
                    renewalsSent += 1; nextRenewalAt = now + ClusterWorkerLease.renewNanoseconds
                    leaseDeadline = max(leaseDeadline, now + ClusterWorkerLease.ttlNanoseconds)
                }
                guard !outgoing.isEmpty else { return (nil, false) }
                var next = outgoing.removeFirst()
                if next.kind == .command { queuedCommands -= 1 }
                next.sequence = nextOutgoing; nextOutgoing += 1
                if next.kind == .command, var frame = try? ClusterWorkerCodec.decodeCommand(next.worker!) {
                    frame = .init(membershipEpoch: frame.membershipEpoch, sequence: next.sequence, requestID: frame.requestID, command: frame.command)
                    next.worker = try? ClusterWorkerCodec.encode(frame)
                }
                return (next, false)
            }
            if work.1 {
                // Past the follower's last possible proof: the waits end (nothing is claimed).
                if lock.withLock({ proofCeilingPassed }) { endWaits() }
                return
            }
            guard let wire = work.0 else {
                _ = wake.wait(timeout: .now() + .milliseconds(250))
                continue
            }
            do { try transport.send(wire.encoded()) } catch { fail() }
        }
    }

    /// One decoded message of this endpoint's session from the link.
    func accept(_ wire: ClusterLinkWorkerWire) {
        do {
            var bootstrapWork: (ClusterOwnerBinding, UInt64, Data)?
            var complete = false, endOwner = false, invalidate = false
            try lock.withLock {
                guard wire.session == session, wire.epoch == expectedIdentity.membershipEpoch, !wire.kind.fromLeader,
                      wire.sequence == nextIncoming else { throw ClusterLinkWorkerError.invalid("Follower session/replay differs") }
                nextIncoming += 1
                switch wire.kind {
                case .accepted:
                    guard !accepted, refusal == nil else { throw ClusterLinkWorkerError.invalid("Repeated acceptance") }
                    accepted = true
                case .refused:
                    // Nothing was launched: there is nothing to clean up or release.
                    guard !accepted, refusal == nil else { throw ClusterLinkWorkerError.invalid("Refusal after acceptance") }
                    refusal = wire.detail ?? ""
                    cleanup = true; released = true; releasedCleanly = true; terminationValue = .launchFailed
                    complete = true; endOwner = true; invalidate = true
                case .invalidated:
                    guard accepted else { throw ClusterLinkWorkerError.invalid("Invalidation before acceptance") }
                    if let detail = wire.detail, detail != ClusterLinkWorkerWire.genericInvalidation { followerDetail = detail }
                    invalidate = true
                case .event:
                    guard accepted, !cleanup, let payload = wire.worker else { throw ClusterLinkWorkerError.invalid("Event outside the session") }
                    let event = try ClusterWorkerCodec.decodeEvent(payload)
                    guard event.membershipEpoch == expectedIdentity.membershipEpoch, event.sequence == nextNativeEvent,
                          incoming.count < 32 else { throw ClusterLinkWorkerError.invalid("Native event replay or queue bound") }
                    if case .ready(let value) = event.event {
                        guard nextNativeEvent == 0, bootstrapRelay.map({ nextBootstrap == UInt64($0.profile.rounds) }) ?? true,
                              value.identity == expectedIdentity, value.profile == expectedProfile,
                              value.rank == rank, value.executionPlanSHA256 == executionPlanSHA256 else {
                            throw ClusterLinkWorkerError.invalid("Follower readiness differs")
                        }
                        ready = value
                    } else { guard nextNativeEvent > 0 else { throw ClusterLinkWorkerError.invalid("Event precedes readiness") } }
                    incoming.append(event); nextNativeEvent += 1
                    switch event.event { case .failed, .unavailable: invalidate = true; default: break }
                case .bootstrapRound:
                    guard accepted, let relay = bootstrapRelay, ready == nil, !cleanup, !bootstrapBusy,
                          wire.bootstrapSequence == nextBootstrap, let bytes = wire.bootstrapBytes,
                          let incarnation = wire.ownerIncarnation, let lease = wire.ownerLease else {
                        throw ClusterLinkWorkerError.invalid("Unexpected bootstrap round")
                    }
                    try relay.profile.validate(sequence: nextBootstrap, contribution: bytes)
                    if invalid { nextBootstrap += 1; break }
                    let binding = try ClusterOwnerBinding(clusterID: clusterID, ownerIncarnation: incarnation, leaseID: lease,
                        identity: expectedIdentity, profile: expectedProfile, rank: rank, executionPlanSHA256: executionPlanSHA256)
                    bootstrapBusy = true; bootstrapWork = (binding, nextBootstrap, bytes)
                case .cleanup:
                    guard accepted, !cleanup else { throw ClusterLinkWorkerError.invalid("Repeated cleanup") }
                    cleanup = true; ready = nil; complete = true; invalidate = true
                case .released:
                    guard accepted, !released else { throw ClusterLinkWorkerError.invalid("Repeated release") }
                    released = true; releasedCleanly = (wire.releasedCleanly ?? false) && cleanup
                    terminationValue = wire.ownerTermination; endOwner = true
                    // The release carries the owner's raw last line; a reason the
                    // follower already stated (how its owner or worker ended, in
                    // those words) says more and is kept.
                    if let detail = wire.detail, followerDetail == nil { followerDetail = detail }
                    // The follower's last message of the session: no cleanup
                    // proof can follow it. A release without one (its owner
                    // ended without proving its worker's exit, e.g. it exited
                    // at launch) ends every wait now, claiming nothing
                    // (`nativeCleanupObserved` stays false, ownership
                    // unresolved, the session quarantined; the follower's
                    // journal keeps the record for `cluster recover`) instead
                    // of holding a stop until its caller's deadline.
                    if !cleanup { complete = true; invalidate = true }
                default: throw ClusterLinkWorkerError.invalid("Leader message from the follower")
                }
            }
            if let (binding, sequence, bytes) = bootstrapWork {
                // The relay waits for rank 0's round: never on the link's queue.
                bootstrapQueue.async {
                    do {
                        let gathered = try self.bootstrapRelay!.exchange(binding: binding, sequence: sequence, contribution: bytes)
                        var reply = ClusterLinkWorkerWire(kind: .bootstrapReply, epoch: self.expectedIdentity.membershipEpoch,
                            session: self.session, sequence: 0)
                        reply.bootstrapSequence = sequence; reply.bootstrapBytes = gathered
                        try self.lock.withLock {
                            guard !self.invalid, !self.cleanup else { throw ClusterWorkerOwnerError.closed }
                            self.outgoing.insert(reply, at: 0); self.nextBootstrap += 1; self.bootstrapBusy = false
                        }
                        self.wake.signal()
                    } catch { self.fail() }
                }
            }
            if complete { leaveNativeEnded() }
            if endOwner { leaveOwnerEnded() }
            if invalidate { fail() }
            arrivals.signal()
        } catch {
            lock.withLock { refusedWires += 1; lastRefusedWire = String("\(wire.kind.rawValue): \(error)".prefix(200)) }
            fail(reason: "a follower message was refused: \(error)")
        }
    }
}

/// What the leader opened on the follower, on the follower's clock.
public struct ClusterLinkWorkerOpen: Sendable {
    public let membershipEpoch: UUID
    public let session: UUID
    public let clusterID: String
    public let rank: Int
    public let executionPlanSHA256: String
    public let bootstrapProfile: ClusterOwnerBootstrapProfile?
    public let nativeStart: ClusterNativeAuthorizationStart?
    public let dataPlaneTrust: Data?
    public let lifetimeDeadlineUptimeNanoseconds: UInt64
}

/// The follower's own configuration for an open it admits: the identity and
/// profile it expects, and how it launches its local owner.
public struct ClusterLinkWorkerAdmission: Sendable {
    public let identity: ClusterWorkerIdentity
    public let profile: ClusterWorkerProfile
    public let launch: @Sendable ((any ClusterOwnerBootstrapExchange)?) throws -> ClusterRemoteWorkerEndpoint
    public init(identity: ClusterWorkerIdentity, profile: ClusterWorkerProfile,
                launch: @escaping @Sendable ((any ClusterOwnerBootstrapExchange)?) throws -> ClusterRemoteWorkerEndpoint) {
        self.identity = identity; self.profile = profile; self.launch = launch
    }
}

/// The follower's side: serves one leader session at a time by launching its
/// local owner and relaying between that owner's endpoint and the link.
public final class ClusterLinkWorkerServer: @unchecked Sendable {
    public typealias Admit = @Sendable (ClusterLinkWorkerOpen) throws -> ClusterLinkWorkerAdmission
    public enum Report: Sendable, Equatable {
        case opened(session: UUID), refused(String), fenced(session: UUID, reason: String)
        case cleanup(session: UUID), released(session: UUID, cleanly: Bool)
    }

    public let clusterID: String
    public let rank: Int
    public let bootstrapProfile: ClusterOwnerBootstrapProfile?
    private let acceptsDataPlaneTrust: Bool
    private let transport: any ClusterLinkWorkerTransport
    private let admit: Admit
    private let report: @Sendable (Report) -> Void
    private let queue = DispatchQueue(label: "darkbloom.link-worker.server")
    private let lock = NSLock()
    private var current: ServerSession?
    private var sessionsServed: UInt64 = 0
    private var stopped = false
    /// The leader's link liveness: a link that closed or went silent and did
    /// not resume in the edge's own re-dial time is a lost leader.
    fileprivate var liveness: ClusterLinkPeerLiveness!

    /// `bootstrapProfile` is this Mac's own selection: an open that names
    /// another is refused (wire bytes alone never enable a profile).
    public init(transport: any ClusterLinkWorkerTransport, clusterID: String, rank: Int = 1,
                bootstrapProfile: ClusterOwnerBootstrapProfile?, linkLimits: ClusterLinkControlLimits = .init(),
                acceptsDataPlaneTrust: Bool = false, admit: @escaping Admit, report: @escaping @Sendable (Report) -> Void = { _ in }) {
        self.transport = transport; self.clusterID = clusterID; self.rank = rank
        self.bootstrapProfile = bootstrapProfile; self.admit = admit; self.report = report
        self.acceptsDataPlaneTrust = acceptsDataPlaneTrust
        liveness = ClusterLinkPeerLiveness(limits: linkLimits) { [weak self] _ in self?.leaderLost(reason: "leader link lost") }
    }

    /// True while a session's owner is alive or its proofs are in flight.
    public var busy: Bool { lock.withLock { current != nil } }
    public var served: UInt64 { lock.withLock { sessionsServed } }

    /// One worker-wire message from the link (the edge's tagged opaque).
    public func deliver(_ bytes: Data) {
        queue.async {
            guard let wire = try? ClusterLinkWorkerWire.decode(bytes), wire.kind.fromLeader else { return }
            if wire.kind == .open { self.open(wire); return }
            let session = self.lock.withLock { self.current }
            guard let session, session.id == wire.session else { return } // Not the live session: stale.
            session.accept(wire)
        }
    }

    /// The leader's process restarted (or the edge closed for good): its
    /// session is gone, so the follower fences what it launched for it at
    /// once instead of at the end of the lease it was granted.
    public func leaderLost(reason: String = "leader lost") {
        queue.async { self.lock.withLock { self.current }?.fence(reason: reason) }
    }

    /// Fences any live session and refuses new opens.
    public func stop() {
        let session = lock.withLock { stopped = true; return current }
        session?.fence(reason: "follower stopping")
    }

    /// Waits until no session is live (its owner released or given up).
    public func waitUntilIdle(deadline: UInt64) -> Bool {
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if !busy { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !busy
    }

    private func open(_ wire: ClusterLinkWorkerWire) {
        var refusedReply = ClusterLinkWorkerWire(kind: .refused, epoch: wire.epoch, session: wire.session, sequence: 0)
        func refuse(_ reason: String) {
            refusedReply.detail = String(reason.prefix(200))
            try? transport.send(refusedReply.encoded())
            report(.refused(reason))
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard wire.sequence == 0, let remaining = wire.remainingNanoseconds, let rank = wire.rank,
              let plan = wire.planSHA256, wire.clusterID == clusterID, rank == self.rank else {
            return refuse("open differs from this member's cluster or rank")
        }
        let (busy, stopped) = lock.withLock { (current != nil, self.stopped) }
        guard !stopped else { return refuse("follower is stopping") }
        guard !busy else { return refuse("follower is serving another session") }
        let profile = wire.bootstrapProfile.flatMap(ClusterOwnerBootstrapProfile.init(rawValue:))
        guard profile == bootstrapProfile, profile != .nativeKeyPrelude else {
            return refuse("bootstrap profile differs from this member's selection")
        }
        var start: ClusterNativeAuthorizationStart?
        if profile?.carriesNativeStart == true {
            guard let bytes = wire.nativeStart, let value = try? ClusterNativeAuthorizationStart(encoded: bytes),
                  value.rank == rank, value.common.epoch == wire.epoch else {
                return refuse("committed native start differs")
            }
            start = value
        } else if wire.nativeStart != nil { return refuse("native start without its profile") }
        guard wire.dataPlaneTrust == nil || acceptsDataPlaneTrust else {
            return refuse("launcher-issued data-plane credential is not enabled by this follower's saved policy")
        }
        let lifetime = now + remaining
        let open = ClusterLinkWorkerOpen(membershipEpoch: wire.epoch, session: wire.session, clusterID: clusterID, rank: rank,
            executionPlanSHA256: plan, bootstrapProfile: profile, nativeStart: start,
            dataPlaneTrust: wire.dataPlaneTrust, lifetimeDeadlineUptimeNanoseconds: lifetime)
        do {
            let admission = try admit(open)
            guard admission.identity.membershipEpoch == wire.epoch else { return refuse("admission epoch differs") }
            let session = try ServerSession(server: self, open: open, admission: admission)
            lock.withLock { current = session; sessionsServed += 1 }
            report(.opened(session: open.session))
            session.begin()
        } catch {
            refuse("open refused: \(error)")
        }
    }

    fileprivate func send(_ wire: ClusterLinkWorkerWire) throws { try transport.send(wire.encoded()) }
    fileprivate func ended(_ session: ServerSession) {
        lock.withLock { if current === session { current = nil } }
    }
    fileprivate func emit(_ value: Report) { report(value) }
}

/// One leader session on the follower.
private final class ServerSession: @unchecked Sendable {
    let id: UUID
    let open: ClusterLinkWorkerOpen
    private unowned let server: ClusterLinkWorkerServer
    private let admission: ClusterLinkWorkerAdmission
    private let lock = NSLock()
    private var endpoint: ClusterRemoteWorkerEndpoint?
    private var proxy: ClusterLinkBootstrapProxy?
    private var nextOutgoing: UInt64 = 0
    private var nextIncoming: UInt64 = 1 // The open was 0.
    private var leaderLease: UInt64
    private var fenced = false
    private var sendFailed = false

    init(server: ClusterLinkWorkerServer, open: ClusterLinkWorkerOpen, admission: ClusterLinkWorkerAdmission) throws {
        self.server = server; self.open = open; self.admission = admission; id = open.session
        leaderLease = open.lifetimeDeadlineUptimeNanoseconds
    }

    private func wire(_ kind: ClusterLinkWorkerWire.Kind) -> ClusterLinkWorkerWire {
        lock.withLock {
            let value = ClusterLinkWorkerWire(kind: kind, epoch: open.membershipEpoch, session: id, sequence: nextOutgoing)
            nextOutgoing += 1
            return value
        }
    }
    /// Sequenced and sent under one lock so the order on the link is the order of sequences.
    private let sendLock = NSLock()
    func send(_ build: (inout ClusterLinkWorkerWire) -> Void, kind: ClusterLinkWorkerWire.Kind) {
        sendLock.withLock {
            var value = wire(kind)
            build(&value)
            do { try server.send(value) } catch { lock.withLock { sendFailed = true } }
        }
    }

    func begin() {
        do {
            var relay: ClusterLinkBootstrapProxy?
            if let profile = open.bootstrapProfile {
                relay = try ClusterLinkBootstrapProxy(profile: profile, identity: admission.identity,
                    executionPlanSHA256: open.executionPlanSHA256,
                    deadlineUptimeNanoseconds: min(open.lifetimeDeadlineUptimeNanoseconds, DispatchTime.now().uptimeNanoseconds + 30_000_000_000),
                    start: open.nativeStart) { [weak self] binding, sequence, bytes in
                        self?.send({ $0.bootstrapSequence = sequence; $0.bootstrapBytes = bytes
                            $0.ownerIncarnation = binding.route.ownerIncarnation; $0.ownerLease = binding.route.leaseID }, kind: .bootstrapRound)
                    }
            }
            lock.withLock { proxy = relay }
            let endpoint = try admission.launch(relay)
            guard endpoint.rank == open.rank, endpoint.expectedIdentity == admission.identity,
                  endpoint.executionPlanSHA256 == open.executionPlanSHA256 else {
                endpoint.requestNativeCleanup()
                throw ClusterLinkWorkerError.invalid("Launched endpoint differs from the open")
            }
            endpoint.setInvalidationHandler { [weak self] in self?.localInvalidated() }
            lock.withLock { self.endpoint = endpoint }
            send({ _ in }, kind: .accepted)
            // An owner handed over already waiting at its mesh rounds (a
            // member's committed start) publishes a round at once: none may
            // reach the leader before the acceptance.
            relay?.markAccepted()
            let pump = Thread { [weak self] in self?.pumpLoop() }
            pump.name = "darkbloom.link-worker.pump"
            pump.start()
        } catch {
            // Nothing is running for this session; the leader learns why.
            send({ $0.detail = String("launch refused: \(error)".prefix(200)) }, kind: .refused)
            server.emit(.refused("launch refused"))
            server.ended(self)
        }
    }

    func accept(_ wire: ClusterLinkWorkerWire) {
        let now = DispatchTime.now().uptimeNanoseconds
        let (ok, endpoint, proxy) = lock.withLock { () -> (Bool, ClusterRemoteWorkerEndpoint?, ClusterLinkBootstrapProxy?) in
            guard wire.sequence == nextIncoming else { return (false, nil, nil) }
            nextIncoming += 1
            return (true, self.endpoint, self.proxy)
        }
        guard ok else { fence(reason: "leader replay or gap"); return }
        switch wire.kind {
        case .renew:
            guard let ttl = wire.remainingNanoseconds else { return }
            lock.withLock { if !fenced { leaderLease = max(leaderLease, now + ttl) } }
        case .fence:
            fence(reason: "leader fenced" + (wire.detail.map { ": " + $0 } ?? ""))
        case .bootstrapReply:
            guard let sequence = wire.bootstrapSequence, let bytes = wire.bootstrapBytes else { return }
            proxy?.deliverReply(sequence: sequence, bytes: bytes)
        case .command:
            do {
                let local = try wire.localCommand(now: now)
                try endpoint?.sendWorkerCommand(local.command, requestID: local.requestID, deadline: local.deliveryDeadline)
            } catch { fence(reason: "command refused") }
        default:
            fence(reason: "unexpected message")
        }
    }

    func fence(reason: String) {
        let (endpoint, proxy, first) = lock.withLock { () -> (ClusterRemoteWorkerEndpoint?, ClusterLinkBootstrapProxy?, Bool) in
            let first = !fenced; fenced = true
            return (self.endpoint, self.proxy, first)
        }
        if first { server.emit(.fenced(session: id, reason: reason)) }
        proxy?.cancel()
        endpoint?.requestNativeCleanup()
    }

    /// How this session's owner ended without its worker's cleanup proof, with
    /// the last line it wrote (bounded, control characters removed): e.g. a
    /// load its memory gate refused. Nil while the owner runs (after waiting
    /// up to `nanoseconds` for it to end) or when its cleanup was proven.
    static func ownerCause(_ endpoint: ClusterRemoteWorkerEndpoint, waitingUpTo nanoseconds: UInt64, evenWithCleanup: Bool = false) -> String? {
        let until = DispatchTime.now().uptimeNanoseconds + nanoseconds
        while endpoint.ownerTermination == nil && DispatchTime.now().uptimeNanoseconds < until { Thread.sleep(forTimeInterval: 0.01) }
        guard let termination = endpoint.ownerTermination, evenWithCleanup || !endpoint.nativeCleanupObserved else { return nil }
        // Its exit is recorded just before its last output is drained (itself
        // bounded at two seconds): wait for that, no longer.
        let drained = DispatchTime.now().uptimeNanoseconds + 2_500_000_000
        while !endpoint.diagnosticDrainComplete && DispatchTime.now().uptimeNanoseconds < drained { Thread.sleep(forTimeInterval: 0.01) }
        let words = String(decoding: endpoint.diagnosticTail, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { String($0.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) }) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            // Bookkeeping records (the forced-exit and orphan-wired lines)
            // are not the reason; the line before them is.
            .last(where: { !$0.isEmpty && !$0.contains("darkbloom-forced-exit-v1") && !$0.contains("darkbloom-orphan-wired-v1") })
        return "its owner \(ClusterRemoteWorkerEndpoint.describe(termination))" + (words.map { ": " + String($0.prefix(160)) } ?? "")
    }

    /// At most `bytes` UTF-8 bytes, cut at a character boundary.
    static func bounded(_ text: String, bytes: Int) -> String {
        var result = ""
        for character in text {
            guard result.utf8.count + String(character).utf8.count <= bytes else { break }
            result.append(character)
        }
        return result
    }

    private func localInvalidated() {
        let (cleanup, endpoint) = lock.withLock { (self.endpoint?.nativeCleanupObserved ?? false, self.endpoint) }
        let reason = endpoint.flatMap { ClusterLinkWorkerWire.ownerReason($0.diagnosticTail) } ?? ClusterLinkWorkerWire.genericInvalidation
        if !cleanup { send({ $0.detail = reason }, kind: .invalidated) }
    }

    /// Relays events, enforces the leader's lease, then reports cleanup and release.
    private func pumpLoop() {
        guard let endpoint = lock.withLock({ self.endpoint }) else { return }
        var sawReady = false
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            let (lease, failed) = lock.withLock { (leaderLease, sendFailed) }
            if now >= lease || failed { fence(reason: failed ? "link send failed" : "leader lease expired") }
            do {
                let event = try endpoint.receiveWorkerEvent(until: now + 100_000_000)
                if case .ready = event.event { sawReady = true }
                let payload = try ClusterWorkerCodec.encode(event)
                send({ $0.worker = payload }, kind: .event)
            } catch ClusterWorkerOwnerError.deadline {
                continue
            } catch {
                // Closed: the endpoint failed or saw native cleanup. Queued
                // events were delivered first. Wait for the cleanup proof, or
                // for the owner to end without one.
                if endpoint.nativeCleanupObserved { break }
                fence(reason: "follower endpoint closed")
                if endpoint.ownerTermination != nil, !endpoint.nativeCleanupObserved { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        if endpoint.nativeCleanupObserved {
            // A worker that ended before it was ever ready (its load refused,
            // say) left a clean proof but no reason anywhere: say how, in its
            // owner's words, before the proof (S24).
            if !sawReady, let cause = Self.ownerCause(endpoint, waitingUpTo: 3_000_000_000, evenWithCleanup: true) {
                server.emit(.fenced(session: id, reason: "follower worker ended before it was ready: " + cause))
                send({ $0.detail = Self.bounded("worker ended before it was ready: " + cause, bytes: 250) }, kind: .invalidated)
            }
            send({ _ in }, kind: .cleanup)
            server.emit(.cleanup(session: id))
        } else if let cause = Self.ownerCause(endpoint, waitingUpTo: 0) {
            // How the owner ended, in its own words (S24): this Mac's report
            // (once more if the first fence could not say it yet) and the
            // leader's incident, not only "rank 1 ended".
            server.emit(.fenced(session: id, reason: "follower endpoint closed: " + cause))
            send({ $0.detail = Self.bounded(cause, bytes: 250) }, kind: .invalidated)
        }
        let deadline = max(endpoint.ownerRetirementDeadlineUptimeNanoseconds, DispatchTime.now().uptimeNanoseconds) + 3_000_000_000
        let cleanly = endpoint.waitForOwnerReleased(deadline: deadline)
        let termination = endpoint.ownerTermination
        // The release says how the rank ended, in the owner's words (its
        // diagnostics are drained once it has ended): a worker that refused
        // or failed on its own ends cleanly too, and only its owner's last
        // line names why. The leader states it.
        let reason = ClusterLinkWorkerWire.ownerReason(endpoint.diagnosticTail)
        send({ $0.releasedCleanly = cleanly; $0.setOwnerTermination(termination); $0.detail = reason }, kind: .released)
        server.emit(.released(session: id, cleanly: cleanly))
        server.ended(self)
    }
}

/// The follower's bootstrap relay: each round of its owner goes to the
/// leader's relay over the link, and the reply comes back the same way.
final class ClusterLinkBootstrapProxy: ClusterOwnerBootstrapExchange, @unchecked Sendable {
    let profile: ClusterOwnerBootstrapProfile
    let identity: ClusterWorkerIdentity
    let executionPlanSHA256: String
    let deadlineUptimeNanoseconds: UInt64
    private let start: ClusterNativeAuthorizationStart?
    private let publish: @Sendable (ClusterOwnerBinding, UInt64, Data) -> Void
    private let condition = NSCondition()
    private var replies: [UInt64: Data] = [:]
    private var failed = false
    private var next: UInt64 = 0
    private var accepted = false

    init(profile: ClusterOwnerBootstrapProfile, identity: ClusterWorkerIdentity, executionPlanSHA256: String,
         deadlineUptimeNanoseconds: UInt64, start: ClusterNativeAuthorizationStart?,
         publish: @escaping @Sendable (ClusterOwnerBinding, UInt64, Data) -> Void) throws {
        guard profile != .nativeKeyPrelude, profile.carriesNativeStart == (start != nil) else {
            throw ClusterLinkWorkerError.invalid("Bootstrap proxy profile/start differs")
        }
        self.profile = profile; self.identity = identity; self.executionPlanSHA256 = executionPlanSHA256
        self.deadlineUptimeNanoseconds = deadlineUptimeNanoseconds; self.start = start; self.publish = publish
    }
    func nativeStart(rank: Int) -> ClusterNativeAuthorizationStart? { start?.rank == rank ? start : nil }
    func cancel() { condition.lock(); failed = true; condition.broadcast(); condition.unlock() }
    /// The session's acceptance went out: rounds may now be published.
    func markAccepted() { condition.lock(); accepted = true; condition.broadcast(); condition.unlock() }
    func deliverReply(sequence: UInt64, bytes: Data) {
        condition.lock(); defer { condition.unlock() }
        guard replies[sequence] == nil, sequence + 1 == next else { failed = true; condition.broadcast(); return }
        replies[sequence] = bytes; condition.broadcast()
    }
    func exchange(binding: ClusterOwnerBinding, sequence: UInt64, contribution: Data) throws -> Data {
        condition.lock()
        guard !failed, sequence == next, binding.identity == identity, binding.executionPlanSHA256 == executionPlanSHA256,
              DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds else {
            failed = true; condition.unlock(); throw ClusterWorkerOwnerErrorProxy.closed
        }
        next += 1
        while !failed && !accepted && DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds {
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02))
        }
        guard !failed, accepted else { failed = true; condition.unlock(); throw ClusterWorkerOwnerErrorProxy.deadline }
        condition.unlock()
        try profile.validate(sequence: sequence, contribution: contribution)
        publish(binding, sequence, contribution)
        condition.lock(); defer { condition.unlock() }
        while !failed && replies[sequence] == nil && DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds {
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02))
        }
        guard !failed, let reply = replies.removeValue(forKey: sequence) else { failed = true; throw ClusterWorkerOwnerErrorProxy.deadline }
        try profile.validateReply(sequence: sequence, contribution: contribution, reply: reply)
        return reply
    }
}

/// Routes the worker wire of one link edge on the leader to the endpoints of
/// live sessions. A message for an unknown session is dropped.
public final class ClusterLinkWorkerRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var endpoints: [UUID: ClusterLinkWorkerEndpoint] = [:]
    private var liveness: ClusterLinkPeerLiveness?
    /// `limits` are the edge's own: they bound how long a live follower needs
    /// to resume its connection (`ClusterLinkPeerLiveness`). `lost` is told
    /// each stated loss, with its reason (the leader's log).
    public init(limits: ClusterLinkControlLimits = .init(),
                schedule: ClusterLinkPeerLiveness.Schedule? = nil,
                lost: (@Sendable (String) -> Void)? = nil) {
        observer = lost
        let observe: @Sendable (String) -> Void = { [weak self] reason in
            lost?(reason); self?.followerLost(reason: reason)
        }
        liveness = schedule.map { ClusterLinkPeerLiveness(limits: limits, schedule: $0, lost: observe) }
            ?? ClusterLinkPeerLiveness(limits: limits, lost: observe)
    }
    private let observer: (@Sendable (String) -> Void)?
    public func register(_ endpoint: ClusterLinkWorkerEndpoint) { lock.withLock { endpoints[endpoint.session] = endpoint } }
    public func unregister(_ endpoint: ClusterLinkWorkerEndpoint) { lock.withLock { endpoints[endpoint.session] = nil } }
    public func deliver(_ bytes: Data) {
        guard let wire = try? ClusterLinkWorkerWire.decode(bytes), !wire.kind.fromLeader else { return }
        lock.withLock { endpoints[wire.session] }?.accept(wire)
    }
    /// The follower's process restarted, or its link closed for good: every
    /// session it served is gone.
    public func followerLost(reason: String = "the follower member's process restarted") {
        for endpoint in lock.withLock({ Array(endpoints.values) }) { endpoint.linkLost(reason: reason) }
    }

    /// The link edge's event handler for this router: tagged opaque messages
    /// to the endpoints, a peer restart to all of them.
    public func handle(_ event: ClusterLinkControlEvent) {
        switch event {
        case .opaque(_, _, let tag, let bytes) where tag == ClusterLinkWorkerWire.tag: deliver(bytes)
        case .peerRestarted:
            let reason = "the follower member's process restarted"
            observer?(reason); followerLost(reason: reason)
        case .connected, .disconnected: liveness?.handle(event)
        default: break
        }
    }
}

extension ClusterLinkWorkerServer {
    /// The link edge's event handler for this server.
    public func handle(_ event: ClusterLinkControlEvent) {
        switch event {
        case .opaque(_, _, let tag, let bytes) where tag == ClusterLinkWorkerWire.tag: deliver(bytes)
        case .peerRestarted: leaderLost()
        case .connected, .disconnected: liveness.handle(event)
        default: break
        }
    }
}
