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
    private var localStartClosedConnection: NativePairMemberConnection?
    private var localServingClosed = false
    private var inboundSequence: UInt64 = 0
    private var epochs = Set<String>()
    init(installation: NativePairMemberInstallation, signer: any AttestationSigner) {
        self.installation = installation; self.signer = signer
    }
    var status: String { lock.withLock { session?.status ?? "idle" } }
    func attach(nonce: String, connection nw: NWConnection) throws -> NativePairMemberConnection {
        try lock.withLock {
            guard !localServingClosed, session == nil, connection?.isLive != true else { throw NativePairMemberError.inactive }
            let next = NativePairMemberConnection(nonce: nonce, connection: nw, signer: signer,
                onInvalidation: { [weak self] value in self?.detach(value) })
            connection = next; localStartClosedConnection = nil; inboundSequence = 0; return next
        }
    }
    func detach(_ expected: NativePairMemberConnection) {
        let old = lock.withLock { () -> NativePairMemberSession? in
            guard connection === expected else { return nil }; connection = nil; return session
        }
        expected.invalidate(); old?.cancel(notify: false)
    }
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
                    guard !localServingClosed, localStartClosedConnection !== expected, session == nil, epochs.count < 1024, epochs.insert(message.epoch).inserted else { throw NativePairMemberError.inactive }
                    let value = try NativePairMemberSession(installation: installation, connection: expected,
                        message: message, receivedAt: receivedAt, wallUnixNanoseconds: wallUnixNanoseconds) { [weak self] old, reusable in
                            self?.finished(old, reusable: reusable)
                        }
                    session = value; start = value
                } else {
                    guard let current = session, message.epoch == current.epoch,
                          message.generation == current.generation,
                          message.prepareBeforeUnixNano == current.prepareUnixNanoseconds,
                          message.expiresAtUnixNano == current.expiresUnixNanoseconds else { throw NativePairMemberError.binding }
                    if message.type == "native_pair_cancel" {
                        guard Data(base64Encoded: message.payload) == Data([68, 66, 78, 67, 1]) else { throw NativePairMemberError.binding }
                        cancel = current
                    } else { try current.accept(message) }
                }
            }
            cancel?.cancel(notify: false); start?.run()
        } catch { detach(expected); throw NativePairMemberError.binding }
    }
    func cancelRequests() {let current=lock.withLock{session};current?.cancel(notify:true)}
    /// Terminal closure of one fresh local-serving loop, including cancellation
    /// before registration/claim. Reconnect can never reopen this control.
    func closeLocalServing() -> Task<Void, Never> {
        let current = lock.withLock { localServingClosed = true; return session }
        current?.cancel(notify: true)
        return Task { if let current { _ = await current.completion.wait() } }
    }
    func requestOwner(profile: DistributedResidentExecutionProfile, until deadline: UInt64) throws -> NativePairRequestExecutionOwner {
        try retainedSessionClaim().claim(profile: profile, until: deadline).requestOwner
    }
    // Capture a specific session before asynchronous preparation. Cancellation
    // and the post-claim check never consult a replacement generation.
    func retainedSessionClaim() throws -> NativePairRetainedSessionClaim {
        let current = try lock.withLock { () throws -> NativePairMemberSession in
            guard !localServingClosed, installation.rank == 0, installation.protectedRuntime != nil, let session,
                  connection === session.connection, session.connection.isLive else { throw NativePairMemberError.inactive }
            return session
        }
        return retainedClaim(current)
    }
    func localStart() throws -> NativePairLocalStart {
        let expected = try lock.withLock { () throws -> NativePairMemberConnection in
            guard !localServingClosed, installation.rank == 0, installation.protectedRuntime != nil,
                  let connection, connection.isLive, localStartClosedConnection !== connection else { throw NativePairMemberError.inactive }
            return connection
        }
        return NativePairLocalStart(next: { [self, expected] in
            let current = try lock.withLock { () throws -> NativePairMemberSession? in
                guard !localServingClosed, connection === expected, expected.isLive,
                      localStartClosedConnection !== expected else { throw NativePairMemberError.inactive }
                guard let session else { return nil }
                guard session.connection === expected else { throw NativePairMemberError.binding }
                return session
            }
            return current.map { retainedClaim($0) }
        }, closeScope: { [self, expected] in
            let current = lock.withLock { () -> NativePairMemberSession? in
                if connection === expected { localStartClosedConnection = expected }
                // A disconnect can clear connection before the old session joins.
                // Only its exact connection may be cancelled by this scope.
                guard session?.connection === expected else { return nil }
                return session
            }
            current?.cancel(notify: true)
            return Task { if let current { _ = await current.completion.wait() } }
        })
    }
    private func retainedClaim(_ current: NativePairMemberSession) -> NativePairRetainedSessionClaim {
        NativePairRetainedSessionClaim(session: current) { [weak self] in
            guard let self else { throw NativePairMemberError.inactive }
            try self.lock.withLock {
                guard !self.localServingClosed, self.session === current, self.connection === current.connection,
                      self.localStartClosedConnection !== current.connection,
                      current.connection.isLive else { throw NativePairMemberError.inactive }
            }
        }
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
