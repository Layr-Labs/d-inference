import Foundation
import MLXLLM
import MLXLMCommon
import MLXNN

/// What the public constructor built for a model whose layers carry routed
/// experts, checked by type name and child layout because the block itself is
/// internal to the pinned package. A dense model is described unchanged.
enum QwenRoutedExpertStageModel {
    private static func isRouted(_ model: any LanguageModel) -> Bool { model is Qwen35MoEModel }

    /// The concrete feed-forward type every layer of this model must have.
    static func feedForwardTypeName(_ model: any LanguageModel) -> String {
        isRouted(model) ? "Qwen35SparseMoeBlock" : "Qwen3NextMLP"
    }

    static func feedForwardKind(_ model: any LanguageModel) -> String {
        isRouted(model) ? "routedExperts" : "dense"
    }

    /// Each routed block is exactly a router, one fused routed bank, a shared
    /// expert and its gate: the layout the canonical tensor names address.
    /// A split gate/up bank would be a different set of parameters.
    static func validate(_ model: any LanguageModel, layerCount: Int) throws {
        guard isRouted(model) else { return }
        let modules = Dictionary(uniqueKeysWithValues: model.namedModules())
        let blocks = modules.keys.filter { $0.hasSuffix(".mlp") }
        guard blocks.count == layerCount else { throw ProbeError("Routed-expert stage has a different layer count") }
        for block in blocks {
            guard let bank = modules[block + ".switch_mlp"] as? SwitchGLU, bank.hasFusedGateUp,
                  modules[block + ".gate"] is Linear, modules[block + ".shared_expert_gate"] is Linear,
                  let shared = modules[block + ".shared_expert"],
                  String(describing: type(of: shared)) == "Qwen3NextMLP" else {
                throw ProbeError("Routed-expert stage changed the pinned router, fused bank or shared expert topology")
            }
        }
    }
}
