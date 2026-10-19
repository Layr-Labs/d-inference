import Foundation
import DarkbloomClusterRuntime
import MLXLLM
import XCTest
@testable import DarkbloomClusterWorker

/// Uses the parent's exact native-scope installed quote input and real metadata.
/// No run/execute/LOAD, model construction, cap installation or device query.
final class GLM5NextCalibrationMetadataBindingWireTests: XCTestCase {
    func testActualMetadataBindingMustBeRederivedBeforeLoad() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let input = environment["DARKBLOOM_GLM_METADATA_INPUT"] else {
            if environment["DARKBLOOM_GLM_METADATA_BINDING_REQUIRED"] == "1" {
                XCTFail("Required source-matched installed metadata input is absent"); return
            }
            throw XCTSkip("Requires the parent's native-scope metadata fixture")
        }
        let inputBytes = try Data(contentsOf: URL(fileURLWithPath: input))
        XCTAssertLessThanOrEqual(inputBytes.count, 256 << 10)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: inputBytes) as? [String: Any])
        let directory = URL(fileURLWithPath: try XCTUnwrap(object["modelDirectory"] as? String))
        let request = try JSONDecoder().decode(GLM5NextCalibrationQuoteWire.Request.self,
            from: JSONSerialization.data(withJSONObject: XCTUnwrap(object["request"])))
        let p = request.selection
        try GLM5NextCalibration.requirePinnedSelection(repository: p.repository, revision: p.revision,
            aggregate: p.artifactSHA256, configurationSHA256: p.files["config.json"]?.sha256,
            indexSHA256: p.files["model.safetensors.index.json"]?.sha256)
        let config = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        XCTAssertLessThanOrEqual(config.count, 32 << 20)
        func descriptor(cut: Int, profileID: String) throws -> GLM5NextResidentDescriptor {
            try .init(modelID: GLM5NextWorkerQualification.modelID,
                artifactIdentity: .init(repository: p.repository, revision: p.revision,
                    files: p.files.mapValues { .init(bytes: $0.bytes, sha256: $0.sha256) }),
                artifactAggregateSHA256: p.artifactSHA256, configurationBytes: config, cut: cut,
                storage: .nvfp4Hybrid, executionPolicy: .serving, profileID: profileID,
                maximumPromptTokens: p.maximumPromptTokens, maximumChunkTokens: p.maximumChunkTokens,
                maximumOutputTokens: p.maximumOutputTokens, maximumContextTokens: p.maximumContextTokens)
        }
        let actual = try descriptor(cut: p.cut, profileID: p.profileID)
        let inventory = try actual.inspectInventory(directory: directory)
        try GLM5NextCalibration.requirePinnedInventory(inventory)
        let binding = try GLM5NextCalibration.binding(descriptor: actual, inventory: inventory)
        try GLM5NextCalibrationCommand.requireBinding(binding, descriptor: actual, inventory: inventory)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(binding)
        let decoded = try JSONDecoder().decode(GLM5NextCalibration.Binding.self, from: bytes)
        try GLM5NextCalibrationCommand.requireBinding(decoded, descriptor: actual, inventory: inventory)
        var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let replacement = binding.executionPlanSHA256.hasPrefix("0") ? "1" : "0"
        wire["executionPlanSHA256"] = replacement + binding.executionPlanSHA256.dropFirst()
        let changed = try JSONDecoder().decode(GLM5NextCalibration.Binding.self,
            from: JSONSerialization.data(withJSONObject: wire))
        XCTAssertThrowsError(try GLM5NextCalibrationCommand.requireBinding(changed,
            descriptor: actual, inventory: inventory))
        var profile = try XCTUnwrap(wire["profile"] as? [String: Any])
        wire["executionPlanSHA256"] = binding.executionPlanSHA256
        profile["vocabularySize"] = binding.profile.vocabularySize + 1; wire["profile"] = profile
        let wrongVocabulary = try JSONDecoder().decode(GLM5NextCalibration.Binding.self,
            from: JSONSerialization.data(withJSONObject: wire))
        XCTAssertThrowsError(try GLM5NextCalibrationCommand.requireBinding(wrongVocabulary,
            descriptor: actual, inventory: inventory))
        let changedProfile = try descriptor(cut: p.cut, profileID: p.profileID + "-changed")
        XCTAssertThrowsError(try GLM5NextCalibrationCommand.requireBinding(binding,
            descriptor: changedProfile, inventory: inventory))
        let changedCut = try descriptor(cut: p.cut == 22 ? 23 : 22, profileID: p.profileID)
        XCTAssertThrowsError(try GLM5NextCalibrationCommand.requireBinding(binding,
            descriptor: changedCut, inventory: inventory))
        if let output = environment["DARKBLOOM_GLM_METADATA_BINDING_OUTPUT"] {
            // Parent supplies a new path in its task-private gate directory.
            try bytes.write(to: URL(fileURLWithPath: output), options: [.withoutOverwriting])
        }
    }
}
