import Foundation

/// The routed-expert feed-forward of a Qwen3.5-architecture mixture-of-experts
/// layer: a router over `experts`, of which each token uses `expertsPerToken`,
/// beside one shared expert behind its own gate. It is token-local and holds
/// no request state, so a layer that carries it splits between stages exactly
/// as a dense layer does.
struct QwenRoutedExpertGeometry: Equatable {
    let experts: Int, expertsPerToken: Int
    let expertIntermediate: Int, sharedIntermediate: Int
}

/// Pure admission and module inventory for layer stages whose layers carry
/// routed experts. Like `QwenStageMetadata`, CPU metadata only.
enum QwenRoutedExpertStageMetadata {
    static let rootModelType = "qwen3_5_moe"
    static let textModelType = "qwen3_5_moe_text"
    /// Root model types whose public constructor wraps the text model in a
    /// `language_model` namespace.
    static let wrapperModelTypes = ["qwen3_5", rootModelType]
    /// Text keys only a routed-expert configuration carries. Neither selects
    /// an operator: the first is a training loss weight, the second must be off.
    static let textKeys: Set<String> = ["router_aux_loss_coef", "output_router_logits"]
    static let stageAdapter = "qwen35-routed-expert-layer-stage-v1"
    static let planAdapter = "qwen35-routed-expert-two-layer-stages-v1"
    private static let sizeKeys = ["num_experts", "num_experts_per_tok", "moe_intermediate_size",
                                   "shared_expert_intermediate_size"]

    /// Nil for a configuration that is not the routed-expert wrapper; the dense
    /// checks then apply unchanged. For the wrapper, every routed-expert size
    /// must be an explicit bounded positive integer and the router policy the
    /// pinned decoder's default.
    static func geometry(text: [String: Any], root: [String: Any], nested: Bool) throws -> QwenRoutedExpertGeometry? {
        guard root["model_type"] as? String == rootModelType else { return nil }
        func size(_ key: String, _ limit: Int) throws -> Int {
            guard let value = BoundedProbeInput.integer(text[key]), (1...limit).contains(value) else {
                throw ProbeError("Routed-expert layer stages require a bounded positive integer: \(key)")
            }
            return value
        }
        func boolean(_ value: Any?, expected: Bool) -> Bool {
            guard let number = value as? NSNumber, String(cString: number.objCType) == "c" else { return false }
            return number.boolValue == expected
        }
        let geometry = QwenRoutedExpertGeometry(experts: try size(sizeKeys[0], 1024),
            expertsPerToken: try size(sizeKeys[1], 64), expertIntermediate: try size(sizeKeys[2], 32768),
            sharedIntermediate: try size(sizeKeys[3], 32768))
        guard nested, geometry.expertsPerToken <= geometry.experts, text["intermediate_size"] == nil,
              text["norm_topk_prob"] == nil || boolean(text["norm_topk_prob"], expected: true),
              text["output_router_logits"] == nil || boolean(text["output_router_logits"], expected: false) else {
            throw ProbeError("Unsupported routed-expert wrapper, dense width or router policy")
        }
        if let coefficient = text["router_aux_loss_coef"] {
            guard let value = coefficient as? NSNumber, String(cString: value.objCType) != "c",
                  value.doubleValue.isFinite else { throw ProbeError("Invalid router auxiliary loss coefficient") }
        }
        return geometry
    }

    /// After `geometry(text:root:nested:)` admitted the same text object.
    static func admittedGeometry(_ text: [String: Any]) -> QwenRoutedExpertGeometry? {
        let sizes = sizeKeys.compactMap { BoundedProbeInput.integer(text[$0]) }
        guard sizes.count == sizeKeys.count, sizes.allSatisfy({ $0 > 0 }) else { return nil }
        return .init(experts: sizes[0], expertsPerToken: sizes[1], expertIntermediate: sizes[2],
                     sharedIntermediate: sizes[3])
    }

    /// The canonical modules of one layer's feed-forward and each one's input
    /// width. The routed experts' gate and up projections are one fused
    /// `gate_up_proj`, the layout the pinned decoder constructs and its
    /// sanitizer produces from the stored halves.
    static func inputWidths(base: String, hidden: Int, geometry: QwenRoutedExpertGeometry) -> [String: Int] {
        [base + "gate": hidden, base + "shared_expert_gate": hidden,
         base + "shared_expert.gate_proj": hidden, base + "shared_expert.up_proj": hidden,
         base + "shared_expert.down_proj": geometry.sharedIntermediate,
         base + "switch_mlp.gate_up_proj": hidden, base + "switch_mlp.down_proj": geometry.expertIntermediate]
    }

    private static let fusedMarker = ".switch_mlp.gate_up_proj."

    /// How many stored tensors one canonical tensor is composed of: the fused
    /// routed gate/up projection is its stored gate half followed by its up
    /// half; every other tensor is one stored tensor.
    static func sourcePartCount(canonicalName: String) -> Int {
        canonicalName.contains(fusedMarker) ? 2 : 1
    }
}
