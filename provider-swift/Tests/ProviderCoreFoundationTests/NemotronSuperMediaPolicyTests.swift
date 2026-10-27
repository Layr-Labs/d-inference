import Foundation
import XCTest

@testable import ProviderCoreFoundation

final class NemotronSuperMediaPolicyTests: XCTestCase {
    func testOmniOutsideTheRegistryIdentityCannotAdvertiseMedia() {
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

    func testOnlyTheExactRegistryIDAdvertisesImageInput() {
        let registryID = "nvidia-nemotron-3.5-super"
        XCTAssertEqual(ModelMediaPolicy.nemotronSuperModelID, registryID)
        let pinned: [String: Any] = [
            "model_type": "nemotron_h_omni", "vision_config": ["model_type": "radio"],
            "llm_config": ["model_type": "nemotron_h"],
        ]
        XCTAssertTrue(ModelMediaPolicy.advertisesMedia(pinned, modelID: registryID))
        var explicitVLM = pinned
        explicitVLM["language_model_only"] = false
        XCTAssertTrue(ModelMediaPolicy.advertisesMedia(explicitVLM, modelID: registryID))
        for identity in [nil, registryID.uppercased(), registryID + "-r2", " " + registryID,
                         registryID + "\n", "nvidia/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-NVFP4"] as [String?] {
            XCTAssertFalse(ModelMediaPolicy.advertisesMedia(pinned, modelID: identity), "\(identity ?? "nil")")
        }
        for modelType in ["NEMOTRON_H_OMNI", " nemotron_h_omni", "nemotron_h_omni\n"] {
            var configuration = pinned
            configuration["model_type"] = modelType
            XCTAssertFalse(ModelMediaPolicy.advertisesMedia(configuration, modelID: registryID), modelType)
        }
        var textOnly = pinned
        textOnly["language_model_only"] = true
        XCTAssertFalse(ModelMediaPolicy.advertisesMedia(textOnly, modelID: registryID))
        var noTower = pinned
        noTower.removeValue(forKey: "vision_config")
        XCTAssertFalse(ModelMediaPolicy.advertisesMedia(noTower, modelID: registryID))
        noTower["vision_config"] = "radio"
        XCTAssertFalse(ModelMediaPolicy.advertisesMedia(noTower, modelID: registryID))
        // The registry id grants nothing to another architecture.
        XCTAssertFalse(ModelMediaPolicy.advertisesMedia(["model_type": "nemotron_h"], modelID: registryID))
        XCTAssertFalse(ModelMediaPolicy.advertisesMedia(
            ["model_type": "qwen4_exp", "vision_config": ["model_type": "qwen4_exp"]], modelID: registryID))
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
