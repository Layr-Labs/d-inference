import Foundation
import Testing
@testable import ProviderCore
import ProviderCoreFoundation

/// Scanner coverage for the gemma-4-31b-4bit flagship checkpoint SHAPE: a
/// dense `gemma4` model with a `vision_config`, 4-bit affine quantization,
/// sharded weights, and NO chat template (base checkpoint). Pins the
/// admission-relevant behaviors the fleet registration relies on
/// (docs/reference/gemma-4-31b-serving.md):
///
/// 1. Discovery treats it as an ordinary resident model — `estimatedMemoryGb`
///    is the on-disk total × the 1.2 overhead factor, NOT a streaming
///    estimate (no `switch_mlp` tensors → `ExpertStreamingAdmission` never
///    engages).
/// 2. The memory filter admits it exactly when the estimate fits available
///    RAM — the provider-side mirror of the coordinator's
///    `TestGemma31bResident*` gates (32GB tier admits, 24GB-class rejects).
/// 3. `vision_config` is detected (drives VLMModelFactory routing at load).
@Suite("gemma-4-31b checkpoint-shape scan", .serialized)
struct Gemma31bScanTests {

    /// Miniature gemma-4-31b-4bit: same config fields that drive scanner
    /// decisions (model_type, vision_config, quantization, no chat_template),
    /// with SPARSE shard files at the real checkpoint's logical sizes
    /// (truncate allocates no data blocks, so nothing near 18GB touches disk
    /// while the scanner still reads the full logical size).
    private func makeGemma31b(in cacheDir: URL, weightBytes: [Int64]) throws -> URL {
        let snapshot = cacheDir.appendingPathComponent("models--mlx-community--gemma-4-31b-4bit")
            .appendingPathComponent("snapshots")
            .appendingPathComponent("local")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        let config = """
            {
                "architectures": ["Gemma4ForConditionalGeneration"],
                "model_type": "gemma4",
                "quantization": {"group_size": 64, "bits": 4, "mode": "affine"},
                "text_config": {
                    "model_type": "gemma4",
                    "num_hidden_layers": 60,
                    "hidden_size": 5376,
                    "enable_moe_block": false,
                    "sliding_window": 1024,
                    "max_position_embeddings": 262144,
                    "vocab_size": 262144
                },
                "vision_config": {"model_type": "gemma4", "hidden_size": 1152}
            }
            """
        try Data(config.utf8).write(to: snapshot.appendingPathComponent("config.json"))
        // Base checkpoint: tokenizer_config WITHOUT chat_template.
        try Data(#"{"tokenizer_class": "GemmaTokenizer"}"#.utf8)
            .write(to: snapshot.appendingPathComponent("tokenizer_config.json"))
        for (i, bytes) in weightBytes.enumerated() {
            let shard = snapshot.appendingPathComponent(
                String(format: "model-%05d-of-%05d.safetensors", i + 1, weightBytes.count))
            FileManager.default.createFile(atPath: shard.path, contents: nil)
            let fh = try FileHandle(forWritingTo: shard)
            try fh.truncate(atOffset: UInt64(bytes))
            try fh.close()
        }
        return snapshot
    }

    /// The real checkpoint's shard sizes (5.37/5.36/5.37/2.32 GB, sparse).
    private static let shardBytes: [Int64] = [
        5_370_000_000, 5_360_000_000, 5_370_000_000, 2_320_000_000,
    ]
    private static let totalBytes: Int64 = shardBytes.reduce(0, +)  // 18.42GB

    @Test("resident estimate is disk×1.2 — no streaming math for a dense gemma4")
    func residentEstimateUsesOverheadFactor() throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        _ = try makeGemma31b(in: cacheDir, weightBytes: Self.shardBytes)

        let all = ModelScanner.scanAllModels(in: cacheDir)
        let model = try #require(all.first { $0.id == "mlx-community/gemma-4-31b-4bit" },
                                 "scanner must discover the sharded gemma4 checkpoint")

        // Scanner units are GiB (bytes / 1024³): 18.42GB = 17.16GiB × 1.2 ≈ 20.6.
        let diskGib = Double(Self.totalBytes) / (1024.0 * 1024.0 * 1024.0)
        let expected = diskGib * 1.2
        #expect(abs(model.estimatedMemoryGb - expected) < 0.001,
                "resident model estimate must be disk total × 1.2 (got \(model.estimatedMemoryGb), want \(expected)) — a streaming-style estimate here would corrupt fleet admission")
    }

    @Test("memory filter mirrors the coordinator's min_ram floor behavior")
    func memoryFilterMatchesFleetTiers() throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        _ = try makeGemma31b(in: cacheDir, weightBytes: Self.shardBytes)

        // Estimate is ~20.6GiB (17.16GiB × 1.2): a 32GB-tier box admits, a
        // 20GB-available box (24GB-class after OS reserve) rejects — the
        // provider-side mirror of the coordinator's min_ram_gb=32 floor.
        let admits = ModelScanner.scanModels(in: cacheDir, availableMemoryGB: 32)
        #expect(admits.contains { $0.id == "mlx-community/gemma-4-31b-4bit" })

        let rejects = ModelScanner.scanModels(in: cacheDir, availableMemoryGB: 20)
        #expect(!rejects.contains { $0.id == "mlx-community/gemma-4-31b-4bit" })
    }

    @Test("vision_config is detected (drives VLMModelFactory routing)")
    func visionConfigDetected() throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let snapshot = try makeGemma31b(in: cacheDir, weightBytes: Self.shardBytes)

        let configURL = snapshot.appendingPathComponent("config.json")
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
        #expect(json["vision_config"] != nil,
                "fixture must carry vision_config — the real checkpoint routes via VLMModelFactory because of it")
    }
}
