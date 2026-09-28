import Foundation
import MLX
import MLXNN

enum AttentionOutputPrecision: String { case native, float32 }

/// Shared arithmetic for a row-parallel output boundary. Widening precedes
/// the quantized projection: promoting an already-rounded partial is too late.
/// Stored parameter arrays remain unchanged, while the native linear may cache
/// wider affine constants. No activation or dtype state crosses forwards.
class QuantizedOutputLinear: QuantizedLinear {
    let widenOutput: Bool
    let collective: Collective?

    init(source: QuantizedLinear, widenOutput: Bool,
         collective: Collective? = nil) throws {
        guard !(source is QuantizedOutputLinear), !(source is ReducedLinear),
            source.mode == .affine, source.bits == 4, source.groupSize == 64,
            source.bias == nil, source.weight.dtype == .uint32, source.weight.ndim == 2,
            let offsets = source.biases, source.scales.ndim == 2,
            source.shape.0 > 0, source.shape.1 > 0, source.shape.1 % 64 == 0,
            source.scales.shape == [source.shape.0, source.shape.1 / 64],
            offsets.shape == source.scales.shape,
            [.float16, .bfloat16, .float32].contains(source.scales.dtype),
            [.float16, .bfloat16, .float32].contains(offsets.dtype) else {
            throw ProbeError("Output precision requires an unwrapped affine W4/G64 projection, valid floating metadata and no ordinary bias")
        }
        self.widenOutput = widenOutput; self.collective = collective
        super.init(weight: source.weight, scales: source.scales, biases: source.biases,
                   groupSize: source.groupSize, bits: source.bits, mode: source.mode)
        freeze()
    }

    final override func callAsFunction(_ input: MLXArray) -> MLXArray {
        if !widenOutput {
            let local = super.callAsFunction(input)
            return collective?.sum(local) ?? local
        }
        precondition([DType.float16, .bfloat16, .float32].contains(input.dtype),
                     "Output precision requires floating activations")
        let local = super.callAsFunction(input.asType(.float32))
        precondition(local.dtype == .float32, "Output projection narrowed before reduction")
        let reduced = collective?.sum(local) ?? local
        precondition(reduced.dtype == .float32, "Output reduction narrowed before its final cast")
        return reduced.asType(input.dtype)
    }
}

/// Existing attention/GDN API, using the common output-projection arithmetic.
final class AttentionOutputLinear: QuantizedOutputLinear {
    let precision: AttentionOutputPrecision

    init(source: QuantizedLinear, precision: AttentionOutputPrecision,
         collective: Collective? = nil) throws {
        self.precision = precision
        try super.init(source: source, widenOutput: precision == .float32, collective: collective)
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
            !(source is ReducedLinear), !(source is QuantizedOutputLinear) else {
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
