// Copyright © 2026 Eigen Labs.

import Foundation
import XCTest

@testable import ProviderCoreFoundation

/// `MuseGlimmerVisionPolicy`: the exact identity and the pinned vision stack
/// decide whether a Muse Glimmer configuration may advertise images (there is
/// no switch); every other configuration is refused with a fixed reason.
final class MuseGlimmerVisionPolicyTests: XCTestCase {
    /// The fields of the pinned `config.json` (revision 47818374) the policy reads.
    private static func pinned() -> [String: Any] {
        [
            "model_type": "muse_glimmer",
            "image_token_id": 200_092,
            "video_token_id": 200_091,
            "vision_config": [
                "model_type": "muse_glimmer_vision", "patch_size": 14, "merge_size": 2,
                "patch_temporal": 2, "hidden_size": 1_536, "num_hidden_layers": 50,
                "intermediate_size": 8_960,
            ] as [String: Any],
        ]
    }

    func testThePinnedStackServesBothIdentities() {
        for id in [MuseGlimmerModelPolicy.catalogModelID, MuseGlimmerModelPolicy.localModelID] {
            XCTAssertNil(MuseGlimmerVisionPolicy.configurationRefusal(Self.pinned(), modelID: id))
        }
    }

    func testAnEmptyConfigurationIsRefused() {
        XCTAssertEqual(MuseGlimmerVisionPolicy.configurationRefusal([:], modelID: nil), .notServingIdentity)
        XCTAssertEqual(
            MuseGlimmerVisionPolicy.configurationRefusal([:], modelID: MuseGlimmerModelPolicy.localModelID),
            .notServingIdentity)
    }

    func testOnlyTheExactIdentity() {
        let id = MuseGlimmerModelPolicy.localModelID
        for modelID in [nil, "", "nvidia/Muse-Glimmer-30B-BF16", "muse-glimmer-30b-vision", id.uppercased()] {
            XCTAssertEqual(MuseGlimmerVisionPolicy.configurationRefusal(
                Self.pinned(), modelID: modelID), .notServingIdentity, "\(modelID ?? "nil")")
        }
        // The wire-protocol rule trims and lowercases; media takes the exact spelling only.
        for modelType in ["MUSE_GLIMMER", " muse_glimmer", "muse_glimmer\n", "muse_glimmer_text"] {
            var configuration = Self.pinned()
            configuration["model_type"] = modelType
            XCTAssertEqual(MuseGlimmerVisionPolicy.configurationRefusal(
                configuration, modelID: id), .notServingIdentity, modelType)
        }
        var missing = Self.pinned()
        missing.removeValue(forKey: "model_type")
        XCTAssertEqual(
            MuseGlimmerVisionPolicy.configurationRefusal(missing, modelID: id), .notServingIdentity)
    }

    func testEveryPinnedVisionFieldIsRequired() {
        let id = MuseGlimmerModelPolicy.localModelID
        func refusal(_ edit: (inout [String: Any]) -> Void) -> MuseGlimmerVisionPolicy.Refusal? {
            var configuration = Self.pinned()
            edit(&configuration)
            return MuseGlimmerVisionPolicy.configurationRefusal(configuration, modelID: id)
        }
        func vision(_ key: String, _ value: Any?) -> MuseGlimmerVisionPolicy.Refusal? {
            refusal { configuration in
                var vision = configuration["vision_config"] as! [String: Any]
                vision[key] = value
                configuration["vision_config"] = vision
            }
        }
        XCTAssertEqual(refusal { $0.removeValue(forKey: "vision_config") }, .configuration)
        XCTAssertEqual(refusal { $0["vision_config"] = "muse_glimmer_vision" }, .configuration)
        XCTAssertEqual(refusal { $0["image_token_id"] = 200_091 }, .configuration)
        XCTAssertEqual(refusal { $0.removeValue(forKey: "image_token_id") }, .configuration)
        XCTAssertEqual(refusal { $0["video_token_id"] = 200_092 }, .configuration)
        XCTAssertEqual(refusal { $0["image_token_id"] = "200092" }, .configuration)
        XCTAssertEqual(vision("model_type", "muse_glimmer_audio"), .configuration)
        XCTAssertEqual(vision("model_type", nil), .configuration)
        for (key, value) in [("patch_size", 16), ("merge_size", 1), ("patch_temporal", 1),
                             ("hidden_size", 1_280), ("num_hidden_layers", 49)] {
            XCTAssertEqual(vision(key, value), .configuration, key)
            XCTAssertEqual(vision(key, nil), .configuration, key)
        }
        // A fraction or a Boolean is not the pinned integer.
        XCTAssertEqual(vision("patch_size", 14.5), .configuration)
        XCTAssertEqual(vision("merge_size", true), .configuration)
        XCTAssertEqual(refusal { $0["image_token_id"] = 200_092.5 }, .configuration)
        // The integral double a JSON reader may produce is the same number.
        XCTAssertNil(vision("patch_size", 14.0))
    }

    func testATextOnlyOverlayNeverServesImages() {
        let id = MuseGlimmerModelPolicy.localModelID
        func refusal(_ overlay: Any) -> MuseGlimmerVisionPolicy.Refusal? {
            var configuration = Self.pinned()
            configuration["language_model_only"] = overlay
            return MuseGlimmerVisionPolicy.configurationRefusal(configuration, modelID: id)
        }
        XCTAssertEqual(refusal(true), .configuration)
        XCTAssertNil(refusal(false))
        // Only a JSON Boolean says "not an overlay".
        XCTAssertEqual(refusal(0), .configuration)
        XCTAssertEqual(refusal("false"), .configuration)
        XCTAssertEqual(refusal(NSNull()), .configuration)
    }

    func testTheRealConfigurationDecodedFromJSONServes() throws {
        // As discovery reads it: JSONSerialization numbers, not Swift literals.
        let data = try JSONSerialization.data(withJSONObject: Self.pinned())
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(MuseGlimmerVisionPolicy.configurationRefusal(
            decoded, modelID: MuseGlimmerModelPolicy.catalogModelID))
        let flagged = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(#"{"language_model_only": false}"#.utf8)) as? [String: Any])
        var configuration = decoded
        configuration["language_model_only"] = flagged["language_model_only"]
        XCTAssertNil(MuseGlimmerVisionPolicy.configurationRefusal(
            configuration, modelID: MuseGlimmerModelPolicy.catalogModelID))
    }

    func testTheCeilingAndTokenIDs() {
        XCTAssertEqual(MuseGlimmerVisionPolicy.maximumImageTokens, 4_096)
        XCTAssertEqual(MuseGlimmerVisionPolicy.framingTokens, 2)
        XCTAssertEqual(MuseGlimmerVisionPolicy.maximumPromptTokensPerImage, 4_098)
        XCTAssertEqual(MuseGlimmerVisionPolicy.imageTokenID, 200_092)
        XCTAssertEqual(MuseGlimmerVisionPolicy.videoTokenID, 200_091)
        for pin in [MuseGlimmerVisionPolicy.pinnedConfigurationSHA256,
                    MuseGlimmerVisionPolicy.pinnedProcessorConfigurationSHA256] {
            XCTAssertEqual(pin.count, 64)
            XCTAssertTrue(pin.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }
    }

    func testReasonsAreFixedAndDistinct() {
        let refusals: [MuseGlimmerVisionPolicy.Refusal] = [
            .notServingIdentity, .configuration, .unpinnedArtifact(file: "config.json"),
            .unpinnedArtifact(file: "processor_config.json"), .encoderUnavailable, .video,
        ]
        let reasons = refusals.map(\.reason)
        XCTAssertEqual(Set(reasons).count, reasons.count)
        for (refusal, reason) in zip(refusals, reasons) {
            XCTAssertEqual(refusal.description, reason)
            XCTAssertFalse(reason.isEmpty)
            XCTAssertFalse(reason.contains("/"), reason)
        }
        XCTAssertEqual(MuseGlimmerVisionPolicy.Refusal.video.reason, "video input is not supported yet")
    }
}
