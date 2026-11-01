import CryptoKit
import DarkbloomClusterSecurity
import Foundation

/// A logical batch request, derived independently from the pinned session and
/// its serialized batch ordinal. The local lifecycle UUID is not a wire ID.
/// Keep the collective's directional record counters alive between batches.
struct QwenBatchRecordBinding {
    struct Lane {
        let slot: Int
        let requestID: UUID
        let requestFingerprint: String
        let committedTokens: Int
        let selectedTokens: Int
    }

    enum Residual {
        case decode
        case prefill(offset: Int, count: Int, final: Bool)
    }

    struct ResidualRecords {
        let payload: CollectiveRecordScope
        let digest: CollectiveRecordScope
    }

    let requestID: UUID
    private let fingerprint: String
    private let laneCount: Int

    static func nextOrdinal(after previous: UInt64) throws -> UInt64 {
        guard previous < UInt64.max else { throw ProbeError("Encrypted batch ordinal exhausted") }
        return previous + 1
    }

    init(epoch: UUID, planFingerprint: String, ordinal: UInt64, lanes: Int) throws {
        guard ordinal > 0, (1...QwenBatchWire.maximumLanes).contains(lanes),
              Self.isDigest(planFingerprint) else {
            throw ProbeError("Invalid encrypted batch identity")
        }
        var bytes = Data("darkbloom/qwen-batch-record-binding/v1\0".utf8)
        Self.append(epoch, to: &bytes)
        bytes.append(contentsOf: planFingerprint.utf8)
        Self.append(ordinal, to: &bytes)
        Self.append(UInt64(lanes), to: &bytes)
        let digest = Array(SHA256.hash(data: bytes))
        fingerprint = Self.hex(digest)
        // A deterministic custom UUID (version 8), not either rank's random
        // lifecycle ID or a lane request learned from a received header.
        var id = Array(digest.prefix(16))
        id[6] = (id[6] & 0x0f) | 0x80
        id[8] = (id[8] & 0x3f) | 0x80
        requestID = UUID(uuid: (id[0], id[1], id[2], id[3], id[4], id[5], id[6], id[7],
                               id[8], id[9], id[10], id[11], id[12], id[13], id[14], id[15]))
        laneCount = lanes
    }

    func opening(fromRank rank: Int) throws -> CollectiveRecordScope {
        guard (0...1).contains(rank) else { throw ProbeError("Invalid batch opening rank") }
        return record(.requestAgreement, "opening/from=\(rank)")
    }

    func header(step: Int) throws -> CollectiveRecordScope {
        try Self.checkStep(step)
        return record(.generationDecision, "header/from=0/step=\(step)")
    }

    func reply(step: Int) throws -> CollectiveRecordScope {
        try Self.checkStep(step)
        return record(.targetToken, "reply/from=1/step=\(step)")
    }

    /// Call before the producer's forward advances its local frontier; the
    /// consumer derives the same facts before receiving. These are local lane
    /// reservations and session frontiers, never received digest/payload bytes.
    func residual(step: Int, kind: Residual, lanes: [Lane]) throws -> ResidualRecords {
        try Self.checkStep(step)
        guard !lanes.isEmpty, lanes.count <= laneCount,
              Set(lanes.map(\.requestID)).count == lanes.count,
              zip(lanes, lanes.dropFirst()).allSatisfy({ $0.slot < $1.slot }) else {
            throw ProbeError("Invalid encrypted batch row order")
        }
        var bytes = Data("darkbloom/qwen-batch-residual/v1\0".utf8)
        Self.append(UInt64(step), to: &bytes)
        switch kind {
        case .decode:
            bytes.append(0)
        case .prefill(let offset, let count, let final):
            guard lanes.count == 1, offset >= 0, count > 0,
                  offset <= Int(Int32.max), count <= Int(Int32.max) - offset else {
                throw ProbeError("Invalid encrypted batch prefill frame")
            }
            bytes.append(1)
            Self.append(UInt64(offset), to: &bytes)
            Self.append(UInt64(count), to: &bytes)
            bytes.append(final ? 1 : 0)
        }
        Self.append(UInt64(lanes.count), to: &bytes)
        for lane in lanes {
            guard (0..<laneCount).contains(lane.slot), Self.isDigest(lane.requestFingerprint),
                  (0...Int(Int32.max)).contains(lane.committedTokens),
                  (0...Int(Int32.max)).contains(lane.selectedTokens) else {
                throw ProbeError("Invalid encrypted batch lane frontier")
            }
            Self.append(UInt64(lane.slot), to: &bytes)
            Self.append(lane.requestID, to: &bytes)
            bytes.append(contentsOf: lane.requestFingerprint.utf8)
            Self.append(UInt64(lane.committedTokens), to: &bytes)
            Self.append(UInt64(lane.selectedTokens), to: &bytes)
        }
        let label = "residual/from=0/" + Self.hex(Array(SHA256.hash(data: bytes)))
        return .init(payload: record(.residualPayload, label), digest: record(.residualHeader, label))
    }

    private func record(_ type: ClusterRecordType, _ label: String) -> CollectiveRecordScope {
        .request(type, requestID: requestID, agreementFingerprint: fingerprint, "qwen-batch/" + label)
    }

    private static func checkStep(_ step: Int) throws {
        guard (0...Int(Int32.max)).contains(step) else { throw ProbeError("Invalid encrypted batch step") }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func append(_ value: UInt64, to bytes: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { bytes.append(contentsOf: $0) }
    }

    private static func append(_ value: UUID, to bytes: inout Data) {
        var uuid = value.uuid
        withUnsafeBytes(of: &uuid) { bytes.append(contentsOf: $0) }
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
