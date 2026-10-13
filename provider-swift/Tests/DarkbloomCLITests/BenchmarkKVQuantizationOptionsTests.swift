import ArgumentParser
import ProviderCore
import Testing

@testable import darkbloom

@Suite("Independent benchmark live and checkpoint precision controls")
struct BenchmarkKVQuantizationOptionsTests {
    @Test func defaultsDoNotInjectPrecisionOverrides() throws {
        let command = try Benchmark.parse([])
        #expect(command.kvQuantization == nil)
        #expect(command.kvCheckpointQuantization == nil)
        #expect(command.kvQuantizationOverrides().isEmpty)
        let help = Benchmark.helpMessage().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(help.contains("--kv-checkpoint-quantization"))
        #expect(help.contains("provider config/environment or native; independent of checkpoint storage"))
        #expect(help.contains("Applies to eligible checkpoint codecs, not live attention"))
        #expect(help.contains("provider config/environment or balanced"))
    }

    @Test(arguments: ["native", "balanced", "k8v4", "k8v8"])
    func flagsWireOnlyTheirOwnEnvironmentKey(precision: String) throws {
        let live = try Benchmark.parse(["--kv-quantization", precision])
        #expect(live.kvQuantization == precision)
        #expect(live.kvCheckpointQuantization == nil)
        #expect(live.kvQuantizationOverrides() == [EngineV2KVQuantizationPolicy.environmentKey: precision])

        let checkpoint = try Benchmark.parse(["--kv-checkpoint-quantization", precision])
        #expect(checkpoint.kvQuantization == nil)
        #expect(checkpoint.kvCheckpointQuantization == precision)
        #expect(checkpoint.kvQuantizationOverrides()
            == [EngineV2KVQuantizationPolicy.checkpointEnvironmentKey: precision])
    }

    @Test func independentOverridesWinEnvironmentAndModelConfig() throws {
        let command = try Benchmark.parse([
            "--kv-quantization", "k8v4", "--kv-checkpoint-quantization", "native",
        ])
        let environment = [
            EngineV2KVQuantizationPolicy.environmentKey: "k8v8",
            EngineV2KVQuantizationPolicy.checkpointEnvironmentKey: "k8v4",
        ].merging(command.kvQuantizationOverrides()) { _, flag in flag }
        #expect(try EngineV2KVQuantizationPolicy.resolve(
            modelType: "gpt_oss", global: "balanced", byModel: ["model": "native"],
            modelID: "model", environment: environment) == .k8v4)
        #expect(try EngineV2KVQuantizationPolicy.resolve(
            modelType: "gpt_oss", global: "balanced", byModel: ["model": "k8v8"],
            modelID: "model", environment: environment, purpose: .checkpoint) == .native)

        let checkpointOnly = try Benchmark.parse(["--kv-checkpoint-quantization", "balanced"])
        #expect(try EngineV2KVQuantizationPolicy.resolve(
            modelType: "gpt_oss", global: "native", byModel: ["model": "k8v8"],
            modelID: "model", environment: checkpointOnly.kvQuantizationOverrides()) == .k8v8)
        let liveOnly = try Benchmark.parse(["--kv-quantization", "k8v8"])
        #expect(try EngineV2KVQuantizationPolicy.resolve(
            modelType: "gpt_oss", global: "native", byModel: ["model": "balanced"],
            modelID: "model", environment: liveOnly.kvQuantizationOverrides(),
            purpose: .checkpoint) == .balanced)
    }

    @Test func malformedOverridesAreDeferredUntilTheModelIsKnown() throws {
        let command = try Benchmark.parse([
            "--kv-quantization", "malformed-live", "--kv-checkpoint-quantization", "malformed-checkpoint",
        ])
        let environment = command.kvQuantizationOverrides()
        #expect(environment[EngineV2KVQuantizationPolicy.environmentKey] == "malformed-live")
        #expect(environment[EngineV2KVQuantizationPolicy.checkpointEnvironmentKey] == "malformed-checkpoint")
        for purpose in [EngineV2KVQuantizationPolicy.Purpose.live, .checkpoint] {
            #expect(try EngineV2KVQuantizationPolicy.resolve(
                modelType: "mimo_v2", global: "malformed-global", byModel: ["model": "malformed-model"],
                modelID: "model", environment: environment, purpose: purpose) == .native)
            #expect(throws: EngineV2KVQuantizationPolicy.Failure.self) {
                try EngineV2KVQuantizationPolicy.resolve(
                    modelType: "gpt_oss", modelID: "model", environment: environment, purpose: purpose)
            }
        }
    }
}
