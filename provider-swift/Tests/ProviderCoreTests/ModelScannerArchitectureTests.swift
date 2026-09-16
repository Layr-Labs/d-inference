import Foundation
import Testing
@testable import ProviderCore

@Suite("Model scanner architecture metadata")
struct ModelScannerArchitectureTests {
    @Test("Normal architecture estimates preserve million-parameter rounding")
    func estimate() throws {
        let parsed = try parse(["hidden_size": 512, "num_hidden_layers": 8])
        #expect(parsed.modelType == "test")
        #expect(parsed.parameters == 25_000_000 + 32_000 * 512)
    }

    @Test("Explicit parameter counts precede architecture estimation")
    func explicitCount() throws {
        for count in [0, 123] {
            #expect(try parse(["num_parameters": count, "hidden_size": -1]).parameters == UInt64(count))
        }
    }

    @Test("Negative or overflowing dimensions retain unknown parameters")
    func malformedDimensions() throws {
        for fields in [
            ["hidden_size": -1, "num_hidden_layers": 8],
            ["hidden_size": 512, "num_hidden_layers": -1],
            ["hidden_size": 512, "num_hidden_layers": 8, "vocab_size": -1],
            ["hidden_size": Int.max, "num_hidden_layers": 8],
            ["hidden_size": 512, "num_hidden_layers": Int.max],
            ["hidden_size": 512, "num_hidden_layers": 8, "vocab_size": Int.max],
        ] {
            let parsed = try parse(fields)
            #expect(parsed.modelType == "test")
            #expect(parsed.parameters == nil)
        }
    }

    private func parse(_ fields: [String: Int]) throws -> (modelType: String?, parameters: UInt64?) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-scanner-metadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var json = fields.mapValues { $0 as Any }
        json["model_type"] = "test"
        let config = directory.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: json).write(to: config)
        return ModelScanner.parseConfigJSON(at: config)
    }
}
