import Foundation
import XCTest

@testable import ProviderCoreFoundation

final class DiffusionGemmaMediaPolicyTests: XCTestCase {
    private var fullConfiguration: [String: Any] {
        ["model_type": "diffusion_gemma",
         "text_config": ["model_type": "diffusion_gemma_text"],
         "vision_config": ["model_type": "gemma4_vision"]]
    }

    func testNativeWrapperAdvertisesItsSupportedVisionTower() {
        var configuration = fullConfiguration
        XCTAssertTrue(ModelMediaPolicy.advertisesMedia(configuration))
        configuration["language_model_only"] = false
        XCTAssertTrue(ModelMediaPolicy.advertisesMedia(configuration))
        configuration["language_model_only"] = true
        XCTAssertFalse(ModelMediaPolicy.advertisesMedia(configuration))
    }

    func testIncompleteOrForeignComponentsRemainTextOnly() {
        for key in ["text_config", "vision_config"] {
            for replacement in [nil, NSNull(), [String: Any](), ["model_type": "other"]] as [Any?] {
                var configuration = fullConfiguration
                configuration[key] = replacement
                XCTAssertFalse(ModelMediaPolicy.advertisesMedia(configuration))
            }
        }
        var text = fullConfiguration
        text["model_type"] = "diffusion_gemma_text"
        XCTAssertFalse(ModelMediaPolicy.advertisesMedia(text))
    }

    func testTemplateChecksActuallyIncludeMediaWithoutChangingConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diffusion-media-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try JSONSerialization.data(withJSONObject: fullConfiguration, options: .sortedKeys)
        let config = directory.appendingPathComponent("config.json")
        try data.write(to: config)
        let textOnlyTemplate = """
            {%- for message in messages -%}
            {{ message['content'].strip() }}
            {%- endfor -%}
            """
        try Data(textOnlyTemplate.utf8).write(to: directory.appendingPathComponent("chat_template.jinja"))
        XCTAssertTrue(TemplateRenderCheck.configDeclaresVision(at: directory))
        XCTAssertEqual(TemplateRenderCheck.renderOK(at: directory), false)
        XCTAssertEqual(try Data(contentsOf: config), data)
    }
}
