import Foundation
import XCTest
@testable import ProviderCoreFoundation

final class MiMoArtifactManifestTests: XCTestCase {
    private func fixture(modelType: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mimo-manifest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try JSONSerialization.data(withJSONObject: ["model_type": modelType])
            .write(to: root.appendingPathComponent("config.json"))
        try Data([1, 2, 3, 4]).write(to: root.appendingPathComponent("model.safetensors"))
        return root
    }

    func testBothNativeMiMoFormatsIncludeTheirActualRootReceipt() async throws {
        for name in ["conversion_manifest.json", "artifact-provenance.json"] {
            let root = try fixture(modelType: "mimo_v2")
            defer { try? FileManager.default.removeItem(at: root) }
            let receipt = Data("{\"fixture\":true}".utf8)
            try receipt.write(to: root.appendingPathComponent(name))
            let nested = root.appendingPathComponent("unrelated")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            try receipt.write(to: nested.appendingPathComponent(name))
            let scanned = ModelScanner.collectWeightFiles(in: root)
            XCTAssertEqual(scanned.sizeBytes, 4)
            XCTAssertEqual(Set(scanned.paths.map(\.lastPathComponent)), Set(["config.json", "model.safetensors", name]))
            XCTAssertEqual(scanned.paths.count, 3)
            let manifest = try await ManifestBuilder.build(modelDirectory: root, modelID: "test/mimo", version: "v1")
            XCTAssertEqual(Set(manifest.files.map(\.path)), Set(["config.json", "model.safetensors", name]))
            XCTAssertEqual(manifest.files.first(where: { $0.path == name })?.sizeBytes, Int64(receipt.count))
        }
    }

    func testMiMoReceiptMutationChangesItsNativeAggregate() async throws {
        let root = try fixture(modelType: "mimo_v2")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("artifact-provenance.json")
        try Data("{\"revision\":1}".utf8).write(to: file)
        let before = try await ManifestBuilder.build(modelDirectory: root, modelID: "test/mimo", version: "v1")
        try Data("{\"revision\":2}".utf8).write(to: file)
        let after = try await ManifestBuilder.build(modelDirectory: root, modelID: "test/mimo", version: "v1")
        XCTAssertNotEqual(before.aggregateSHA256, after.aggregateSHA256)
        XCTAssertEqual(before.files.first(where: { $0.role == "weight" })?.sha256,
                       after.files.first(where: { $0.role == "weight" })?.sha256)
    }

    func testOtherFamiliesKeepTheirExistingIntegrityListsAndHashes() async throws {
        for family in ["qwen4_exp", "qwen3_5", "gemma4", "unknown"] {
            let root = try fixture(modelType: family)
            defer { try? FileManager.default.removeItem(at: root) }
            let before = try await ManifestBuilder.build(modelDirectory: root, modelID: "test/other", version: "v1")
            for name in ["conversion_manifest.json", "artifact-provenance.json"] {
                try Data("{\"unrelated\":true}".utf8).write(to: root.appendingPathComponent(name))
            }
            let after = try await ManifestBuilder.build(modelDirectory: root, modelID: "test/other", version: "v1")
            XCTAssertEqual(before.aggregateSHA256, after.aggregateSHA256, family)
            XCTAssertEqual(before.files.map(\.path), after.files.map(\.path), family)
        }
    }

    func testMalformedOrOversizedConfigDoesNotExpandTheGenericList() throws {
        let root = try fixture(modelType: "mimo_v2")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: root.appendingPathComponent("artifact-provenance.json"))
        for bytes in [Data("not-json".utf8), Data(repeating: 32, count: 1_048_577)] {
            try bytes.write(to: root.appendingPathComponent("config.json"))
            XCTAssertEqual(Set(ModelScanner.collectWeightFiles(in: root).paths.map(\.lastPathComponent)),
                           Set(["config.json", "model.safetensors"]))
        }
    }

    func testHFConfigSymlinkRetainsModelSpecificMetadata() throws {
        let root = try fixture(modelType: "mimo_v2")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config.json")
        let blob = root.appendingPathComponent("config-blob")
        try FileManager.default.moveItem(at: config, to: blob)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: blob)
        try Data("{}".utf8).write(to: root.appendingPathComponent("artifact-provenance.json"))
        XCTAssertEqual(Set(ModelScanner.collectWeightFiles(in: root).paths.map(\.lastPathComponent)),
                       Set(["config.json", "model.safetensors", "artifact-provenance.json"]))
    }
}
