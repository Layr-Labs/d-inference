import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing
@testable import ProviderCore

/// Actual Qwen modules, native KV backends and production slot assembly.
/// Tiny random weights verify lifecycle/wiring, not released-model throughput.
@Suite("Production Qwen startup calibration", .serialized)
struct ProductionModelCalibrationTests {
    init() { _ = LiveInferenceFixtures.ensureMetallibColocated() }

    @Test("dense and MoE Qwen slots calibrate after every reload without customer work",
        arguments: ["EigenLabs/Qwen3.8-27B-4bit-mtp", "qwen3.5-35b-a3b", "qwen3.6-35b-a3b-vl-mtp-mxfp8"],
        ["auto", "contiguous"])
    func productionQwenCalibratesWithoutJob(modelID: String, backend: String) async throws {
        var previousEpoch: String?
        for _ in 0..<2 {
            let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
                .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: 8 << 30)
            }
            let bridge = try await makeQwenBridge(modelID: modelID, backend: backend, budget: budget)
            let before = await bridge.backendSlotCapacity()
            #expect(before.performanceMeasurements?.isolatedPrefill == nil)
            let engine = try #require(await bridge.ownedEngine as? EngineV2)
            #expect(engine.nativeShutdownExecutionContractID == nil,
                "ordinary Qwen must not masquerade as a managed MiMo engine")
            #expect(await bridge.kvBackendKind.rawValue == (backend == "auto" ? "paged" : "contiguous"))
            let started = await bridge.startModelCalibrationIfNeeded(requireNominalPosture: false)
            #expect(started)
            await bridge.awaitProductionCalibration()
            let capacity = await bridge.backendSlotCapacity()
            let measurements = try #require(capacity.performanceMeasurements)
            #expect(measurements.epoch != previousEpoch)
            previousEpoch = measurements.epoch
            #expect(measurements.isolatedPrefill?.sampleCount == 2, "\(measurements)")
            #expect(measurements.decode?.sampleCount == 2)
            #expect((measurements.isolatedPrefill?.tokensPerSecond ?? 0) > 0)
            #expect((measurements.decode?.tokensPerSecond ?? 0) > 0)
            #expect(measurements.workloadBuckets.contains {
                $0.phase == "prefill" && $0.promptTokenBucket == 1_024 && $0.contention == "isolated"
            })
            #expect(await bridge.productionCalibrationWorkCounters() == [0, 0, 0, 0])
            #expect(engine.capacity().activeRequests == 0 && budget.serviceBudget.count == 0)
            #expect(!(await bridge.startModelCalibrationIfNeeded(requireNominalPosture: false)))
            await bridge.shutdown()
            #expect(!(await bridge.startModelCalibrationIfNeeded(requireNominalPosture: false)))
        }
    }

    private func makeQwenBridge(modelID: String, backend: String,
        budget: GlobalKVCacheBudget) async throws -> EngineV2Bridge {
        let experts = modelID.contains("27B") ? 0 : 4
        // Keep tensors small but enough real layers for measured prefill to
        // stay inside the existing 20k TPS plausibility bound. A two-layer toy
        // runs at ~100k TPS and is correctly rejected by serving-rate policy.
        let config = try EngineV2VLMTextExtraction.decodeQwenConfiguration(configData: Data("""
        {"model_type":"qwen3_5","hidden_size":64,"num_hidden_layers":32,
         "intermediate_size":128,"num_attention_heads":1,"num_key_value_heads":1,
         "head_dim":64,"linear_num_value_heads":1,"linear_num_key_heads":1,
         "linear_key_head_dim":64,"linear_value_head_dim":64,"linear_conv_kernel_dim":4,
         "vocab_size":64,"full_attention_interval":2,"num_experts":\(experts),
         "num_experts_per_tok":\(experts > 0 ? 2 : 0),"moe_intermediate_size":64,
         "shared_expert_intermediate_size":64,"mtp_num_hidden_layers":0}
        """.utf8))
        let model: any LanguageModel = experts > 0 ? Qwen35MoEModel(config) : Qwen35Model(config)
        let tokenizer = ModelCalibrationTokenizer()
        let container = ModelContainer(context: .init(configuration: .init(id: modelID),
            model: model, processor: CalibrationFixtureProcessor(), tokenizer: tokenizer))
        let bundle = try await EngineV2SlotFactory.makeProductionBundle(
            modelId: modelID, modelType: experts > 0 ? "qwen3_5_moe" : "qwen3_5", isVLM: false,
            modelDirectory: nil, container: container, tokenizer: TokenizerHandle(tokenizer),
            sizing: .init(weightsBytes: 1, fp16KVBytesPerToken: 256,
                maxContextLength: 2_048, defaultMaxTokens: 32),
            kvBytesCapacity: 4 << 30, maxConcurrentRequests: 2, kvBudget: budget,
            kvBackendConfig: backend, weightHash: nil,
            specDecPreparation: .init(artifact: nil, status: .disabled(.configDisabled, configured: false)),
            preparedModel: .init(snapshot: .init(model: model, eosTokenIds: [], extraEOSTokens: []),
                servingModel: model, assistant: nil,
                mtpStatus: .disabled(.configDisabled, configured: false), mtpArtifact: nil),
            environment: [PrefixCachePolicy.environmentFlag: "0", KVBackendGuardStore.pathEnvKey: "/dev/null",
                EngineV2KVQuantizationPolicy.environmentKey: "native"],
            startServingTelemetry: false, emitTelemetry: { _ in })
        return bundle.bridge
    }
}

private struct CalibrationFixtureProcessor: UserInputProcessor {
    struct NotUsed: Error {}
    func prepare(input: UserInput) async throws -> LMInput { throw NotUsed() }
}

private extension EngineV2Bridge {
    func awaitProductionCalibration() async { await modelCalibration.task?.value }
    func productionCalibrationWorkCounters() -> [Int64] {
        [prefillTokensTotal, prefillRequestsTotal, generatedTokensTotal, generationRequestsTotal]
    }
}
