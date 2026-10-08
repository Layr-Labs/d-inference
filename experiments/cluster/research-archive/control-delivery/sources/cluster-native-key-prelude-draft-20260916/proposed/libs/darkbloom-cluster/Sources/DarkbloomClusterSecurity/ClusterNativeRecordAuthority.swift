import CryptoKit
import DarkbloomClusterBootstrap
import Foundation

public struct ClusterNativeKeyReceipt: Sendable {
    public let epoch: UUID
    public let rank: Int
    public let localPublicKey: Data
    public let peerPublicKey: Data
    public let transcriptSHA256: Data
}

/// Native-only private-key owner. Construction requires the opaque context
/// returned by an actual parent-PID-authenticated prelude, not public grant data.
/// It supplies the existing record transport once without exporting any secret.
/// The native session retains this authority through transport retirement;
/// destroying the authority invalidates its transport.
/// This does not approve a runtime, reserve native memory, or release a lease.
public final class ClusterNativeRecordAuthority: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private enum Phase: Equatable { case fresh, establishing, confirmed, consuming, consumed, failed }
    private let context: ClusterNativePreludeContext
    private let start: ClusterNativeAuthorizationStart
    private let lock = NSLock()
    private var phase: Phase = .fresh
    private var privateKey: Curve25519.KeyAgreement.PrivateKey?
    private var recordMaster: SymmetricKey?
    private var acceptedBinding: ClusterNativeKeyBinding?
    private var transport: ClusterAuthenticatedRecordTransport?
    public var description: String { "ClusterNativeRecordAuthority(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(String?, Any)>()) }

    public init(ownedPrelude context: ClusterNativePreludeContext) throws {
        do {
            let start = try ClusterNativeAuthorizationStart(encoded: context.startBytes)
            guard start.common.epoch == context.identity.membershipEpoch, start.rank == context.identity.rank else {
                throw ClusterNativeKeyError.wrongContext
            }
            let key = Curve25519.KeyAgreement.PrivateKey()
            try context.requireLive()
            self.context = context; self.start = start; privateKey = key
            try context.claimNativeKeyHolder { [weak self] in self?.invalidate() }
            try context.requireLive()
        } catch {
            context.cancel()
            throw (error as? ClusterNativeKeyError) ?? .authenticationFailed
        }
    }

    deinit { invalidate() }

    /// Blocking socket waits have the original local bootstrap deadline and are
    /// interruptible through invalidate(). No lock is held during IO or crypto.
    public func establish() throws -> ClusterNativeKeyReceipt {
        do {
            let key: Curve25519.KeyAgreement.PrivateKey = try lock.withLock {
                guard phase == .fresh, let key = privateKey else { throw ClusterNativeKeyError.concurrentOperation }
                phase = .establishing; return key
            }
            try context.requireLive()
            let hello = try ClusterNativeKeyHello(start: start, publicKey: key.publicKey.rawRepresentation)
            let binding = try ClusterNativeKeyBinding(encoded: context.exchangeHello(hello.canonicalBytes))
            guard binding.hellos[start.rank].canonicalBytes == hello.canonicalBytes else {
                throw ClusterNativeKeyError.wrongContext
            }
            try context.requireLive()
            let digest = binding.transcriptSHA256
            let peer = binding.hellos[1 - start.rank].publicKey
            let keys = try NativeTrafficKeyDerivation.derive(privateKey: key, peerPublicKey: peer, transcriptSHA256: digest)
            let ownTag = try NativeTrafficKeyDerivation.confirmation(rank: start.rank, transcriptSHA256: digest, key: keys.confirmation)
            try context.requireLive()
            let peerTag = try context.exchangeConfirmation(ownTag)
            try NativeTrafficKeyDerivation.verify(peerTag, rank: 1 - start.rank, transcriptSHA256: digest, key: keys.confirmation)
            try context.requireLive()
            try context.complete(transcriptSHA256: digest)
            try context.requireLive()
            try lock.withLock {
                guard phase == .establishing else { throw ClusterNativeKeyError.inactive }
                guard DispatchTime.now().uptimeNanoseconds < context.deadlineUptimeNanoseconds else { throw ClusterNativeKeyError.deadline }
                recordMaster = keys.recordMaster; privateKey = nil; acceptedBinding = binding; phase = .confirmed
            }
            return .init(epoch: start.common.epoch, rank: start.rank, localPublicKey: hello.publicKey,
                         peerPublicKey: peer, transcriptSHA256: digest)
        } catch {
            invalidate()
            throw (error as? ClusterNativeKeyError) ?? .authenticationFailed
        }
    }

    /// Called once as the protected group is constructed, before weights/load
    /// readiness. Creation must finish within the original bootstrap deadline.
    /// Afterward native session/request checks retain their original lifetime;
    /// this key helper neither refreshes those deadlines nor owns model state.
    public func makeRecordTransport(io: any ClusterRecordByteIO) throws -> ClusterAuthenticatedRecordTransport {
        do {
            let values: (SymmetricKey, ClusterNativeKeyBinding) = try lock.withLock {
                guard phase == .confirmed, let key = recordMaster, let binding = acceptedBinding else {
                    throw ClusterNativeKeyError.alreadyConsumed
                }
                guard DispatchTime.now().uptimeNanoseconds < context.deadlineUptimeNanoseconds else { throw ClusterNativeKeyError.deadline }
                phase = .consuming; recordMaster = nil
                return (key, binding)
            }
            guard io.localRank == start.rank, io.worldSize == 2,
                  io.maximumFrameBytes == start.common.maximumTransportFrameBytes else { throw ClusterNativeKeyError.wrongContext }
            let recordBinding = try ClusterRecordBinding(epoch: start.common.epoch, planSHA256: start.common.planSHA256,
                membershipTranscriptSHA256: values.1.transcriptSHA256)
            let created = try ClusterAuthenticatedRecordTransport(sessionKey: values.0, binding: recordBinding,
                limits: start.common.limits, io: io)
            do {
                try lock.withLock {
                    guard phase == .consuming else { throw ClusterNativeKeyError.inactive }
                    guard DispatchTime.now().uptimeNanoseconds < context.deadlineUptimeNanoseconds else { throw ClusterNativeKeyError.deadline }
                    transport = created; phase = .consumed
                }
            } catch { created.invalidate(); throw error }
            return created
        } catch {
            invalidate()
            throw (error as? ClusterNativeKeyError) ?? .authenticationFailed
        }
    }

    /// Immediate local invalidation. It interrupts prelude IO and poisons any
    /// constructed codec; native cancellation/retirement remain caller-owned.
    public func invalidate() {
        let value = lock.withLock {
            phase = .failed; privateKey = nil; recordMaster = nil
            return transport
        }
        context.cancel(); value?.invalidate()
    }
}
