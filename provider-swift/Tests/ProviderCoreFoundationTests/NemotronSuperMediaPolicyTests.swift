import Foundation
import XCTest

@testable import ProviderCoreFoundation

final class NemotronSuperMediaPolicyTests: XCTestCase {
    func testUnqualifiedOmniCannotAdvertiseMediaUnderAnyIdentity() {
        // Relevant fields from the official Super VL config at 7d4bc747;
        // tower metadata does not establish a native serving implementation.
        let vision: [String: Any] = [
            "model_type": "radio", "hidden_size": 1280,
            "patch_size": 16, "min_num_patches": 1024, "max_num_patches": 13312,
        ]
        let identities: [String?] = [
            nil,
            "nvidia/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-NVFP4",
            "nvidia/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-BF16",
            "local-super-candidate",
        ]
        for modelType in ["nemotron_h_omni", "NEMOTRON_H_OMNI", " \tnemotron_h_omni\n"] {
            for identity in identities {
                for textOnly in [nil, false, true] as [Bool?] {
                    var configuration: [String: Any] = [
                        "model_type": modelType, "vision_config": vision,
                        "llm_config": ["model_type": "nemotron_h"],
                    ]
                    configuration["language_model_only"] = textOnly
                    XCTAssertFalse(ModelMediaPolicy.advertisesMedia(configuration, modelID: identity))
                }
            }
        }
    }

    func testGateDoesNotChangeOtherModelMediaPolicy() {
        let vision: [String: Any] = ["model_type": "radio"]
        for modelType in ["nemotron_h", "qwen3_vl", "other"] {
            var configuration: [String: Any] = ["model_type": modelType, "vision_config": vision]
            XCTAssertTrue(ModelMediaPolicy.advertisesMedia(configuration))
            configuration["language_model_only"] = true
            XCTAssertFalse(ModelMediaPolicy.advertisesMedia(configuration))
        }
        XCTAssertFalse(ModelMediaPolicy.advertisesMedia(["model_type": "nemotron_h"]))
    }
}
