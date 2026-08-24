import Foundation

/// Versioned, machine-readable evidence from the opt-in Qwen exact-prefix
/// benchmark. Validation checks structural honesty only: misses and token
/// inequality remain valid measurements and are never rejected from output.
public struct QwenPrefixReuseReport: Codable, Sendable {
    public static let currentSchemaVersion = 1
    public static let benchmarkName = "qwen-prefix-reuse"

    public struct Model: Codable, Sendable {
        public let id: String
        public let path: String
        public let artifactSHA256: String
        public let modelType: String
        public let architecture: String?
        public let maximumContextTokens: Int?
    }

    public struct Corpus: Codable, Sendable {
        public let id: String
        public let version: String
        public let path: String
        public let sha256: String
        public let license: String
        public let provenance: String
        public let suffixCount: Int
    }

    public struct Hardware: Codable, Sendable {
        public let machineModel: String
        public let chipName: String
        public let memoryGB: UInt64
        public let gpuCores: UInt32
    }

    public struct Engine: Codable, Sendable {
        public let factory: String
        public let instanceCount: Int
        public let maxConcurrentRequests: Int
        public let kvBackend: BenchmarkKVBackend
        public let kvBytesCapacity: Int
        public let prefixCacheImplementation: String
        public let prefixCacheMatchPolicy: String
        public let prefixCacheRequested: Bool
        public let prefixCacheBudgetBytes: Int?
        public let cacheBlockTokens: Int?
        public let cacheSaltScope: String
        public let capabilitySupported: Bool
        public let capabilityStrategy: String?
        public let capabilityUnsupportedReason: String?
        public let replayBoundTokens: Int
        public let warmupPerformed: Bool
        public let policyEnvironment: [String: String]
    }

    public struct Configuration: Codable, Sendable {
        public let promptTokens: Int
        public let decodeTokens: Int
        public let iterations: Int
        public let identicalBatchSizes: [Int]
        public let commonPrefixFractions: [Double]
        public let commonPrefixBatchSize: Int
        public let donationTimeoutMs: Int
        public let generationPolicy: String
    }

    public struct Row: Codable, Sendable {
        public let row: Int
        public let requestID: UInt64
        public let promptTokens: Int
        public let ttftMs: Double
        public let totalTimeMs: Double
        public let firstTokenID: Int
        public let firstTokenChecksum: String
        public let tokenIDs: [Int]
        public let tokenChecksum: String
        public let finishReason: String
        public let cacheOutcome: String
        public let matchedTokens: Int
        public let savedPrefillTokens: Int
        public let replayTokens: Int
        public let reuseStrategy: String?
        public let replayBoundarySplits: Int
        /// Exact logical `nbytes` of cache state handed to backend adoption.
        /// For Qwen this is the atomic attention + recurrent snapshot, plus
        /// frontier logits only on a full-prompt hit. Zero on every non-hit.
        public let stateBytesCloned: Int
    }

    public struct CacheAccounting: Codable, Equatable, Sendable {
        public let requestCount: Int
        public let hitCount: Int
        public let missCount: Int
        public let skippedPolicyCount: Int
        public let disabledCount: Int
        public let skippedCapacityCount: Int
        public let adoptionFailedCount: Int
        /// Denominator is every request in this accounting block. Construction
        /// misses therefore remain in the rate rather than disappearing.
        public let hitRate: Double
        public let missRate: Double

        init(rows: [Row]) {
            let hit = rows.count(where: { $0.cacheOutcome == "hit" })
            let miss = rows.count(where: { $0.cacheOutcome == "miss" })
            let count = rows.count
            requestCount = count
            hitCount = hit
            missCount = miss
            skippedPolicyCount = rows.count(where: { $0.cacheOutcome == "skipped_policy" })
            disabledCount = rows.count(where: { $0.cacheOutcome == "disabled" })
            skippedCapacityCount = rows.count(where: { $0.cacheOutcome == "skipped_capacity" })
            adoptionFailedCount = rows.count(where: { $0.cacheOutcome == "adoption_failed" })
            hitRate = count > 0 ? Double(hit) / Double(count) : 0
            missRate = count > 0 ? Double(miss) / Double(count) : 0
        }
    }

    public struct Batch: Codable, Sendable {
        public let prefixCacheEnabled: Bool
        public let makespanMs: Double
        public let firstTokenMakespanMs: Double
        public let rows: [Row]
        public let cacheAccounting: CacheAccounting
        public let totalSavedPrefillTokens: Int
        public let totalStateBytesCloned: Int
    }

    public struct CacheConstruction: Codable, Sendable {
        /// This row is submitted with caching enabled against an empty cache.
        /// Its miss/disabled outcome is part of sample accounting.
        public let row: Row
        public let donationObserved: Bool
        public let submitToCacheReadyMs: Double?
        /// Cache publication timestamp minus the construction terminal
        /// timestamp. Exact-state donation normally publishes before the
        /// first token, so a healthy value is negative.
        public let cacheReadyMinusTerminalMs: Double?
        public let cacheBytesAfterReady: Int
    }

    public struct Equality: Codable, Sendable {
        public let row: Int
        public let firstTokenEqual: Bool
        public let fullTokensEqual: Bool
        public let finishReasonEqual: Bool
    }

    public struct Sample: Codable, Sendable {
        public let iteration: Int
        public let coldBaseline: Batch
        public let cacheConstruction: CacheConstruction
        public let warm: Batch
        /// Includes the cache-construction row plus every warm row. This is
        /// the denominator that prevents the compulsory cold miss from being
        /// silently removed from hit/miss rates.
        public let cacheAccountingIncludingConstruction: CacheAccounting
        public let equality: [Equality]
    }

    public struct Summary: Codable, Sendable {
        public let medianColdMakespanMs: Double
        public let medianWarmMakespanMs: Double
        public let medianCacheConstructionRequestMs: Double
        public let medianSubmitToCacheReadyMs: Double?
        public let warmCacheAccounting: CacheAccounting
        public let cacheAccountingIncludingConstruction: CacheAccounting
        public let totalSavedPrefillTokens: Int
        public let totalStateBytesCloned: Int
        public let equalityComparisons: Int
        public let firstTokenEqualityRate: Double
        public let fullTokenEqualityRate: Double
    }

    public struct Scenario: Codable, Sendable {
        public let id: String
        public let kind: String
        public let batchSize: Int
        public let requestedCommonPrefixFraction: Double?
        public let constructedCommonPrefixTokens: Int?
        public let constructedCommonPrefixFraction: Double?
        public let suffixIDs: [String]
        public let samples: [Sample]
        public let summary: Summary
    }

    public let schemaVersion: Int
    public let benchmark: String
    public let createdAtUTC: String
    public let model: Model
    public let corpus: Corpus
    public let hardware: Hardware
    public let engine: Engine
    public let configuration: Configuration
    public let scenarios: [Scenario]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        benchmark: String = benchmarkName,
        createdAtUTC: String,
        model: Model,
        corpus: Corpus,
        hardware: Hardware,
        engine: Engine,
        configuration: Configuration,
        scenarios: [Scenario]
    ) {
        self.schemaVersion = schemaVersion
        self.benchmark = benchmark
        self.createdAtUTC = createdAtUTC
        self.model = model
        self.corpus = corpus
        self.hardware = hardware
        self.engine = engine
        self.configuration = configuration
        self.scenarios = scenarios
    }

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw QwenPrefixReportError.unsupportedSchemaVersion(schemaVersion)
        }
        guard benchmark == Self.benchmarkName else {
            throw QwenPrefixReportError.wrongBenchmark(benchmark)
        }
        guard isSHA256(model.artifactSHA256), isSHA256(corpus.sha256) else {
            throw QwenPrefixReportError.invalidDigest
        }
        let validCacheContract =
            (engine.prefixCacheImplementation == "PrefixCacheV2"
                && engine.prefixCacheMatchPolicy == "whole-block-prefix"
                && (engine.cacheBlockTokens ?? 0) > 0)
            || (engine.prefixCacheImplementation == "ExactPrefixCacheV2"
                && engine.prefixCacheMatchPolicy == "longest-exact-block-prefix"
                && (engine.cacheBlockTokens ?? 0) > 0
                && (engine.prefixCacheBudgetBytes ?? 0) > 0)
        let validCapabilityContract =
            engine.capabilitySupported
            ? engine.capabilityStrategy != nil
                && engine.capabilityUnsupportedReason == nil
            : engine.capabilityStrategy == nil
        guard engine.factory == "EngineV2Factory.makeProductionBuild", // pragma: allowlist secret
              engine.instanceCount == 1,
              engine.maxConcurrentRequests == 4,
              engine.kvBytesCapacity > 0,
              engine.prefixCacheRequested,
              validCacheContract,
              validCapabilityContract,
              engine.kvBackend.resolved.count == 1,
              !engine.cacheSaltScope.isEmpty,
              engine.replayBoundTokens >= 0,
              engine.warmupPerformed,
              configuration.promptTokens >= 2,
              configuration.decodeTokens >= 2,
              configuration.iterations > 0,
              configuration.identicalBatchSizes == QwenPrefixPromptBuilder.batchSizes,
              configuration.commonPrefixFractions
                == QwenPrefixPromptBuilder.commonPrefixFractions,
              configuration.commonPrefixBatchSize
                == QwenPrefixPromptBuilder.commonPrefixBatchSize,
              configuration.donationTimeoutMs > 0,
              configuration.generationPolicy
                == "greedy-fixed-length-no-stop-tokens"
        else {
            throw QwenPrefixReportError.invalidEngineContract
        }

        let expectedIDs = Set(
            QwenPrefixPromptBuilder.batchSizes.map { "identical-b\($0)" }
                + QwenPrefixPromptBuilder.commonPrefixFractions.map {
                    "common-prefix-\(Int($0 * 100))"
                })
        guard Set(scenarios.map(\.id)) == expectedIDs,
              scenarios.count == expectedIDs.count
        else {
            throw QwenPrefixReportError.invalidScenarioSet
        }
        for scenario in scenarios {
            try validate(scenario)
        }
        let requestIDs = scenarios.flatMap(\.samples).flatMap {
            $0.coldBaseline.rows.map(\.requestID)
                + [$0.cacheConstruction.row.requestID]
                + $0.warm.rows.map(\.requestID)
        }
        guard Set(requestIDs).count == requestIDs.count else {
            throw QwenPrefixReportError.duplicateRequestID
        }
    }

    private func validate(_ scenario: Scenario) throws {
        let identicalShapes = [
            "identical-b1": 1,
            "identical-b2": 2,
            "identical-b4": 4,
        ]
        let commonShapes = [
            "common-prefix-25": 0.25,
            "common-prefix-50": 0.50,
            "common-prefix-75": 0.75,
            "common-prefix-90": 0.90,
        ]
        guard [1, 2, 4].contains(scenario.batchSize),
              scenario.samples.count == configuration.iterations,
              scenario.suffixIDs.count == scenario.batchSize,
              scenario.samples.map(\.iteration).sorted()
                == Array(1 ... configuration.iterations)
        else {
            throw QwenPrefixReportError.invalidScenario(scenario.id)
        }
        if scenario.kind == QwenPrefixScenarioKind.commonPrefix.rawValue {
            guard scenario.batchSize == configuration.commonPrefixBatchSize,
                  let fraction = scenario.requestedCommonPrefixFraction,
                  commonShapes[scenario.id] == fraction,
                  configuration.commonPrefixFractions.contains(fraction),
                  let commonTokens = scenario.constructedCommonPrefixTokens,
                  commonTokens == Int(
                      (Double(configuration.promptTokens) * fraction).rounded(.down)),
                  scenario.constructedCommonPrefixFraction
                    == Double(commonTokens) / Double(configuration.promptTokens),
                  Set(scenario.suffixIDs).count == scenario.suffixIDs.count
            else {
                throw QwenPrefixReportError.invalidScenario(scenario.id)
            }
        } else {
            guard scenario.kind == QwenPrefixScenarioKind.identical.rawValue,
                  identicalShapes[scenario.id] == scenario.batchSize,
                  scenario.requestedCommonPrefixFraction == 1,
                  scenario.constructedCommonPrefixTokens == configuration.promptTokens,
                  scenario.constructedCommonPrefixFraction == 1,
                  Set(scenario.suffixIDs).count == 1
            else {
                throw QwenPrefixReportError.invalidScenario(scenario.id)
            }
        }

        for sample in scenario.samples {
            guard sample.coldBaseline.rows.count == scenario.batchSize,
                  sample.warm.rows.count == scenario.batchSize,
                  sample.equality.count == scenario.batchSize,
                  !sample.coldBaseline.prefixCacheEnabled,
                  sample.warm.prefixCacheEnabled,
                  sample.cacheConstruction.row.row == 0
            else {
                throw QwenPrefixReportError.invalidSample(
                    scenario: scenario.id,
                    iteration: sample.iteration)
            }
            try validate(
                sample.coldBaseline,
                expectedRows: scenario.batchSize,
                scenario: scenario.id,
                iteration: sample.iteration)
            try validate(
                sample.warm,
                expectedRows: scenario.batchSize,
                scenario: scenario.id,
                iteration: sample.iteration)
            guard sample.coldBaseline.rows.allSatisfy({
                $0.cacheOutcome == "disabled" || $0.cacheOutcome == "skipped_policy"
            }) else {
                throw QwenPrefixReportError.invalidSample(
                    scenario: scenario.id,
                    iteration: sample.iteration)
            }
            if scenario.kind == QwenPrefixScenarioKind.commonPrefix.rawValue,
                let commonTokens = scenario.constructedCommonPrefixTokens
            {
                guard sample.warm.rows.allSatisfy({
                    $0.cacheOutcome != "hit" || $0.matchedTokens <= commonTokens
                }) else {
                    throw QwenPrefixReportError.invalidSample(
                        scenario: scenario.id,
                        iteration: sample.iteration)
                }
            }
            let cacheRows = [sample.cacheConstruction.row] + sample.warm.rows
            guard sample.cacheAccountingIncludingConstruction
                    == CacheAccounting(rows: cacheRows),
                  sample.coldBaseline.cacheAccounting
                    == CacheAccounting(rows: sample.coldBaseline.rows),
                  sample.warm.cacheAccounting
                    == CacheAccounting(rows: sample.warm.rows)
            else {
                throw QwenPrefixReportError.invalidSample(
                    scenario: scenario.id,
                    iteration: sample.iteration)
            }
            if sample.cacheConstruction.donationObserved {
                guard sample.cacheConstruction.submitToCacheReadyMs?.isFinite == true,
                      (sample.cacheConstruction.submitToCacheReadyMs ?? -1) >= 0,
                      sample.cacheConstruction.cacheReadyMinusTerminalMs?.isFinite == true,
                      sample.cacheConstruction.cacheBytesAfterReady > 0
                else {
                    throw QwenPrefixReportError.invalidSample(
                        scenario: scenario.id,
                        iteration: sample.iteration)
                }
            } else {
                guard sample.cacheConstruction.submitToCacheReadyMs == nil,
                      sample.cacheConstruction.cacheReadyMinusTerminalMs == nil,
                      sample.cacheConstruction.cacheBytesAfterReady == 0
                else {
                    throw QwenPrefixReportError.invalidSample(
                        scenario: scenario.id,
                        iteration: sample.iteration)
                }
            }
            let expectedRows = Array(0 ..< scenario.batchSize)
            guard sample.coldBaseline.rows.map(\.row) == expectedRows,
                  sample.warm.rows.map(\.row) == expectedRows,
                  sample.equality.map(\.row) == expectedRows
            else {
                throw QwenPrefixReportError.invalidSample(
                    scenario: scenario.id,
                    iteration: sample.iteration)
            }
            let requestIDs = sample.coldBaseline.rows.map(\.requestID)
                + [sample.cacheConstruction.row.requestID]
                + sample.warm.rows.map(\.requestID)
            guard Set(requestIDs).count == requestIDs.count else {
                throw QwenPrefixReportError.invalidSample(
                    scenario: scenario.id,
                    iteration: sample.iteration)
            }
            for row in sample.coldBaseline.rows + [sample.cacheConstruction.row]
                + sample.warm.rows
            {
                try validate(row, scenario: scenario.id, iteration: sample.iteration)
            }
            for ((cold, warm), equality) in zip(
                zip(sample.coldBaseline.rows, sample.warm.rows),
                sample.equality)
            {
                guard equality.row == cold.row,
                      equality.firstTokenEqual
                        == (cold.firstTokenID == warm.firstTokenID),
                      equality.fullTokensEqual == (cold.tokenIDs == warm.tokenIDs),
                      equality.finishReasonEqual
                        == (cold.finishReason == warm.finishReason)
                else {
                    throw QwenPrefixReportError.invalidSample(
                        scenario: scenario.id,
                        iteration: sample.iteration)
                }
            }
        }
        try validateSummary(scenario)
    }

    private func validate(
        _ batch: Batch,
        expectedRows: Int,
        scenario: String,
        iteration: Int
    ) throws {
        let accounting = CacheAccounting(rows: batch.rows)
        guard batch.rows.count == expectedRows,
              batch.makespanMs.isFinite,
              batch.makespanMs >= 0,
              batch.firstTokenMakespanMs.isFinite,
              batch.firstTokenMakespanMs >= 0,
              batch.firstTokenMakespanMs <= batch.makespanMs,
              batch.cacheAccounting == accounting,
              batch.totalSavedPrefillTokens
                == saturatingSum(batch.rows.map(\.savedPrefillTokens)),
              batch.totalStateBytesCloned
                == saturatingSum(batch.rows.map(\.stateBytesCloned))
        else {
            throw QwenPrefixReportError.invalidSample(
                scenario: scenario,
                iteration: iteration)
        }
    }

    private func validateSummary(_ scenario: Scenario) throws {
        let samples = scenario.samples
        let warmRows = samples.flatMap(\.warm.rows)
        let cacheRows = samples.flatMap {
            [$0.cacheConstruction.row] + $0.warm.rows
        }
        let equalities = samples.flatMap(\.equality)
        let readyTimes = samples.compactMap(\.cacheConstruction.submitToCacheReadyMs)
        let expectedReady = readyTimes.isEmpty ? nil : median(readyTimes)
        guard scenario.summary.medianColdMakespanMs
                == median(samples.map(\.coldBaseline.makespanMs)),
              scenario.summary.medianWarmMakespanMs
                == median(samples.map(\.warm.makespanMs)),
              scenario.summary.medianCacheConstructionRequestMs
                == median(samples.map(\.cacheConstruction.row.totalTimeMs)),
              scenario.summary.medianSubmitToCacheReadyMs == expectedReady,
              scenario.summary.warmCacheAccounting == CacheAccounting(rows: warmRows),
              scenario.summary.cacheAccountingIncludingConstruction
                == CacheAccounting(rows: cacheRows),
              scenario.summary.totalSavedPrefillTokens
                == saturatingSum(warmRows.map(\.savedPrefillTokens)),
              scenario.summary.totalStateBytesCloned
                == saturatingSum(warmRows.map(\.stateBytesCloned)),
              scenario.summary.equalityComparisons == equalities.count,
              scenario.summary.firstTokenEqualityRate
                == equalityRate(equalities.map(\.firstTokenEqual)),
              scenario.summary.fullTokenEqualityRate
                == equalityRate(equalities.map(\.fullTokensEqual))
        else {
            throw QwenPrefixReportError.invalidScenario(scenario.id)
        }
    }

    private func validate(
        _ row: Row,
        scenario: String,
        iteration: Int
    ) throws {
        let (accountedHitTokens, hitTokenOverflow) =
            row.savedPrefillTokens.addingReportingOverflow(row.replayTokens)
        let validOutcomes: Set<String> = [
            "disabled", "skipped_policy", "miss", "hit",
            "skipped_capacity", "adoption_failed",
        ]
        let validExactHit =
            engine.prefixCacheMatchPolicy != "longest-exact-block-prefix"
            || row.cacheOutcome != "hit"
            || (row.savedPrefillTokens == row.matchedTokens
                && row.replayTokens == 0
                && row.reuseStrategy == "direct")
        let validMatchAlignment = engine.cacheBlockTokens.map { blockTokens in
            row.matchedTokens == row.promptTokens
                || row.matchedTokens % blockTokens == 0
        } ?? true
        guard row.row >= 0,
              row.promptTokens == configuration.promptTokens,
              row.ttftMs.isFinite,
              row.ttftMs >= 0,
              row.totalTimeMs.isFinite,
              row.totalTimeMs >= row.ttftMs,
              row.tokenIDs.count == configuration.decodeTokens,
              row.tokenIDs.first == row.firstTokenID,
              row.firstTokenChecksum
                == ArrivalPrefillAccounting.tokenChecksum([row.firstTokenID]),
              row.tokenChecksum
                == ArrivalPrefillAccounting.tokenChecksum(row.tokenIDs),
              row.finishReason == "length",
              validOutcomes.contains(row.cacheOutcome),
              row.matchedTokens >= 0,
              row.matchedTokens <= row.promptTokens,
              validMatchAlignment,
              row.savedPrefillTokens >= 0,
              row.replayTokens >= 0,
              row.replayBoundarySplits >= 0,
              row.stateBytesCloned >= 0,
              validExactHit,
              (row.cacheOutcome == "hit"
                ? row.matchedTokens > 0
                    && row.savedPrefillTokens > 0
                    && !hitTokenOverflow
                    && accountedHitTokens == row.matchedTokens
                    && row.reuseStrategy != nil
                    && row.stateBytesCloned > 0
                : row.savedPrefillTokens == 0
                    && row.replayTokens == 0
                    && row.reuseStrategy == nil
                    && row.replayBoundarySplits == 0
                    && row.stateBytesCloned == 0)
        else {
            throw QwenPrefixReportError.invalidRow(
                scenario: scenario,
                iteration: iteration,
                row: row.row)
        }
    }

    private func isSHA256(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 64 && bytes.allSatisfy {
            (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0)
        }
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    private func equalityRate(_ values: [Bool]) -> Double {
        guard !values.isEmpty else { return 0 }
        return Double(values.count(where: { $0 })) / Double(values.count)
    }

    private func saturatingSum(_ values: [Int]) -> Int {
        values.reduce(0) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(value)
            return overflow ? Int.max : sum
        }
    }
}

public enum QwenPrefixReportError: Error, Equatable, CustomStringConvertible {
    case unsupportedSchemaVersion(Int)
    case wrongBenchmark(String)
    case invalidDigest
    case invalidEngineContract
    case invalidScenarioSet
    case invalidScenario(String)
    case invalidSample(scenario: String, iteration: Int)
    case invalidRow(scenario: String, iteration: Int, row: Int)
    case duplicateRequestID

    public var description: String {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "Qwen prefix report schemaVersion \(version) is unsupported"
        case .wrongBenchmark(let name):
            return "Qwen prefix report benchmark '\(name)' is not "
                + "'\(QwenPrefixReuseReport.benchmarkName)'"
        case .invalidDigest:
            return "Qwen prefix report contains an invalid model or corpus SHA-256"
        case .invalidEngineContract:
            return "Qwen prefix report does not describe one serving CBv2 engine"
        case .invalidScenarioSet:
            return "Qwen prefix report does not contain the required B1/B2/B4 and "
                + "25/50/75/90 percent scenarios"
        case .invalidScenario(let id):
            return "Qwen prefix report scenario '\(id)' is inconsistent"
        case .invalidSample(let scenario, let iteration):
            return "Qwen prefix report scenario '\(scenario)' iteration \(iteration) "
                + "is inconsistent"
        case .invalidRow(let scenario, let iteration, let row):
            return "Qwen prefix report scenario '\(scenario)' iteration \(iteration) "
                + "row \(row) is inconsistent"
        case .duplicateRequestID:
            return "Qwen prefix report reuses a CBv2 request identifier"
        }
    }
}
