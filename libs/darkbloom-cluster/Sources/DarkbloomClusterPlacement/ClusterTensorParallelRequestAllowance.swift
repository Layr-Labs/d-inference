import Foundation

/// A family's complete per-rank request reservation, shared with its native
/// LOAD and request gates. It excludes loaded weights and loading headroom.
/// The complete quote is a floor for the planner's existing estimate, never
/// an additional copy of the same KV/workspace budget. No quote changes the
/// behavior or serialized form of existing families.
public struct ClusterTensorParallelRequestAllowance: Codable, Equatable, Sendable {
    public let maximumContextTokens: Int
    public let maximumChunkTokens: Int
    public let requestBytesExcludingCollectives: Int
    /// Largest one-rank FP32 payload, including selected-expert multiplicity.
    public let maximumCollectivePayloadBytes: Int
    /// Largest encoded frame, including the native codec's authentication overhead.
    public let maximumCollectiveFrameBytes: Int
    /// Eight independently bounded allocations cover local/peer/result and
    /// sealed, opened and transfer scratch; they are not one rounded sum.
    public let collectiveScratchBytes: Int
    public var reservedBytes: Int { requestBytesExcludingCollectives + collectiveScratchBytes }

    public init(maximumContextTokens: Int, maximumChunkTokens: Int,
                requestBytesExcludingCollectives: Int, maximumCollectivePayloadBytes: Int,
                maximumCollectiveFrameBytes: Int, allocationBound: (Int) throws -> Int) throws {
        guard maximumContextTokens > 0, maximumChunkTokens > 0,
              maximumChunkTokens <= maximumContextTokens, requestBytesExcludingCollectives >= 0,
              maximumCollectivePayloadBytes > 0, maximumCollectiveFrameBytes >= maximumCollectivePayloadBytes else {
            throw ClusterPlacementError("Invalid tensor-parallel request allowance")
        }
        let frame = try allocationBound(maximumCollectiveFrameBytes)
        let scratch = frame.multipliedReportingOverflow(by: 8)
        let total = requestBytesExcludingCollectives.addingReportingOverflow(scratch.partialValue)
        guard frame >= maximumCollectiveFrameBytes, !scratch.overflow, !total.overflow else {
            throw ClusterPlacementError("Invalid or overflowing tensor-parallel request allowance")
        }
        try self.init(maximumContextTokens: maximumContextTokens, maximumChunkTokens: maximumChunkTokens,
            requestBytesExcludingCollectives: requestBytesExcludingCollectives,
            maximumCollectivePayloadBytes: maximumCollectivePayloadBytes, maximumCollectiveFrameBytes: maximumCollectiveFrameBytes,
            collectiveScratchBytes: scratch.partialValue)
    }

    private enum CodingKeys: String, CodingKey {
        case maximumContextTokens, maximumChunkTokens, requestBytesExcludingCollectives
        case maximumCollectivePayloadBytes, maximumCollectiveFrameBytes, collectiveScratchBytes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(maximumContextTokens: values.decode(Int.self, forKey: .maximumContextTokens),
            maximumChunkTokens: values.decode(Int.self, forKey: .maximumChunkTokens),
            requestBytesExcludingCollectives: values.decode(Int.self, forKey: .requestBytesExcludingCollectives),
            maximumCollectivePayloadBytes: values.decode(Int.self, forKey: .maximumCollectivePayloadBytes),
            maximumCollectiveFrameBytes: values.decode(Int.self, forKey: .maximumCollectiveFrameBytes),
            collectiveScratchBytes: values.decode(Int.self, forKey: .collectiveScratchBytes))
    }

    private init(maximumContextTokens: Int, maximumChunkTokens: Int, requestBytesExcludingCollectives: Int,
                 maximumCollectivePayloadBytes: Int, maximumCollectiveFrameBytes: Int, collectiveScratchBytes: Int) throws {
        let scratch = maximumCollectiveFrameBytes.multipliedReportingOverflow(by: 8)
        let total = requestBytesExcludingCollectives.addingReportingOverflow(collectiveScratchBytes)
        guard maximumContextTokens > 0, maximumChunkTokens > 0, maximumChunkTokens <= maximumContextTokens,
              requestBytesExcludingCollectives >= 0, maximumCollectivePayloadBytes > 0,
              maximumCollectiveFrameBytes >= maximumCollectivePayloadBytes,
              !scratch.overflow, collectiveScratchBytes >= scratch.partialValue,
              !total.overflow, total.partialValue <= Int.max / 4 else {
            throw ClusterPlacementError("Invalid or overflowing tensor-parallel request allowance")
        }
        self.maximumContextTokens = maximumContextTokens
        self.maximumChunkTokens = maximumChunkTokens
        self.requestBytesExcludingCollectives = requestBytesExcludingCollectives
        self.maximumCollectivePayloadBytes = maximumCollectivePayloadBytes
        self.maximumCollectiveFrameBytes = maximumCollectiveFrameBytes
        self.collectiveScratchBytes = collectiveScratchBytes
    }

    func covers(context: Int, chunk: Int) -> Bool {
        context > 0 && context <= maximumContextTokens && chunk > 0 && chunk <= maximumChunkTokens
    }

    func validate(layout: ClusterModelLayout, partialBytesPerToken: Int) throws {
        let payload = maximumChunkTokens.multipliedReportingOverflow(by: partialBytesPerToken)
        let scratch = maximumCollectiveFrameBytes.multipliedReportingOverflow(by: 8)
        let total = requestBytesExcludingCollectives.addingReportingOverflow(collectiveScratchBytes)
        guard covers(context: layout.maximumContextTokens, chunk: layout.maximumChunkTokens),
              maximumChunkTokens <= maximumContextTokens, requestBytesExcludingCollectives >= 0,
              maximumCollectivePayloadBytes > 0, !payload.overflow, !scratch.overflow, !total.overflow,
              maximumCollectiveFrameBytes >= maximumCollectivePayloadBytes,
              maximumCollectivePayloadBytes >= payload.partialValue,
              collectiveScratchBytes >= scratch.partialValue else {
            throw ClusterPlacementError("Model layout's tensor-parallel request allowance is malformed or too small")
        }
    }
}
