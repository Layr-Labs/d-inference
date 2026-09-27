import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import ProviderCoreFoundation

/// Native committed-token measurements. `completionTokens` includes a terminal
/// EOS when emitted; `tokenIDs` excludes it, but can include native framing.
/// Neither canvas work nor retokenized display text counts as generated tokens.
@_spi(Benchmarking)
public struct DiffusionGemmaBenchmarkIteration: Sendable {
    public let tokenIDs: [Int]
    public let text: String
    public let usage: CBv2Usage
    public let totalMilliseconds: Double
    public var prefillMilliseconds: Double {
        (EngineV2NativeBlockTiming.prefillSeconds(usage.timing) ?? 0) * 1000
    }
    public var firstCommittedMilliseconds: Double { Double(usage.timing.firstTokenNanos) / 1e6 }
    public var generationMilliseconds: Double {
        guard usage.timing.finishedNanos > usage.timing.promptComputedNanos else { return 0 }
        return Double(usage.timing.finishedNanos - usage.timing.promptComputedNanos) / 1e6
    }
    public var committedTokensPerSecond: Double {
        guard usage.timing.promptComputedNanos > 0, generationMilliseconds > 0 else { return 0 }
        return Double(tokenIDs.count) * 1000 / generationMilliseconds
    }
}

@_spi(Benchmarking)
public struct DiffusionGemmaBenchmarkResult: Sendable {
    public let iterations: [DiffusionGemmaBenchmarkIteration]
    public let weightHash: String
    public let backend: String
    public let loadMilliseconds: Double
    public let grant: EngineV2BenchmarkProductionGrant
}

extension EngineV2Factory {
    enum DiffusionBenchmarkFailure: Error {
        case invalidArguments, wrongArchitecture, weightHashMismatch, runtimeIdentityUnavailable
        case insufficientMemory, missingNativeEngine, unexpectedFinish, inconsistentUsage
    }

    /// Cold uncached native benchmark through the ordinary slot factory and
    /// process ledger. No listener, assistant, cache-root or account side effects.
    @_spi(Benchmarking)
    public static func runDiffusionGemmaBenchmark(
        modelID: String, directory: URL, prompt: String, iterations: Int,
        maxTokens: Int, backend: String = "auto"
    ) async throws -> DiffusionGemmaBenchmarkResult {
        guard iterations > 0, maxTokens > 0,
            ["auto", "contiguous", "paged"].contains(backend) else {
            throw DiffusionBenchmarkFailure.invalidArguments
        }
        guard let model = ModelScanner.parseModelInfo(snapshotDir: directory, modelName: modelID),
            model.modelType == "diffusion_gemma" else { throw DiffusionBenchmarkFailure.wrongArchitecture }
        guard bindRuntimeMetallibForMLX() != nil, selfBinaryHash() != nil else {
            throw DiffusionBenchmarkFailure.runtimeIdentityUnavailable
        }
        _ = try GPUEnforcement.requireMetal()
        // This entry point does not construct ProviderLoop or StandaloneServer,
        // which normally install the process-wide allocator safeguards. Apply
        // the same existing policy before loading weights, not a benchmark-only
        // lower reserve or an unbounded default MLX reusable-buffer pool.
        MLXMemoryGuard.configureOnce()
        var environment = ProcessInfo.processInfo.environment
        environment["DARKBLOOM_PREFIX_CACHE"] = "0"
        environment["DARKBLOOM_PREFIX_CACHE_MEMORY"] = "0"
        let reserve = UnifiedMemoryCap.resolvedActivationReserveBytes(env: environment, modelIDs: [modelID])
        let budget = GlobalKVCacheBudget(activationReserveBytes: reserve,
            configReserveBytes: ProviderSettings(name: "benchmark").memoryReserveGB * (1 << 30))
        let bytes = ProviderLoop.pendingLoadReservationBytes(estimatedWeightsGb: model.estimatedMemoryGb, extraWeightBytes: 0)
        guard let permit = await budget.claimPendingLoad(requestID: "native-benchmark-load", weightBytes: bytes) else {
            throw DiffusionBenchmarkFailure.insufficientMemory
        }
        var owner: EngineV2NewcomerBox?
        let start = ContinuousClock.now
        do {
            try Task.checkCancellation()
            guard let hash = WeightHasher.computeHash(snapshotDir: directory, modelID: modelID) else {
                throw DiffusionBenchmarkFailure.weightHashMismatch
            }
            guard await budget.recheckPendingLoad(permit) else { throw DiffusionBenchmarkFailure.insufficientMemory }
            owner = EngineV2NewcomerBox(try await ModelContainerLoading.loadServingContainer(from: directory, modelID: modelID))
            guard await budget.reducePendingLoad(permit, remainingWeightBytes: 0) else {
                throw DiffusionBenchmarkFailure.insufficientMemory
            }
            guard WeightHasher.computeHash(snapshotDir: directory, modelID: modelID) == hash else {
                throw DiffusionBenchmarkFailure.weightHashMismatch
            }
            // The helper's temporary model/engine aliases die before releasing
            // this sole owner and clearing reclaimable buffers on either exit.
            guard let loadedOwner = owner else { throw DiffusionBenchmarkFailure.missingNativeEngine }
            let result = try await runLoadedDiffusionBenchmark(
                owner: loadedOwner, budget: budget, permit: permit, modelID: modelID,
                directory: directory, hash: hash, prompt: prompt, iterations: iterations,
                maxTokens: maxTokens, backend: backend, environment: environment,
                loadStart: start)
            await owner?.releaseAfterExternalResources()
            owner = nil
            Memory.clearCache()
            _ = await budget.finishPendingLoad(permit)
            return result
        } catch {
            await owner?.releaseAfterExternalResources()
            owner = nil
            Memory.clearCache()
            _ = await budget.finishPendingLoad(permit)
            throw error
        }
    }

    private static func runLoadedDiffusionBenchmark(
        owner: EngineV2NewcomerBox, budget: GlobalKVCacheBudget, permit: PendingModelLoadLease,
        modelID: String, directory: URL, hash: String, prompt: String, iterations: Int,
        maxTokens: Int, backend: String, environment: [String: String], loadStart: ContinuousClock.Instant
    ) async throws -> DiffusionGemmaBenchmarkResult {
        let serving = try owner.borrowModel()
        guard let native = serving.diffusion else { throw DiffusionBenchmarkFailure.wrongArchitecture }
        let sizing = await serving.sizing(modelPath: directory, defaultMaxTokens: maxTokens)
        let grant = try benchmarkProductionGrant(modelId: modelID, sizing: sizing, environment: environment)
        let tokenizer = await serving.tokenizerHandle(modelType: "diffusion_gemma", directory: directory)
        let preparation = SpecDecPreparation(artifact: nil, status: .disabled(.targetUnsupported, configured: false))
        let bundle = try await EngineV2SlotFactory.makeProductionBundle(
            modelId: modelID, modelType: "diffusion_gemma", isVLM: true, modelDirectory: directory,
            container: serving, tokenizer: tokenizer, sizing: sizing, kvBytesCapacity: grant.grantBytes,
            maxConcurrentRequests: 1, kvBudget: budget, activationReserveBytes: grant.activationReserveBytes,
            kvBackendConfig: backend, weightHash: hash, specDecPreparation: preparation,
            environment: environment, startServingTelemetry: false)
        do {
            guard let engine = await bundle.bridge.ownedEngine as? CBv2NativeBlockEngine else {
                throw DiffusionBenchmarkFailure.missingNativeEngine
            }
            Memory.clearCache()
            let headroom = budget.memoryHeadroomSnapshot()
            let kind = await bundle.bridge.kvBackendKind
            let pool = await bundle.bridge.kvBackendPoolBytes()
            guard KVHeadroomProbe.postBuildServeable(kvBackendKind: kind, pagedPoolBytes: pool,
                activationReserveBytes: grant.activationReserveBytes, measuredHeadroomBytes: headroom.runtimeRemainingBytes) else {
                throw DiffusionBenchmarkFailure.insufficientMemory
            }
            _ = await budget.finishPendingLoad(permit)
            let loadMs = diffusionMilliseconds(ContinuousClock.now - loadStart)
            let results = try await runDiffusionBenchmarkIterations(
                container: native, engine: engine, budget: budget, modelID: modelID,
                prompt: prompt, iterations: iterations, maxTokens: maxTokens,
                stopTokens: await bundle.bridge.stopTokenIds)
            await bundle.bridge.shutdown()
            return .init(iterations: results, weightHash: hash, backend: kind.rawValue,
                loadMilliseconds: loadMs, grant: grant)
        } catch {
            await bundle.bridge.shutdown()
            throw error
        }
    }

    static func diffusionMilliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
