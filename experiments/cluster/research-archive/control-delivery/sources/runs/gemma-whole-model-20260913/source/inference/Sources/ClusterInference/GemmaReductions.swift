import MLX
import MLXNN

/// A per-layer dependency orders the two otherwise independent collectives.
/// It is consumed during graph construction and never chains different forwards.
private final class GemmaBranchOrder {
    private var denseSum: MLXArray?
    let collective: Collective
    init(_ collective: Collective) { self.collective = collective }

    func dense(_ input: MLXArray) -> MLXArray {
        precondition(denseSum == nil, "Gemma dense branch reentered before sparse branch")
        let sum = collective.sum(input)
        denseSum = sum
        return sum
    }

    func sparse(_ input: MLXArray) -> MLXArray {
        guard let previous = denseSum else { preconditionFailure("Gemma sparse branch has no preceding dense branch") }
        denseSum = nil
        return collective.sum(depends(input: input, dependencies: [previous]))
    }
}

private final class GemmaReducedNorm: RMSNorm {
    let reduce: (MLXArray) -> MLXArray
    init(_ source: RMSNorm, reduce: @escaping (MLXArray) -> MLXArray) throws {
        self.reduce = reduce
        super.init(dimensions: source.weight.size, eps: source.eps)
        try update(parameters: source.parameters(), verify: [.all])
    }
    override func callAsFunction(_ input: MLXArray) -> MLXArray {
        super.callAsFunction(reduce(input))
    }
}

func attachGemmaReductions(model: Module, plan: GemmaPartitionPlan, collective: Collective) throws {
    let modules = Dictionary(uniqueKeysWithValues: model.namedModules())
    let paths = try plan.normalizationInputPaths(in: model)
    let orders = (0..<plan.layers).map { _ in GemmaBranchOrder(collective) }
    for (index, path) in paths.enumerated() {
        let components = path.split(separator: ".")
        guard let name = components.last,
            let parent = modules[components.dropLast().joined(separator: ".")],
            let norm = modules[path] as? RMSNorm else {
            throw ProbeError("Missing Gemma branch normalization boundary: \(path)")
        }
        let reduce: (MLXArray) -> MLXArray
        if plan.isMoE {
            let order = orders[index / 2]
            reduce = index % 2 == 0 ? order.dense : order.sparse
        } else { reduce = collective.sum }
        try parent.update(modules: ModuleChildren(values: [String(name):
            .value(try GemmaReducedNorm(norm, reduce: reduce))]), verify: [.noUnusedKeys])
    }
    model.freeze()
}
