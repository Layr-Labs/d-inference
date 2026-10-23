import DarkbloomClusterProtocol
import Foundation

/// A registered family's conservative request charge for one explicit planning
/// request. It extends a layout's reference envelope without changing that
/// layout, and is bound to the same model/configuration/artifact and request.
/// This is planning metadata, never LOAD authority or a measured residency.
public struct ClusterPlacementRequestScope: Codable, Equatable, Sendable {
    public static let schemaName = "darkbloom_cluster_placement_request_scope_v1"
    public static let maximumEncodedBytes = 16_384
    public let schema: String
    public let runtimeModelID: String
    public let artifactSHA256: String
    public let configurationSHA256: String
    public let promptTokens: Int
    public let outputTokens: Int
    public let maximumPromptTokens: Int
    public let maximumOutputTokens: Int
    public let maximumContextTokens: Int
    public let requestChargeEveryRankBytes: Int

    public init(runtimeModelID: String, artifactSHA256: String, configurationSHA256: String,
                promptTokens: Int, outputTokens: Int, maximumPromptTokens: Int,
                maximumOutputTokens: Int, maximumContextTokens: Int, requestChargeEveryRankBytes: Int) throws {
        schema = Self.schemaName
        self.runtimeModelID = runtimeModelID; self.artifactSHA256 = artifactSHA256
        self.configurationSHA256 = configurationSHA256
        self.promptTokens = promptTokens; self.outputTokens = outputTokens
        self.maximumPromptTokens = maximumPromptTokens; self.maximumOutputTokens = maximumOutputTokens
        self.maximumContextTokens = maximumContextTokens
        self.requestChargeEveryRankBytes = requestChargeEveryRankBytes
        try validate()
    }

    public func validate() throws {
        // This extension is for standard resident families. Exact adapter
        // quotations (including GLM's longer scope) keep their separate route.
        guard schema == Self.schemaName,
              (1...ClusterWorkerLimits.promptTokens).contains(maximumPromptTokens),
              (1...ClusterWorkerLimits.outputTokens).contains(maximumOutputTokens),
              (1...ClusterWorkerLimits.contextTokens).contains(maximumContextTokens),
              maximumPromptTokens < maximumContextTokens, maximumOutputTokens < maximumContextTokens,
              (1...maximumPromptTokens).contains(promptTokens),
              (1...maximumOutputTokens).contains(outputTokens),
              promptTokens <= maximumContextTokens - outputTokens,
              (0...ClusterWorkerLimits.capacityBytes).contains(requestChargeEveryRankBytes) else {
            throw ClusterPlacementError("The requested scope is outside the model's request limits")
        }
    }

    public static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= maximumEncodedBytes else { throw ClusterPlacementError("Placement request scope is too large") }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        try value.validate()
        return value
    }

    /// A scope may only price the exact request it was computed for. Smaller
    /// requests keep their ordinary layout accounting unless quoted afresh.
    public func apply(to policy: inout ClusterPlacementPolicy, layout: ClusterModelLayout) throws {
        try validate()
        guard runtimeModelID == layout.runtimeModelID, artifactSHA256 == layout.artifactSHA256,
              configurationSHA256 == layout.configurationSHA256,
              promptTokens == (policy.promptTokens ?? layout.maximumPromptTokens),
              outputTokens == (policy.outputTokens ?? layout.maximumOutputTokens) else {
            throw ClusterPlacementError("Placement request scope describes another model or request")
        }
        policy.largestContextTokens = maximumContextTokens
        policy.requestChargeEveryRankBytes = requestChargeEveryRankBytes
    }
}
