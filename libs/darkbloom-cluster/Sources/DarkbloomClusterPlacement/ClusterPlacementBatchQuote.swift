import DarkbloomClusterProtocol
import Foundation

/// The complete lane and shared-workspace quote for one native batch shape.
/// Unlike a singleton scope this is bound to both width and original chunk.
public struct ClusterPlacementBatchQuote: Codable, Equatable, Sendable {
    public static let schemaName = "darkbloom_cluster_placement_batch_quote_v1"
    public static let maximumEncodedBytes = 32_768
    public let schema: String
    public let request: ClusterPlacementRequestScope
    public let lanes: Int
    public let chunkTokens: Int
    public let sharedWorkspaceEveryRankBytes: Int

    public init(request: ClusterPlacementRequestScope, lanes: Int, chunkTokens: Int,
                sharedWorkspaceEveryRankBytes: Int) throws {
        schema = Self.schemaName; self.request = request; self.lanes = lanes
        self.chunkTokens = chunkTokens; self.sharedWorkspaceEveryRankBytes = sharedWorkspaceEveryRankBytes
        try validate()
    }

    public func validate() throws {
        try request.validate()
        guard schema == Self.schemaName, [2, 4, 8].contains(lanes), (1...512).contains(chunkTokens),
              request.requestChargeEveryRankBytes > 0, sharedWorkspaceEveryRankBytes > 0,
              let adapter = ClusterRuntimeAdapter.registering(runtimeModelID: request.runtimeModelID),
              [.gptossLayerStage, .mimoV26LayerStage].contains(adapter) else {
            throw ClusterPlacementError("Invalid native batch quote identity, width, chunk or allowance")
        }
        _ = try totalEveryRankBytes()
    }

    public func totalEveryRankBytes() throws -> Int {
        let lanesBytes = request.requestChargeEveryRankBytes.multipliedReportingOverflow(by: lanes)
        let total = lanesBytes.partialValue.addingReportingOverflow(sharedWorkspaceEveryRankBytes)
        guard !lanesBytes.overflow, !total.overflow, total.partialValue > 0,
              total.partialValue <= ClusterWorkerLimits.capacityBytes else {
            throw ClusterPlacementError("The native batch quote exceeds its placement byte bound")
        }
        return total.partialValue
    }

    /// A valid helper response must still describe the exact demand that was
    /// sent. Accepting a smaller history would underprice the waiting requests.
    public func requireRequest(promptTokens: Int, outputTokens: Int, lanes: Int, chunkTokens: Int) throws {
        guard request.promptTokens == promptTokens, request.outputTokens == outputTokens,
              self.lanes == lanes, self.chunkTokens == chunkTokens else {
            throw ClusterPlacementError("The native batch quote changed its requested scope, width or chunk")
        }
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedBytes else { throw ClusterPlacementError("Native batch quote is too large") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }
}
