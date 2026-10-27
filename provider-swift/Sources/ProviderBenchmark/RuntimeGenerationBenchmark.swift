import CryptoKit
import Foundation
import MLX
import MLXLMCommon
@_spi(Benchmarking) import ProviderCore
import ProviderCoreFoundation

/// Paired quality runs through the actual serving cache, with public/synthetic prompts.
public enum RuntimeGenerationBenchmark {
    public enum Failure: Error, Equatable {
        case invalidArguments, unsupportedMiMo, modelHashMismatch, missingTerminal
    }

    struct Report: Encodable {
        let schema = 1
        let scope = "production_runtime_generation"
        let modelID: String
        let verifiedModelAggregateSHA256: String
        let runtimeIdentity: [String: String]
        let promptSHA256: String
        let promptTokens: [Int]
        let renderDate: String
        let resolvedBackend: String
        let kvQuantization: String
        let kvCheckpointQuantization: String
        let checkpointBackendLayout: String?
        let mtpRequested: Bool
        let mtpActive: Bool
        let mtpMetrics: MTPBenchmarkMetrics
        let assistantIdentity: [String: String]
        let generatedTokens: [Int]
        let text: String
        let finishReason: String
        let promptTokenCount: Int
        let completionTokenCount: Int
        let firstTokenMilliseconds: Double?
        let totalMilliseconds: Double
        let peakMLXMemoryBytes: Int
        let preRequestActiveMemoryBytes: Int
        let peakMLXMemoryDeltaBytes: Int
        let peakObservedKVBytesInUse: Int
        let peakObservedKVBytesReserved: Int
        let peakObservedPagedCommittedBytes: Int?
        let peakObservedPagedLivePageBytes: Int?
        let capacityObservation =
            "Host samples before submit and at delta/terminal events; excludes unobserved prefill transient peaks. Pre-request active bytes include weights and setup allocations."
        let finalMemory: ProcessMemoryTelemetry?
    }

    public static func run(
        modelID: String, modelDirectory: URL, prompt: String, maxTokens: Int,
        backend: String, mtpEnabled: Bool = false, assistantDirectory: URL? = nil,
        renderDate: String, checkpointQuantizationConfig: String = "balanced"
    ) async throws -> (json: String, succeeded: Bool) {
        guard maxTokens > 0, maxTokens <= 131_072, prompt.utf8.count <= 4 << 20,
            let date = PromptRenderDate(renderDate),
            ["auto", "paged", "contiguous"].contains(backend),
            assistantDirectory == nil || mtpEnabled
        else { throw Failure.invalidArguments }
        let target = try await loadVerifiedTarget(modelID: modelID, modelDirectory: modelDirectory)
        let container = target.container
        let verified = target.weightHash
        do {
            let prepared = try preparedPrompt(
                prompt, modelID: modelID, maxTokens: maxTokens, target: target, date: date)
            let session = try await EngineV2Factory.makeBenchmarkSession(
                modelId: modelID, modelDirectory: modelDirectory, isVLM: target.isVLM,
                container: container, tokenizer: target.tokenizer, verifiedWeightHash: verified,
                kvBytesCapacity: 1 << 30, maxConcurrentRequests: 1, mtpEnabled: mtpEnabled,
                assistantDirectory: assistantDirectory,
                useProductionKVGrant: true, kvBackendConfig: backend,
                checkpointQuantizationConfig: checkpointQuantizationConfig, requirePersistentKey: false,
                environment: prefixCacheDisabledEnvironment())
            do {
                let stopTokens = await session.stopTokenIDs()
                let preRequestActive = Memory.activeMemory
                var peakInUse = 0
                var peakReserved = 0
                var peakCommitted: Int?
                var peakLivePages: Int?
                func observeCapacity() {
                    let capacity = session.rawEngine.capacity()
                    peakInUse = max(peakInUse, capacity.kvBytesInUse)
                    peakReserved = max(peakReserved, capacity.kvBytesReserved)
                    if let pages = capacity.pagedStorage {
                        peakCommitted = max(peakCommitted ?? 0, pages.committedBytes)
                        peakLivePages = max(peakLivePages ?? 0, pages.livePageBytes)
                    }
                }
                observeCapacity()
                Memory.peakMemory = 0
                let started = DispatchTime.now().uptimeNanoseconds
                let submission = try await session.submit(
                    CBv2Request(
                        id: CBv2RequestID(1), promptTokens: prepared.tokens,
                        sampling: prepared.sampling,
                        maxTokens: maxTokens, stopTokens: stopTokens, prefixCacheEnabled: false))
                var first: UInt64?
                var terminal: (CBv2FinishReason, CBv2Usage)?
                var tokens: [Int] = []
                var text = ""
                for await event in submission.events {
                    observeCapacity()
                    switch event {
                    case .delta(let chunk, let sampled, _):
                        if first == nil, !sampled.isEmpty {
                            first = DispatchTime.now().uptimeNanoseconds
                        }
                        text += chunk
                        tokens.append(contentsOf: sampled)
                    case .finished(let reason, let usage): terminal = (reason, usage)
                    }
                }
                let finished = DispatchTime.now().uptimeNanoseconds
                guard let (reason, usage) = terminal else { throw Failure.missingTerminal }
                await session.complete(receiptID: submission.receiptID)
                let succeeded = reason == .stop || reason == .length
                let report = Report(
                    modelID: modelID, verifiedModelAggregateSHA256: verified,
                    runtimeIdentity: EngineV2Factory.benchmarkRuntimeIdentity(),
                    promptSHA256: sha256Hex(Data(prompt.utf8)),
                    promptTokens: prepared.tokens, renderDate: prepared.renderDate,
                    resolvedBackend: session.backend,
                    kvQuantization: session.kvQuantization.rawValue,
                    kvCheckpointQuantization: session.kvCheckpointQuantization.rawValue,
                    checkpointBackendLayout: session.checkpointBackendLayout,
                    mtpRequested: mtpEnabled,
                    mtpActive: session.rawEngine.mtpMetricsSnapshot() != nil,
                    mtpMetrics: MTPBenchmarkEngineMetrics.snapshot(engine: session.rawEngine),
                    assistantIdentity: (await session.cacheSnapshot()).assistantIdentity,
                    generatedTokens: tokens, text: text, finishReason: String(describing: reason),
                    promptTokenCount: usage.promptTokens,
                    completionTokenCount: usage.completionTokens,
                    firstTokenMilliseconds: first.map { Double($0 - started) / 1_000_000 },
                    totalMilliseconds: Double(finished - started) / 1_000_000,
                    peakMLXMemoryBytes: Memory.peakMemory,
                    preRequestActiveMemoryBytes: preRequestActive,
                    peakMLXMemoryDeltaBytes: max(0, Memory.peakMemory - preRequestActive),
                    peakObservedKVBytesInUse: peakInUse, peakObservedKVBytesReserved: peakReserved,
                    peakObservedPagedCommittedBytes: peakCommitted,
                    peakObservedPagedLivePageBytes: peakLivePages,
                    finalMemory: await session.memorySnapshot())
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let json = String(decoding: try encoder.encode(report), as: UTF8.self)
                await session.shutdown()
                await EngineV2Factory.releaseBenchmarkContainer(container)
                return (json, succeeded)
            } catch {
                await session.shutdown()
                throw error
            }
        } catch {
            await EngineV2Factory.releaseBenchmarkContainer(container)
            throw error
        }
    }
}

/// Target loading and prompt preparation shared by the runtime benchmarks.
extension RuntimeGenerationBenchmark {
    struct VerifiedTarget {
        let modelType: String?
        /// Equal before and after the container load.
        let weightHash: String
        let container: ModelContainer
        let isVLM: Bool
        let tokenizer: TokenizerHandle
    }

    /// `makeBenchmarkSession` requires fresh equal hashes around the load.
    /// On a mismatch the container is released here; otherwise the caller
    /// releases it after its sessions shut down.
    static func loadVerifiedTarget(modelID: String, modelDirectory: URL) async throws
        -> VerifiedTarget
    {
        let modelType = try ModelBenchmark.decodedModelType(
            from: Data(contentsOf: modelDirectory.appendingPathComponent("config.json")))
        guard modelType != "mimo_v2" else { throw Failure.unsupportedMiMo }
        _ = try GPUEnforcement.requireMetal()
        MLXMemoryGuard.configureOnce()
        guard let verified = WeightHasher.computeHash(snapshotDir: modelDirectory, modelID: modelID)
        else { throw Failure.modelHashMismatch }
        let loaded = try await EngineV2Factory.loadBenchmarkContainer(
            modelID: modelID, directory: modelDirectory)
        guard WeightHasher.computeHash(snapshotDir: modelDirectory, modelID: modelID) == verified
        else {
            await EngineV2Factory.releaseBenchmarkContainer(loaded.container)
            throw Failure.modelHashMismatch
        }
        let tokenizer = await loaded.container.perform { TokenizerHandle($0.tokenizer) }
        return VerifiedTarget(
            modelType: modelType, weightHash: verified, container: loaded.container,
            isVLM: loaded.isVLM, tokenizer: tokenizer)
    }

    /// One greedy, seeded user turn through the production prompt pipeline.
    static func preparedPrompt(
        _ content: String, modelID: String, maxTokens: Int, target: VerifiedTarget,
        date: PromptRenderDate
    ) throws -> EngineV2Factory.BenchmarkPrompt {
        let body = try JSONSerialization.data(
            withJSONObject: [
                "model": modelID, "messages": [["role": "user", "content": content]],
                "temperature": 0, "seed": 1, "max_tokens": maxTokens,
            ] as [String: Any])
        return try EngineV2Factory.benchmarkPrompt(
            body: body, tokenizer: target.tokenizer.inner, modelType: target.modelType,
            defaultDate: date)
    }

    static func prefixCacheDisabledEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["DARKBLOOM_PREFIX_CACHE"] = "0"
        environment["DARKBLOOM_PREFIX_CACHE_MEMORY"] = "0"
        return environment
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
