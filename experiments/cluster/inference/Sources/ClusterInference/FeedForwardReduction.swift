import MLX
import MLXNN

/// Preserve the actual model block's routing, gating and branch arithmetic, then
/// combine its local full-width output before the decoder adds the residual.
/// This adapter is for the ordinary UnaryLayer forward path, not CBv2/MTP.
final class ReducedFeedForward: Module, UnaryLayer {
    let local: Module
    let collective: Collective

    init(_ local: Module, collective: Collective) throws {
        guard local is any UnaryLayer else { throw ProbeError("Feed-forward reduction requires UnaryLayer") }
        self.local = local; self.collective = collective
    }

    func callAsFunction(_ input: MLXArray) -> MLXArray {
        collective.sum((local as! any UnaryLayer)(input))
    }
}

/// Local oracle combining separately loaded model blocks. Each block retains
/// its original router/shared-gate implementation and its rank-local tensors.
final class LocalSummedFeedForward: Module, UnaryLayer {
    let parts: [Module]

    init(_ parts: [Module]) throws {
        guard parts.count == 2, parts.allSatisfy({ $0 is any UnaryLayer }) else {
            throw ProbeError("Local feed-forward oracle requires two UnaryLayer blocks")
        }
        self.parts = parts
    }

    func callAsFunction(_ input: MLXArray) -> MLXArray {
        (parts[0] as! any UnaryLayer)(input) + (parts[1] as! any UnaryLayer)(input)
    }
}
