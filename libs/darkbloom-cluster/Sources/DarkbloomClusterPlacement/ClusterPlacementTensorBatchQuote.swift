import DarkbloomClusterProtocol
import Foundation

/// The exact Qwen27 native TP batch LOAD reservation. It is a complete
/// per-rank floor, separate from the pipeline's whole-model per-lane state.
/// Header-only native derivation supplies the allocator bound; this value
/// never grants capacity or scales a measured single-request rate.
public struct ClusterPlacementTensorBatchQuote: Codable, Equatable, Sendable {
    public static let schemaName = "darkbloom_cluster_placement_tensor_batch_quote_v1"
    public static let maximumEncodedBytes = 32_768
    public static let runtimeModelID = "registered_qwen38_27b"
    public let schema: String
    public let request: ClusterPlacementRequestScope
    public let lanes: Int
    public let chunkTokens: Int
    public let perLaneStateBytes: Int
    public let sharedBytesExcludingCollectives: Int
    public let allowance: ClusterTensorParallelRequestAllowance

    public init(request: ClusterPlacementRequestScope, lanes: Int, chunkTokens: Int,
                perLaneStateBytes: Int, sharedBytesExcludingCollectives: Int,
                allowance: ClusterTensorParallelRequestAllowance) throws {
        schema = Self.schemaName; self.request = request; self.lanes = lanes; self.chunkTokens = chunkTokens
        self.perLaneStateBytes = perLaneStateBytes
        self.sharedBytesExcludingCollectives = sharedBytesExcludingCollectives; self.allowance = allowance
        try validate()
    }

    public func validate() throws {
        try request.validate()
        let state = perLaneStateBytes.multipliedReportingOverflow(by: lanes)
        let total = state.partialValue.addingReportingOverflow(sharedBytesExcludingCollectives)
        guard schema == Self.schemaName, request.runtimeModelID == Self.runtimeModelID,
              [2, 4, 8].contains(lanes), (1...512).contains(chunkTokens), perLaneStateBytes > 0,
              sharedBytesExcludingCollectives > 0, !state.overflow, !total.overflow,
              total.partialValue == allowance.requestBytesExcludingCollectives,
              allowance.maximumContextTokens == request.maximumContextTokens,
              allowance.maximumChunkTokens == 512,
              allowance.reservedBytes <= ClusterWorkerLimits.capacityBytes else {
            throw ClusterPlacementError("Invalid Qwen27 tensor batch quote identity, width or full LOAD allowance")
        }
    }

    public func requireRequest(promptTokens: Int, outputTokens: Int, lanes: Int, chunkTokens: Int) throws {
        guard request.promptTokens == promptTokens, request.outputTokens == outputTokens,
              self.lanes == lanes, self.chunkTokens == chunkTokens else {
            throw ClusterPlacementError("The tensor batch quote changed its requested scope, width or chunk")
        }
    }

    func validate(layout: ClusterModelLayout) throws {
        try validate()
        guard request.runtimeModelID == layout.runtimeModelID, request.artifactSHA256 == layout.artifactSHA256,
              request.configurationSHA256 == layout.configurationSHA256,
              let tp = layout.tensorParallel else {
            throw ClusterPlacementError("The tensor batch quote describes another model or layout")
        }
        try allowance.validate(layout: layout, partialBytesPerToken: tp.family.partialBytesPerToken)
        if let scalar = tp.family.requestAllowance {
            guard allowance.reservedBytes >= scalar.reservedBytes else {
                throw ClusterPlacementError("The tensor batch quote is smaller than the native singleton allowance")
            }
        }
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedBytes else { throw ClusterPlacementError("Tensor batch quote is too large") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate(); return value
    }
}
