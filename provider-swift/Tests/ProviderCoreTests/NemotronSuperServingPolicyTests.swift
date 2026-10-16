// Copyright © 2026 Eigen Labs.

import Foundation
import MLXVLM
import ProviderCoreFoundation
import Testing
@testable import ProviderCore

/// CPU-only production identity, discovery and load-plan policy of the
/// managed Super slot. The gated checkpoint case reads the real pinned
/// checkpoint (hashing every shard) when `NEMOTRON_SUPER_CHECKPOINT_DIR` is set.
struct NemotronSuperServingPolicyTests {
    private static let superID = NemotronSuperServingPolicy.modelID
    private static let hfID = "nvidia/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-NVFP4"

    private static func info(_ id: String, _ type: String?) -> ModelInfo {
        ModelInfo(id: id, modelType: type, sizeBytes: 1, estimatedMemoryGb: 1)
    }

    @Test func onlyTheExactRegistryIdentityIsSupported() {
        #expect(EngineV2SupportedModels.isSupported(model: Self.info(Self.superID, "nemotron_h_omni")))
        // A provider without this policy reduced the check to the type, which
        // still refuses it: they keep dropping every Super artifact.
        #expect(!EngineV2SupportedModels.isSupported(modelType: "nemotron_h_omni"))
        for id in [Self.hfID, "EigenLabs/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-NVFP4",
                   Self.superID.uppercased(), Self.superID + "-r2", " " + Self.superID] {
            #expect(!EngineV2SupportedModels.isSupported(model: Self.info(id, "nemotron_h_omni")), "\(id)")
        }
        for type in [" nemotron_h_omni", "NEMOTRON_H_OMNI", "nemotron_h", nil] as [String?] {
            #expect(!EngineV2SupportedModels.isSupported(model: Self.info(Self.superID, type)), "\(type ?? "nil")")
        }
        let (supported, unsupported) = EngineV2SupportedModels.partition(
            [Self.info(Self.hfID, "nemotron_h_omni"), Self.info(Self.superID, "nemotron_h_omni")])
        #expect(supported.map(\.id) == [Self.superID] && unsupported.map(\.id) == [Self.hfID])
    }

    @Test func defaultsSpeculateAtDepthThreeForEightRequests() throws {
        // Qualification keys for speculation and width are replaced by policy.
        let plan = NemotronSuperServingPolicy.loadPlan(
            base: [NemotronSuperLocalMTP.enabledKey: "0", NemotronSuperLocalBridgeBuilder.maxConcurrentKey: "3"],
            mode: .auto, configuredConcurrency: nil, kvBytesCapacity: 100 << 30)
        #expect(plan.speculates && plan.requests == 8 && plan.prefixBankBytes == 0)
        #expect(plan.environment[NemotronSuperLocalMTP.enabledKey] == "1")
        #expect(plan.environment[NemotronSuperLocalMTP.depthKey] == "3")
        #expect(plan.environment[NemotronSuperLocalBridgeBuilder.maxConcurrentKey] == "8")
        #expect(plan.environment[PrefixCachePolicy.memoryEnvironmentFlag] == nil)
        // The builder resolves exactly this configuration from the plan.
        #expect(try NemotronSuperLocalMTP.Setting.resolve(environment: plan.environment)
            == .init(depth: 3, verification: .rectangularExact, adaptive: false))
        #expect(try NemotronSuperLocalBridgeBuilder.concurrentRequests(
            environment: plan.environment, speculates: true) == 8)
        // Above the 25,926,570,879-byte minimum grant measured for depth 3 x 8.
        #expect(plan.admissionKVBytes == 26 << 30 && plan.admissionKVBytes > 25_926_570_879)
    }

    @Test func slotPolicyBoundsConcurrencyAndOperatorKeysStay() throws {
        let narrow = NemotronSuperServingPolicy.loadPlan(
            base: [NemotronSuperLocalMTP.depthKey: "1", NemotronSuperLocalMTP.verificationKey: "rectangular"],
            mode: .on, configuredConcurrency: 2, kvBytesCapacity: 100 << 30)
        #expect(narrow.requests == 2 && narrow.environment[NemotronSuperLocalMTP.depthKey] == "1")
        #expect(narrow.admissionKVBytes == 2 * (3 << 30) + (2 << 30))
        let wide = NemotronSuperServingPolicy.loadPlan(base: [:], mode: .auto,
            configuredConcurrency: 16, kvBytesCapacity: 100 << 30)
        #expect(wide.requests == 8, "one captured verify window bounds speculation")
        let plain = NemotronSuperServingPolicy.loadPlan(base: [:], mode: .off,
            configuredConcurrency: 16, kvBytesCapacity: 100 << 30)
        #expect(plain.requests == 16 && !plain.speculates)
        // A grant below the policy bound caps the claim at the grant itself.
        let small = NemotronSuperServingPolicy.loadPlan(base: [:], mode: .auto,
            configuredConcurrency: nil, kvBytesCapacity: 4 << 30)
        #expect(small.admissionKVBytes == 4 << 30)
    }

    @Test func plainOwnerReusesExactTextPrefixesWhenTheGrantHoldsTheBank() {
        let plan = NemotronSuperServingPolicy.loadPlan(base: [NemotronSuperLocalMTP.enabledKey: "1"],
            mode: .off, configuredConcurrency: nil, kvBytesCapacity: 100 << 30)
        #expect(!plan.speculates && plan.requests == 8)
        #expect(plan.environment[NemotronSuperLocalMTP.enabledKey] == nil)
        #expect(plan.environment[PrefixCachePolicy.memoryEnvironmentFlag] == "1")
        #expect(plan.prefixBankBytes == 1 << 30)
        // Every request's fixed bytes, 2 GiB and the bank; above the measured
        // 5,477,654,231-byte plain minimum for eight requests.
        #expect(plan.admissionKVBytes == 8 * (1 << 29) + (2 << 30) + (1 << 30))
        #expect(plan.admissionKVBytes - plan.prefixBankBytes > 5_477_654_231)
        let killSwitch = NemotronSuperServingPolicy.loadPlan(base: ["DARKBLOOM_CBV2_MTP": "0"],
            mode: .on, configuredConcurrency: nil, kvBytesCapacity: 100 << 30)
        #expect(!killSwitch.speculates && killSwitch.prefixBankBytes == 1 << 30)
    }

    @Test func operatorChoiceOrASmallGrantKeepsTheBankOff() {
        for base in [[PrefixCachePolicy.memoryEnvironmentFlag: "0"], ["DARKBLOOM_PREFIX_CACHE": "0"],
                     ["DARKBLOOM_CBV2_HYBRID_PREFIX_CACHE": "0"]] {
            let plan = NemotronSuperServingPolicy.loadPlan(base: base, mode: .off,
                configuredConcurrency: nil, kvBytesCapacity: 100 << 30)
            #expect(plan.prefixBankBytes == 0, "\(base)")
        }
        let tight = NemotronSuperServingPolicy.loadPlan(base: [:], mode: .off,
            configuredConcurrency: nil, kvBytesCapacity: 6 << 30)
        #expect(tight.prefixBankBytes == 0 && tight.environment[PrefixCachePolicy.memoryEnvironmentFlag] == nil)
    }

    @Test func discoveryFootprintCoversTheLargestDefaultLoad() {
        // The ship-check claim at a 28 GiB grant: installation, head and grant.
        #expect(NemotronSuperServingPolicy.pinnedInstallationLoadBytes
            + NemotronSuperServingPolicy.pinnedHeadLoadBytes + (28 << 30) == 121_013_708_416)
        let footprint = NemotronSuperServingPolicy.discoveryFootprint(sizeBytes: 75_010_188_240)
        #expect(footprint.nativeLoadTransientBytes == 15_938_749_104)
        let expected = Double(82_100_665_864 + 8_848_271_480 + (12 << 30) + (26 << 30)) / 1_073_741_824
        #expect(abs(footprint.estimatedMemoryGb - expected) < 1e-9)
        let plain = NemotronSuperServingPolicy.loadPlan(base: [:], mode: .off,
            configuredConcurrency: nil, kvBytesCapacity: 100 << 30)
        let plainBytes = 82_100_665_864 + (12 << 30) + plain.admissionKVBytes
        #expect(Double(plainBytes) / 1_073_741_824 < footprint.estimatedMemoryGb)
    }

    /// Cold quotes compare the published load room with the discovery
    /// footprint (LOAD claim, prefill lane and admission KV), and the slot
    /// advertises no media.
    @Test func capacityQuotesUseTheManagedLoadFootprint() {
        let footprint = NemotronSuperServingPolicy.discoveryFootprint(sizeBytes: 75_010_188_240)
        let model = ModelInfo(id: Self.superID, modelType: "nemotron_h_omni", sizeBytes: 75_010_188_240,
            estimatedMemoryGb: footprint.estimatedMemoryGb, templateRenderOK: true,
            nativeLoadTransientBytes: footprint.nativeLoadTransientBytes)
        func quote(freeForLoadGb: Double, vision: Bool = false) -> ProviderMessage.CapacityQuote {
            CapacityQuoteEngine.quote(.init(
                probe: .init(quoteId: "q", model: Self.superID, promptTokensBucket: 512, maxOutputTokens: 512,
                    requiresVision: vision, visionImageCount: 0, deadlineRemainingMs: 9000),
                capacity: BackendCapacity(slots: [], gpuMemoryActiveGb: 0, gpuMemoryPeakGb: 0,
                    gpuMemoryCacheGb: 0, totalMemoryGb: 256, freeForLoadGb: freeForLoadGb, capacitySeq: 3),
                model: model, ttft: nil,
                visionLimits: .init(maxBufferBytes: 38 << 30, attentionElementBytes: 2, headFactor: 1),
                refusingNewWork: false))
        }
        #expect(quote(freeForLoadGb: footprint.estimatedMemoryGb).admissibleNow)
        // The shard bytes alone would fit; the full managed LOAD does not.
        let shardsOnly = quote(freeForLoadGb: 75_010_188_240 * 1.2 / 1_073_741_824)
        #expect(!shardsOnly.admissibleNow && shardsOnly.rejectionReason == .memoryCap)
        #expect(quote(freeForLoadGb: 200, vision: true).rejectionReason == .capability)
    }

    @Test func scannerWithholdsTheRegistryIDWithoutThePinnedMetadata() throws {
        let directory = try Self.syntheticSnapshot()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(ModelScanner.parseModelInfo(snapshotDir: directory, modelName: Self.superID) == nil)
        let other = try #require(ModelScanner.parseModelInfo(snapshotDir: directory, modelName: Self.hfID))
        #expect(other.modelType == "nemotron_h_omni" && other.isVision == nil)
        #expect(other.nativeLoadTransientBytes == nil && !EngineV2SupportedModels.isSupported(model: other))
    }

    @Test func pinnedTemplatePassesTheScanRenderCheck() throws {
        let directory = try Self.syntheticSnapshot()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(TemplateRenderCheck.renderOK(at: directory, modelID: Self.superID) == true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEMOTRON_SUPER_CHECKPOINT_DIR"] != nil))
    func pinnedCheckpointIsDiscoveredWithItsRecordedLoadCharges() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["NEMOTRON_SUPER_CHECKPOINT_DIR"])
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let info = try #require(ModelScanner.parseModelInfo(snapshotDir: directory, modelName: Self.superID))
        let footprint = NemotronSuperServingPolicy.discoveryFootprint(sizeBytes: info.sizeBytes)
        #expect(info.modelType == "nemotron_h_omni" && info.quantization == "nvfp4")
        #expect(info.sizeBytes == 75_010_188_240 && info.isVision == nil && info.templateRenderOK == true)
        #expect(info.estimatedMemoryGb == footprint.estimatedMemoryGb)
        #expect(info.nativeLoadTransientBytes == footprint.nativeLoadTransientBytes)
        #expect(EngineV2SupportedModels.isSupported(model: info))
        // The recorded constants equal the SDK quotes over the verified shards.
        let opened = try await NemotronSuperCheckpoint.open(directory: directory)
        #expect(try NemotronSuperInstallation.requiredLoadBytes(source: opened.source,
            backendAllowanceBytes: NemotronSuperServingPolicy.backendAllowanceBytes)
            == Int(NemotronSuperServingPolicy.pinnedInstallationLoadBytes))
        let staging = try NemotronSuperLocalLoad.Staging.pinned(configData: opened.inputs.configData,
            source: opened.source)
        let head = try #require(staging.head)
        #expect(try NemotronSuperLocalMTP.loadSupplementBytes(head.quote())
            == Int(NemotronSuperServingPolicy.pinnedHeadLoadBytes))
        #expect(opened.inputs.fp16KVBytesPerToken == 8192 && opened.inputs.eosTokenIDs == [2, 11])
    }

    /// A `nemotron_h_omni` snapshot with the pinned template but unpinned
    /// config and index bytes.
    private static func syntheticSnapshot() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("super-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let config = #"{"model_type":"nemotron_h_omni","vision_config":{"model_type":"radio"}}"#
        try Data(config.utf8).write(to: directory.appendingPathComponent("config.json"))
        try Data(#"{"weight_map":{"x":"model-00001-of-00001.safetensors"}}"#.utf8)
            .write(to: directory.appendingPathComponent("model.safetensors.index.json"))
        try Data(count: 16).write(to: directory.appendingPathComponent("model-00001-of-00001.safetensors"))
        try Data(#"{"bos_token":"<s>","eos_token":"<|im_end|>"}"#.utf8)
            .write(to: directory.appendingPathComponent("tokenizer_config.json"))
        let template = try #require(Data(base64Encoded: superImagePinnedTemplateBase64,
                                        options: .ignoreUnknownCharacters))
        try template.write(to: directory.appendingPathComponent("chat_template.jinja"))
        return directory
    }
}
