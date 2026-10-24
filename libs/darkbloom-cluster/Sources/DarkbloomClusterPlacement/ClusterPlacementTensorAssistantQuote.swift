import DarkbloomClusterProtocol

/// Exact replicated head residency and the complete future head LOAD charge.
/// The latter includes residency, temporary constructor/quantization arrays,
/// two whole host tensors and aligned read scratch. Request state is carried
/// once in the enclosing complete tensor quote, never added here again.
public struct ClusterPlacementTensorAssistantQuote: Codable, Equatable, Sendable {
    public let policy: ClusterQwenTensorAssistantPolicy
    public let residentBytes: Int
    public let loadBytes: Int
    public let largestAllocationBytes: Int

    public init(policy: ClusterQwenTensorAssistantPolicy, residentBytes: Int,
                loadBytes: Int, largestAllocationBytes: Int) throws {
        self.policy = policy; self.residentBytes = residentBytes
        self.loadBytes = loadBytes; self.largestAllocationBytes = largestAllocationBytes
        try validate()
    }

    public func validate() throws {
        try policy.validate()
        guard residentBytes > 0, loadBytes >= residentBytes,
              loadBytes <= ClusterWorkerLimits.capacityBytes,
              largestAllocationBytes > 0, largestAllocationBytes <= loadBytes else {
            throw ClusterPlacementError("Invalid tensor assistant residency or full LOAD quote")
        }
    }
}
