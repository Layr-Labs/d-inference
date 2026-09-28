import MLX
import MLXNN

/// Dense Qwen's down projection only. Gate/up, SILU and normalization retain
/// their incoming arithmetic; this is distinct from whole-branch precision.
enum FFNOutputPrecision: String { case native, float32 }

final class FFNOutputLinear: QuantizedOutputLinear {
    let precision: FFNOutputPrecision

    init(source: QuantizedLinear, precision: FFNOutputPrecision,
         collective: Collective? = nil) throws {
        self.precision = precision
        try super.init(source: source, widenOutput: precision == .float32, collective: collective)
    }
}

/// Matched unpartitioned solo control. Cooperative models install this wrapper
/// with the collective through attachPartitionReductions instead. Keep the
/// actual Qwen3NextMLP: CBv2 dispatches that concrete type and calls down_proj.
func attachFFNOutputPrecision(model: Module, layers: Int,
                              precision: FFNOutputPrecision) throws {
    guard layers > 0 else { throw ProbeError("FFN output precision requires a positive layer count") }
    let modules = Dictionary(uniqueKeysWithValues: model.namedModules())
    let paths = modules.keys.filter { $0.hasSuffix(".mlp") }.sorted()
    var seen = Set<Int>()
    var replacements: [(parent: Module, linear: FFNOutputLinear)] = []
    for path in paths {
        guard let marker = path.range(of: ".layers."), let parent = modules[path] else {
            throw ProbeError("Unknown dense Qwen FFN path: \(path)")
        }
        let components = path[marker.upperBound...].split(separator: ".")
        guard components.count == 2, components[1] == "mlp", let layer = Int(components[0]),
            (0..<layers).contains(layer), seen.insert(layer).inserted,
            String(describing: type(of: parent)) == "Qwen3NextMLP" else {
            throw ProbeError("FFN output precision requires each original dense Qwen MLP; MoE and whole-MLP substitutes are unsupported")
        }
        let weights = try FFNWeights(module: parent, path: path, requireTwoWaySplit: false)
        let replacement = try FFNOutputLinear(source: weights.down, precision: precision)
        replacements.append((parent, replacement))
    }
    guard seen == Set(0..<layers) else {
        throw ProbeError("FFN output precision did not find every dense model layer")
    }
    // Constructors reject existing output/reduction wrappers. All topology,
    // metadata and duplicate checks finish before the first module mutation.
    for replacement in replacements {
        try replacement.parent.update(modules: ModuleChildren(values: [
            "down_proj": .value(replacement.linear),
        ]), verify: [.noUnusedKeys])
    }
    model.freeze()
}
