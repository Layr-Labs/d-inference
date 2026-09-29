import Foundation
import MLXLLM
import MLXVLM
import XCTest
@testable import ProviderCore

/// Prepared metadata/route tests, UNRUN. No load(), claim(), native array or
/// fabricated SidecarLoaded receipt. Existing tiny fixture is reused unchanged
/// except for the same bounded metadata/manifest setup as the media tests.
final class MiMoV26NormalEntrypointTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mimo-normal-route-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    private func fixture() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["MIMO_V26_SERIAL_LOAD_FIXTURES"] else {
            throw XCTSkip("Requires existing strict tiny-bf16 header/payload fixture")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mimo-normal-fixture-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path).appendingPathComponent("tiny-bf16"), to: root)
        let configURL = root.appendingPathComponent("config.json")
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
        var processor = try XCTUnwrap(fields["processor_config"] as? [String: Any])
        processor["patch_size"] = 2
        processor["image_min_pixels"] = 16; processor["image_max_pixels"] = 256
        processor["video_min_pixels"] = 16; processor["video_max_pixels"] = 256
        processor["video_total_max_pixels"] = 512
        processor["video_start_token_id"] = 9; processor["video_end_token_id"] = 10
        fields["processor_config"] = processor
        try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]).write(to: configURL)
        try updateFixtureManifest(root)
        return root
    }
    private func updateFixtureManifest(_ root: URL) throws {
        let config = try Data(contentsOf: root.appendingPathComponent("config.json"))
        let index = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: root.appendingPathComponent("model.safetensors.index.json"))) as? [String: Any])
        let weights = try XCTUnwrap(index["weight_map"] as? [String: String])
        let metadata = try XCTUnwrap(index["metadata"] as? [String: Any])
        let manifest: [String: Any] = [
            "source_repository": "XiaomiMiMo/MiMo-V2.6-Flash-RL",
            "source_revision": String(repeating: "a", count: 40),
            "source_config_sha256": MiMoV26ServingLoad.hash(config),
            "experts": "original E2M1/E8M0 codes, group 32, no requantization",
            "dense": "FP8 dequantized to BF16; original BF16 unchanged",
            "output_tensor_count": weights.count,
            "output_weight_bytes": try XCTUnwrap(metadata["total_size"]),
            "modality_tensor_counts": Dictionary(uniqueKeysWithValues:
                ["visual", "audio_encoder", "speech_embeddings"].map { prefix in
                    (prefix, weights.keys.filter { $0.hasPrefix(prefix + ".") }.count)
                }),
            "mtp_embedded": ["architecture": "mimo_v2_nextn", "storage": "embedded",
                             "num_layers": 3, "file": "model-mtp.safetensors"]]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("conversion_manifest.json"))
    }
    private func configuration(_ root: URL) throws -> MiMoV26Configuration {
        try JSONDecoder().decode(MiMoV26Configuration.self,
            from: Data(contentsOf: root.appendingPathComponent("config.json")))
    }
    private var device: VisionTowerBudget.Limits {
        .init(maxBufferBytes: 64 << 20, attentionElementBytes: 4, headFactor: 1, operatorMaxPatches: 1024)
    }
    private var ingest: MiMoV26OrdinaryServingPolicy.IngestBounds {
        .init(maximumImages: 2, maximumVideos: 1, maximumImagePixels: 10000,
            maximumVideoPixels: 20000, maximumPartBytes: 1 << 20, maximumMetadataBytes: 65536)
    }
    private func budget() -> GlobalKVCacheBudget {
        // Metadata-only budget; no reservation/load success is asserted.
        .init(memorySnapshot: { .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30) })
    }

    func testCanonicalFamilyRecognitionAndOtherModelPartitionRemainStable() {
        XCTAssertTrue(EngineV2SupportedModels.isSupported(modelType: "mimo_v2"))
        for value in ["mimo_v2_nextn", "mimo_v2_mtp", "mimo", "MIMO_V2", " mimo_v2 "] {
            XCTAssertFalse(EngineV2SupportedModels.isSupported(modelType: value))
        }
        for value in ["gpt_oss", "gemma4", "gemma4_text", "qwen3_5", "qwen3_5_moe",
                      "qwen3_vl_moe", "qwen4_exp", "qwen4_exp_text", "diffusion_gemma"] {
            XCTAssertTrue(EngineV2SupportedModels.isSupported(modelType: value))
        }
        XCTAssertFalse(EngineV2SupportedModels.isSupported(modelType: nil))
        XCTAssertFalse(EngineV2SupportedModels.isSupported(modelType: "llama"))
        let models = [("unknown", "llama"), ("native", "mimo_v2"), ("old", "gpt_oss")].map {
            ModelInfo(id: $0.0, modelType: $0.1, sizeBytes: 1, estimatedMemoryGb: 1)
        }
        let partition = EngineV2SupportedModels.partition(models)
        XCTAssertEqual(partition.supported.map(\.id), ["native", "old"])
        XCTAssertEqual(partition.unsupported.map(\.id), ["unknown"])
    }

    func testOrdinaryInspectionDoesNothingForOtherFamilies() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let budget = budget()
        for modelType in ["gpt_oss", "gemma4", "qwen3_5", "qwen4_exp", "mimo_v2_nextn"] {
            try JSONSerialization.data(withJSONObject: ["model_type": modelType])
                .write(to: root.appendingPathComponent("config.json"))
            // No device limit injection: the non-MiMo return must precede the
            // production process-lifetime GPU metadata lookup and native plan.
            XCTAssertNil(try MiMoV26OrdinaryServingPolicy.inspect(directory: root, budget: budget))
        }
    }

    func testVisualPolicyUsesNativeFrameContextAndUnchangedReserveCeilings() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = try configuration(root)
        let policy = try MiMoV26OrdinaryServingPolicy.make(configuration: c, sidecar: .absent,
            physicalBytes: 64 << 30, reserveBytes: 8 << 30, deviceLimits: device, ingest: ingest)
        XCTAssertNil(policy.audio)
        XCTAssertEqual(policy.media.additionalSystemReserveBytes, 8 << 30)
        XCTAssertEqual(policy.media.maximumReservationBytes, 56 << 30)
        XCTAssertEqual(policy.media.limits.maximumPromptTokens, c.maxPositionEmbeddings)
        XCTAssertEqual(policy.media.limits.maximumVideoFrames,
                       try MiMoV26EncodedVisualDecoder.Sampling(configuration: c).maximumFrames)
        XCTAssertEqual(policy.media.limits.maximumMedia, 3)
        XCTAssertEqual(policy.media.limits.maximumMetadataBytes, ingest.maximumMetadataBytes)
        XCTAssertLessThanOrEqual(policy.media.limits.vision.maximumPatches, 1024)
        XCTAssertLessThanOrEqual(policy.media.limits.vision.maximumAttentionScoreElements, (64 << 20) / 4)
        XCTAssertEqual(policy.media.limits.pixels.maximumInputElements, 90000)
        XCTAssertLessThanOrEqual(policy.media.limits.pixels.maximumOutputElements, (64 << 20) / 4)
    }

    func testNormalVisualRouteRetainsStrictArtifactInspectionWithoutAudioAuthority() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = try XCTUnwrap(MiMoV26OrdinaryServingPolicy.inspect(
            directory: root, budget: budget(), deviceLimits: device))
        XCTAssertNotNil(value.decodedMediaPolicy)
        XCTAssertNil(value.decodedAudioPolicy); XCTAssertNil(value.audioLoadRequest)
        XCTAssertNil(value.transaction, "inspection is not a permit or loaded owner")
        XCTAssertEqual(value.request.binding.configSHA256,
            MiMoV26ServingLoad.hash(try Data(contentsOf: root.appendingPathComponent("config.json"))))
        // A marker/allowlist does not replace the strict original provenance.
        try Data("{}".utf8).write(to: root.appendingPathComponent("conversion_manifest.json"))
        XCTAssertThrowsError(try MiMoV26OrdinaryServingPolicy.inspect(
            directory: root, budget: budget(), deviceLimits: device))
    }

    func testPresentInvalidOrLinkedSidecarNeverFallsBackToVisual() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("audio_tokenizer")
        XCTAssertEqual(try MiMoV26OrdinaryServingPolicy.sidecarPresence(root: root), .absent)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: false)
        XCTAssertEqual(try MiMoV26OrdinaryServingPolicy.sidecarPresence(root: root), .present)
        // No fake codec/header/digest: an empty present subtree must refuse.
        XCTAssertThrowsError(try MiMoV26OrdinaryServingPolicy.inspect(
            directory: root, budget: budget(), deviceLimits: device))
        try FileManager.default.removeItem(at: audio)
        try FileManager.default.createSymbolicLink(atPath: audio.path,
            withDestinationPath: root.appendingPathComponent("missing").path)
        XCTAssertThrowsError(try MiMoV26OrdinaryServingPolicy.sidecarPresence(root: root))
    }

    func testSelectedSidecarNormalInspectionBindsRealHeaderWithoutClaimingPayloadAuthentication() throws {
        guard let path = ProcessInfo.processInfo.environment["MIMO_V26_MANAGED_AUDIO_FIXTURE_ROOT"] else {
            throw XCTSkip("Requires existing target plus unchanged selected audio sidecar")
        }
        let load = try XCTUnwrap(MiMoV26OrdinaryServingPolicy.inspect(
            directory: URL(fileURLWithPath: path), budget: budget(), deviceLimits: device))
        let request = try XCTUnwrap(load.audioLoadRequest)
        XCTAssertNotNil(load.decodedMediaPolicy)
        XCTAssertNotNil(load.decodedAudioPolicy)
        XCTAssertEqual(request.inputTensorCount, 389)
        XCTAssertEqual(request.payloadSHA256, MiMoV26AudioTokenizerWeights.selectedPayloadSHA256)
        XCTAssertEqual(request.mainConfigurationSHA256, load.request.binding.configSHA256)
        XCTAssertGreaterThan(request.unusedStoredBytes, 0)
        XCTAssertGreaterThan(request.requiredLoadBytes, UInt64(request.inputStoredBytes))
        XCTAssertNil(load.transaction)
        // Header/config bindings only. No load(), real budget claim or full-byte
        // digest execution happened; no SidecarLoaded owner is manufactured.
    }

    func testTextOnlyDeclarationKeepsExistingNonMediaLoad() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        fields["language_model_only"] = true
        try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]).write(to: url)
        try updateFixtureManifest(root)
        let value = try XCTUnwrap(MiMoV26OrdinaryServingPolicy.inspect(directory: root, budget: budget()))
        XCTAssertNil(value.decodedMediaPolicy); XCTAssertNil(value.decodedAudioPolicy)
        XCTAssertNil(value.audioLoadRequest); XCTAssertNil(value.transaction)
    }

    func testInvalidCapacityUnknownDeviceAndOverflowRefuseBeforeAnyPermit() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = try configuration(root)
        XCTAssertThrowsError(try MiMoV26OrdinaryServingPolicy.make(configuration: c, sidecar: .absent,
            physicalBytes: 8 << 30, reserveBytes: 8 << 30, deviceLimits: device, ingest: ingest))
        XCTAssertThrowsError(try MiMoV26OrdinaryServingPolicy.make(configuration: c, sidecar: .absent,
            physicalBytes: .max, reserveBytes: 1, deviceLimits: device, ingest: ingest))
        XCTAssertThrowsError(try MiMoV26OrdinaryServingPolicy.make(configuration: c, sidecar: .absent,
            physicalBytes: 64 << 30, reserveBytes: 8 << 30,
            deviceLimits: .init(maxBufferBytes: 0, attentionElementBytes: 4, headFactor: 1), ingest: ingest))
        let overflow = MiMoV26OrdinaryServingPolicy.IngestBounds(maximumImages: 2, maximumVideos: 1,
            maximumImagePixels: .max, maximumVideoPixels: 1, maximumPartBytes: 1024, maximumMetadataBytes: 65536)
        XCTAssertThrowsError(try MiMoV26OrdinaryServingPolicy.make(configuration: c, sidecar: .absent,
            physicalBytes: 64 << 30, reserveBytes: 8 << 30, deviceLimits: device, ingest: overflow))
    }

    func testMiMoMTPAutoSelectsEmbeddedHeadsAndExplicitOffRemainsAuthoritative() throws {
        XCTAssertTrue(MTPMode.auto.enablesMTP(forModelType: "mimo_v2", embeddedArtifactDeclared: true))
        XCTAssertFalse(MTPMode.auto.enablesMTP(forModelType: "mimo_v2", embeddedArtifactDeclared: false))
        XCTAssertFalse(MTPMode.off.enablesMTP(forModelType: "mimo_v2", embeddedArtifactDeclared: true))
        XCTAssertTrue(MTPMode.on.enablesMTP(forModelType: "mimo_v2", embeddedArtifactDeclared: true))
        let automatic = try MiMoV26ServingLoad.preparation(mode: .auto, externalPath: nil, environment: [:])
        XCTAssertTrue(automatic.status.configured)
        XCTAssertFalse(automatic.status.active)
        XCTAssertThrowsError(try MiMoV26ServingLoad.preparation(mode: .on, externalPath: "/not-a-native-head"))
    }
}
