import Foundation
import Network

/// One member's actual owner obligation across reconnects. No inferred native
/// cleanup, second session, automatic retry, or old-grant reuse is permitted.
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
    init(installation: NativePairMemberInstallation, signer: any AttestationSigner) {
        self.installation = installation; self.signer = signer
    }
    var servingHost: (any NativePairMemberServingHost)? {
        get { lock.withLock { servingHostReference } }
        set { lock.withLock { servingHostReference = newValue } }
    }
    var status: String { lock.withLock { session?.status ?? "idle" } }
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
    /// the coordinator then renews its grant here.
    func attach(nonce: String, connection nw: NWConnection) throws -> NativePairMemberConnection {
        try lock.withLock {
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
                    guard session == nil, epochs.count < 1024, epochs.insert(message.epoch).inserted else { throw NativePairMemberError.inactive }
                    let value = try NativePairMemberSession(installation: installation, connection: expected,
                        message: message, receivedAt: receivedAt, wallUnixNanoseconds: wallUnixNanoseconds,
                        servingHost: servingHostReference) { [weak self] old, reusable in
                            self?.finished(old, reusable: reusable)
                        }
                    session = value; start = value
                } else {
                    guard let current = session, message.epoch == current.epoch,
                          message.generation == current.generation,
                          message.prepareBeforeUnixNano == current.prepareUnixNanoseconds,
                          message.type == "native_pair_lease" || message.expiresAtUnixNano == current.expiresUnixNanoseconds else { throw NativePairMemberError.binding }
                    if message.type == "native_pair_cancel" {
                        guard Data(base64Encoded: message.payload) == Data([68, 66, 78, 67, 1]) else { throw NativePairMemberError.binding }
                        cancel = current
                    } else { try current.accept(message, receivedAt: receivedAt, wallUnixNanoseconds: wallUnixNanoseconds) }
                }
            }
            cancel?.cancel(notify: false); start?.run()
        } catch { detach(expected); throw NativePairMemberError.binding }
    }
    /// A graceful member stop, while the control connection is still open:
    /// end the running session (native cleanup of its owner; a no-op once the
    /// owner already released) and wait, bounded, until it finished, so its
    /// authenticated release receipt reaches the coordinator before the
    /// connection closes. Returns whether no session is left running.
    func endSessionBeforeClose(timeout: TimeInterval) async -> Bool {
        guard let current = lock.withLock({ session }) else { return true }
        current.cancel(notify: false)
        let deadline = Date().addingTimeInterval(timeout)
        return await Task.detached { current.waitUntilFinished(deadline: deadline) }.value
    }
    private func finished(_ old: NativePairMemberSession, reusable: Bool) {
        lock.withLock {
            guard session === old else { return }
            // An unacknowledged cleanup or old disconnected identity stays
            // quarantined. Public EOF/timeout is never a replacement slot.
            if reusable { session = nil }
        }
    }
}
