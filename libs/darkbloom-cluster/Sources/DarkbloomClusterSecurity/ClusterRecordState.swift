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
    /// Nil keeps the original behaviour: one key per direction for the whole
    /// session, generation zero on the wire, limits over the whole session.
    private let rekey: ClusterRecordRekeyPolicy?
    private let clock: @Sendable () -> UInt64
    private var sendKey: SymmetricKey?
    private var receiveKey: SymmetricKey?
    private var active = true
    private var inFlight: UInt64?
    private var nextOperation: UInt64 = 0
    // Session totals: the global sequence of each direction (never reset).
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    private var sentBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    // The current generation of each direction and what it has carried.
    private var sendGeneration: UInt32 = 0
    private var receiveGeneration: UInt32 = 0
    private var sentInGeneration: UInt64 = 0
    private var receivedInGeneration: UInt64 = 0
    private var sentBytesInGeneration: UInt64 = 0
    private var receivedBytesInGeneration: UInt64 = 0
    private var sendGenerationStarted: UInt64

    init(sessionKey: SymmetricKey, binding: ClusterRecordBinding,
         localRank: Int, limits: ClusterRecordLimits, rekey: ClusterRecordRekeyPolicy? = nil,
         clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) throws {
        guard sessionKey.bitCount == 256 else { throw ClusterRecordError.invalidKeySize }
        guard (0...1).contains(localRank) else { throw ClusterRecordError.invalidConfiguration }
        if let rekey { guard rekey.fits(limits) else { throw ClusterRecordError.invalidConfiguration } }
        self.binding = binding; self.localRank = UInt8(localRank); self.limits = limits
        self.rekey = rekey; self.clock = clock; sendGenerationStarted = clock()
        var salt = Data("darkbloom/rdma-record/hkdf-salt/v1\0".utf8)
        salt.append(binding.canonicalBytes); salt.append(limits.canonicalBytes)
        // A rekeying channel binds its policy too, so both ends must agree on it.
        if let rekey { salt.append(rekey.canonicalBytes) }
        func derive(_ rank: UInt8) -> SymmetricKey {
            var info = Data("darkbloom/rdma-record/directional-aes256-gcm/v1\0".utf8)
            info.append(contentsOf: [rank, 1 - rank])
            return HKDF<SHA256>.deriveKey(inputKeyMaterial: sessionKey, salt: salt,
                info: info, outputByteCount: 32)
        }
        sendKey = derive(UInt8(localRank)); receiveKey = derive(UInt8(1 - localRank))
    }

    /// The next generation's key of one direction, from the current one only.
    static func nextKey(_ key: SymmetricKey, direction: UInt8, generation: UInt32) -> SymmetricKey {
        var info = Data("darkbloom/rdma-record/rekey/v1\0".utf8)
        info.append(direction); info.clusterAppendBigEndian(generation)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data("darkbloom/rdma-record/rekey-salt/v1\0".utf8),
            info: info, outputByteCount: 32)
    }

    var status: ClusterRecordStatus {
        lock.lock(); defer { lock.unlock() }
        return .init(active: active, operationInFlight: inFlight != nil,
            sealedRecords: sent, openedRecords: received,
            sealedPlaintextBytes: sentBytes, openedPlaintextBytes: receivedBytes,
            sendGeneration: sendGeneration, receiveGeneration: receiveGeneration)
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
            if let rekey, sendKey != nil {
                let now = clock()
                let due = sentInGeneration >= rekey.records
                    || UInt64(max(byteCount, 0)) > rekey.bytes - min(sentBytesInGeneration, rekey.bytes)
                    || (rekey.seconds > 0 && now &- sendGenerationStarted >= rekey.seconds * 1_000_000_000)
                if due && (sentInGeneration > 0) {
                    guard sendGeneration < UInt32.max else { throw ClusterRecordError.usageLimitReached }
                    sendGeneration += 1
                    sendKey = Self.nextKey(sendKey!, direction: localRank, generation: sendGeneration)
                    sentInGeneration = 0; sentBytesInGeneration = 0; sendGenerationStarted = now
                }
            }
            try requireBudgetLocked(bytes: byteCount, count: rekey == nil ? sent : sentInGeneration,
                used: rekey == nil ? sentBytes : sentBytesInGeneration)
            guard sent < UInt64.max, let sendKey else { throw ClusterRecordError.inactive }
            let header = ClusterRecordHeader(direction: localRank, type: context.type,
                sequence: sent, plaintextBytes: byteCount, generation: sendGeneration)
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
            // The sender's generation: the current one, or (with a policy) the
            // next one, which this side derives before opening. Anything else,
            // and any rotation that would come before the first record of the
            // current generation, is refused. A forged rotation fails to open
            // under the derived key and poisons the channel like any tamper.
            if header.generation != receiveGeneration {
                guard rekey != nil, receiveGeneration < UInt32.max, header.generation == receiveGeneration + 1,
                      receivedInGeneration > 0, let current = receiveKey else {
                    throw ClusterRecordError.unexpectedRecord
                }
                receiveGeneration += 1
                receiveKey = Self.nextKey(current, direction: 1 - localRank, generation: receiveGeneration)
                receivedInGeneration = 0; receivedBytesInGeneration = 0
            }
            try requireBudgetLocked(bytes: header.plaintextBytes, count: rekey == nil ? received : receivedInGeneration,
                used: rekey == nil ? receivedBytes : receivedBytesInGeneration)
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
            sent += 1; sentBytes &+= UInt64(work.header.plaintextBytes)
            sentInGeneration += 1; sentBytesInGeneration += UInt64(work.header.plaintextBytes)
        } else {
            guard work.header.sequence == received else {
                invalidateLocked(); throw ClusterRecordError.sequenceMismatch
            }
            received += 1; receivedBytes &+= UInt64(work.header.plaintextBytes)
            receivedInGeneration += 1; receivedBytesInGeneration += UInt64(work.header.plaintextBytes)
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
