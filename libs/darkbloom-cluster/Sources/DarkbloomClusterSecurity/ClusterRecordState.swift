import CryptoKit
import Foundation

/// Owns sequencing and publication only. A copied operation key may remain on
/// its synchronous crypto stack until that call returns; invalidation prevents
/// publication immediately but does not claim immediate key-memory erasure.
final class ClusterRecordState: @unchecked Sendable {
    struct Work: Sendable {
        let id: UInt64
        let outbound: Bool
        let key: SymmetricKey
        let header: ClusterRecordHeader
        let authenticatedData: Data
    }

    private let lock = NSLock()
    private let binding: ClusterRecordBinding
    private let limits: ClusterRecordLimits
    private let localRank: UInt8
    private var sendKey: SymmetricKey?
    private var receiveKey: SymmetricKey?
    private var active = true
    private var inFlight: UInt64?
    private var nextOperation: UInt64 = 0
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    private var sentBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0

    init(sessionKey: SymmetricKey, binding: ClusterRecordBinding,
         localRank: Int, limits: ClusterRecordLimits) throws {
        guard sessionKey.bitCount == 256 else { throw ClusterRecordError.invalidKeySize }
        guard (0...1).contains(localRank) else { throw ClusterRecordError.invalidConfiguration }
        self.binding = binding; self.localRank = UInt8(localRank); self.limits = limits
        var salt = Data("darkbloom/rdma-record/hkdf-salt/v1\0".utf8)
        salt.append(binding.canonicalBytes); salt.append(limits.canonicalBytes)
        func derive(_ rank: UInt8) -> SymmetricKey {
            var info = Data("darkbloom/rdma-record/directional-aes256-gcm/v1\0".utf8)
            info.append(contentsOf: [rank, 1 - rank])
            return HKDF<SHA256>.deriveKey(inputKeyMaterial: sessionKey, salt: salt,
                info: info, outputByteCount: 32)
        }
        sendKey = derive(UInt8(localRank)); receiveKey = derive(UInt8(1 - localRank))
    }

    var status: ClusterRecordStatus {
        lock.lock(); defer { lock.unlock() }
        return .init(active: active, operationInFlight: inFlight != nil,
            sealedRecords: sent, openedRecords: received,
            sealedPlaintextBytes: sentBytes, openedPlaintextBytes: receivedBytes)
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        invalidateLocked()
    }

    /// Aborts only the caller's ticket; a racing reject must not falsely report
    /// that another synchronous crypto operation has finished.
    func fail(operation: UInt64?) {
        lock.lock(); defer { lock.unlock() }
        invalidateLocked()
        if let operation, inFlight == operation { inFlight = nil }
    }

    func beginSeal(byteCount: Int, context: ClusterRecordContext) throws -> Work {
        lock.lock(); defer { lock.unlock() }
        do {
            try requireIdleLocked()
            try requireBudgetLocked(bytes: byteCount, count: sent, used: sentBytes)
            guard let sendKey else { throw ClusterRecordError.inactive }
            let header = ClusterRecordHeader(direction: localRank, type: context.type,
                sequence: sent, plaintextBytes: byteCount)
            return installLocked(outbound: true, key: sendKey, header: header, context: context)
        } catch { invalidateLocked(); throw error }
    }

    func beginOpen(header: ClusterRecordHeader, recordByteCount: Int,
                   context: ClusterRecordContext) throws -> Work {
        lock.lock(); defer { lock.unlock() }
        do {
            try requireIdleLocked()
            guard header.direction == 1 - localRank, header.type == context.type,
                  header.recordByteCount == recordByteCount else {
                throw ClusterRecordError.unexpectedRecord
            }
            guard header.sequence == received else { throw ClusterRecordError.sequenceMismatch }
            try requireBudgetLocked(bytes: header.plaintextBytes, count: received, used: receivedBytes)
            guard let receiveKey else { throw ClusterRecordError.inactive }
            return installLocked(outbound: false, key: receiveKey, header: header, context: context)
        } catch { invalidateLocked(); throw error }
    }

    /// The codec calls this only after seal or authenticated open succeeds.
    /// Authentication failure never advances a receive counter or byte budget.
    func finish(_ work: Work) throws {
        lock.lock(); defer { lock.unlock() }
        guard inFlight == work.id else {
            invalidateLocked(); throw ClusterRecordError.inactive
        }
        inFlight = nil
        guard active else { throw ClusterRecordError.inactive }
        if work.outbound {
            guard work.header.sequence == sent else {
                invalidateLocked(); throw ClusterRecordError.sequenceMismatch
            }
            sent += 1; sentBytes += UInt64(work.header.plaintextBytes)
        } else {
            guard work.header.sequence == received else {
                invalidateLocked(); throw ClusterRecordError.sequenceMismatch
            }
            received += 1; receivedBytes += UInt64(work.header.plaintextBytes)
        }
    }

    private func requireIdleLocked() throws {
        guard active else { throw ClusterRecordError.inactive }
        guard inFlight == nil else { throw ClusterRecordError.concurrentOperation }
    }

    private func requireBudgetLocked(bytes: Int, count: UInt64, used: UInt64) throws {
        guard bytes > 0, bytes <= limits.maximumPlaintextBytes else {
            throw ClusterRecordError.recordTooLarge
        }
        // The hard record cap is below UInt64.max. Check before any addition,
        // nonce construction or operation ticket; exhaustion poisons the channel.
        guard count < limits.maximumRecordsPerDirection,
              used <= limits.maximumCumulativePlaintextBytesPerDirection,
              UInt64(bytes) <= limits.maximumCumulativePlaintextBytesPerDirection - used else {
            throw ClusterRecordError.usageLimitReached
        }
    }

    private func installLocked(outbound: Bool, key: SymmetricKey,
                               header: ClusterRecordHeader, context: ClusterRecordContext) -> Work {
        let id = nextOperation
        nextOperation += 1 // At most 2 * hardMaximumRecords for this channel.
        inFlight = id
        var aad = Data("darkbloom/rdma-record/aad/v1\0".utf8)
        aad.append(binding.canonicalBytes); aad.append(limits.canonicalBytes)
        aad.append(context.canonicalBytes); aad.append(header.encoded)
        return .init(id: id, outbound: outbound, key: key, header: header, authenticatedData: aad)
    }

    private func invalidateLocked() {
        active = false; sendKey = nil; receiveKey = nil
    }
}
