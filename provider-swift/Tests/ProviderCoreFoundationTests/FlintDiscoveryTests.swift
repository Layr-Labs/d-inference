import Darwin
import Foundation
import Testing
@testable import ProviderCoreFoundation

@Suite("Flint shard-only discovery")
struct FlintDiscoveryTests {
    @Test func discoversOnlyFlintAndNeverBlocksOnSpecialConfig() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.json")
        try Data([1]).write(to: directory.appendingPathComponent("model-00000.safetensors"))
        try Data(#"{"model_type":"flint"}"#.utf8).write(to: config)
        #expect(ModelScanner.isMLXModel(snapshotDir: directory, modelName: "RecursiveSI/flint-int4"))
        try Data(#"{"model_type":"unknown"}"#.utf8).write(to: config)
        #expect(!ModelScanner.isMLXModel(snapshotDir: directory, modelName: "unknown"))
        try FileManager.default.removeItem(at: config)
        #expect(mkfifo(config.path, 0o600) == 0)
        #expect(!ModelScanner.isMLXModel(snapshotDir: directory, modelName: "unknown"))
    }
}
