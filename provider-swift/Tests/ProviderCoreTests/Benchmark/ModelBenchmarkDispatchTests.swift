import Foundation
import ProviderCore
import Testing

@testable import ProviderBenchmark

struct ModelBenchmarkDispatchTests {
    @Test func diffusionHasItsOwnNativeBlockDispatch() {
        #expect(ModelBenchmark.usesNativeBlockGeneration(modelType: "diffusion_gemma"))
        for modelType in [nil, "qwen4_exp", "gemma4", "diffusion_gemma_text", "prism_hadamard_qwen35"] {
            #expect(!ModelBenchmark.usesNativeBlockGeneration(modelType: modelType))
        }
    }
    @Test func nativePackedFamiliesUseTheNativeBenchmark() {
        #expect(ModelBenchmark.usesNativeGeneration(modelType: "mimo_v2"))
        #expect(ModelBenchmark.usesNativeGeneration(modelType: "qwen4_exp"))
        #expect(ModelBenchmark.usesNativeGeneration(modelType: "qwen4_exp_text"))
        #expect(ModelBenchmark.usesNativeGeneration(modelType: "prism_hadamard_qwen35"))
        for modelType in [nil, "qwen3_5", "qwen3_5_text", "gemma4", "nemotron_h"] {
            #expect(!ModelBenchmark.usesNativeGeneration(modelType: modelType))
        }
    }

    @Test func durationIncludesWholeSeconds() {
        #expect(ModelBenchmark.milliseconds(.seconds(7) + .milliseconds(250)) == 7250)
        #expect(ModelBenchmark.milliseconds(.milliseconds(250)) == 250)
        #expect(ModelBenchmark.milliseconds(.zero) == 0)
    }

    @Test func dispatchPreservesFactoryJSON5Support() throws {
        let json5 = Data("{\"model_type\":\"gemma4\", // checkpoint comment\n}".utf8)
        #expect(try ModelBenchmark.decodedModelType(from: json5) == "gemma4")
        let standard = Data(#"{"model_type":"qwen4_exp"}"#.utf8)
        #expect(try ModelBenchmark.decodedModelType(from: standard) == "qwen4_exp")
    }

    @Test func nativeBaselineUsesExplicitOrdinarySampling() throws {
        let data = try ModelBenchmark.nativeRequestBody(modelID: "fixture", prompt: "hello", maxTokens: 8)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["temperature"] as? Double == 0.6)
        #expect(body["top_p"] as? Double == 1)
        #expect(body["top_k"] as? Int == 0)
        #expect(body["min_p"] as? Double == 0)
        #expect(body["max_tokens"] as? Int == 8)
    }

    @Test func invalidIterationAndOutputBudgetsFailBeforeLoad() throws {
        try ModelBenchmark.validateArguments(iterations: 1, maxTokens: 1)
        for (iterations, tokens) in [(0, 1), (-1, 1), (1, 0), (1, -1)] {
            #expect(throws: ModelBenchmark.Failure.invalidArguments) {
                try ModelBenchmark.validateArguments(iterations: iterations, maxTokens: tokens)
            }
        }
    }

    @Test func nativeMiMoRequiresTheConfiguredReserveWithoutOverflowOrDefaultSubstitution() throws {
        for reserveGB in [UInt64(0), 4, 17, UInt64.max >> 30] {
            #expect(try ModelBenchmark.nativeOperatorReserveBytes(modelType: "mimo_v2",
                configuredMemoryReserveGB: reserveGB) == reserveGB * (1 << 30))
        }
        #expect(throws: ModelBenchmark.Failure.invalidNativeMemoryPolicy) {
            try ModelBenchmark.nativeOperatorReserveBytes(modelType: "mimo_v2",
                configuredMemoryReserveGB: nil)
        }
        #expect(throws: ModelBenchmark.Failure.invalidNativeMemoryPolicy) {
            try ModelBenchmark.nativeOperatorReserveBytes(modelType: "mimo_v2",
                configuredMemoryReserveGB: (UInt64.max >> 30) + 1)
        }
        // No unrelated benchmark policy is broadened or changed by this seam.
        for modelType in [nil, "qwen4_exp", "gemma4", "diffusion_gemma", "mimo_v2_flash"] {
            #expect(try ModelBenchmark.nativeOperatorReserveBytes(modelType: modelType,
                configuredMemoryReserveGB: nil) == nil)
            #expect(try ModelBenchmark.nativeOperatorReserveBytes(modelType: modelType,
                configuredMemoryReserveGB: .max) == nil)
        }
    }

    @Test func ordinaryMiMoRouteRefusesMissingOrOverflowedPolicyBeforeWeights() async throws {
        enum RouteBoundary: Error { case reached }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimo-benchmark-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Absence of weights alone is NOT a no-hash witness: metadata can hash.
        // The task-local refusal below stops at the actual native-route boundary.
        try Data(#"{"model_type":"mimo_v2"}"#.utf8)
            .write(to: directory.appendingPathComponent("config.json"))
        let hardware = HardwareInfo(
            machineModel: "fixture", chipName: "fixture", chipFamily: .m4, chipTier: .max,
            memoryGb: 128, memoryAvailableGb: 124,
            cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546)
        await ModelBenchmark.$nativeRouteEntryForTesting.withValue({ resolvedBytes in
            #expect(resolvedBytes == UInt64(17) << 30)
            throw RouteBoundary.reached
        }) {
            for configured in [Optional<UInt64>.none, UInt64.max] {
                do {
                    _ = try await ModelBenchmark.run(modelID: "native-policy-fixture",
                        modelDirectory: directory, prompt: "unused", iterations: 1, maxTokens: 1,
                        hardware: hardware, configuredMemoryReserveGB: configured)
                    Issue.record("invalid native memory policy reached benchmark execution")
                } catch {
                    #expect((error as? ModelBenchmark.Failure) == .invalidNativeMemoryPolicy)
                }
            }
            // The positive control proves the refusal hook is on this actual
            // route; neither arm reaches hashing/runtime/model construction.
            do {
                _ = try await ModelBenchmark.run(modelID: "native-policy-fixture",
                    modelDirectory: directory, prompt: "unused", iterations: 1, maxTokens: 1,
                    hardware: hardware, configuredMemoryReserveGB: 17)
                Issue.record("valid policy did not reach the native-route refusal")
            } catch {
                #expect((error as? RouteBoundary) == .reached)
            }
        }
    }
}
