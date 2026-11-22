import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("EngineV2KVQuantizationPolicy")
struct EngineV2KVQuantizationPolicyTests {
    @Test(arguments: [
        "gpt-oss-20b", "Qwen3.5-9B", "ternary-bonsai-2-27b",
        "qwen3.6-35b-a3b-vl-mtp-mxfp8", "EigenLabs/Qwen3.8-27B-4bit-mtp",
        "gemma-4-26b", "gemma-4-26b-qat-4bit", "gemma-4-26b-8bit",
        "qwen3.5-35b-a3b", "nvidia-nemotron-3.5-lightning", "future-supported-model",
    ])
    func defaultIsGeometryIndependent(modelID: String) throws {
        let selection = try EngineV2KVQuantizationPolicy.resolve(
            modelType: "supported", modelID: modelID, environment: [:])
        #expect(selection == .native)
        #expect(selection.configuration == nil)
        let checkpoint = try EngineV2KVQuantizationPolicy.resolve(
            modelType: "supported", modelID: modelID, environment: [:], purpose: .checkpoint)
        #expect(checkpoint == .balanced)
        let configuration = try #require(checkpoint.configuration)
        #expect(configuration.keyBits == 4 && configuration.valueBits == 4)
        #expect(configuration.groupSize == 64)
        #expect(configuration.recentTokenCount == 128)
        #expect(configuration.resolvedRotationBlockSize(headDim: 192) == 64)
    }

    @Test(arguments: EngineV2KVQuantizationSelection.allCases.map(\.rawValue) + ["invalid"])
    func exactMiMoTypeIgnoresEveryOverride(raw: String) throws {
        #expect(try EngineV2KVQuantizationPolicy.resolve(
            modelType: "mimo_v2", global: raw, byModel: ["arbitrary-alias": raw],
            modelID: "arbitrary-alias",
            environment: [EngineV2KVQuantizationPolicy.environmentKey: raw]) == .native)
        #expect(try EngineV2KVQuantizationPolicy.resolve(
            modelType: "mimo_v2", global: raw, byModel: ["arbitrary-alias": raw],
            modelID: "arbitrary-alias",
            environment: [EngineV2KVQuantizationPolicy.checkpointEnvironmentKey: raw],
            purpose: .checkpoint) == .native)
    }

    @Test func storageOverridesAreIndependentAndErrorsNameTheirPurpose() throws {
        let environment = [
            EngineV2KVQuantizationPolicy.environmentKey: "native",
            EngineV2KVQuantizationPolicy.checkpointEnvironmentKey: "k8v8",
        ]
        #expect(try EngineV2KVQuantizationPolicy.resolve(
            modelType: nil, global: "balanced", modelID: "m", environment: environment) == .native)
        #expect(try EngineV2KVQuantizationPolicy.resolve(
            modelType: nil, global: "native", byModel: ["m": "k8v4"], modelID: "m",
            environment: [:], purpose: .checkpoint) == .k8v4)
        #expect(try EngineV2KVQuantizationPolicy.resolve(
            modelType: nil, global: "native", byModel: ["m": "k8v4"], modelID: "m",
            environment: environment, purpose: .checkpoint) == .k8v8)
        #expect(try EngineV2KVQuantizationPolicy.parseSelection(" ") == .native)
        #expect(try EngineV2KVQuantizationPolicy.parseSelection(" ", purpose: .checkpoint) == .balanced)
        #expect(throws: EngineV2KVQuantizationPolicy.Failure.invalidCheckpointSelection("invalid")) {
            try EngineV2KVQuantizationPolicy.parseSelection("invalid", purpose: .checkpoint)
        }
        #expect(EngineV2KVQuantizationPolicy.Failure.invalidSelection("invalid").description
            .contains("live KV"))
        #expect(EngineV2KVQuantizationPolicy.Failure.invalidCheckpointSelection("invalid").description
            .contains("checkpoint KV"))
    }

    @Test func precedenceAndNativeOverride() throws {
        #expect(try EngineV2KVQuantizationPolicy.resolve(
            modelType: nil, global: "native", byModel: ["m": "k8v4"],
            modelID: "m", environment: [:]) == .k8v4)
        #expect(try EngineV2KVQuantizationPolicy.resolve(
            modelType: nil, global: "balanced", byModel: ["m": "k8v4"], modelID: "m",
            environment: [EngineV2KVQuantizationPolicy.environmentKey: " OFF "]) == .native)
        #expect(try EngineV2KVQuantizationPolicy.parseSelection("k8v8").configuration?.valueBits == 8)
        #expect(EngineV2KVQuantizationSelection.native.configuration == nil)
        #expect(throws: EngineV2KVQuantizationPolicy.Failure.self) {
            try EngineV2KVQuantizationPolicy.parseSelection("k4v44")
        }
    }

    @Test func quantizedConstructionCannotSilentlyBecomeNativeContiguous() throws {
        try EngineV2KVQuantizationPolicy.requireResolvedBackend(.paged, selection: .balanced)
        try EngineV2KVQuantizationPolicy.requireResolvedBackend(.contiguous, selection: .native)
        for selection in [EngineV2KVQuantizationSelection.balanced, .k8v4, .k8v8] {
            #expect(throws: EngineV2KVQuantizationPolicy.Failure.self) {
                try EngineV2KVQuantizationPolicy.requireResolvedBackend(
                    .contiguous, selection: selection, reason: "kill_switch")
            }
        }
    }

    @Test func oldConfigurationDefaultsAndExplicitPrecisionRoundtrip() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(BackendSettings.self, from: Data("{}".utf8))
            .engineV2KVQuantization == "native")
        #expect(try decoder.decode(BackendSettings.self, from: Data("{}".utf8))
            .engineV2KVCheckpointQuantization == "balanced")
        let settings = BackendSettings(
            engineV2KVQuantization: "k8v4", engineV2KVQuantizationByModel: ["gpt-oss-20b": "native"])
        #expect(try decoder.decode(BackendSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func assistantNativeOwnersAndPhysicalMarginalRate() throws {
        let window = CBv2LayerKind(attention: .slidingWindow(1024), headDim: 64, kvHeads: 2, queryHeads: 4)
        let full = CBv2LayerKind(attention: .full, headDim: 64, kvHeads: 2, queryHeads: 4)
        let borrower = CBv2LayerKind(attention: .full, sharesKVWithLayer: 3,
            headDim: 64, kvHeads: 2, queryHeads: 4)
        let kinds = [window, full, window, full, borrower]
        #expect(EngineV2KVQuantizationPolicy.nativeAssistantAccessLayers(
            layerKinds: kinds, gemmaAssistantActive: false).isEmpty)
        let native = EngineV2KVQuantizationPolicy.nativeAssistantAccessLayers(
            layerKinds: kinds, gemmaAssistantActive: true)
        #expect(native == [2, 3])
        let format = try #require(EngineV2KVQuantizationSelection.balanced.configuration)
        let config = PagedKVPoolConfig(capacityBytes: 64 << 20,
            quantization: format, nativeLayerIndices: native)
        #expect(try EngineV2Factory.physicalFullKVBytesPerToken(
            layerKinds: kinds, dtypes: [.bfloat16, .bfloat16, .float32, .float32, .float32],
            config: config) == 1_184)
        // Pure target rate excludes windows, borrowed storage and assistant state.
        #expect(try EngineV2Factory.physicalFullKVBytesPerToken(
            layerKinds: [full], dtypes: [.float32], config: .init(
                capacityBytes: 64 << 20, quantization: format)) == 160)
    }

    /// A Gemma slot built target-only (assistant not downloaded yet, catalog
    /// metadata not ready, or the assistant skipped for memory) keeps the same
    /// native access layers as an attached slot, whether or not it ever attaches,
    /// so its checkpoints store the target rows in the attached slot's layout.
    @Test func gemmaAccessLayersStayNativeBeforeTheAssistantAttaches() {
        let window = CBv2LayerKind(attention: .slidingWindow(1024), headDim: 64, kvHeads: 2, queryHeads: 4)
        let full = CBv2LayerKind(attention: .full, headDim: 64, kvHeads: 2, queryHeads: 4)
        let kinds = [window, full, window, full]
        func keepsNative(
            attached: Bool, mtp: Bool = true, _ status: MTPActivationStatus, process: Bool = true
        ) -> Bool {
            EngineV2KVQuantizationPolicy.gemmaAssistantAccessExpected(
                assistantAttached: attached, mtpEnabled: mtp, status: status, processMTPEnabled: process,
                nativeRowsBeforeAssistant: true)
        }
        func layers(_ native: Bool) -> Set<Int> {
            EngineV2KVQuantizationPolicy.nativeAssistantAccessLayers(layerKinds: kinds, gemmaAssistantActive: native)
        }
        let activeStatus = MTPActivationStatus(
            configured: true, active: true, reason: nil, source: nil, revision: nil,
            artifactBytes: 1, assistantBytes: 1)
        let attachedLayers = layers(keepsNative(attached: true, activeStatus))
        #expect(attachedLayers == [2, 3])
        for reason in [MTPFallbackReason.artifactNotCached, .catalogUnavailable, .assistantMemoryUnavailable] {
            #expect(layers(keepsNative(attached: false, .disabled(reason, configured: true)))
                == attachedLayers, "\(reason)")
        }
        // MTP switched off keeps the target-only layout, attached or not.
        #expect(!keepsNative(attached: true, mtp: false, activeStatus))
        #expect(!keepsNative(attached: false, .disabled(.configDisabled, configured: false)))
        #expect(!keepsNative(attached: false, .disabled(.killSwitchDisabled, configured: true)))
        #expect(!keepsNative(attached: false, .disabled(.artifactNotCached, configured: true), process: false))
    }

    /// `DARKBLOOM_GEMMA_NATIVE_ROWS_BEFORE_ASSISTANT=0` restores the earlier rule
    /// exactly: native only with the assistant attached and MTP on.
    @Test func nativeRowsBeforeAssistantSwitchRestoresTheAttachedOnlyRule() {
        let activeStatus = MTPActivationStatus(
            configured: true, active: true, reason: nil, source: nil, revision: nil,
            artifactBytes: 1, assistantBytes: 1)
        let statuses: [MTPActivationStatus] = [
            activeStatus,
            .disabled(.artifactNotCached, configured: true), .disabled(.catalogUnavailable, configured: true),
            .disabled(.assistantMemoryUnavailable, configured: true), .disabled(.killSwitchDisabled, configured: true),
            .disabled(.configDisabled, configured: false),
        ]
        for status in statuses {
            for attached in [true, false] {
                for mtp in [true, false] {
                    for process in [true, false] {
                        // The rule before #2547: the attach state and MTP only.
                        #expect(
                            EngineV2KVQuantizationPolicy.gemmaAssistantAccessExpected(
                                assistantAttached: attached, mtpEnabled: mtp, status: status,
                                processMTPEnabled: process, nativeRowsBeforeAssistant: false)
                                == (attached && mtp), "\(status) \(attached) \(mtp) \(process)")
                    }
                }
            }
        }
    }

    @Test func nativeRowsBeforeAssistantRollbackIsForwarded() {
        let key = EngineV2KVQuantizationPolicy.gemmaNativeRowsBeforeAssistantEnvironmentKey
        #expect(key == "DARKBLOOM_GEMMA_NATIVE_ROWS_BEFORE_ASSISTANT")
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "0"])[key] == "0")
        #expect(LaunchAgent.passthroughEnvironment(from: [:])[key] == nil)
        // The slot factory's call, which omits the parameter, follows the process switch.
        let enabled = EngineV2KVQuantizationPolicy.gemmaNativeRowsBeforeAssistantEnabled
        #expect(enabled == MTPAutomaticVerificationPolicy.gemmaLoneRowEnabled(ProcessInfo.processInfo.environment[key]))
        #expect(
            EngineV2KVQuantizationPolicy.gemmaAssistantAccessExpected(
                assistantAttached: false, mtpEnabled: false, status: .disabled(.artifactNotCached, configured: true),
                processMTPEnabled: true) == enabled)
    }

    @Test func theSlotFactoryKeepsAccessLayersForAConfiguredAssistant() throws {
        let source = try String(
            contentsOf: Self.sources.appendingPathComponent(
                "ProviderCore/Inference/Engine/Factory/EngineV2SlotFactory.swift"),
            encoding: .utf8
        ).filter { !$0.isWhitespace }
        // The decision feeds the backend's native KV layers.
        #expect(source.contains(
            "gemmaAssistantActive:EngineV2KVQuantizationPolicy.gemmaAssistantAccessExpected(assistantAttached:"
                + "assistantHandle?.drafter!=nil,mtpEnabled:mtpConfig.effectiveEnabled,status:mtpStatus"))
    }

    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Engine
        .deletingLastPathComponent()  // Inference
        .deletingLastPathComponent()  // ProviderCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // provider-swift
        .appendingPathComponent("Sources")
}
