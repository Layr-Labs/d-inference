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
        renderDate: String
    ) async throws -> (json: String, succeeded: Bool) {
        guard maxTokens > 0, maxTokens <= 131_072, prompt.utf8.count <= 4 << 20,
            let date = PromptRenderDate(renderDate),
            ["auto", "paged", "contiguous"].contains(backend),
            assistantDirectory == nil || mtpEnabled
        else { throw Failure.invalidArguments }
        let modelType = try ModelBenchmark.decodedModelType(
            from: Data(contentsOf: modelDirectory.appendingPathComponent("config.json")))
        guard modelType != "mimo_v2" else { throw Failure.unsupportedMiMo }
        _ = try GPUEnforcement.requireMetal()
        MLXMemoryGuard.configureOnce()
        guard let verified = WeightHasher.computeHash(snapshotDir: modelDirectory, modelID: modelID)
        else { throw Failure.modelHashMismatch }
        let loaded = try await EngineV2Factory.loadBenchmarkContainer(
            modelID: modelID, directory: modelDirectory)
        let container = loaded.container
        do {
            guard
                WeightHasher.computeHash(snapshotDir: modelDirectory, modelID: modelID) == verified
            else { throw Failure.modelHashMismatch }
            let tokenizer = await container.perform { TokenizerHandle($0.tokenizer) }
            let body = try JSONSerialization.data(
                withJSONObject: [
                    "model": modelID, "messages": [["role": "user", "content": prompt]],
                    "temperature": 0, "seed": 1, "max_tokens": maxTokens,
                ] as [String: Any])
            let prepared = try EngineV2Factory.benchmarkPrompt(
                body: body, tokenizer: tokenizer.inner, modelType: modelType, defaultDate: date)
            var environment = ProcessInfo.processInfo.environment
            environment["DARKBLOOM_PREFIX_CACHE"] = "0"
            environment["DARKBLOOM_PREFIX_CACHE_MEMORY"] = "0"
            let session = try await EngineV2Factory.makeBenchmarkSession(
                modelId: modelID, modelDirectory: modelDirectory, isVLM: loaded.isVLM,
                container: container, tokenizer: tokenizer, verifiedWeightHash: verified,
                kvBytesCapacity: 1 << 30, maxConcurrentRequests: 1, mtpEnabled: mtpEnabled,
                assistantDirectory: assistantDirectory,
                useProductionKVGrant: true, kvBackendConfig: backend, requirePersistentKey: false,
                environment: environment)
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
                    promptSHA256: SHA256.hash(data: Data(prompt.utf8)).map {
                        String(format: "%02x", $0)
                    }.joined(),
                    promptTokens: prepared.tokens, renderDate: prepared.renderDate,
                    resolvedBackend: session.backend,
                    kvQuantization: session.kvQuantization.rawValue,
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
