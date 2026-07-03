import XCTest
@testable import ProviderCoreFoundation

/// Coverage for `SafetensorsSizing`'s header-only tensor-byte accounting —
/// the primitive `ExpertStreamingAdmission` (and `ModelScanner`'s streaming-
/// aware estimate) build on to size DeepSeek-V4's routed-expert
/// (`switch_mlp`) footprint without ever reading tensor payload bytes.
final class SafetensorsSizingTests: XCTestCase {

    /// Write a minimal valid safetensors file: an 8-byte little-endian header
    /// length, followed by the JSON header. No tensor payload bytes are
    /// written — `SafetensorsSizing` never reads past the header, so tests
    /// don't need to materialize (potentially huge) fake tensor data.
    private func writeSafetensorsFile(
        at url: URL, tensors: [(name: String, byteSize: Int)]
    ) throws {
        var header: [String: Any] = [:]
        var offset = 0
        for (name, byteSize) in tensors {
            header[name] = [
                "dtype": "F32",
                "shape": [max(1, byteSize / 4)],
                "data_offsets": [offset, offset + byteSize],
            ]
            offset += byteSize
        }
        header["__metadata__"] = ["format": "mlx"]

        let headerData = try JSONSerialization.data(withJSONObject: header)
        var fileData = Data()
        var length = UInt64(headerData.count).littleEndian
        withUnsafeBytes(of: &length) { fileData.append(contentsOf: $0) }
        fileData.append(headerData)
        try fileData.write(to: url)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("safetensors-sizing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Single-shard (no index)

    func testSumsMatchingTensorsInASingleShardWithoutAnIndex() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeSafetensorsFile(
            at: dir.appendingPathComponent("model.safetensors"),
            tensors: [
                ("model.layers.0.ffn.switch_mlp.gate_proj.weight", 1_000_000),
                ("model.layers.0.ffn.switch_mlp.up_proj.weight", 2_000_000),
                ("model.layers.0.self_attn.q_proj.weight", 500_000),
            ])

        let total = try SafetensorsSizing.sumTensorBytes(in: dir) { $0.contains(".ffn.switch_mlp.") }
        XCTAssertEqual(total, 3_000_000)
    }

    func testNonMatchingKeysAreExcluded() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeSafetensorsFile(
            at: dir.appendingPathComponent("model.safetensors"),
            tensors: [("model.embed_tokens.weight", 12_345)])

        let total = try SafetensorsSizing.sumTensorBytes(in: dir) { $0.contains(".ffn.switch_mlp.") }
        XCTAssertEqual(total, 0)
    }

    // MARK: - Multi-shard (via index.json)

    func testSumsAcrossShardsListedInTheIndex() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeSafetensorsFile(
            at: dir.appendingPathComponent("model-00001-of-00002.safetensors"),
            tensors: [("model.layers.0.ffn.switch_mlp.gate_proj.weight", 700_000)])
        try writeSafetensorsFile(
            at: dir.appendingPathComponent("model-00002-of-00002.safetensors"),
            tensors: [
                ("model.layers.1.ffn.switch_mlp.gate_proj.weight", 300_000),
                ("model.layers.1.self_attn.q_proj.weight", 999),
            ])

        let index: [String: Any] = [
            "metadata": ["total_size": 1_000_999],
            "weight_map": [
                "model.layers.0.ffn.switch_mlp.gate_proj.weight": "model-00001-of-00002.safetensors",
                "model.layers.1.ffn.switch_mlp.gate_proj.weight": "model-00002-of-00002.safetensors",
                "model.layers.1.self_attn.q_proj.weight": "model-00002-of-00002.safetensors",
            ],
        ]
        try JSONSerialization.data(withJSONObject: index).write(
            to: dir.appendingPathComponent("model.safetensors.index.json"))

        let total = try SafetensorsSizing.sumTensorBytes(in: dir) { $0.contains(".ffn.switch_mlp.") }
        XCTAssertEqual(total, 1_000_000)
    }

    // MARK: - Empty / missing directory

    func testReturnsZeroWhenThereAreNoSafetensorsFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let total = try SafetensorsSizing.sumTensorBytes(in: dir) { _ in true }
        XCTAssertEqual(total, 0)
    }

    // MARK: - Malformed entries are skipped, not fatal

    func testMalformedTensorEntryIsSkippedNotThrown() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let header: [String: Any] = [
            "model.layers.0.ffn.switch_mlp.gate_proj.weight": [
                "dtype": "F32", "shape": [1], "data_offsets": [0, 400],
            ],
            "model.layers.0.ffn.switch_mlp.broken": [
                "dtype": "F32", "shape": [1],
                // Missing data_offsets entirely.
            ],
        ]
        let headerData = try JSONSerialization.data(withJSONObject: header)
        var fileData = Data()
        var length = UInt64(headerData.count).littleEndian
        withUnsafeBytes(of: &length) { fileData.append(contentsOf: $0) }
        fileData.append(headerData)
        try fileData.write(to: dir.appendingPathComponent("model.safetensors"))

        let total = try SafetensorsSizing.sumTensorBytes(in: dir) { $0.contains(".ffn.switch_mlp.") }
        XCTAssertEqual(total, 400, "the malformed entry is skipped, the well-formed one still counts")
    }
}
