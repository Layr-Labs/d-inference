import Foundation
import XCTest
@testable import ProviderCoreFoundation

final class NemotronSuperDistributionManifestTests: XCTestCase {
    private func fixture(_ modelType: String, padding: Int = 0) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("super-distribution-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try JSONSerialization.data(withJSONObject: ["model_type": modelType, "padding": String(repeating: "x", count: padding)])
            .write(to: root.appendingPathComponent("config.json"))
        try Data([1, 2, 3, 4]).write(to: root.appendingPathComponent("model.safetensors"))
        return root
    }

    func testOneManifestCarriesRootNoticesWithLargeSuperConfig() async throws {
        let root = try fixture("nemotron_h_omni", padding: 8_668_620)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["LICENSE.txt", "UPSTREAM_README.md"] {
            try Data("distribution notice".utf8).write(to: root.appendingPathComponent(name))
        }
        let nested = root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data("unrelated".utf8).write(to: nested.appendingPathComponent("LICENSE.txt"))
        let manifest = try await ManifestBuilder.build(modelDirectory: root, modelID: "test/super", version: "v1")
        XCTAssertEqual(Set(manifest.files.map(\.path)), Set(["config.json", "model.safetensors", "LICENSE.txt", "UPSTREAM_README.md"]))
        XCTAssertEqual(manifest.files.first { $0.path == "LICENSE.txt" }?.role, "other")
        XCTAssertEqual(manifest.aggregateSHA256, WeightHasher.computeHash(snapshotDir: root))
        XCTAssertEqual(ModelScanner.collectWeightFiles(in: root).sizeBytes, 4)
        try Data("changed notice".utf8).write(to: root.appendingPathComponent("LICENSE.txt"))
        XCTAssertNotEqual(manifest.aggregateSHA256, WeightHasher.computeHash(snapshotDir: root))
    }

    func testNoticesDoNotChangeOtherFamiliesOrMiMoReadBound() throws {
        for (family, padding) in [("qwen3_5", 0), ("unknown", 0), ("mimo_v2", 1_048_577)] {
            let root = try fixture(family, padding: padding)
            defer { try? FileManager.default.removeItem(at: root) }
            let before = WeightHasher.computeHash(snapshotDir: root)
            for name in ["LICENSE.txt", "UPSTREAM_README.md", "artifact-provenance.json"] {
                try Data("unrelated".utf8).write(to: root.appendingPathComponent(name))
            }
            XCTAssertEqual(before, WeightHasher.computeHash(snapshotDir: root), family)
        }
    }
}
