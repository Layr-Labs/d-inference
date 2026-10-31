import Foundation

/// How a mixture-of-experts family routes a token: to `selected` of the
/// `experts` routed experts of every expert layer. Stated by the family from
/// its own configuration.
public struct ClusterExpertRouting: Codable, Equatable, Sendable {
    public let selected: Int
    public let experts: Int
    public init(selected: Int, experts: Int) { self.selected = selected; self.experts = experts }
}

/// A layout's routed experts: what a decode step reads of them. One token's
/// step reads only the experts it is routed to, so the bytes a step reads
/// are every other layer byte plus `selected / experts` of these
/// (`ClusterHardwarePrior.decodeBytesPerToken`). Derived by
/// `ClusterModelLayoutBuilder` from the tensors the family names routed
/// experts; nil for a model without them, or in a layout written before it.
public struct ClusterRoutedExperts: Codable, Equatable, Sendable {
    public let routing: ClusterExpertRouting
    /// Loaded bytes of every layer's routed experts.
    public let loadedBytes: Int
    /// Of those, the bytes the family's tensor-parallel plan divides; nil
    /// without tensor-parallel facts.
    public let tensorParallelDividedBytes: Int?

    public init(routing: ClusterExpertRouting, loadedBytes: Int, tensorParallelDividedBytes: Int?) {
        self.routing = routing; self.loadedBytes = loadedBytes; self.tensorParallelDividedBytes = tensorParallelDividedBytes
    }

    /// Of `bytes` of routed experts, what one token's step reads (rounded up).
    public func activeBytes(_ bytes: Int) -> Int {
        let (product, overflow) = bytes.multipliedReportingOverflow(by: routing.selected)
        guard !overflow else { return bytes }
        return (product + routing.experts - 1) / routing.experts
    }

    func validate(layout: ClusterModelLayout) throws {
        let layerBytes = layout.layers.reduce(0) { $0 + $1.weights.loadedBytes }
        let divided = layout.tensorParallel?.layerDividedBytes.reduce(0, +)
        guard (1...65_536).contains(routing.experts), (1...routing.experts).contains(routing.selected),
              loadedBytes > 0, loadedBytes <= layerBytes,
              (tensorParallelDividedBytes == nil) == (divided == nil),
              tensorParallelDividedBytes.map({ $0 >= 0 && $0 <= loadedBytes && $0 <= divided! }) ?? true else {
            throw ClusterPlacementError("Model layout's routed experts are malformed")
        }
    }
}
