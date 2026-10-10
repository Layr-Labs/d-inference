import Foundation
// The model-free script check compiles this file against its own module name.
#if canImport(DarkbloomClusterRuntimeChecks)
@testable import DarkbloomClusterRuntimeChecks
#else
@testable import DarkbloomClusterRuntime
#endif

/// The canonical tensors of the registered Nemotron 3.5 Lightning geometry,
/// rebuilt from the architecture alone: what the pinned sanitizer keeps of the
/// artifact's stored tensors (everything but its `mtp.` head). Affine weights
/// pack 32 bits of values a word; scales and offsets have one value per 64
/// inputs. Mamba and attention projections are 8-bit and everything else
/// 4-bit, as the artifact's own quantization table says. A test that feeds
/// this to the registered profile proves the pinned inventory hash is exactly
/// this tensor set, with no weight file read.
enum NemotronInventoryFixture {
    static let pattern = "MEMEM*EMEMEM*EMEMEM*EMEMEM*EMEMEM*EMEMEMEM*EMEMEMEME"

    static func canonicalTensors() -> [QwenDenseCanonicalTensor] {
        var tensors: [QwenDenseCanonicalTensor] = []
        func plain(_ name: String, _ shape: [Int], _ dtype: String = "BF16") {
            tensors.append(.init(name: name, shape: shape, sourceDType: dtype,
                                 byteCount: shape.reduce(dtype == "F32" ? 4 : 2, *)))
        }
        func affine(_ module: String, lead: [Int] = [], out: Int, input: Int, bits: Int = 4) {
            let weight = lead + [out, input * bits / 32], groups = lead + [out, input / 64]
            tensors.append(.init(name: module + ".weight", shape: weight, sourceDType: "U32", byteCount: weight.reduce(4, *)))
            for suffix in ["scales", "biases"] {
                tensors.append(.init(name: module + "." + suffix, shape: groups, sourceDType: "BF16", byteCount: groups.reduce(2, *)))
            }
        }
        let hidden = 2688, vocabulary = 131_072, experts = 128
        let mambaWidth = 64 * 64, convolutionWidth = mambaWidth + 2 * 8 * 128, attentionWidth = 32 * 128
        affine("backbone.embeddings", out: vocabulary, input: hidden)
        affine("lm_head", out: vocabulary, input: hidden)
        plain("backbone.norm_f.weight", [hidden])
        for (layer, kind) in pattern.enumerated() {
            let base = "backbone.layers.\(layer)."
            plain(base + "norm.weight", [hidden])
            switch kind {
            case "M":
                for name in ["A_log", "D", "dt_bias"] { plain(base + "mixer." + name, [64]) }
                plain(base + "mixer.conv1d.weight", [convolutionWidth, 4, 1])
                plain(base + "mixer.conv1d.bias", [convolutionWidth])
                plain(base + "mixer.norm.weight", [mambaWidth])
                affine(base + "mixer.in_proj", out: mambaWidth + convolutionWidth + 64, input: hidden, bits: 8)
                affine(base + "mixer.out_proj", out: hidden, input: mambaWidth, bits: 8)
            case "*":
                affine(base + "mixer.q_proj", out: attentionWidth, input: hidden, bits: 8)
                affine(base + "mixer.k_proj", out: 2 * 128, input: hidden, bits: 8)
                affine(base + "mixer.v_proj", out: 2 * 128, input: hidden, bits: 8)
                affine(base + "mixer.o_proj", out: hidden, input: attentionWidth, bits: 8)
            default:
                plain(base + "mixer.gate.weight", [experts, hidden])
                plain(base + "mixer.gate.e_score_correction_bias", [experts], "F32")
                affine(base + "mixer.switch_mlp.fc1", lead: [experts], out: 1856, input: hidden)
                affine(base + "mixer.switch_mlp.fc2", lead: [experts], out: hidden, input: 1856)
                affine(base + "mixer.shared_experts.up_proj", out: 3712, input: hidden)
                affine(base + "mixer.shared_experts.down_proj", out: hidden, input: 3712)
            }
        }
        return tensors
    }
}
