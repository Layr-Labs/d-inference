import MLX
import MLXNN

struct FFNWeights {
    let gate: QuantizedLinear
    let up: QuantizedLinear
    let down: QuantizedLinear

    init(module: Module, path: String, requireTwoWaySplit: Bool = true) throws {
        let children = Dictionary(uniqueKeysWithValues: module.namedModules())
        guard let gate = children["gate_proj"] as? QuantizedLinear,
            let up = children["up_proj"] as? QuantizedLinear,
            let down = children["down_proj"] as? QuantizedLinear,
            children["switch_mlp"] == nil
        else { throw ProbeError("\(path) is not a supported quantized dense FFN") }
        for linear in [gate, up, down] {
            guard linear.mode == .affine, linear.bits == 4, linear.groupSize == 64,
                linear.bias == nil, linear.biases != nil,
                linear.weight.dtype == .uint32
            else { throw ProbeError("\(path) requires affine W4/G64, uint32 packing, and no linear bias") }
        }
        let hidden = gate.shape.0
        guard gate.shape == up.shape, down.shape.0 == gate.shape.1,
            down.shape.1 == hidden, hidden % (requireTwoWaySplit ? 128 : 64) == 0
        else { throw ProbeError("\(path) has incompatible FFN dimensions or unaligned quantization groups") }
        self.gate = gate; self.up = up; self.down = down
    }

    func shard(rank: Int) throws -> FFNWeights {
        guard (0..<2).contains(rank), gate.shape.0 % 128 == 0 else {
            throw ProbeError("Invalid dense FFN shard rank or group alignment")
        }
        let width = gate.shape.0 / 2
        let rows = (rank * width)..<((rank + 1) * width)
        func columnParallel(_ source: QuantizedLinear) throws -> QuantizedLinear {
            try QuantizedLinear(
                weight: copySelectedTensor(source.weight, selection: .axis(0, [rows])),
                scales: copySelectedTensor(source.scales, selection: .axis(0, [rows])),
                biases: source.biases.map { try copySelectedTensor($0, selection: .axis(0, [rows])) },
                groupSize: source.groupSize, bits: source.bits, mode: source.mode)
        }
        let words = (rows.lowerBound / 8)..<(rows.upperBound / 8)
        let groups = (rows.lowerBound / 64)..<(rows.upperBound / 64)
        let rowParallel = try QuantizedLinear(
            weight: copySelectedTensor(down.weight, selection: .axis(1, [words])),
            scales: copySelectedTensor(down.scales, selection: .axis(1, [groups])),
            biases: down.biases.map { try copySelectedTensor($0, selection: .axis(1, [groups])) },
            groupSize: down.groupSize, bits: down.bits, mode: down.mode)
        return try FFNWeights(gate: columnParallel(gate), up: columnParallel(up), down: rowParallel)
    }

    private init(gate: QuantizedLinear, up: QuantizedLinear, down: QuantizedLinear) {
        self.gate = gate; self.up = up; self.down = down
    }
}

final class ReducedLinear: QuantizedLinear {
    let collective: Collective

    init(_ local: QuantizedLinear, collective: Collective) {
        self.collective = collective
        super.init(weight: local.weight, scales: local.scales, biases: local.biases,
                   groupSize: local.groupSize, bits: local.bits, mode: local.mode)
    }

    override func callAsFunction(_ input: MLXArray) -> MLXArray {
        collective.sum(super.callAsFunction(input))
    }
}

/// Local execution of both partitions is a correctness oracle, never a speedup benchmark.
final class LocalPartitionedFFN: Module, UnaryLayer {
    let gates: [QuantizedLinear]
    let ups: [QuantizedLinear]
    let downs: [QuantizedLinear]

    init(_ source: FFNWeights) throws {
        let shards = try (0..<2).map { try source.shard(rank: $0) }
        gates = shards.map(\.gate); ups = shards.map(\.up); downs = shards.map(\.down)
    }

    init(shards: [FFNWeights]) {
        precondition(shards.count == 2)
        gates = shards.map(\.gate); ups = shards.map(\.up); downs = shards.map(\.down)
    }

    func callAsFunction(_ input: MLXArray) -> MLXArray {
        downs[0](silu(gates[0](input)) * ups[0](input))
            + downs[1](silu(gates[1](input)) * ups[1](input))
    }
}

func attachPartitionReductions(model: Module, plan: QwenPartitionPlan, collective: Collective) throws {
    guard !plan.isMoE || plan.ffnOutputPrecision == .native else {
        throw ProbeError("FFN output precision currently requires dense Qwen")
    }
    let modules = Dictionary(uniqueKeysWithValues: model.namedModules())
    var replacements: [(parent: Module, name: String, module: Module)] = []
    for path in try plan.reductionPaths(in: model) {
        let components = path.split(separator: ".")
        let parentPath = components.dropLast().joined(separator: ".")
        guard let module = modules[path], let parent = modules[parentPath], let name = components.last else {
            throw ProbeError("Unsupported partition reduction projection: \(path)")
        }
        let replacement: Module
        if plan.isMoE && path.hasSuffix(".mlp") {
            guard !(module is ReducedFeedForward) else {
                throw ProbeError("Feed-forward reduction is already attached: \(path)")
            }
            replacement = try ReducedFeedForward(module, collective: collective)
        } else if path.hasSuffix(".self_attn.o_proj") || path.hasSuffix(".linear_attn.out_proj"),
                  let local = module as? QuantizedLinear {
            replacement = try AttentionOutputLinear(source: local, precision: plan.attentionOutputPrecision,
                                                    collective: collective)
        } else if !plan.isMoE, path.hasSuffix(".mlp.down_proj"),
                  String(describing: type(of: parent)) == "Qwen3NextMLP",
                  let local = module as? QuantizedLinear {
            replacement = try FFNOutputLinear(source: local, precision: plan.ffnOutputPrecision,
                                              collective: collective)
        } else { throw ProbeError("Unsupported partition reduction boundary: \(path)") }
        replacements.append((parent, String(name), replacement))
    }
    // Reject malformed or already-wrapped boundaries before changing any layer.
    for replacement in replacements {
        try replacement.parent.update(modules: ModuleChildren(values: [
            replacement.name: .value(replacement.module),
        ]), verify: [.noUnusedKeys])
    }
    model.freeze()
}

@discardableResult
func installLocalFFNOracle(model: Module, expectedLayers: Int) throws -> Int {
    let modules = model.namedModules()
    let ffns = modules.filter { $0.0.hasSuffix(".mlp") }
    guard ffns.count == expectedLayers else {
        throw ProbeError("Expected \(expectedLayers) dense FFNs, found \(ffns.count)")
    }
    // Validate every module before replacing any weights.
    let validated = try ffns.map { (path, module) in
        (path, module, try FFNWeights(module: module, path: path))
    }
    let parents = Dictionary(uniqueKeysWithValues: modules)
    for (path, _, weights) in validated {
        let parentPath = String(path.dropLast(".mlp".count))
        guard let parent = parents[parentPath] else { throw ProbeError("Missing FFN parent") }
        try parent.update(modules: ModuleChildren(values: [
            "mlp": .value(try LocalPartitionedFFN(weights)),
        ]), verify: [.noUnusedKeys])
    }
    model.freeze()
    eval(model)
    return ffns.count
}
