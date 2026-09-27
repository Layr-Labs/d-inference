import Foundation
import XCTest

@testable import ProviderCoreFoundation

final class Qwen4MediaPolicyTests: XCTestCase {
    func testUnqualifiedNativeQwen4MediaIsDisabledForEveryOverlayState() {
        for type in ["qwen4_exp", "qwen4_exp_text"] {
            for overlay in [nil, false, true] as [Bool?] {
                var configuration: [String: Any] = [
                    "model_type": type, "vision_config": ["hidden_size": 64],
                ]
                if let overlay { configuration["language_model_only"] = overlay }
                XCTAssertFalse(ModelMediaPolicy.advertisesMedia(configuration))
            }
        }
    }

    func testNativeTypeRecognitionIsClosed() {
        for type in ["qwen4_exp", "qwen4_exp_text", " QWEN4_EXP_TEXT "] {
            XCTAssertTrue(ModelMediaPolicy.isNativeQwen4Type(type))
        }
        for type in [nil, "qwen3_5", "qwen4_exp_mtp", "custom_qwen4_exp", "gemma4"] as [String?] {
            XCTAssertFalse(ModelMediaPolicy.isNativeQwen4Type(type))
        }
    }

    func testOtherFamiliesKeepVisionAndTextOnlyPolicy() {
        for type in ["qwen3_5", "qwen3_5_moe", "qwen3_vl_moe", "gemma4"] {
            var configuration: [String: Any] = ["model_type": type]
            XCTAssertFalse(ModelMediaPolicy.advertisesMedia(configuration))
            configuration["vision_config"] = ["hidden_size": 64]
            XCTAssertTrue(ModelMediaPolicy.advertisesMedia(configuration))
            configuration["language_model_only"] = false
            XCTAssertTrue(ModelMediaPolicy.advertisesMedia(configuration))
            configuration["language_model_only"] = true
            XCTAssertFalse(ModelMediaPolicy.advertisesMedia(configuration))
        }
    }

    func testTemplateCheckUsesTextFixturesAndPreservesOriginalConfig() throws {
        let textTemplate = """
            {%- for message in messages -%}
            <|{{ message['role'] }}|>{{ message['content'].strip() }}
            {%- endfor -%}
            {%- if add_generation_prompt -%}<|assistant|>{%- endif -%}
            """
        for type in ["qwen4_exp", "qwen4_exp_text"] {
            for overlay in [nil, false, true] as [Bool?] {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("qwen4-media-template-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                var configuration: [String: Any] = [
                    "model_type": type, "vision_config": ["hidden_size": 64],
                ]
                if let overlay { configuration["language_model_only"] = overlay }
                let original = try JSONSerialization.data(withJSONObject: configuration, options: .sortedKeys)
                let configURL = directory.appendingPathComponent("config.json")
                try original.write(to: configURL)
                try Data(textTemplate.utf8).write(to: directory.appendingPathComponent("chat_template.jinja"))

                XCTAssertFalse(TemplateRenderCheck.configDeclaresVision(at: directory))
                XCTAssertEqual(TemplateRenderCheck.renderOK(at: directory), true)
                XCTAssertEqual(try Data(contentsOf: configURL), original)
            }
        }
    }
}
