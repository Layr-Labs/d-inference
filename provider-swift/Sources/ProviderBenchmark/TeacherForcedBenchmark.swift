import CryptoKit
import Foundation
import MLXLLM
import MLXVLM
@_spi(Diagnostics) import MLXLMCommon
@_spi(Benchmarking) import ProviderCore

/// Ordinary target scoring at identical, supplied contexts. This report never
/// certifies free generation, sampling, speculative verification or a release.
public enum TeacherForcedBenchmark {
    public enum Failure: Error {
        case invalidInputIdentity, inputTooLarge, invalidDeclaration, explicitBackendRequired
        case modelHashMismatch, runtimeIdentityUnavailable, unexpectedServingMode
    }

    struct Activity: Codable, Equatable {
        let prefillChunks: Int
        let decodeForwards: Int
        init(before: CBv2TeacherForcedScoringActivity, after: CBv2TeacherForcedScoringActivity) {
            prefillChunks = after.prefillChunksExecuted - before.prefillChunksExecuted
            decodeForwards = after.decodeForwardsExecuted - before.decodeForwardsExecuted
        }
    }

    struct Report: Encodable {
        let schema = 1
        let scope = "ordinary_teacher_forced_scores"
        let status: String
        let inconclusiveReasons: [String]
        let input: TeacherForcedBenchmarkInput
        let inputSHA256: String
        let verifiedModelAggregateSHA256: String
        let executableSHA256: String
        let metallibSHA256: String
        let modelDirectory: String
        let resolvedBackend: String
        let cacheMode = "off"
        let mtpEnabled = false
        let concurrency = 1
        let kvCapacityBytes: Int
        let productionGrant: EngineV2BenchmarkProductionGrant
        let plainTop1: [Int]
        let activity: [Activity]
        let diagnostic: CBv2TeacherForcedScoreSnapshot
        let repeatedDiagnostic: CBv2TeacherForcedScoreSnapshot
        let meanForcedTokenNLL: Double?
        let gemmaOptimizations: GemmaOptimizationSettings
        let limits = [
            "Observational scores, not a model-correctness or release verdict.",
            "Ordinary target forwards do not certify scheduler, sampler or rectangular MTP behavior.",
            "Existing exact-token failures and comparators remain separate and unchanged.",
            "Native scalar values are preserved as FP32 bits; logSumExp/NLL use diagnostic-only FP32 reductions.",
        ]
    }

    static func controlReasons(plain: [Int], first: CBv2TeacherForcedScoreSnapshot,
        repeated: CBv2TeacherForcedScoreSnapshot, activity: [Activity], count: Int) -> [String]
    {
        var reasons: [String] = []
        if plain.count != count || first.records.count != count || repeated.records.count != count {
            reasons.append("incomplete scoring sequence")
        }
        if plain != first.top1 || plain != repeated.top1 {
            reasons.append("plain and diagnostic top1 differ")
        }
        if first.records.map(\.argMaxID) != first.top1 ||
            repeated.records.map(\.argMaxID) != repeated.top1 {
            reasons.append("independent diagnostic argmax differs from scored top1")
        }
        if first != repeated { reasons.append("repeated diagnostic values differ") }
        if activity.count != 3 || (activity.first?.prefillChunks ?? 0) <= 0 ||
            !activity.allSatisfy({ $0 == activity.first && $0.decodeForwards == count - 1 }) {
            reasons.append("plain and diagnostic forward activity differs or is incomplete")
        }
        if !first.allFinite || !repeated.allFinite { reasons.append("nonfinite score evidence") }
        return reasons
    }

    public static func validateBackend(_ backend: String) throws {
        guard backend == "contiguous" || backend == "paged" else {
            throw Failure.explicitBackendRequired
        }
    }

    public static func run(modelID: String, modelDirectory: URL, inputURL: URL,
        backend: String, gemmaOptimizations: GemmaOptimizationSettings) async throws
        -> (json: String, controlsPassed: Bool)
    {
        try validateBackend(backend)
        let bytes = try TeacherForcedBenchmarkInput.readBounded(inputURL)
        let input = try JSONDecoder().decode(TeacherForcedBenchmarkInput.self, from: bytes)
        // Apply the absolute token/identity bounds before reading model files.
        _ = try input.request(modelID: modelID, vocabularySize: 1_048_576)
        // Read the bounded declaration inside the same integrity bracket used
        // for loading the actual model, before any token or cache allocation.
        guard let verified = WeightHasher.computeHash(snapshotDir: modelDirectory, modelID: modelID),
            verified == input.expectedModelAggregateSHA256 else { throw Failure.modelHashMismatch }
        let declaration = try JSONDecoder().decode(TeacherForcedBenchmarkInput.Declaration.self,
            from: TeacherForcedBenchmarkInput.readBounded(modelDirectory.appendingPathComponent("config.json")))
        guard let vocabulary = declaration.vocabularySize else { throw Failure.invalidDeclaration }
        let request = try input.request(modelID: modelID, vocabularySize: vocabulary)
        guard let metallib = bindRuntimeMetallibForMLX(), let executable = selfBinaryHash() else {
            throw Failure.runtimeIdentityUnavailable
        }
        let isVLM = declaration.visionConfig != nil
        let container: ModelContainer
        if isVLM {
            container = try await VLMModelFactory.shared.loadContainer(
                from: modelDirectory, using: LocalTokenizerLoader())
        } else {
            container = try await LLMModelFactory.shared.loadContainer(
                from: modelDirectory, using: LocalTokenizerLoader())
        }
        guard WeightHasher.computeHash(snapshotDir: modelDirectory, modelID: modelID) == verified else {
            throw Failure.modelHashMismatch
        }
        let tokenizer = await container.perform { TokenizerHandle($0.tokenizer) }
        var environment = ProcessInfo.processInfo.environment
        environment["DARKBLOOM_PREFIX_CACHE"] = "0"
        environment["DARKBLOOM_PREFIX_CACHE_MEMORY"] = "0"
        let session = try await EngineV2Factory.makeBenchmarkSession(
            modelId: modelID, modelDirectory: modelDirectory, isVLM: isVLM,
            container: container, tokenizer: tokenizer, verifiedWeightHash: verified,
            kvBytesCapacity: 1 << 30, maxConcurrentRequests: 1, mtpEnabled: false,
            useProductionKVGrant: true, kvBackendConfig: backend, requirePersistentKey: false,
            environment: environment)
        do {
            let cache = await session.cacheSnapshot()
            let engine = session.rawEngine
            guard session.backend == backend, session.backendFallback == nil,
                !cache.memoryEnabled, cache.durableMode == nil, cache.recurrentBankBudgetBytes == 0,
                engine.mtpMetricsSnapshot() == nil, let grant = cache.productionGrant else {
                throw Failure.unexpectedServingMode
            }
            let start = engine.teacherForcedScoringActivity()
            let plain = try engine.teacherForcedTop1(
                promptTokens: request.promptTokens, continuation: request.continuation)
            let afterPlain = engine.teacherForcedScoringActivity()
            let first = try engine.teacherForcedScores(request)
            let afterFirst = engine.teacherForcedScoringActivity()
            let repeated = try engine.teacherForcedScores(request)
            let afterRepeated = engine.teacherForcedScoringActivity()
            let activity = [Activity(before: start, after: afterPlain),
                Activity(before: afterPlain, after: afterFirst),
                Activity(before: afterFirst, after: afterRepeated)]
            let reasons = controlReasons(plain: plain, first: first, repeated: repeated,
                activity: activity, count: request.continuation.count)
            let report = Report(status: reasons.isEmpty ? "observed" : "inconclusive",
                inconclusiveReasons: reasons, input: input,
                inputSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                verifiedModelAggregateSHA256: verified, executableSHA256: executable,
                metallibSHA256: metallib, modelDirectory: modelDirectory.path,
                resolvedBackend: session.backend, kvCapacityBytes: cache.engineKVCapacityBytes,
                productionGrant: grant, plainTop1: plain, activity: activity,
                diagnostic: first, repeatedDiagnostic: repeated,
                meanForcedTokenNLL: first.allFinite ? first.records.reduce(0.0) {
                    $0 + Double(Float(bitPattern: $1.nllBits))
                } / Double(first.records.count) : nil,
                gemmaOptimizations: gemmaOptimizations)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let json = String(decoding: try encoder.encode(report), as: UTF8.self)
            await session.shutdown()
            return (json, reasons.isEmpty)
        } catch {
            await session.shutdown()
            throw error
        }
    }
}
