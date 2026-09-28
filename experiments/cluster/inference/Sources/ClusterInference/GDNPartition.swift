import Foundation
import CoreFoundation

/// Two ranks own matching contiguous groups of key and value heads. Q/K/V are
/// separate segments, not two contiguous halves of the concatenated projection.
/// Construct Qwen35 with configurationUpdates before loading these tensors.
struct QwenGDNPartition {
    let hiddenSize: Int
    let keyHeads: Int
    let valueHeads: Int
    let keyHeadDimension: Int
    let valueHeadDimension: Int
    let convolutionKernel: Int
    let reductionModule = "out_proj"

    var keyWidth: Int { keyHeads * keyHeadDimension }
    var valueWidth: Int { valueHeads * valueHeadDimension }
    var convolutionWidth: Int { 2 * keyWidth + valueWidth }
    var configurationUpdates: [String: Int] {
        ["linear_num_key_heads": keyHeads / 2, "linear_num_value_heads": valueHeads / 2]
    }

    init(text: [String: Any]) throws {
        func dimension(_ key: String) throws -> Int {
            guard let value = text[key] as? Int, value > 0, value <= 1_048_576,
                let number = text[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID()
            else { throw ProbeError("GDN partition requires an explicit positive integer \(key)") }
            return value
        }
        hiddenSize = try dimension("hidden_size")
        keyHeads = try dimension("linear_num_key_heads")
        valueHeads = try dimension("linear_num_value_heads")
        keyHeadDimension = try dimension("linear_key_head_dim")
        valueHeadDimension = try dimension("linear_value_head_dim")
        convolutionKernel = try dimension("linear_conv_kernel_dim")
        guard keyHeads % 2 == 0, valueHeads % 2 == 0, valueHeads % keyHeads == 0 else {
            throw ProbeError("GDN requires even key/value head counts and integral value-to-key grouping")
        }
        guard keyHeadDimension % 32 == 0, hiddenSize % 64 == 0,
            (valueHeads * valueHeadDimension / 2) % 64 == 0,
            2 * keyHeads * keyHeadDimension + valueHeads * valueHeadDimension <= Int(Int32.max)
        else { throw ProbeError("GDN head dimensions must support the recurrence kernel and affine W4/G64 columns") }
    }

    func selection(relativeName: String, shape: [Int], rank: Int) throws -> TensorSelection {
        guard (0..<2).contains(rank) else { throw ProbeError("GDN partition rank must be zero or one") }
        func require(_ expected: [Int]) throws {
            guard shape == expected else {
                throw ProbeError("GDN \(relativeName) has shape \(shape); expected \(expected)")
            }
        }
        func half(_ size: Int, offset: Int = 0) -> Range<Int> {
            (offset + rank * size / 2)..<(offset + (rank + 1) * size / 2)
        }
        let qkv = [half(keyWidth), half(keyWidth, offset: keyWidth),
                   half(valueWidth, offset: 2 * keyWidth)]
        switch relativeName {
        case "conv1d.weight":
            // Sanitized MLX depthwise convolution: [channel, kernel, 1].
            try require([convolutionWidth, convolutionKernel, 1])
            return .axis(0, qkv)
        case "A_log", "dt_bias":
            try require([valueHeads])
            return .axis(0, [half(valueHeads)])
        case "norm.weight":
            // RMS normalization is within each value head, not across heads.
            try require([valueHeadDimension])
            return .all
        default: break
        }

        let parts = relativeName.split(separator: ".").map(String.init)
        guard parts.count == 2, ["weight", "scales", "biases"].contains(parts[1]) else {
            throw ProbeError("Unsupported GDN tensor \(relativeName)")
        }
        let packedDivisor = parts[1] == "weight" ? 8 : 64
        if parts[0] == reductionModule {
            try require([hiddenSize, valueWidth / packedDivisor])
            return .axis(1, [half(valueWidth / packedDivisor)])
        }
        let rows: Int
        let ranges: [Range<Int>]
        switch parts[0] {
        case "in_proj_qkv": rows = convolutionWidth; ranges = qkv
        case "in_proj_z": rows = valueWidth; ranges = [half(valueWidth)]
        case "in_proj_b", "in_proj_a": rows = valueHeads; ranges = [half(valueHeads)]
        default: throw ProbeError("Unsupported GDN tensor \(relativeName)")
        }
        try require([rows, hiddenSize / packedDivisor])
        return .axis(0, ranges)
    }
}
