import Foundation

/// Exact logical record/frame sizes. These are NOT an allocator/scratch bound,
/// a Ready/capacity claim, or a native/device reservation. The additional host
/// allocator, CryptoKit workspace and native allocator policy remain external.
public struct ClusterRecordTransferAccounting: Sendable, Equatable {
    public static let framingBytes = ClusterAuthenticatedRecordChannel.framingPrefixBytes
        + ClusterAuthenticatedRecordChannel.tagBytes
    public let maximumPlaintextBytes: Int
    public let maximumSealedRecordBytes: Int
    public let maximumFrameByteCounts: [Int]
    public let additionalFramingDataBytes: Int
    public let codecCiphertextAndTagLogicalBytes: Int

    public init(length: ClusterRecordTransferLength, maximumTransportFrameBytes: Int) throws {
        let bytes = length.maximumPlaintextBytes
        guard bytes > 0, bytes <= ClusterRecordLimits.hardMaximumPlaintextBytes,
              maximumTransportFrameBytes > Self.framingBytes,
              maximumTransportFrameBytes <= ClusterRecordLimits.hardMaximumPlaintextBytes,
              bytes <= maximumTransportFrameBytes - Self.framingBytes else {
            throw ClusterRecordTransferError.invalidConfiguration
        }
        maximumPlaintextBytes = bytes
        maximumSealedRecordBytes = bytes + Self.framingBytes
        codecCiphertextAndTagLogicalBytes = bytes + ClusterAuthenticatedRecordChannel.tagBytes
        switch length {
        case .exact:
            maximumFrameByteCounts = [maximumSealedRecordBytes]
            additionalFramingDataBytes = 0
        case .bounded:
            maximumFrameByteCounts = [ClusterAuthenticatedRecordChannel.framingPrefixBytes,
                bytes + ClusterAuthenticatedRecordChannel.tagBytes]
            // Prefix/body copies may overlap the assembled record. Logical
            // lengths only: Foundation allocation capacities are not exposed.
            additionalFramingDataBytes = maximumSealedRecordBytes
        }
    }
}

/// A directional, worst-case record envelope for pre-admission accounting.
/// Include setup/control/ACK records, every possible output, and all requests.
/// This check is a pure observation, NOT atomic request admission. The existing
/// serialized owner must reserve it before starting any known transfer work.
public struct ClusterRecordTransferEnvelope: Sendable, Equatable {
    public let records: UInt64
    public let plaintextBytes: UInt64
    public let sealedBytes: UInt64
    public let nativeTransfers: UInt64
    public let maximumRecordPlaintextBytes: Int

    public init(entries: [(ClusterRecordTransferLength, UInt64)], maximumTransportFrameBytes: Int) throws {
        guard !entries.isEmpty else { throw ClusterRecordTransferError.invalidConfiguration }
        var records: UInt64 = 0, plaintext: UInt64 = 0, sealed: UInt64 = 0, transfers: UInt64 = 0
        var maximumRecord = 0
        for (length, count) in entries {
            guard count > 0 else { throw ClusterRecordTransferError.invalidConfiguration }
            let layout = try ClusterRecordTransferAccounting(length: length,
                maximumTransportFrameBytes: maximumTransportFrameBytes)
            records = try Self.add(records, count)
            plaintext = try Self.add(plaintext, Self.multiply(UInt64(layout.maximumPlaintextBytes), count))
            sealed = try Self.add(sealed, Self.multiply(UInt64(layout.maximumSealedRecordBytes), count))
            transfers = try Self.add(transfers, Self.multiply(UInt64(length.nativeTransferCount), count))
            maximumRecord = max(maximumRecord, layout.maximumPlaintextBytes)
        }
        self.records = records; plaintextBytes = plaintext; sealedBytes = sealed; nativeTransfers = transfers
        maximumRecordPlaintextBytes = maximumRecord
    }

    public func requireRemaining(usedRecords: UInt64, usedPlaintextBytes: UInt64,
                                 limits: ClusterRecordLimits) throws {
        guard maximumRecordPlaintextBytes <= limits.maximumPlaintextBytes,
              usedRecords <= limits.maximumRecordsPerDirection,
              usedPlaintextBytes <= limits.maximumCumulativePlaintextBytesPerDirection,
              records <= limits.maximumRecordsPerDirection - usedRecords,
              plaintextBytes <= limits.maximumCumulativePlaintextBytesPerDirection - usedPlaintextBytes else {
            throw ClusterRecordTransferError.insufficientSessionBudget
        }
    }

    private static func add(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let value = a.addingReportingOverflow(b)
        guard !value.overflow else { throw ClusterRecordTransferError.arithmeticOverflow }
        return value.partialValue
    }
    private static func multiply(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let value = a.multipliedReportingOverflow(by: b)
        guard !value.overflow else { throw ClusterRecordTransferError.arithmeticOverflow }
        return value.partialValue
    }
}
