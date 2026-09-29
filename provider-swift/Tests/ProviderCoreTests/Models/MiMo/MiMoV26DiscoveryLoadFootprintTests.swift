import Darwin
import Foundation
import MLXLLM
import MLXVLM
import ProviderCoreFoundation
import XCTest
@testable import ProviderCore

/// Shared test inputs, not production quotes or allocation permits. These
/// selected-artifact constants pin arithmetic separately from the real strict
/// metadata inspection tests below. No test calls load(), claim(), or eval().
enum MiMoDiscoveryFixture {
    static let selectedStoredBytes: UInt64 = 172_847_269_645
    static let selectedMainLoadBytes: UInt64 = 185_475_445_024
    static let selectedSidecarLoadBytes: UInt64 = 3_879_023_504
    static let selectedTotalLoadBytes = selectedMainLoadBytes + selectedSidecarLoadBytes
    static let GiB = 1_073_741_824.0
    static var selectedLoadGiB: Double { Double(selectedTotalLoadBytes) / GiB }
    static var oldLoadGiB: Double { Double(selectedStoredBytes) / GiB * 1.2 }
    static func selectedArithmeticInfo() -> ModelInfo {
        .init(id: "test/mimo-load-price", modelType: "mimo_v2", sizeBytes: selectedStoredBytes,
            estimatedMemoryGb: selectedLoadGiB,
            nativeLoadTransientBytes: selectedTotalLoadBytes - selectedStoredBytes)
    }

    static func copyTiny() throws -> URL {
        let source = URL(fileURLWithPath: try XCTUnwrap(
            ProcessInfo.processInfo.environment["MIMO_V26_SERIAL_LOAD_FIXTURES"]))
            .appendingPathComponent("tiny-bf16")
        let bytes = try MiMoV26ServingLoad.readMetadata(source.appendingPathComponent("config.json"), limit: 1 << 20).bytes
        let configuration = try JSONDecoder().decode(MiMoV26Configuration.self, from: bytes)
        guard configuration.hiddenSize <= 64, configuration.numHiddenLayers <= 4,
              ModelScanner.collectWeightFiles(in: source).sizeBytes <= 128 << 20 else {
            throw MiMoV26ServingLoadError.metadata
        }
        // Match the repository's canonical temp-root identity contract.
        let path = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(path) }
        let root = URL(fileURLWithPath: String(cString: path), isDirectory: true)
            .appendingPathComponent("mimo-load-price-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: source, to: root)
        try refreshSyntheticManifest(root)
        return root
    }

    static func refreshSyntheticManifest(_ root: URL) throws {
        let config = try Data(contentsOf: root.appendingPathComponent("config.json"))
        let index = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: root.appendingPathComponent("model.safetensors.index.json"))) as? [String: Any])
        let weights = try XCTUnwrap(index["weight_map"] as? [String: String])
        let metadata = try XCTUnwrap(index["metadata"] as? [String: Any])
        // Same explicitly synthetic provenance as existing strict native tests;
        // never substituted for the selected artifact's provenance or payload.
        let manifest: [String: Any] = [
            "source_repository": "XiaomiMiMo/MiMo-V2.6-Flash-RL",
            "source_revision": String(repeating: "a", count: 40),
            "source_config_sha256": MiMoV26ServingLoad.hash(config),
            "experts": "original E2M1/E8M0 codes, group 32, no requantization",
            "dense": "FP8 dequantized to BF16; original BF16 unchanged",
            "output_tensor_count": weights.count, "output_weight_bytes": try XCTUnwrap(metadata["total_size"]),
            "modality_tensor_counts": Dictionary(uniqueKeysWithValues:
                ["visual", "audio_encoder", "speech_embeddings"].map { prefix in
                    (prefix, weights.keys.filter { $0.hasPrefix(prefix + ".") }.count)
                }),
            "mtp_embedded": ["architecture": "mimo_v2_nextn", "storage": "embedded",
                "num_layers": 3, "file": "model-mtp.safetensors"],
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("conversion_manifest.json"))
    }

    static func scan(_ root: URL) throws -> ModelInfo {
        try XCTUnwrap(ModelScanner.parseModelInfo(snapshotDir: root, modelName: "test/mimo-load-price"))
    }
}

final class MiMoV26DiscoveryLoadFootprintTests: XCTestCase {
    func testFullLoadWireRoundTripHasNoSSDDiscountAndKeepsExactByteUnits() throws {
        let info = MiMoDiscoveryFixture.selectedArithmeticInfo()
        let bytes = try JSONEncoder().encode(info)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNil(fields["ssd_offloaded_weight_bytes"])
        XCTAssertEqual(try JSONDecoder().decode(ModelInfo.self, from: bytes), info)
        XCTAssertEqual(info.nativeLoadTransientBytes, 16_507_198_883)
        XCTAssertEqual(info.estimatedMemoryGb, 176.35009114444256)
        for bad in [true, -1, 1.5, "16507198883"] as [Any] {
            var invalid = fields; invalid["native_load_transient_bytes"] = bad
            XCTAssertThrowsError(try JSONDecoder().decode(ModelInfo.self,
                from: JSONSerialization.data(withJSONObject: invalid)))
        }
    }

    func testStrictRootQuoteIsExactlyTheRealRequestNotDiskPadding() throws {
        let root = try MiMoDiscoveryFixture.copyTiny()
        defer { try? FileManager.default.removeItem(at: root) }
        let size = ModelScanner.collectWeightFiles(in: root).sizeBytes
        let quoted = try XCTUnwrap(MiMoV26DiscoveryLoadFootprint.estimate(
            snapshotDir: root, modelType: "mimo_v2", sizeBytes: size))
        let actual = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: root))
        XCTAssertNil(actual.transaction)
        XCTAssertEqual(quoted.totalBytes, actual.request.requiredLoadBytes)
        XCTAssertEqual(quoted.mainLoadBytes, actual.request.requiredLoadBytes)
        XCTAssertEqual(quoted.sidecarLoadBytes, 0)
        XCTAssertEqual(quoted.storedBytes, size)
        XCTAssertEqual(quoted.transientBytes, quoted.totalBytes - size)
        let info = try MiMoDiscoveryFixture.scan(root)
        XCTAssertEqual(info.estimatedMemoryGb, Double(quoted.totalBytes) / MiMoDiscoveryFixture.GiB)
        XCTAssertEqual(info.nativeLoadTransientBytes, quoted.transientBytes)
        XCTAssertNil(info.ssdOffloadedWeightBytes)
        // Tiny fixtures deliberately demonstrate that the true 1-GiB metadata
        // envelope can be LARGER than disk×1.2: this is not a blanket discount.
        XCTAssertGreaterThan(info.estimatedMemoryGb, Double(size) / MiMoDiscoveryFixture.GiB * 1.2)
    }

    func testChangedIncompleteUnknownAndForeignInventoryCannotIssueNativeQuote() throws {
        let root = try MiMoDiscoveryFixture.copyTiny()
        defer { try? FileManager.default.removeItem(at: root) }
        let size = ModelScanner.collectWeightFiles(in: root).sizeBytes
        for type in [nil, "mimo", "MIMO_V2", " mimo_v2 ", "qwen4_exp", "gemma4"] as [String?] {
            XCTAssertNil(MiMoV26DiscoveryLoadFootprint.estimate(snapshotDir: root, modelType: type, sizeBytes: size))
        }
        XCTAssertNil(MiMoV26DiscoveryLoadFootprint.estimate(snapshotDir: root, modelType: "mimo_v2", sizeBytes: size + 1))
        XCTAssertNil(MiMoV26DiscoveryLoadFootprint.estimate(snapshotDir: root, modelType: "mimo_v2", sizeBytes: UInt64.max))
        let extra = root.appendingPathComponent(".extra.safetensors")
        try Data([1, 2, 3]).write(to: extra)
        XCTAssertNil(MiMoV26DiscoveryLoadFootprint.estimate(snapshotDir: root, modelType: "mimo_v2", sizeBytes: size))
        try FileManager.default.removeItem(at: extra)
        try Data("{}".utf8).write(to: root.appendingPathComponent("conversion_manifest.json"))
        XCTAssertNil(MiMoV26DiscoveryLoadFootprint.estimate(snapshotDir: root, modelType: "mimo_v2", sizeBytes: size))
        let fallback = try MiMoDiscoveryFixture.scan(root)
        XCTAssertNil(fallback.nativeLoadTransientBytes)
        XCTAssertEqual(fallback.estimatedMemoryGb, Double(size) / MiMoDiscoveryFixture.GiB * 1.2)
    }

    func testAbsentPresentInvalidAndExplicitLanguageOnlySidecarRules() throws {
        let root = try MiMoDiscoveryFixture.copyTiny()
        defer { try? FileManager.default.removeItem(at: root) }
        let size = ModelScanner.collectWeightFiles(in: root).sizeBytes
        func quote() -> MiMoV26DiscoveryLoadFootprint.Estimate? {
            MiMoV26DiscoveryLoadFootprint.estimate(snapshotDir: root, modelType: "mimo_v2", sizeBytes: size)
        }
        XCTAssertNotNil(quote())
        let sidecar = root.appendingPathComponent("audio_tokenizer")
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: false)
        XCTAssertNil(quote(), "present-invalid is not a visual-only quote")
        try FileManager.default.removeItem(at: sidecar)
        try FileManager.default.createSymbolicLink(atPath: sidecar.path, withDestinationPath: root.appendingPathComponent("absent").path)
        XCTAssertNil(quote(), "broken sidecar alias must not become absence")
        try FileManager.default.removeItem(at: sidecar)
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: false)
        let configURL = root.appendingPathComponent("config.json")
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
        fields["language_model_only"] = true
        try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]).write(to: configURL)
        try MiMoDiscoveryFixture.refreshSyntheticManifest(root)
        let languageOnly = try XCTUnwrap(quote())
        let actual = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: root))
        XCTAssertEqual(languageOnly.totalBytes, actual.request.requiredLoadBytes)
        XCTAssertEqual(languageOnly.sidecarLoadBytes, 0)
    }

    func testRealSelectedAudioMetadataQuoteMatchesOrdinaryFullLoadRequest() throws {
        // Metadata-only fixture input, not native load authorization. No payload
        // is copied, authenticated, loaded or fabricated; a missing input FAILS.
        let root = URL(fileURLWithPath: try XCTUnwrap(
            ProcessInfo.processInfo.environment["MIMO_V26_DISCOVERY_AUDIO_FIXTURE_ROOT"]))
        let size = ModelScanner.collectWeightFiles(in: root).sizeBytes
        let quote = try XCTUnwrap(MiMoV26DiscoveryLoadFootprint.estimate(
            snapshotDir: root, modelType: "mimo_v2", sizeBytes: size))
        let budget = GlobalKVCacheBudget(memorySnapshot: {
            .init(total: 256 << 30, active: 0, cache: 0, systemAvailable: 256 << 30)
        })
        let actual = try XCTUnwrap(MiMoV26OrdinaryServingPolicy.inspect(directory: root, budget: budget,
            deviceLimits: .init(maxBufferBytes: 4 << 30, attentionElementBytes: 4, headFactor: 1, operatorMaxPatches: 1024)))
        XCTAssertNotNil(actual.decodedAudioPolicy)
        XCTAssertNil(actual.transaction)
        let audio = try XCTUnwrap(actual.audioLoadRequest)
        XCTAssertEqual(quote.mainLoadBytes, actual.request.requiredLoadBytes)
        XCTAssertEqual(quote.sidecarLoadBytes, audio.requiredLoadBytes)
        XCTAssertEqual(quote.totalBytes, actual.request.requiredLoadBytes + audio.requiredLoadBytes)
        XCTAssertEqual(Double(quote.totalBytes) / MiMoDiscoveryFixture.GiB, actual.estimatedWeightsGb)
        XCTAssertEqual(audio.requiredLoadBytes, MiMoDiscoveryFixture.selectedSidecarLoadBytes)
        XCTAssertEqual(quote.totalBytes, MiMoDiscoveryFixture.selectedTotalLoadBytes)
        XCTAssertEqual(quote.storedBytes, MiMoDiscoveryFixture.selectedStoredBytes)
        XCTAssertEqual(budget.processLedger.snapshot().ownerCount, 0, "quotation created a reservation")
    }
}
