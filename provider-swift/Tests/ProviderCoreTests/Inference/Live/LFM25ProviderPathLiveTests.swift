// Copyright © 2026 Eigen Labs.
//
// LIVE (weight-gated) provider-path smoke for LFM2.5-24B-A2B on the real
// pinned artifact: scan -> advertise gate -> container load -> slot sizing ->
// production bundle (automatic backend, default SSD complete-checkpoint
// tier in an isolated root with an ephemeral key and a test-supplied
// runtime identity) -> short generation -> cold/warm long prompt with
// recurrent checkpoint reuse, under the default balanced checkpoint storage
// and under native storage (which must reproduce the cold output exactly).
//
// The prompt is assembled from the artifact's ChatML control tokens rather
// than its Jinja template so this engine smoke does not depend on template
// rendering (covered by the prompting suites).
//
// Gates: DARKBLOOM_LIVE_MLX_TESTS and DARKBLOOM_LIVE_LFM25_SNAPSHOT (the HF
// snapshot directory of LiquidAI/LFM2.5-24B-A2B-MLX-4bit). Nothing is written
// outside the test-owned temporary cache root.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

private enum LFM25Live {
    static let snapshotKey = "DARKBLOOM_LIVE_LFM25_SNAPSHOT"
    static var snapshot: URL? {
        guard LiveInferenceFixtures.liveTestsEnabled,
              let raw = ProcessInfo.processInfo.environment[snapshotKey], !raw.isEmpty
        else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    static func chatML(_ user: String) -> String {
        "<|startoftext|><|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n<think>"
    }

    static func request(maxTokens: Int) throws -> ChatCompletionRequest {
        try JSONDecoder().decode(ChatCompletionRequest.self, from: Data("""
            {"model":"\(EngineV2SupportedModels.lfm25_24bA2BModelID)",
             "messages":[{"role":"user","content":"smoke"}],
             "max_tokens":\(maxTokens),"temperature":0}
            """.utf8))
    }
}

@Suite("LFM2.5-24B-A2B provider path (live)", .serialized,
       .enabled(if: LFM25Live.snapshot != nil))
struct LFM25ProviderPathLiveTests {
    @Test("scan, load, paged + SSD checkpoint defaults, generate, warm prefix reuse")
    func providerPathSmoke() async throws {
        let snapshot = try #require(LFM25Live.snapshot)
        let hub = snapshot.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let modelID = EngineV2SupportedModels.lfm25_24bA2BModelID

        // 1. Discovery and the exact advertise gate.
        let scanned = ModelScanner.scanAllModels(in: hub, environment: [:])
        let info = try #require(scanned.first { $0.id == modelID })
        #expect(info.modelType == "lfm2_moe")
        #expect(EngineV2SupportedModels.isSupported(model: info))
        print("LFM25-SMOKE scan id=\(info.id) sizeBytes=\(info.sizeBytes) "
            + "estimatedMemoryGb=\(info.estimatedMemoryGb) templateRenderOK=\(String(describing: info.templateRenderOK))")

        // 2. Load through the provider loader and size the slot.
        _ = try #require(LiveInferenceFixtures.ensureMetallibColocated())
        let loadStart = Date()
        let container = try await ModelContainerLoading.loadContainer(from: snapshot, modelID: modelID)
        let loadSeconds = Date().timeIntervalSince(loadStart)
        let sizing = await SlotSizingSnapshot.build(
            container: container, modelPath: snapshot, fallbackDefaultMaxTokens: 4096)
        #expect(sizing.fp16KVBytesPerToken == 20_480)
        #expect(sizing.maxContextLength == 131_072)
        let isLFM = await container.perform { $0.model is LFM2MoEModel }
        #expect(isLFM)
        let hashStart = Date()
        let weightHash = try #require(WeightHasher.computeHash(snapshotDir: snapshot, modelID: modelID))
        print("LFM25-SMOKE load seconds=\(String(format: "%.1f", loadSeconds)) "
            + "weightsBytes=\(sizing.weightsBytes) kvRate=\(sizing.fp16KVBytesPerToken) "
            + "hashSeconds=\(String(format: "%.1f", Date().timeIntervalSince(hashStart)))")

        let convDTypes = await container.perform { context in
            Set((context.model as? LFM2MoEModel)?.cbv2RecurrentStateSpec.layers.map {
                String(describing: $0.convDType) } ?? [])
        }
        print("LFM25-SMOKE convStateDTypes=\(convDTypes.sorted())")

        // 3-5 run twice: the product default (balanced encrypted checkpoint
        // storage, lossy for attention rows) and native checkpoint storage,
        // which must restore attention KV + conv state exactly.
        for checkpointPrecision in ["balanced", "native"] {
            try await runServing(
                snapshot: snapshot, info: info, container: container, sizing: sizing,
                weightHash: weightHash, checkpointPrecision: checkpointPrecision)
        }
    }

    private func runServing(
        snapshot: URL, info: ModelInfo, container: ModelContainer, sizing: SlotSizingSnapshot,
        weightHash: String, checkpointPrecision: String
    ) async throws {
        let modelID = info.id
        let tag = "LFM25-SMOKE [checkpoint=\(checkpointPrecision)]"
        // 3. Production bundle with an isolated SSD root and ephemeral key.
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lfm25-smoke-ssd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let environment = [
            KVBackendGuardStore.pathEnvKey: "/dev/null",
            SSDPrefixCacheFactory.testRootEnvironmentKey: cacheRoot.path,
            "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1",
        ]
        let telemetry = LFM25TelemetryLog()
        let tokenizer = await container.perform { TokenizerHandle($0.tokenizer) }
        // Test seam (labelled): a test process has no runtime-bound metallib or
        // provider binary identity, so the complete-checkpoint identity is
        // supplied with the REAL weight aggregate and prompt contract, exactly
        // as the other gated checkpoint suites do. Every other gate (loaded
        // capability, native types, backend, storage layout) is production.
        let contract = try PromptContractIdentity.compute(modelDirectory: snapshot)
        let identity = CBv2CompleteCheckpointIdentity(
            modelAggregateHash: weightHash, promptContractID: contract,
            buildID: "lfm25-live-smoke", numericsFingerprint: "lfm25-live-smoke-\(checkpointPrecision)")
        let bridge = try await EngineV2SlotFactory.makeProductionBundle(
            modelId: modelID, modelType: info.modelType, isVLM: false,
            modelDirectory: snapshot, container: container, tokenizer: tokenizer,
            sizing: sizing, kvBytesCapacity: 16 << 30, maxConcurrentRequests: 2,
            kvBudget: nil, checkpointQuantizationConfig: checkpointPrecision, weightHash: weightHash,
            specDecPreparation: SpecDecPreparation(
                artifact: nil, status: .disabled(.configDisabled, configured: false)),
            assemblyOverrides: .init(promptContractID: contract, completeCheckpointIdentity: identity),
            environment: environment,
            emitTelemetry: { telemetry.append($0) }).bridge
        defer { MLX.Memory.clearCache() }
        let backend = await bridge.kvBackendKind
        let fixedRequestBytes = await bridge.fixedRequestBytes
        let kvBytesPerToken = await bridge.kvBytesPerToken
        #expect(backend == .paged)
        print("\(tag) prefixCacheStatus=\(String(describing: bridge.prefixCacheBaseStatus))")
        let store = try #require(bridge.ssdHybridCheckpointStore)
        print("\(tag) bridge backend=\(backend.rawValue) "
            + "fixedRequestBytes=\(fixedRequestBytes) kvBytesPerToken=\(kvBytesPerToken) "
            + "storeLayout=\(store.config.backendLayout) minEffective=\(store.config.minEffectiveTokens)")

        // 4. Warmup + one short generation.
        let short = tokenizer.inner.encode(
            text: LFM25Live.chatML("What is 17 + 25? Answer with the number."), addSpecialTokens: false)
        let shortStart = Date()
        let first = await collect(from: bridge, promptTokens: short, request: try LFM25Live.request(maxTokens: 96))
        #expect(!first.didError, "\(first.error ?? "")")
        #expect((first.info?.completionTokens ?? 0) > 0)
        print("\(tag) short promptTokens=\(short.count) completion=\(first.info?.completionTokens ?? -1) "
            + "seconds=\(String(format: "%.2f", Date().timeIntervalSince(shortStart))) "
            + "tps=\(String(format: "%.1f", first.info?.tokensPerSecond ?? 0)) chars=\(first.fullText.count)")

        // 5. Cold then warm long prompt: the recurrent complete checkpoint
        // must be written and then consumed.
        let filler = (0 ..< 120).map { index in
            "Record \(index): warehouse \(index % 13) logged \(index * 7 % 97) crates of part \(index % 29)."
        }.joined(separator: " ")
        let long = tokenizer.inner.encode(
            text: LFM25Live.chatML(filler + " Which warehouse logged record 42? Answer briefly."),
            addSpecialTokens: false)
        #expect(long.count > store.config.minEffectiveTokens)
        let coldStart = Date()
        let cold = await collect(from: bridge, promptTokens: long, request: try LFM25Live.request(maxTokens: 24))
        let coldSeconds = Date().timeIntervalSince(coldStart)
        #expect(!cold.didError, "\(cold.error ?? "")")
        var written = store.stats().filesWritten
        for _ in 0 ..< 100 where written == 0 {
            try await Task.sleep(nanoseconds: 100_000_000)
            written = store.stats().filesWritten
        }
        #expect(written > 0)
        let warmStart = Date()
        let warm = await collect(from: bridge, promptTokens: long, request: try LFM25Live.request(maxTokens: 24))
        let warmSeconds = Date().timeIntervalSince(warmStart)
        #expect(!warm.didError, "\(warm.error ?? "")")
        let stats = store.stats()
        #expect(stats.stageConsumptions > 0)
        #expect(stats.consumedPrefixTokens > 0)
        let identical = warm.fullText == cold.fullText
        if checkpointPrecision == "native" {
            // Exact storage: restored attention KV and conv state reproduce
            // the cold greedy continuation.
            #expect(identical)
        }
        print("\(tag) prefix promptTokens=\(long.count) coldSeconds=\(String(format: "%.2f", coldSeconds)) "
            + "warmSeconds=\(String(format: "%.2f", warmSeconds)) filesWritten=\(stats.filesWritten) "
            + "bytesWritten=\(stats.bytesWritten) stages=\(stats.stages) consumptions=\(stats.stageConsumptions) "
            + "consumedPrefixTokens=\(stats.consumedPrefixTokens) misses=\(stats.misses) "
            + "identical=\(identical) coldCompletion=\(cold.info?.completionTokens ?? -1) "
            + "warmCompletion=\(warm.info?.completionTokens ?? -1) "
            + "peakGiB=\(String(format: "%.2f", Double(MLX.Memory.peakMemory) / 1_073_741_824))")
        print("\(tag) telemetry kinds=\(telemetry.kinds())")
        await bridge.shutdown()
    }
}

/// Records only event kinds (bounded, content-free) for the smoke log.
private final class LFM25TelemetryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func append(_ event: TelemetryEvent) {
        lock.lock(); defer { lock.unlock() }
        events.append(String(describing: event.kind))
    }
    func kinds() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return events.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }
}
