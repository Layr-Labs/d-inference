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
    /// Link control channel frames (TCP over the Thunderbolt link). Their keys
    /// are separate from the data plane's, so a record of one never opens as
    /// the other; the frame's own message and request identities are inside.
    case linkControl
    /// Data plane (S16): the phase-split hand-off header and its state
    /// segments, the decoding rank's relayed token batches (with or without
    /// the speculative head) and their answers, the prefix agreement, and the
    /// idle keep-warm exchange.
    case handoffHeader, handoffState, tokenRelay, relayDecision, prefixAgreement, keepWarm

    var requiresRequest: Bool {
        switch self {
        case .keyConfirmation, .loadAgreement, .loadedReady, .linkControl, .keepWarm: false
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

/// Rekey without a fixed lifetime (S16). The sender moves its direction to
/// the next key generation before a record that would exceed `records` records
/// or `bytes` plaintext bytes under the current generation, or once the
/// generation is `seconds` old (0: no time trigger). The generation travels in
/// the authenticated header and the receiver follows it, one step at a time.
/// Each generation's key is derived from the previous one, which is dropped.
/// With a policy, the channel's limits bound each generation (the receiver
/// refuses a sender that overruns them) instead of the whole session.
public struct ClusterRecordRekeyPolicy: Sendable, Equatable {
    public static let maximumSeconds: UInt64 = 86_400
    public let records: UInt64
    public let bytes: UInt64
    public let seconds: UInt64

    public init(records: UInt64, bytes: UInt64, seconds: UInt64) throws {
        guard records > 0, records <= ClusterRecordLimits.hardMaximumRecords,
              bytes > 0, bytes <= ClusterRecordLimits.hardMaximumCumulativePlaintextBytes,
              seconds <= Self.maximumSeconds else { throw ClusterRecordError.invalidConfiguration }
        self.records = records; self.bytes = bytes; self.seconds = seconds
    }

    /// The data plane's policy: a new key every 262,144 records, 2 GiB or ten
    /// minutes per direction, whichever comes first.
    public static let dataPlane = try! ClusterRecordRekeyPolicy(records: 262_144, bytes: 2 << 30, seconds: 600)

    /// Qualification only: `records:<n>`, canonical decimal, 2...262,144. The
    /// data plane's policy with a new key every n records per direction (its
    /// byte and age limits unchanged), so one short request crosses several
    /// key generations. Anything else is refused, never read loosely.
    public static func qualification(_ text: String) throws -> ClusterRecordRekeyPolicy {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "records", let records = UInt64(parts[1]), String(records) == parts[1],
              (2...dataPlane.records).contains(records) else { throw ClusterRecordError.invalidConfiguration }
        return try ClusterRecordRekeyPolicy(records: records, bytes: dataPlane.bytes, seconds: dataPlane.seconds)
    }

    /// The sender rotates before a generation's limits are reached.
    func fits(_ limits: ClusterRecordLimits) -> Bool {
        records <= limits.maximumRecordsPerDirection
            && bytes <= limits.maximumCumulativePlaintextBytesPerDirection
    }

    var canonicalBytes: Data {
        var result = Data("darkbloom/rdma-record/rekey-policy/v1\0".utf8)
        result.clusterAppendBigEndian(records); result.clusterAppendBigEndian(bytes)
        result.clusterAppendBigEndian(seconds)
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
    /// Key generations in use: zero until the first rekey.
    public var sendGeneration: UInt32 = 0
    public var receiveGeneration: UInt32 = 0
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
