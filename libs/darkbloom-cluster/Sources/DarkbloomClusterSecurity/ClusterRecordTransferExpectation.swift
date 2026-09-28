import CryptoKit
import Foundation

public enum ClusterRecordTransferError: Error, Sendable, Equatable {
    case invalidConfiguration, unexpectedByteCount, inactive, concurrentOperation
    case arithmeticOverflow, insufficientSessionBudget
}

/// Locally selected framing. Exact hot-path records use one native transfer.
/// Variable controls use a fixed prefix followed by a capped ciphertext body.
public enum ClusterRecordTransferLength: Sendable, Equatable {
    case exact(Int)
    case bounded(maximum: Int)

    public var maximumPlaintextBytes: Int {
        switch self { case .exact(let count), .bounded(let count): count }
    }
    public var nativeTransferCount: Int {
        switch self { case .exact: 1; case .bounded: 2 }
    }
    func accepts(_ count: Int) -> Bool {
        switch self {
        case .exact(let expected): count == expected
        case .bounded(let maximum): count > 0 && count <= maximum
        }
    }
}

/// Caller-supplied expectation, never learned from a received record/header.
/// Source metadata digest excludes payload bytes; framing mode and length are
/// additionally bound here, so equal payload sizes cannot hide a policy mismatch.
public struct ClusterRecordTransferExpectation: Sendable {
    public let context: ClusterRecordContext
    public let length: ClusterRecordTransferLength

    public init(context: ClusterRecordContext, length: ClusterRecordTransferLength) throws {
        guard (1...ClusterRecordLimits.hardMaximumPlaintextBytes).contains(length.maximumPlaintextBytes) else {
            throw ClusterRecordTransferError.invalidConfiguration
        }
        self.context = context; self.length = length
    }

    var authenticatedContext: ClusterRecordContext {
        get throws {
            var material = Data("darkbloom/rdma-record/transfer-expectation/v1\0".utf8)
            material.append(context.expectationSHA256)
            material.append(length.nativeTransferCount == 1 ? 1 : 2)
            var count = UInt32(length.maximumPlaintextBytes).bigEndian
            withUnsafeBytes(of: &count) { material.append(contentsOf: $0) }
            return try .init(requestID: context.requestID, type: context.type,
                expectationSHA256: Data(SHA256.hash(data: material)))
        }
    }
}
