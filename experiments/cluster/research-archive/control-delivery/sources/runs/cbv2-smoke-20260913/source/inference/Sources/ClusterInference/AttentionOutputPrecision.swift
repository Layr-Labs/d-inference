import Foundation
import MLX
import MLXNN

enum AttentionOutputPrecision: String { case native, float32 }

/// Changes arithmetic precision at an attention/GDN output boundary while
/// retaining the exact packed weight and quantization metadata arrays.
final class AttentionOutputLinear: QuantizedLinear {
    let precision: AttentionOutputPrecision
    let collective: Collective?

    init(source: QuantizedLinear, precision: AttentionOutputPrecision,
         collective: Collective? = nil) throws {
        guard source.mode == .affine, source.bits == 4, source.groupSize == 64,
            source.bias == nil, source.weight.dtype == .uint32, source.weight.ndim == 2,
            let offsets = source.biases, source.scales.ndim == 2,
            source.shape.0 > 0, source.shape.1 > 0, source.shape.1 % 64 == 0,
            source.scales.shape == [source.shape.0, source.shape.1 / 64],
            offsets.shape == source.scales.shape,
            [.float16, .bfloat16, .float32].contains(source.scales.dtype),
            [.float16, .bfloat16, .float32].contains(offsets.dtype) else {
            throw ProbeError("Attention output precision requires affine W4/G64, valid floating metadata and no ordinary bias")
        }
        self.precision = precision; self.collective = collective
        super.init(weight: source.weight, scales: source.scales, biases: source.biases,
                   groupSize: source.groupSize, bits: source.bits, mode: source.mode)
        freeze()
    }

    override func callAsFunction(_ input: MLXArray) -> MLXArray {
        switch precision {
        case .native:
            let local = super.callAsFunction(input)
            return collective?.sum(local) ?? local
        case .float32:
            let local = super.callAsFunction(input.asType(.float32))
            let reduced = collective?.sum(local) ?? local
            return reduced.asType(input.dtype)
        }
    }
}

/// For baseline or FFN-only execution. Full TP installs the same precision
/// wrapper with its collective at the partition's reduction boundary instead.
func attachAttentionOutputPrecision(model: Module, layers: Int,
                                    precision: AttentionOutputPrecision) throws {
    guard layers > 0 else { throw ProbeError("Attention precision requires a positive layer count") }
    let modules = Dictionary(uniqueKeysWithValues: model.namedModules())
    var seen = Set<Int>()
    var replacements: [(parent: Module, child: String, linear: AttentionOutputLinear)] = []
    for path in modules.keys.sorted()
    where path.hasSuffix(".self_attn.o_proj") || path.hasSuffix(".linear_attn.out_proj") {
        guard let marker = path.range(of: ".layers.") else {
            throw ProbeError("Attention output precision encountered an unknown layer path: \(path)")
        }
        let parts = path[marker.upperBound...].split(separator: ".").map(String.init)
        guard parts.count == 3, let layer = Int(parts[0]), (0..<layers).contains(layer),
            seen.insert(layer).inserted, let source = modules[path] as? QuantizedLinear,
            !(source is ReducedLinear), !(source is AttentionOutputLinear) else {
            throw ProbeError("Attention output precision requires one unwrapped output projection per layer: \(path)")
        }
        let parentPath = path.split(separator: ".").dropLast().joined(separator: ".")
        guard let parent = modules[parentPath] else { throw ProbeError("Missing attention output parent") }
        let replacement = try AttentionOutputLinear(source: source, precision: precision)
        replacements.append((parent, parts[2], replacement))
    }
    guard seen == Set(0..<layers) else {
        throw ProbeError("Attention output precision did not find every model layer")
    }
    // Validation and wrapper construction finish before the first module swap.
    for replacement in replacements {
        try replacement.parent.update(modules: ModuleChildren(values: [
            replacement.child: .value(replacement.linear),
        ]), verify: [.noUnusedKeys])
    }
    model.freeze()
}
