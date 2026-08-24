import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import ProviderCore

/// Opt-in exact-prefix benchmark for Qwen. One loaded container, one
/// `EngineV2Factory.makeProductionBuild` engine, and one reference cache serve // pragma: allowlist secret
/// every cold, construction, and warm arm. Existing benchmark defaults remain
/// cache-free; this path is reachable only through `--qwen-prefix-reuse`.
public enum QwenPrefixReuseBenchmark {
    public static let defaultPromptTokens = 8_192
    public static let defaultDecodeTokens = 64
    public static let defaultIterations = 3
    public static let donationTimeoutMilliseconds = 10_000

    private static let warmupRequestID: UInt64 = 0x5158_0000
    private static let measuredRequestIDBase: UInt64 = 0x5158_1000
    private static let exactCacheBudgetDivisor = 5
    private static let prefixExperimentEnvironmentKeys = [
        "DARKBLOOM_CBV2_PROMPT_FORK",
        "DARKBLOOM_PREFIX_BENCH_FORCE_FORK",
        "DARKBLOOM_PREFIX_BENCH_CACHE_MAX_BYTES",
    ]

    private struct ModelDescriptor: Sendable {
        let modelType: String
        let architecture: String?
        let isVLM: Bool
    }

    private struct EngineComponents: Sendable {
        let engine: any CBv2Engine
        let scenarios: [QwenPrefixPreparedScenario]
        let resolvedKVBackend: String
        let capabilitySupported: Bool
        let capabilityStrategy: String?
        let capabilityUnsupportedReason: String?
        let replayBoundTokens: Int
    }

    private struct RequestIDs {
        var next: UInt64

        mutating func allocate(_ count: Int) throws -> UInt64 {
            guard count > 0, let increment = UInt64(exactly: count) else {
                throw QwenPrefixBenchmarkError.requestIDOverflow
            }
            let base = next
            let (advanced, overflow) = next.addingReportingOverflow(increment)
            guard !overflow else {
                throw QwenPrefixBenchmarkError.requestIDOverflow
            }
            next = advanced
            return base
        }
    }

    public static func run(
        modelID: String,
        modelDirectory: URL,
        corpusURL: URL,
        promptTokens: Int = defaultPromptTokens,
        decodeTokens: Int = defaultDecodeTokens,
        iterations: Int = defaultIterations,
        kvBackend: EngineV2KVBackendSelection = .auto,
        hardware: HardwareInfo
    ) async throws -> QwenPrefixReuseReport {
        guard promptTokens >= 2 else {
            throw QwenPrefixBenchmarkError.invalidPromptTokens(promptTokens)
        }
        guard decodeTokens >= 2 else {
            throw QwenPrefixBenchmarkError.invalidDecodeTokens(decodeTokens)
        }
        guard iterations >= 1 else {
            throw QwenPrefixBenchmarkError.invalidIterations(iterations)
        }

        let modelDirectory = modelDirectory.resolvingSymlinksInPath().standardizedFileURL
        let corpus = try QwenPrefixCorpusLoader.load(from: corpusURL)
        let processEnvironment = ProcessInfo.processInfo.environment
        let policyEnvironment = capturedPolicyEnvironment(processEnvironment)

        log("hashing fixed model artifact \(modelID)")
        guard let fingerprintBefore = WeightHasher.snapshotFingerprint(
            snapshotDir: modelDirectory)
        else {
            throw QwenPrefixBenchmarkError.modelFingerprintUnavailable
        }
        guard let artifactSHA256 = WeightHasher.computeHash(
            snapshotDir: modelDirectory,
            modelID: modelID)
        else {
            throw QwenPrefixBenchmarkError.modelHashUnavailable
        }
        guard WeightHasher.snapshotFingerprint(snapshotDir: modelDirectory)
            == fingerprintBefore
        else {
            throw QwenPrefixBenchmarkError.modelArtifactChangedDuringRun
        }

        let descriptor = try inspectModel(at: modelDirectory)
        guard descriptor.modelType.lowercased().contains("qwen")
            || descriptor.architecture?.lowercased().contains("qwen") == true
        else {
            throw QwenPrefixBenchmarkError.notQwen(
                modelType: descriptor.modelType,
                architecture: descriptor.architecture)
        }

        log("loading model \(modelID) once")
        log("  path: \(modelDirectory.path)")
        let container: ModelContainer
        if descriptor.isVLM {
            container = try await VLMModelFactory.shared.loadContainer(
                from: modelDirectory,
                using: LocalTokenizerLoader())
        } else {
            container = try await LLMModelFactory.shared.loadContainer(
                from: modelDirectory,
                using: LocalTokenizerLoader())
        }
        let sizing = await SlotSizingSnapshot.build(
            container: container,
            modelPath: modelDirectory,
            fallbackDefaultMaxTokens: decodeTokens)
        let (requiredContext, contextOverflow) = promptTokens.addingReportingOverflow(
            decodeTokens)
        guard !contextOverflow else {
            throw QwenPrefixBenchmarkError.contextLengthOverflow
        }
        if sizing.maxContextLength > 0, requiredContext > sizing.maxContextLength {
            throw QwenPrefixBenchmarkError.contextLengthExceeded(
                promptTokens: promptTokens,
                decodeTokens: decodeTokens,
                maximumContextTokens: sizing.maxContextLength)
        }

        let totalStateCapacity = Int(min(
            UnifiedMemoryCap.kvBudgetBytes(
                physicalBytes: ProcessInfo.processInfo.physicalMemory,
                residentWeightBytes: UInt64(max(0, sizing.weightsBytes)),
                configReserveBytes: 0),
            UInt64(Int.max)))
        let defaultCacheBudget = totalStateCapacity / exactCacheBudgetDivisor
        let configuredCacheBudget = processEnvironment[
            "DARKBLOOM_PREFIX_BENCH_CACHE_MAX_BYTES"
        ].flatMap(Int.init)
        let exactCacheBudget = min(
            defaultCacheBudget,
            configuredCacheBudget ?? defaultCacheBudget)
        let kvCapacity = totalStateCapacity - exactCacheBudget
        let blockSize = CBv2BlockHasher.defaultBlockSize
        guard kvCapacity > 0, exactCacheBudget > 0 else {
            throw QwenPrefixBenchmarkError.insufficientStateBudget(
                totalBytes: totalStateCapacity)
        }
        let policyIdentity = policyEnvironment
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ";")
        let cache: any QwenPrefixBenchmarkCache = QwenExactPrefixTrackingCache(
            config: .init(
                modelIdentity: "qwen-prefix-benchmark:\(artifactSHA256)",
                policyIdentity:
                    "qwen-prefix-benchmark-v2;kv=\(kvBackend.rawValue);"
                        + "block=\(blockSize);"
                        + (policyIdentity.isEmpty ? "strict-default" : policyIdentity),
                scopeID: "benchmark-default-unused",
                blockSize: blockSize,
                maxBytes: exactCacheBudget))
        let components = try await container.perform { context -> EngineComponents in
            let scenarios = try QwenPrefixPromptBuilder.prepare(
                corpus: corpus.corpus,
                promptTokens: promptTokens,
                tokenizer: context.tokenizer)
            let servingModel = try EngineV2Factory.benchmarkServingModel(
                model: context.model,
                isVLM: descriptor.isVLM,
                modelDirectory: modelDirectory,
                environment: processEnvironment)
            let build = try EngineV2Factory.makeProductionBuild( // pragma: allowlist secret
                model: servingModel,
                tokenizer: context.tokenizer,
                kvBytesCapacity: kvCapacity,
                maxConcurrentRequests: 4,
                prefixCache: cache,
                kvBackend: kvBackend,
                maxContextLength: sizing.maxContextLength > 0
                    ? sizing.maxContextLength : nil,
                environment: processEnvironment)
            let capability = (build.engine as? EngineV2)?.prefixReuseCapability
            return EngineComponents(
                engine: build.engine,
                scenarios: scenarios,
                resolvedKVBackend: build.resolvedKVBackendDescriptor,
                capabilitySupported: capability?.isSupported ?? false,
                capabilityStrategy: capability?.strategy?.rawValue,
                capabilityUnsupportedReason: capability?.unsupportedReason?.rawValue,
                replayBoundTokens: capability?.conservativeReplayBoundTokens ?? 0)
        }
        log("engine resolved KV backend \(components.resolvedKVBackend)")
        if !components.capabilitySupported {
            log("prefix capability unsupported; miss/disabled rows will remain in the report"
                + (components.capabilityUnsupportedReason.map { " (\($0))" } ?? ""))
        }

        let samplesByScenario: [String: [QwenPrefixReuseReport.Sample]]
        do {
            let warmupPrompt = Array(
                components.scenarios[0].donorPrompt.prefix(min(128, promptTokens)))
            _ = try await QwenPrefixEngineRunner.run(
                engine: components.engine,
                cache: cache,
                prompts: [warmupPrompt],
                decodeTokens: 1,
                requestIDBase: warmupRequestID,
                prefixCacheEnabled: false,
                cacheSalt: "qwen-prefix-warmup")
            samplesByScenario = try await measureAll(
                engine: components.engine,
                cache: cache,
                scenarios: components.scenarios,
                iterations: iterations,
                decodeTokens: decodeTokens,
                capabilitySupported: components.capabilitySupported)
        } catch {
            await stopAndSynchronize(components.engine)
            throw error
        }
        await stopAndSynchronize(components.engine)
        cache.evict(toFit: 0)

        guard WeightHasher.snapshotFingerprint(snapshotDir: modelDirectory)
            == fingerprintBefore
        else {
            throw QwenPrefixBenchmarkError.modelArtifactChangedDuringRun
        }

        let reportScenarios = try components.scenarios.map { prepared in
            guard let samples = samplesByScenario[prepared.id] else {
                throw QwenPrefixBenchmarkError.missingScenario(prepared.id)
            }
            return scenarioReport(prepared: prepared, samples: samples)
        }
        let report = QwenPrefixReuseReport(
            createdAtUTC: timestamp(),
            model: .init(
                id: modelID,
                path: modelDirectory.path,
                artifactSHA256: artifactSHA256,
                modelType: descriptor.modelType,
                architecture: descriptor.architecture,
                maximumContextTokens: sizing.maxContextLength > 0
                    ? sizing.maxContextLength : nil),
            corpus: .init(
                id: corpus.corpus.id,
                version: corpus.corpus.version,
                path: corpus.path,
                sha256: corpus.sha256,
                license: corpus.corpus.license,
                provenance: corpus.corpus.provenance,
                suffixCount: corpus.corpus.suffixes.count),
            hardware: .init(
                machineModel: hardware.machineModel,
                chipName: hardware.chipName,
                memoryGB: hardware.memoryGb,
                gpuCores: hardware.gpuCores),
            engine: .init(
                factory: "EngineV2Factory.makeProductionBuild", // pragma: allowlist secret
                instanceCount: 1,
                maxConcurrentRequests: 4,
                kvBackend: BenchmarkKVBackend(
                    selection: kvBackend.rawValue,
                    resolved: [components.resolvedKVBackend]),
                kvBytesCapacity: kvCapacity,
                prefixCacheImplementation: cache.implementationName,
                prefixCacheMatchPolicy: cache.matchPolicy,
                prefixCacheRequested: true,
                prefixCacheBudgetBytes: cache.cacheBudgetBytes,
                cacheBlockTokens: cache.cacheBlockTokens,
                cacheSaltScope: "unique per scenario iteration",
                capabilitySupported: components.capabilitySupported,
                capabilityStrategy: components.capabilityStrategy,
                capabilityUnsupportedReason: components.capabilityUnsupportedReason,
                replayBoundTokens: components.replayBoundTokens,
                warmupPerformed: true,
                policyEnvironment: policyEnvironment),
            configuration: .init(
                promptTokens: promptTokens,
                decodeTokens: decodeTokens,
                iterations: iterations,
                identicalBatchSizes: QwenPrefixPromptBuilder.batchSizes,
                commonPrefixFractions: QwenPrefixPromptBuilder.commonPrefixFractions,
                commonPrefixBatchSize: QwenPrefixPromptBuilder.commonPrefixBatchSize,
                donationTimeoutMs: donationTimeoutMilliseconds,
                generationPolicy: "greedy-fixed-length-no-stop-tokens"),
            scenarios: reportScenarios)
        try report.validate()
        return report
    }

    /// Prefix reports extend the quality harness's safe policy allowlist with
    /// the two controls that distinguish a durable-cache run from a forced
    /// no-hit live-fork run. Never serialize unrelated process environment.
    static func capturedPolicyEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var captured = QwenQualityCorpusBenchmark.capturedPolicyEnvironment(
            environment)
        for key in prefixExperimentEnvironmentKeys {
            if let value = environment[key], !value.isEmpty {
                captured[key] = value
            }
        }
        return captured
    }

    private static func measureAll(
        engine: any CBv2Engine,
        cache: any QwenPrefixBenchmarkCache,
        scenarios: [QwenPrefixPreparedScenario],
        iterations: Int,
        decodeTokens: Int,
        capabilitySupported: Bool
    ) async throws -> [String: [QwenPrefixReuseReport.Sample]] {
        var samples = Dictionary(
            uniqueKeysWithValues: scenarios.map { ($0.id, [QwenPrefixReuseReport.Sample]()) })
        var ids = RequestIDs(next: measuredRequestIDBase)
        let timeout = Duration.milliseconds(donationTimeoutMilliseconds)

        for iteration in 1 ... iterations {
            let shift = (iteration - 1) % scenarios.count
            let order = Array(scenarios[shift...]) + Array(scenarios[..<shift])
            for scenario in order {
                cache.evict(toFit: 0)
                guard cache.bytesInUse == 0 else {
                    throw QwenPrefixBenchmarkError.cacheDidNotEvict(cache.bytesInUse)
                }
                let salt = "qwen-prefix/\(iteration)/\(scenario.id)"
                log("iteration \(iteration)/\(iterations): \(scenario.id) cold")
                let coldBase = try ids.allocate(scenario.batchSize)
                let cold = try await QwenPrefixEngineRunner.run(
                    engine: engine,
                    cache: cache,
                    prompts: scenario.prompts,
                    decodeTokens: decodeTokens,
                    requestIDBase: coldBase,
                    prefixCacheEnabled: false,
                    cacheSalt: salt)

                log("iteration \(iteration)/\(iterations): \(scenario.id) construct")
                let constructionBase = try ids.allocate(1)
                let construction = try await QwenPrefixEngineRunner.run(
                    engine: engine,
                    cache: cache,
                    prompts: [scenario.donorPrompt],
                    decodeTokens: decodeTokens,
                    requestIDBase: constructionBase,
                    prefixCacheEnabled: true,
                    cacheSalt: salt)
                let constructionRow = construction.rows[0]
                let donation: QwenPrefixDonationObservation?
                if capabilitySupported {
                    donation = await cache.waitForDonation(
                        requestID: constructionRow.requestID,
                        timeout: timeout)
                } else {
                    donation = cache.donation(for: constructionRow.requestID)
                }

                log("iteration \(iteration)/\(iterations): \(scenario.id) warm")
                let warmSalt =
                    ProcessInfo.processInfo.environment[
                        "DARKBLOOM_PREFIX_BENCH_FORCE_FORK"] == "1"
                    ? salt + "/fork"
                    : salt
                let warmBase = try ids.allocate(scenario.batchSize)
                let warm = try await QwenPrefixEngineRunner.run(
                    engine: engine,
                    cache: cache,
                    prompts: scenario.prompts,
                    decodeTokens: decodeTokens,
                    requestIDBase: warmBase,
                    prefixCacheEnabled: true,
                    cacheSalt: warmSalt)
                if capabilitySupported {
                    await cache.waitForDonations(
                        requestIDs: warm.rows.compactMap {
                            cache.shouldAwaitDonation(after: $0.usage.prefixCacheOutcome)
                                ? $0.requestID : nil
                        },
                        timeout: timeout)
                }

                let sample = sampleReport(
                    iteration: iteration,
                    cold: cold,
                    construction: constructionRow,
                    donation: donation,
                    warm: warm)
                samples[scenario.id, default: []].append(sample)
                log("  outcomes construct=\(sample.cacheConstruction.row.cacheOutcome), "
                    + "warm=\(sample.warm.rows.map(\.cacheOutcome).joined(separator: ",")), "
                    + "saved=\(sample.warm.totalSavedPrefillTokens), "
                    + "cold/warm=\(format(sample.coldBaseline.makespanMs))/"
                    + "\(format(sample.warm.makespanMs)) ms")
            }
        }
        return samples
    }

    private static func sampleReport(
        iteration: Int,
        cold: QwenPrefixEngineBatch,
        construction: QwenPrefixEngineRow,
        donation: QwenPrefixDonationObservation?,
        warm: QwenPrefixEngineBatch
    ) -> QwenPrefixReuseReport.Sample {
        let coldReport = batchReport(cold, prefixCacheEnabled: false)
        let constructionReport = rowReport(construction)
        let warmReport = batchReport(warm, prefixCacheEnabled: true)
        let equality = zip(coldReport.rows, warmReport.rows).map { coldRow, warmRow in
            QwenPrefixReuseReport.Equality(
                row: coldRow.row,
                firstTokenEqual: coldRow.firstTokenID == warmRow.firstTokenID,
                fullTokensEqual: coldRow.tokenIDs == warmRow.tokenIDs,
                finishReasonEqual: coldRow.finishReason == warmRow.finishReason)
        }
        let submitToReady = donation.map {
            milliseconds(from: construction.submittedAtNs, to: $0.publishedAtNs)
        }
        let readyMinusTerminal = donation.map {
            signedMilliseconds(from: construction.completedAtNs, to: $0.publishedAtNs)
        }
        let cacheRows = [constructionReport] + warmReport.rows
        return QwenPrefixReuseReport.Sample(
            iteration: iteration,
            coldBaseline: coldReport,
            cacheConstruction: .init(
                row: constructionReport,
                donationObserved: donation != nil,
                submitToCacheReadyMs: submitToReady,
                cacheReadyMinusTerminalMs: readyMinusTerminal,
                cacheBytesAfterReady: donation?.cacheBytesAfterPublish ?? 0),
            warm: warmReport,
            cacheAccountingIncludingConstruction: .init(rows: cacheRows),
            equality: equality)
    }

    private static func batchReport(
        _ batch: QwenPrefixEngineBatch,
        prefixCacheEnabled: Bool
    ) -> QwenPrefixReuseReport.Batch {
        let rows = batch.rows.map(rowReport)
        let firstTokenEnd = batch.rows.map(\.firstTokenAtNs).max() ?? batch.startedAtNs
        return QwenPrefixReuseReport.Batch(
            prefixCacheEnabled: prefixCacheEnabled,
            makespanMs: milliseconds(from: batch.startedAtNs, to: batch.completedAtNs),
            firstTokenMakespanMs: milliseconds(
                from: batch.startedAtNs,
                to: firstTokenEnd),
            rows: rows,
            cacheAccounting: .init(rows: rows),
            totalSavedPrefillTokens: saturatingSum(rows.map(\.savedPrefillTokens)),
            totalStateBytesCloned: saturatingSum(rows.map(\.stateBytesCloned)))
    }

    private static func rowReport(
        _ row: QwenPrefixEngineRow
    ) -> QwenPrefixReuseReport.Row {
        let firstToken = row.tokenIDs[0]
        return QwenPrefixReuseReport.Row(
            row: row.row,
            requestID: row.requestID.raw,
            promptTokens: row.promptTokenCount,
            ttftMs: milliseconds(from: row.submittedAtNs, to: row.firstTokenAtNs),
            totalTimeMs: milliseconds(from: row.submittedAtNs, to: row.completedAtNs),
            firstTokenID: firstToken,
            firstTokenChecksum: ArrivalPrefillAccounting.tokenChecksum([firstToken]),
            tokenIDs: row.tokenIDs,
            tokenChecksum: ArrivalPrefillAccounting.tokenChecksum(row.tokenIDs),
            finishReason: row.finishReason,
            cacheOutcome: QwenPrefixEngineRunner.describe(row.usage.prefixCacheOutcome),
            matchedTokens: max(
                row.usage.prefixCacheMatchedTokens,
                row.usage.prefixCacheHitTokens),
            savedPrefillTokens: max(
                row.usage.prefixCachePrefillTokensSaved,
                row.usage.prefixCacheHitTokens),
            replayTokens: max(0, row.usage.prefixCacheReplayTokens),
            reuseStrategy: row.usage.prefixCacheStrategy?.rawValue,
            replayBoundarySplits: max(0, row.usage.prefixCacheBoundarySplits),
            stateBytesCloned: max(0, row.stateBytesCloned))
    }

    private static func scenarioReport(
        prepared: QwenPrefixPreparedScenario,
        samples: [QwenPrefixReuseReport.Sample]
    ) -> QwenPrefixReuseReport.Scenario {
        let warmRows = samples.flatMap(\.warm.rows)
        let allCacheRows = samples.flatMap {
            [$0.cacheConstruction.row] + $0.warm.rows
        }
        let equalities = samples.flatMap(\.equality)
        let readyTimes = samples.compactMap(\.cacheConstruction.submitToCacheReadyMs)
        let count = equalities.count
        return QwenPrefixReuseReport.Scenario(
            id: prepared.id,
            kind: prepared.kind.rawValue,
            batchSize: prepared.batchSize,
            requestedCommonPrefixFraction: prepared.requestedCommonPrefixFraction,
            constructedCommonPrefixTokens: prepared.constructedCommonPrefixTokens,
            constructedCommonPrefixFraction: prepared.constructedCommonPrefixTokens.map {
                Double($0) / Double(prepared.donorPrompt.count)
            },
            suffixIDs: prepared.suffixIDs,
            samples: samples.sorted { $0.iteration < $1.iteration },
            summary: .init(
                medianColdMakespanMs: median(samples.map(\.coldBaseline.makespanMs)),
                medianWarmMakespanMs: median(samples.map(\.warm.makespanMs)),
                medianCacheConstructionRequestMs: median(
                    samples.map(\.cacheConstruction.row.totalTimeMs)),
                medianSubmitToCacheReadyMs: readyTimes.isEmpty ? nil : median(readyTimes),
                warmCacheAccounting: .init(rows: warmRows),
                cacheAccountingIncludingConstruction: .init(rows: allCacheRows),
                totalSavedPrefillTokens: saturatingSum(
                    warmRows.map(\.savedPrefillTokens)),
                totalStateBytesCloned: saturatingSum(
                    warmRows.map(\.stateBytesCloned)),
                equalityComparisons: count,
                firstTokenEqualityRate: count > 0
                    ? Double(equalities.count(where: \.firstTokenEqual)) / Double(count)
                    : 0,
                fullTokenEqualityRate: count > 0
                    ? Double(equalities.count(where: \.fullTokensEqual)) / Double(count)
                    : 0))
    }

    private static func inspectModel(at directory: URL) throws -> ModelDescriptor {
        let configURL = directory.appendingPathComponent("config.json")
        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch {
            throw QwenPrefixBenchmarkError.invalidModelConfig(
                "could not read \(configURL.path): \(error)")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw QwenPrefixBenchmarkError.invalidModelConfig(
                "config.json must contain a JSON object")
        }
        let textConfig = object["text_config"] as? [String: Any]
        guard let modelType = (object["model_type"] as? String)
            ?? (textConfig?["model_type"] as? String),
            !modelType.isEmpty
        else {
            throw QwenPrefixBenchmarkError.invalidModelConfig(
                "config.json is missing model_type")
        }
        let architecture = (object["architectures"] as? [String])?.first
            ?? (textConfig?["architectures"] as? [String])?.first
        return ModelDescriptor(
            modelType: modelType,
            architecture: architecture,
            isVLM: object["vision_config"] != nil)
    }

    private static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        guard end >= start else { return 0 }
        return Double(end - start) / 1_000_000
    }

    private static func signedMilliseconds(from start: UInt64, to end: UInt64) -> Double {
        end >= start
            ? Double(end - start) / 1_000_000
            : -Double(start - end) / 1_000_000
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    private static func saturatingSum(_ values: [Int]) -> Int {
        values.reduce(0) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(value)
            return overflow ? Int.max : sum
        }
    }

    private static func stopAndSynchronize(_ engine: any CBv2Engine) async {
        await engine.shutdown()
        Stream().synchronize()
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[qwen-prefix] \(message)\n".utf8))
    }
}

public enum QwenPrefixBenchmarkError: Error, Equatable, CustomStringConvertible {
    case invalidPromptTokens(Int)
    case invalidDecodeTokens(Int)
    case invalidIterations(Int)
    case contextLengthOverflow
    case contextLengthExceeded(
        promptTokens: Int,
        decodeTokens: Int,
        maximumContextTokens: Int
    )
    case invalidModelConfig(String)
    case notQwen(modelType: String, architecture: String?)
    case modelHashUnavailable
    case modelFingerprintUnavailable
    case modelArtifactChangedDuringRun
    case requestIDOverflow
    case insufficientStateBudget(totalBytes: Int)
    case cacheDidNotEvict(Int)
    case missingScenario(String)

    public var description: String {
        switch self {
        case .invalidPromptTokens(let count):
            return "Qwen prefix prompt tokens must be at least 2 (got \(count))"
        case .invalidDecodeTokens(let count):
            return "Qwen prefix decode tokens must be at least 2 (got \(count))"
        case .invalidIterations(let count):
            return "Qwen prefix iterations must be at least 1 (got \(count))"
        case .contextLengthOverflow:
            return "Qwen prefix prompt plus decode length overflowed"
        case .contextLengthExceeded(let prompt, let decode, let maximum):
            return "Qwen prefix workload requires \(prompt)+\(decode) tokens, "
                + "exceeding model context \(maximum)"
        case .invalidModelConfig(let message):
            return "Qwen prefix benchmark model config is invalid: \(message)"
        case .notQwen(let modelType, let architecture):
            return "Qwen prefix benchmark requires a Qwen checkpoint "
                + "(model_type=\(modelType), architecture=\(architecture ?? "unknown"))"
        case .modelHashUnavailable:
            return "Qwen prefix benchmark could not compute the model artifact SHA-256"
        case .modelFingerprintUnavailable:
            return "Qwen prefix benchmark could not fingerprint the model artifact"
        case .modelArtifactChangedDuringRun:
            return "Qwen prefix benchmark model artifact changed during the run"
        case .requestIDOverflow:
            return "Qwen prefix benchmark exhausted the CBv2 request-id space"
        case .insufficientStateBudget(let totalBytes):
            return "Qwen prefix benchmark cannot split its \(totalBytes)-byte "
                + "state grant between one exact cache entry and four live rows"
        case .cacheDidNotEvict(let bytes):
            return "Qwen prefix benchmark cache retained \(bytes) bytes after full eviction"
        case .missingScenario(let id):
            return "Qwen prefix benchmark did not produce samples for '\(id)'"
        }
    }
}
