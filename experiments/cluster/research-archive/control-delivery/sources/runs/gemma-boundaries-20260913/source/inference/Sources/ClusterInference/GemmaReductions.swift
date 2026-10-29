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

func attachGemmaExecution(model: Module, plan: GemmaPartitionPlan, collective: Collective?,
                          trace: GemmaBoundaryTrace? = nil) throws {
    guard collective != nil || plan.ffnBranchPrecision != .native || trace != nil else { return }
    let modules = Dictionary(uniqueKeysWithValues: model.namedModules())
    let paths = try plan.normalizationInputPaths(in: model)
    let orders = collective.map { group in (0..<plan.layers).map { _ in GemmaBranchOrder(group) } }
    var replacements: [(Module, String, FFNBoundaryNorm)] = []
    for (index, path) in paths.enumerated() {
        let components = path.split(separator: ".")
        guard let name = components.last,
            let parent = modules[components.dropLast().joined(separator: ".")],
            let norm = modules[path] as? RMSNorm, !(norm is FFNBoundaryNorm) else {
            throw ProbeError("Missing Gemma branch normalization boundary: \(path)")
        }
        let reduce: (MLXArray) -> MLXArray
        if let orders, plan.isMoE {
            let order = orders[index / 2]
            reduce = index % 2 == 0 ? order.dense : order.sparse
        } else if let collective { reduce = collective.sum }
        else { reduce = { $0 } }
        let finish: (MLXArray) -> MLXArray
        if plan.ffnBranchPrecision == .float32 || trace != nil {
            let preName = plan.isMoE && index % 2 == 1
                ? "pre_feedforward_layernorm_2" : "pre_feedforward_layernorm"
            let prePath = components.dropLast().joined(separator: ".") + "." + preName
            guard let preNorm = modules[prePath] as? RMSNorm, !(preNorm is FFNBoundaryNorm) else {
                throw ProbeError("Missing Gemma FFN input normalization boundary: \(prePath)")
            }
            let cast = plan.ffnBranchPrecision == .float32 ? FFNBranchCast() : nil
            replacements.append((parent, preName, try FFNBoundaryNorm(preNorm, before: { value in
                trace?.record(path, "branch.input", value)
                return value
            }, after: { value in
                trace?.record(path, "input_norm", value)
                let output = cast?.enter(value) ?? value
                trace?.record(path, "projection.input", output)
                return output
            })))
            finish = { value in
                trace?.record(path, "branch.local", value)
                let reduced = reduce(value)
                trace?.record(path, "branch.reduced", reduced)
                let output = cast?.leave(reduced) ?? reduced
                trace?.record(path, "output_norm.input", output)
                return output
            }
        } else { finish = reduce }
        replacements.append((parent, String(name), try FFNBoundaryNorm(norm, before: finish, after: { value in
            trace?.record(path, "output_norm.output", value)
            return value
        })))
    }
    if let trace {
        for (path, module) in modules where path.hasSuffix(".post_attention_layernorm") ||
            (plan.isMoE && path.hasSuffix(".post_feedforward_layernorm")) {
            let components = path.split(separator: ".")
            guard let norm = module as? RMSNorm, let name = components.last,
                let parent = modules[components.dropLast().joined(separator: ".")] else {
                throw ProbeError("Gemma diagnostic has an unexpected common normalization boundary")
            }
            replacements.append((parent, String(name), try FFNBoundaryNorm(norm, before: { value in
                trace.record(path, "norm.input", value); return value
            }, after: { value in
                trace.record(path, "norm.output", value); return value
            })))
        }
    }
    // Validate all boundaries before changing any module.
    for (parent, name, replacement) in replacements {
        try parent.update(modules: ModuleChildren(values: [name: .value(replacement)]), verify: [.noUnusedKeys])
    }
    model.freeze()
}
