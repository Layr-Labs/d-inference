import Foundation

extension PairConfiguration {
    /// The existing tensor-parallel qualification contract stays unchanged.
    /// Pipeline isolation is restricted to catalog rows using the Qwen, GPT-OSS or MiMo lane
    /// runtimes; other adapters and modes still fence a started cancellation.
    var lanesRetireAlone: Bool {
        Self.lanesRetireAlone(modelID: request.modelID, mode: generationMode, lanes: batchLanes)
    }

    static func lanesRetireAlone(modelID: String, mode: String, lanes: Int) -> Bool {
        if mode == tensorParallelMode { return true }
        guard mode == pipelineMode, (2...8).contains(lanes) else { return false }
        return pipelineLaneModels.contains(modelID)
    }

    private static let pipelineLaneModels: Set<String> = [
        "registered_qwen35_9b", "registered_qwen38_27b",
        "registered_nemotron35_lightning", "registered_mimo_v26_flash_mopd",
        "registered_qwen35_35b_a3b", "registered_qwen36_35b_a3b",
        "registered_ternary_bonsai_2_27b", "registered_ternary_bonsai_2_9b",
        "registered_gemma4_26b_qat_4bit",
        "registered_gemma4_26b", "registered_gemma4_26b_8bit", "registered_gpt_oss_20b",
    ]
}
