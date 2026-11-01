import XCTest
@testable import DarkbloomClusterQualification

final class PairBatchCancellationTests: XCTestCase {
    func testPipelineIsolationIsExplicitlyBoundToEligibleCatalogRowsAndLanes() {
        let eligible: Set<String> = ["registered_qwen35_9b", "registered_qwen38_27b",
            "registered_nemotron35_lightning", "registered_mimo_v26_flash_mopd",
            "registered_qwen35_35b_a3b", "registered_qwen36_35b_a3b", "registered_ternary_bonsai_2_27b",
            "registered_ternary_bonsai_2_9b", "registered_gemma4_26b_qat_4bit", "registered_gemma4_26b", "registered_gemma4_26b_8bit", "registered_gpt_oss_20b"]
        for model in QualificationRequest.registeredModels.map(\.modelID) + ["unknown"] {
            for lanes in [0, 1, 2, 4, 8, 9] {
                XCTAssertEqual(PairConfiguration.lanesRetireAlone(modelID: model,
                    mode: PairConfiguration.pipelineMode, lanes: lanes),
                    eligible.contains(model) && (2...8).contains(lanes))
            }
            for mode in [PairConfiguration.pipelineMTPMode, PairConfiguration.phaseSplitMode,
                         PairConfiguration.phaseSplitMTPMode, PairConfiguration.pipelineCompactDecodeMode] {
                XCTAssertFalse(PairConfiguration.lanesRetireAlone(modelID: model, mode: mode, lanes: 8))
            }
        }
    }

    func testExistingTensorParallelQualificationContractIsPreserved() {
        for lanes in [1, 2, 8] {
            XCTAssertTrue(PairConfiguration.lanesRetireAlone(modelID: "registered_glm53_flash",
                mode: PairConfiguration.tensorParallelMode, lanes: lanes))
        }
    }
}
