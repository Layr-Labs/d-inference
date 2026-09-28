import CryptoKit
import Foundation

/// Serialized, bounded encrypted-record transfer. No raw fallback, model state,
/// cleanup ACK, logger, retry/reset, or membership authority is provided here.
/// The caller supplies an independently authorized fresh secret and retains all
/// native/request ownership until its existing real retirement/release proofs.
public final class ClusterAuthenticatedRecordTransport: @unchecked Sendable {
    private let io: any ClusterRecordByteIO
    private let channel: ClusterAuthenticatedRecordChannel
    private let lock = NSLock()
    private var active = true
    private var inOperation = false
    public let localRank: Int
    public let maximumFrameBytes: Int
    public let maximumPlaintextBytes: Int

    public init(sessionKey: SymmetricKey, binding: ClusterRecordBinding,
                limits: ClusterRecordLimits, io: any ClusterRecordByteIO) throws {
        guard io.worldSize == 2, (0...1).contains(io.localRank) else {
            throw ClusterRecordTransferError.invalidConfiguration
        }
        _ = try ClusterRecordTransferAccounting(length: .exact(limits.maximumPlaintextBytes),
            maximumTransportFrameBytes: io.maximumFrameBytes)
        self.io = io; localRank = io.localRank; maximumFrameBytes = io.maximumFrameBytes
        maximumPlaintextBytes = limits.maximumPlaintextBytes
        channel = try .init(sessionKey: sessionKey, binding: binding, localRank: io.localRank, limits: limits)
    }

    public var status: ClusterRecordTransportStatus {
        lock.lock(); defer { lock.unlock() }
        return .init(active: active, operationInFlight: inOperation, codec: channel.status)
    }

    /// Lock-only fail-closed signal; never invokes IO or waits for a blocked peer.
    /// It does not cancel native work, release state, or clear a device journal.
    public func invalidate() {
        lock.lock(); active = false; lock.unlock()
        channel.invalidate()
    }

    /// Exact-size payloads: one combined ciphertext frame and one completed send.
    /// Variable controls: prefix + ciphertext body, with two completed sends.
    public func send(_ plaintext: Data, expecting expected: ClusterRecordTransferExpectation,
                     check: () throws -> Void) throws {
        try operation {
            try checked(check); try validate(expected)
            guard expected.length.accepts(plaintext.count) else {
                throw ClusterRecordTransferError.unexpectedByteCount
            }
            let record = try channel.seal(plaintext, context: expected.authenticatedContext)
            try checked(check)
            try withExtendedLifetime(record) {
                switch expected.length {
                case .exact:
                    try io.sendCompleted(record, check: { try self.checked(check) })
                case .bounded:
                    let prefix = Data(record.prefix(ClusterAuthenticatedRecordChannel.framingPrefixBytes))
                    try io.sendCompleted(prefix, check: { try self.checked(check) })
                    try checked(check)
                    let body = Data(record.dropFirst(ClusterAuthenticatedRecordChannel.framingPrefixBytes))
                    try io.sendCompleted(body, check: { try self.checked(check) })
                }
            }
            try checked(check)
        }
    }

    /// No payload escapes before full AEAD verification and a post-open local
    /// deadline/cancellation check. The caller still validates semantic payload
    /// invariants before reconstruction/consumption. Invalidation can race after
    /// this publication point; existing request-state checks remain necessary.
    public func receive(expecting expected: ClusterRecordTransferExpectation,
                        check: () throws -> Void) throws -> Data {
        try operation {
            try checked(check); try validate(expected)
            let record = try receiveRecord(expected, check: check)
            try checked(check)
            let plaintext = try channel.open(record, expecting: expected.authenticatedContext)
            guard expected.length.accepts(plaintext.count) else {
                throw ClusterRecordTransferError.unexpectedByteCount
            }
            try checked(check)
            return plaintext
        }
    }

    private func receiveRecord(_ expected: ClusterRecordTransferExpectation,
                               check: () throws -> Void) throws -> Data {
        switch expected.length {
        case .exact(let count):
            return try receiveFrame(count + ClusterRecordTransferAccounting.framingBytes, check: check)
        case .bounded(let maximum):
            var record = try receiveFrame(ClusterAuthenticatedRecordChannel.framingPrefixBytes, check: check)
            // This observation is unauthenticated and used ONLY for a bounded
            // receive allocation. It cannot authorize state or model work.
            let total = try ClusterAuthenticatedRecordChannel.boundedRecordByteCount(
                fromPrefix: record, maximumPlaintextBytes: maximum)
            guard total <= maximum + ClusterRecordTransferAccounting.framingBytes,
                  total <= maximumFrameBytes else { throw ClusterRecordTransferError.unexpectedByteCount }
            try checked(check)
            let body = try receiveFrame(total - ClusterAuthenticatedRecordChannel.framingPrefixBytes, check: check)
            record.append(body)
            guard record.count == total else { throw ClusterRecordTransferError.unexpectedByteCount }
            return record
        }
    }

    private func receiveFrame(_ count: Int, check: () throws -> Void) throws -> Data {
        guard count > 0, count <= maximumFrameBytes else { throw ClusterRecordTransferError.unexpectedByteCount }
        let bytes = try io.receiveCompleted(byteCount: count, check: { try self.checked(check) })
        guard bytes.count == count else { throw ClusterRecordTransferError.unexpectedByteCount }
        try checked(check)
        return bytes
    }
    private func validate(_ expected: ClusterRecordTransferExpectation) throws {
        guard io.localRank == localRank, io.worldSize == 2, io.maximumFrameBytes == maximumFrameBytes,
              expected.length.maximumPlaintextBytes <= channel.limits.maximumPlaintextBytes else {
            throw ClusterRecordTransferError.invalidConfiguration
        }
        _ = try ClusterRecordTransferAccounting(length: expected.length, maximumTransportFrameBytes: maximumFrameBytes)
    }
    private func checked(_ check: () throws -> Void) throws {
        try check()
        lock.lock(); let live = active; lock.unlock()
        guard live else { throw ClusterRecordTransferError.inactive }
    }
    private func operation<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        guard active, !inOperation else {
            let error: ClusterRecordTransferError = active ? .concurrentOperation : .inactive
            active = false; lock.unlock(); channel.invalidate(); throw error
        }
        inOperation = true; lock.unlock()
        defer { lock.lock(); inOperation = false; lock.unlock() }
        do {
            let result = try body()
            try checked({})
            return result
        } catch { invalidate(); throw error }
    }
}
