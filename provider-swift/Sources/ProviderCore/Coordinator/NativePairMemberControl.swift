import Foundation
import Logging
import Network

/// One member's actual owner obligation across reconnects. No inferred native
/// cleanup, second session, automatic retry, or old-grant reuse is permitted.
/// A session ends with its release receipt, or, when none could be sent, once
/// its grant and native cleanup have passed and its owner's exit was observed
/// (`NativePairMemberSession.endedPastCleanup`).
final class NativePairMemberControl: @unchecked Sendable {
    let installation: NativePairMemberInstallation
    private let signer: any AttestationSigner
    private let lock = NSLock()
    private var connection: NativePairMemberConnection?
    private var session: NativePairMemberSession?
    private var inboundSequence: UInt64 = 0
    private var epochs = Set<String>()
    /// What serves a committed start once its owner launched (S10). Weak: the
    /// provider loop that serves holds this control.
    private weak var servingHostReference: (any NativePairMemberServingHost)?
    private var sessionStatusHandler: (@Sendable (ClusterSessionStatus) -> Void)?
    /// For the next session's timeline (`NativePairOwnerTimeline`), each used
    /// once: when the coordinator's cancel of the current session arrived, and
    /// when the last session's run finished (its owner seen stopped). A record only.
    private var lastCancelledAt: UInt64?
    private var lastFinishedAt: UInt64?
    init(installation: NativePairMemberInstallation, signer: any AttestationSigner) {
        self.installation = installation; self.signer = signer
    }
    var servingHost: (any NativePairMemberServingHost)? {
        get { lock.withLock { servingHostReference } }
        set { lock.withLock { servingHostReference = newValue } }
    }
    /// Called with each change of `sessionStatus` while a session runs (its
    /// owner launched; its worker published readiness): the client sends a
    /// heartbeat at once (`NativePairSessionStatusWatch`).
    var sessionStatusChanged: (@Sendable (ClusterSessionStatus) -> Void)? {
        get { lock.withLock { sessionStatusHandler } }
        set { lock.withLock { sessionStatusHandler = newValue } }
    }
    var status: String { lock.withLock { session?.status ?? "idle" } }
    /// The current session's timeline so far (the member log and tests).
    var sessionTimeline: NativePairOwnerTimeline? { lock.withLock { session }?.timeline }
    /// What the next session's timeline will start from (tests).
    var previousSessionMarks: (cancelled: UInt64?, finished: UInt64?) { lock.withLock { (cancelled: lastCancelledAt, finished: lastFinishedAt) } }
    /// The heartbeat's `cluster_session` (S16): present only while an owner
    /// runs for a session; the data-plane properties are what its worker
    /// published in its readiness.
    var sessionStatus: ClusterSessionStatus? {
        guard let current = lock.withLock({ session }), let plane = current.dataPlaneObservation else { return nil }
        let value = ClusterSessionStatus(epoch: current.epoch, generation: current.generation,
            encryptedDataPlane: plane.encrypted, peerVerified: plane.peerVerified)
        return value.isValid ? value : nil
    }
    /// A new connection. A session away in its disconnect grace (its
    /// registration on this connection claimed it with `resume`) moves to it;
    /// the coordinator then renews its grant here. `now` is this Mac's uptime.
    func attach(nonce: String, connection nw: NWConnection,
                now: UInt64 = DispatchTime.now().uptimeNanoseconds) throws -> NativePairMemberConnection {
        try lock.withLock {
            freeEndedSession(now: now)
            guard session == nil || session?.resumeClaim != nil, connection?.isLive != true else { throw NativePairMemberError.inactive }
            let next = NativePairMemberConnection(nonce: nonce, connection: nw, signer: signer,
                onInvalidation: { [weak self] value in self?.detach(value) })
            try session?.reattach(next)
            connection = next; inboundSequence = 0; return next
        }
    }
    /// A connection boundary. An established session keeps its owner for the
    /// disconnect grace, never past its grant; anything else ends now.
    func detach(_ expected: NativePairMemberConnection) {
        let old = lock.withLock { () -> NativePairMemberSession? in
            guard connection === expected else { return nil }; connection = nil; return session
        }
        expected.invalidate(); _ = old?.detached()
    }
    /// The `resume` claim to register on the next connection, if a session is
    /// away in its grace.
    var resumeClaim: ClusterMembership.Resume? { lock.withLock { session?.resumeClaim } }
    func receive(_ message: NativePairMessage, on expected: NativePairMemberConnection,
                 receivedAt: UInt64, wallUnixNanoseconds: Int64) throws {
        var start: NativePairMemberSession?
        var cancel: NativePairMemberSession?
        do {
            try lock.withLock {
                guard connection === expected, expected.isLive, message.memberNonce == expected.nonce,
                      message.signature == nil, NativePairMessage.outboundTypes.contains(message.type),
                      message.sequence > inboundSequence,
                      message.type == "native_pair_cancel" || message.sequence == inboundSequence + 1 else { throw NativePairMemberError.binding }
                // B may discard unsent earlier frames when publishing cancellation;
                // only that terminal record may skip a connection sequence.
                inboundSequence = message.sequence
                if message.type == "native_pair_prepare" {
                    freeEndedSession(now: receivedAt)
                    guard session == nil, epochs.count < 1024, epochs.insert(message.epoch).inserted else { throw NativePairMemberError.inactive }
                    let value = try NativePairMemberSession(installation: installation, connection: expected,
                        message: message, receivedAt: receivedAt, wallUnixNanoseconds: wallUnixNanoseconds,
                        servingHost: servingHostReference, previousCancelled: lastCancelledAt,
                        previousFinished: lastFinishedAt) { [weak self] old, reusable in
                            self?.finished(old, reusable: reusable)
                        }
                    session = value; start = value; lastCancelledAt = nil; lastFinishedAt = nil
                } else if message.type == "native_pair_cancel" {
                    // A cancel only stops. It names its session by epoch,
                    // generation and preparation time and is honoured whatever
                    // grant expiry it repeats: the coordinator sends a cancel
                    // with the session's first grant even after renewals moved
                    // it, and a strict check turned that cancel into a dropped
                    // control connection (no receipt, a quarantined session, the
                    // member refused on its next registration; hardware pub4).
                    // A cancel for a session that already ended is ignored.
                    guard Data(base64Encoded: message.payload) == Data([68, 66, 78, 67, 1]) else { throw NativePairMemberError.binding }
                    if let current = session, message.epoch == current.epoch, message.generation == current.generation,
                       message.prepareBeforeUnixNano == current.prepareUnixNanoseconds {
                        cancel = current; lastCancelledAt = receivedAt
                    }
                } else {
                    guard let current = session, message.epoch == current.epoch,
                          message.generation == current.generation,
                          message.prepareBeforeUnixNano == current.prepareUnixNanoseconds,
                          message.type == "native_pair_lease" || message.expiresAtUnixNano == current.expiresUnixNanoseconds else { throw NativePairMemberError.binding }
                    try current.accept(message, receivedAt: receivedAt, wallUnixNanoseconds: wallUnixNanoseconds)
                }
            }
            cancel?.cancel(notify: false, reason: "the coordinator cancelled it"); start?.run()
            if let start { watchSessionStatus(start) }
        } catch { detach(expected); throw NativePairMemberError.binding }
    }
    /// A graceful member stop, while the control connection is still open:
    /// end the running session (native cleanup of its owner; a no-op once the
    /// owner already released) and wait, bounded, until it finished, so its
    /// authenticated release receipt reaches the coordinator before the
    /// connection closes. Returns whether no session is left running.
    func endSessionBeforeClose(timeout: TimeInterval) async -> Bool {
        guard let current = lock.withLock({ session }) else { return true }
        current.cancel(notify: false, reason: "this Mac's member is stopping")
        let deadline = Date().addingTimeInterval(timeout)
        // The wait blocks a thread for up to the timeout: a dispatch thread,
        // never one of the cooperative pool's.
        let finished = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async { done.resume(returning: current.waitUntilFinished(deadline: deadline)) }
        }
        // What the stop left: the line a release check reads in the member log.
        let outcome = current.status
        if finished, outcome == "released" {
            nativeMemberLog.info("member stop: committed session \(current.epoch) released its owner and sent its release receipt")
        } else {
            nativeMemberLog.warning("member stop: committed session \(current.epoch) sent no release receipt (\(finished ? outcome : "still running after \(Int(timeout)) s"))")
        }
        return finished
    }
    /// The held session's native cleanup bound on this Mac's uptime clock.
    var cleanupDeadline: UInt64? { lock.withLock { session?.cleanupDeadline } }
    /// Reports each change of the started session's report while it is the current one.
    private func watchSessionStatus(_ value: NativePairMemberSession) {
        NativePairSessionStatusWatch.start(
            current: { [weak self] in self?.sessionStatus },
            live: { [weak self, weak value] in
                guard let self, let value else { return false }
                return self.lock.withLock { self.session === value }
            },
            changed: { [weak self] status in self?.sessionStatusChanged?(status) })
    }
    /// A session that ended without its release receipt (its connection
    /// closed first, or its owner ended without the release proof) is freed
    /// once `endedPastCleanup` holds. Kept longer, it refused every new
    /// connection and prepare until the member restarted. The caller holds `lock`.
    private func freeEndedSession(now: UInt64) {
        guard let current = session, current.endedPastCleanup(now: now) else { return }
        session = nil
        nativeMemberLog.info("committed session \(current.epoch): freed without a release receipt (\(current.status)); its grant and native cleanup have passed and its owner is gone")
    }
    private func finished(_ old: NativePairMemberSession, reusable: Bool) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.withLock {
            guard session === old else { return }
            lastFinishedAt = now
            // An unacknowledged cleanup or old disconnected identity stays
            // quarantined. Public EOF/timeout is never a replacement slot.
            if reusable { session = nil }
        }
    }
}
