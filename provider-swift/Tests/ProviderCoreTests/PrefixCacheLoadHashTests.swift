import Foundation
import MLXLLM
import Testing

@testable import ProviderCore

@Suite("SSD load hashing follows model capability")
struct PrefixCacheLoadHashTests {
    private func snapshot(_ config: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssd-load-hash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(config.utf8).write(to: directory.appendingPathComponent("config.json"))
        try Data("weights".utf8).write(to: directory.appendingPathComponent("model.safetensors"))
        return directory
    }

    @Test("Qwen text and wrapper configs ask the model's own SSD capability")
    func recurrentCapability() throws {
        for config in [
            #"{"model_type":"qwen3_5"}"#,
            #"{"model_type":"qwen3_5","text_config":{"model_type":"qwen3_5_text"}}"#,
            #"{"model_type":"qwen3_5_moe","text_config":{"num_experts":8}}"#,
        ] {
            let directory = try snapshot(config)
            defer { try? FileManager.default.removeItem(at: directory) }
            let model = try JSONDecoder().decode(Qwen35Configuration.self, from: Data(config.utf8))
            #expect(!model.cbv2Capabilities.supportsPrefixReuse)
            #expect(PrefixCachePolicy.requiresLoadHashBracket(modelDirectory: directory, environment: [:])
                == model.cbv2Capabilities.supportsRecurrentCheckpointReuse)
        }
    }

    @Test("changed, unknown, and unreadable configurations retain a fresh bracket")
    func noCachedExclusion() throws {
        let directory = try snapshot(#"{"model_type":"qwen3_5"}"#)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(PrefixCachePolicy.requiresLoadHashBracket(modelDirectory: directory, environment: [:]))
        for config in [#"{"model_type":"gpt_oss"}"#, #"{"model_type":"gemma4"}"#,
                       #"{"model_type":"future_model"}"#, #"{"model_type":"qwen3_5","text_config":false}"#, "invalid"] {
            try Data(config.utf8).write(to: directory.appendingPathComponent("config.json"))
            #expect(PrefixCachePolicy.requiresLoadHashBracket(modelDirectory: directory, environment: [:]))
        }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("config.json"))
        #expect(PrefixCachePolicy.requiresLoadHashBracket(modelDirectory: directory, environment: [:]))
        #expect(!PrefixCachePolicy.requiresLoadHashBracket(
            modelDirectory: directory, environment: ["DARKBLOOM_PREFIX_CACHE": "0"]))
    }

    @Test("standalone skips disabled caching and brackets dense and MoE loads")
    func standaloneBracket() async throws {
        let directory = try snapshot(#"{"model_type":"qwen3_5_moe","text_config":{"num_experts":8}}"#)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = StandaloneServer(models: [])
        let calls = HashCallRecorder()
        await server.setV2TestHooksForTesting(.init(
            computeWeightHash: { _, _ in calls.hash() },
            makeEngine: { _, grant in InertStubEngine(kvBytesCapacity: grant) }))
        let required = PrefixCachePolicy.requiresLoadHashBracket(
            modelDirectory: directory, environment: ["DARKBLOOM_PREFIX_CACHE": "0"])
        for _ in 0..<2 {
            #expect(await server.computeStandaloneWeightHash(
                modelPath: directory, modelId: "test/qwen", required: required) == nil)
        }
        #expect(calls.count == 0)

        for config in [
            #"{"model_type":"qwen3_5"}"#,
            #"{"model_type":"qwen3_5_moe","text_config":{"num_experts":8}}"#,
        ] {
            try Data(config.utf8).write(to: directory.appendingPathComponent("config.json"))
            let eligible = PrefixCachePolicy.requiresLoadHashBracket(modelDirectory: directory, environment: [:])
            #expect(eligible)
            let pre = await server.computeStandaloneWeightHash(modelPath: directory, modelId: "test/qwen", required: eligible)
            let post = await server.computeStandaloneWeightHash(modelPath: directory, modelId: "test/qwen", required: eligible)
            #expect(pre != nil && pre == post)
        }
        #expect(calls.count == 4)
    }

    @Test("a failed standalone hash is retried rather than cached")
    func failedHashNotCached() async throws {
        let directory = try snapshot(#"{"model_type":"gpt_oss"}"#)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = StandaloneServer(models: [])
        let calls = HashCallRecorder(failFirst: true)
        await server.setV2TestHooksForTesting(.init(
            computeWeightHash: { _, _ in calls.hash() },
            makeEngine: { _, grant in InertStubEngine(kvBytesCapacity: grant) }))
        #expect(await server.computeStandaloneWeightHash(modelPath: directory, modelId: "test/gpt", required: true) == nil)
        #expect(await server.computeStandaloneWeightHash(modelPath: directory, modelId: "test/gpt", required: true) != nil)
        #expect(calls.count == 2)
    }
}

private final class HashCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let failFirst: Bool
    init(failFirst: Bool = false) { self.failFirst = failFirst }
    var count: Int { lock.withLock { calls } }
    func hash() -> String? {
        lock.withLock {
            calls += 1
            return failFirst && calls == 1 ? nil : String(repeating: "a", count: 64)
        }
    }
}
