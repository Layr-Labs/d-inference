import Foundation
@testable import DarkbloomClusterRuntime

/// The canonical text tensors of a registered 35B A3B geometry, rebuilt from
/// the architecture alone: what the pinned sanitizer keeps of an artifact's
/// stored tensors (no vision, no MTP), with each layer's routed gate and up
/// halves as the one fused tensor they load as. Affine weights pack 32 bits
/// of values a word; scales and offsets have one value per 64 inputs. A test
/// that feeds this to the registered profile proves the pinned inventory hash
/// is exactly this tensor set, with no weight file read.
enum RoutedExpertInventoryFixture {
    /// `routerBits`: the width of the two router projections (the routed
    /// experts' router and the shared expert's gate); everything else is
    /// 4-bit. `decayDType`: how the artifact stores the recurrent `A_log`.
    static func canonicalTensors(routerBits: Int, decayDType: String) -> [QwenDenseCanonicalTensor] {
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
        let hidden = 2048, experts = 256, intermediate = 512
        affine("language_model.model.embed_tokens", out: 248_320, input: hidden)
        affine("language_model.lm_head", out: 248_320, input: hidden)
        plain("language_model.model.norm.weight", [hidden])
        for layer in 0..<40 {
            let base = "language_model.model.layers.\(layer)."
            plain(base + "input_layernorm.weight", [hidden]); plain(base + "post_attention_layernorm.weight", [hidden])
            affine(base + "mlp.gate", out: experts, input: hidden, bits: routerBits)
            affine(base + "mlp.shared_expert_gate", out: 1, input: hidden, bits: routerBits)
            affine(base + "mlp.shared_expert.gate_proj", out: intermediate, input: hidden)
            affine(base + "mlp.shared_expert.up_proj", out: intermediate, input: hidden)
            affine(base + "mlp.shared_expert.down_proj", out: hidden, input: intermediate)
            affine(base + "mlp.switch_mlp.gate_up_proj", lead: [experts], out: 2 * intermediate, input: hidden)
            affine(base + "mlp.switch_mlp.down_proj", lead: [experts], out: hidden, input: intermediate)
            if (layer + 1) % 4 == 0 {
                plain(base + "self_attn.q_norm.weight", [256]); plain(base + "self_attn.k_norm.weight", [256])
                affine(base + "self_attn.q_proj", out: 16 * 256 * 2, input: hidden)
                affine(base + "self_attn.k_proj", out: 2 * 256, input: hidden)
                affine(base + "self_attn.v_proj", out: 2 * 256, input: hidden)
                affine(base + "self_attn.o_proj", out: hidden, input: 16 * 256)
            } else {
                plain(base + "linear_attn.A_log", [32], decayDType); plain(base + "linear_attn.dt_bias", [32])
                plain(base + "linear_attn.conv1d.weight", [8192, 4, 1]); plain(base + "linear_attn.norm.weight", [128])
                affine(base + "linear_attn.in_proj_qkv", out: 8192, input: hidden)
                affine(base + "linear_attn.in_proj_z", out: 4096, input: hidden)
                affine(base + "linear_attn.in_proj_a", out: 32, input: hidden)
                affine(base + "linear_attn.in_proj_b", out: 32, input: hidden)
                affine(base + "linear_attn.out_proj", out: hidden, input: 4096)
            }
        }
        return tensors
    }
}
