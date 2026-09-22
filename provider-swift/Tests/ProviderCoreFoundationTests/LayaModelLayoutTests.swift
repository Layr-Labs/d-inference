import Foundation
import XCTest
@testable import ProviderCoreFoundation

final class LayaModelLayoutTests: XCTestCase {
    private func fixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("laya-layout-\(UUID())")
        for folder in ["", "encoder", "tokenizer"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let files = [
            "mlx_config.json": #"{"format":"laya-mlx","format_version":1,"dtype":"float16"}"#,
            "encoder/config.json": #"{"model_type":"modernbert"}"#,
            "rl_agent_config.json": #"{"head_layers":2,"max_len":512,"head_max_len":192,"max_prefixes":6}"#,
            "tokenizer/tokenizer.json": "{}", "tokenizer/tokenizer_config.json": "{}",
            "model.safetensors": "fixture-weights",
            "LICENSE": "fixture-license", "NOTICE": "fixture-notice",
        ]
        for (name, value) in files { try Data(value.utf8).write(to: dir.appendingPathComponent(name)) }
        return dir
    }

    func testNestedNativeLayoutNeedsNoInventedChatFiles() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(LayaModelLayout.isSupported(at: dir))
        XCTAssertTrue(ModelScanner.isMLXModel(snapshotDir: dir, modelName: "catalog/decision"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("tokenizer/tokenizer.json"))
        XCTAssertFalse(LayaModelLayout.isSupported(at: dir))
    }

    func testGenerativeHashContractIgnoresIncidentalDecisionMetadata() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"format":"other"}"#.utf8).write(to: dir.appendingPathComponent("mlx_config.json"))
        let before = WeightHasher.computeHash(snapshotDir: dir, modelID: "catalog/chat")
        try Data("changed".utf8).write(to: dir.appendingPathComponent("rl_agent_config.json"))
        let after = WeightHasher.computeHash(snapshotDir: dir, modelID: "catalog/chat")
        XCTAssertNotNil(before)
        XCTAssertEqual(before, after)
        XCTAssertFalse(ModelScanner.integrityFileNames.contains("mlx_config.json"))
        XCTAssertFalse(ModelScanner.integrityFileNames.contains("rl_agent_config.json"))
    }

    func testNativeMetadataAndNestedTokenizerAreAttested() async throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = try await ManifestBuilder.build(modelDirectory: dir, modelID: "catalog/decision", version: "v1")
        for name in ["mlx_config.json", "rl_agent_config.json", "encoder/config.json", "tokenizer/tokenizer.json", "LICENSE", "NOTICE"] {
            XCTAssertNotNil(before.files.first { $0.path == name })
        }
        XCTAssertEqual(before.files.first { $0.path == "rl_agent_config.json" }?.role, "config")
        try Data(#"{"max_len":1024}"#.utf8).write(to: dir.appendingPathComponent("rl_agent_config.json"))
        let after = try await ManifestBuilder.build(modelDirectory: dir, modelID: "catalog/decision", version: "v1")
        XCTAssertNotEqual(before.aggregateSHA256, after.aggregateSHA256)
        XCTAssertEqual(before.files.first { $0.path == "LICENSE" }?.role, "other")
        XCTAssertEqual(before.files.first { $0.path == "NOTICE" }?.role, "other")
        try Data("changed-notice".utf8).write(to: dir.appendingPathComponent("NOTICE"))
        let afterNotice = try await ManifestBuilder.build(modelDirectory: dir, modelID: "catalog/decision", version: "v1")
        XCTAssertNotEqual(after.aggregateSHA256, afterNotice.aggregateSHA256)
        XCTAssertFalse(LayaModelLayout.isSupported(at: dir))
    }
}
