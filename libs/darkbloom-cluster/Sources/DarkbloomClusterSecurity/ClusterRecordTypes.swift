import Foundation

/// Closed, payload-free failures. Never include keys, AAD, ciphertext or plaintext.
public enum ClusterRecordError: Error, Sendable, Equatable {
    case invalidKeySize, invalidConfiguration, invalidContext, inactive
    case concurrentOperation, malformedRecord, recordTooLarge, unexpectedRecord
    case sequenceMismatch, usageLimitReached, authenticationFailed, encryptionFailed
}

public enum ClusterRecordSuite: UInt8, Sendable {
    case aes256GcmHkdfSha256V1 = 1
}

/// Authority is external: this value does not prove membership or key freshness.
public struct ClusterRecordBinding: Sendable {
    public let epoch: UUID
    public let planSHA256: Data
    public let membershipTranscriptSHA256: Data
    public let suite: ClusterRecordSuite

    public init(epoch: UUID, planSHA256: Data, membershipTranscriptSHA256: Data,
                suite: ClusterRecordSuite = .aes256GcmHkdfSha256V1) throws {
        guard !clusterRecordUUIDBytes(epoch).allSatisfy({ $0 == 0 }),
              planSHA256.count == 32, membershipTranscriptSHA256.count == 32 else {
            throw ClusterRecordError.invalidContext
        }
        self.epoch = epoch; self.planSHA256 = planSHA256
        self.membershipTranscriptSHA256 = membershipTranscriptSHA256; self.suite = suite
    }

    // Fixed-width canonical encoding; no JSON, optional fields or ambiguous joins.
    var canonicalBytes: Data {
        var result = Data("darkbloom/rdma-record/binding/v1\0".utf8)
        result.append(suite.rawValue)
        result.append(clusterRecordUUIDBytes(epoch))
        result.append(planSHA256); result.append(membershipTranscriptSHA256)
        return result
    }
}

public enum ClusterRecordType: UInt8, Sendable {
    case keyConfirmation = 1, loadAgreement, loadedReady
    case requestAgreement, residualHeader, residualPayload, targetToken
    case generationDecision, acknowledgement, requestRetired

    var requiresRequest: Bool {
        switch self {
        case .keyConfirmation, .loadAgreement, .loadedReady: false
        default: true
        }
    }
}

/// Expected locally, never adopted from received bytes. expectationSHA256 binds
/// the caller's canonical phase/geometry/frontier metadata, not inference data.
public struct ClusterRecordContext: Sendable {
    public let requestID: UUID?
    public let type: ClusterRecordType
    public let expectationSHA256: Data

    public init(requestID: UUID?, type: ClusterRecordType, expectationSHA256: Data) throws {
        guard type.requiresRequest == (requestID != nil), expectationSHA256.count == 32 else {
            throw ClusterRecordError.invalidContext
        }
        if let requestID, clusterRecordUUIDBytes(requestID).allSatisfy({ $0 == 0 }) {
            throw ClusterRecordError.invalidContext
        }
        self.requestID = requestID; self.type = type; self.expectationSHA256 = expectationSHA256
    }

    var canonicalBytes: Data {
        var result = Data([requestID == nil ? 0 : 1, type.rawValue])
        result.append(requestID.map(clusterRecordUUIDBytes) ?? Data(repeating: 0, count: 16))
        result.append(expectationSHA256)
        return result
    }
}

/// Additional protocol bounds, not a native memory reservation. The membership
/// transcript must bind the agreed limits. Resource admission remains external.
public struct ClusterRecordLimits: Sendable {
    public static let hardMaximumPlaintextBytes = 16 * 1024 * 1024
    public static let hardMaximumRecords: UInt64 = 1_048_576
    public static let hardMaximumCumulativePlaintextBytes: UInt64 = 4_294_967_296
    public let maximumPlaintextBytes: Int
    public let maximumRecordsPerDirection: UInt64
    public let maximumCumulativePlaintextBytesPerDirection: UInt64

    public init(maximumPlaintextBytes: Int,
                maximumRecordsPerDirection: UInt64 = Self.hardMaximumRecords,
                maximumCumulativePlaintextBytesPerDirection: UInt64 = Self.hardMaximumCumulativePlaintextBytes) throws {
        guard (1...Self.hardMaximumPlaintextBytes).contains(maximumPlaintextBytes),
              maximumRecordsPerDirection > 0, maximumRecordsPerDirection <= Self.hardMaximumRecords,
              maximumCumulativePlaintextBytesPerDirection > 0,
              maximumCumulativePlaintextBytesPerDirection <= Self.hardMaximumCumulativePlaintextBytes,
              UInt64(maximumPlaintextBytes) <= maximumCumulativePlaintextBytesPerDirection else {
            throw ClusterRecordError.invalidConfiguration
        }
        self.maximumPlaintextBytes = maximumPlaintextBytes
        self.maximumRecordsPerDirection = maximumRecordsPerDirection
        self.maximumCumulativePlaintextBytesPerDirection = maximumCumulativePlaintextBytesPerDirection
    }

    var canonicalBytes: Data {
        var result = Data()
        result.clusterAppendBigEndian(UInt32(maximumPlaintextBytes))
        result.clusterAppendBigEndian(maximumRecordsPerDirection)
        result.clusterAppendBigEndian(maximumCumulativePlaintextBytesPerDirection)
        return result
    }
}

public struct ClusterRecordStatus: Sendable, Equatable {
    public let active: Bool
    public let operationInFlight: Bool
    public let sealedRecords: UInt64
    public let openedRecords: UInt64
    public let sealedPlaintextBytes: UInt64
    public let openedPlaintextBytes: UInt64
}

func clusterRecordUUIDBytes(_ value: UUID) -> Data {
    var bytes = value.uuid
    return withUnsafeBytes(of: &bytes) { Data($0) }
}

extension Data {
    mutating func clusterAppendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
