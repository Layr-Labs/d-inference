import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderBenchmark

@Suite("Qwen exact-prefix benchmark")
struct QwenPrefixReuseTests {
    @Test
    func committedCorpusAndSchemasAreValid() throws {
        let root = repositoryRoot()
        let directory = root.appendingPathComponent("Benchmarks/QwenPrefixReuse")
        let loaded = try QwenPrefixCorpusLoader.load(
            from: directory.appendingPathComponent("qwen-prefix-natural-v1.json"))

        #expect(loaded.corpus.id == "darkbloom-qwen-prefix-natural")
        #expect(loaded.corpus.license == "CC0-1.0")
        #expect(loaded.corpus.suffixes.count >= 5)
        #expect(Set(loaded.corpus.suffixes.map(\.id)).count == loaded.corpus.suffixes.count)
        #expect(loaded.sha256.count == 64)

        for name in [
            "qwen-prefix-corpus.schema.json",
            "qwen-prefix-report.schema.json",
        ] {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            let schema = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(schema?["$schema"] as? String
                == "https://json-schema.org/draft/2020-12/schema")
        }
    }

    @Test
    func corpusValidationRejectsDuplicatesAndUnknownFields() throws {
        let duplicate = prefixCorpus(suffixIDs: ["a", "b", "c", "d", "a"])
        #expect(throws: QwenPrefixCorpusError.duplicateSuffixID("a")) {
            try QwenPrefixCorpusLoader.validate(duplicate)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen-prefix-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("""
            {
              "schemaVersion": 1,
              "id": "corpus",
              "version": "v1",
              "description": "test",
              "license": "CC0-1.0",
              "provenance": "synthetic",
              "sharedPrefix": "shared",
              "suffixes": [
                {"id": "a", "text": "a"},
                {"id": "b", "text": "b"},
                {"id": "c", "text": "c", "txet": "typo"},
                {"id": "d", "text": "d"},
                {"id": "e", "text": "e"}
              ]
            }
            """.utf8).write(to: url)
        #expect(throws: QwenPrefixCorpusError.unknownFields(
            path: "$.suffixes[2]", fields: ["txet"]))
        {
            _ = try QwenPrefixCorpusLoader.load(from: url)
        }
    }

    @Test
    func promptBuilderConstructsRequiredExactTokenBoundaries() throws {
        let scenarios = try QwenPrefixPromptBuilder.prepare(
            corpus: prefixCorpus(suffixIDs: ["a", "b", "c", "d", "e"]),
            promptTokens: 40,
            tokenizer: PrefixTokenizer())

        #expect(scenarios.map(\.id) == [
            "identical-b1",
            "identical-b2",
            "identical-b4",
            "common-prefix-25",
            "common-prefix-50",
            "common-prefix-75",
            "common-prefix-90",
        ])
        #expect(scenarios.prefix(3).map(\.batchSize) == [1, 2, 4])
        #expect(scenarios.prefix(3).allSatisfy {
            Set($0.prompts).count == 1 && $0.prompts[0] == $0.donorPrompt
        })

        let expectedCommon = [10, 20, 30, 36]
        for (scenario, expected) in zip(scenarios.dropFirst(3), expectedCommon) {
            #expect(scenario.batchSize == 4)
            #expect(scenario.constructedCommonPrefixTokens == expected)
            #expect(Set(scenario.suffixIDs).count == 4)
            #expect(Set(scenario.prompts).count == 4)
            #expect(scenario.prompts.allSatisfy {
                QwenPrefixPromptBuilder.commonPrefixLength(
                    scenario.donorPrompt, $0) == expected
            })
        }
    }

    @Test
    func engineRunnerUsesOneEngineAndPreservesCacheControls() async throws {
        let cache = QwenPrefixTrackingCache(config: .init(blockSize: 2))
        let kind = CBv2LayerKind(
            attention: .full,
            headDim: 2,
            kvHeads: 1,
            queryHeads: 1)
        cache.donate(
            requestID: CBv2RequestID(800),
            tokens: [1, 2, 7, 8],
            snapshots: [(
                keys: MLXArray.zeros([1, 1, 4, 2]),
                values: MLXArray.ones([1, 1, 4, 2]),
                offset: 4
            )],
            layerKinds: [kind],
            cacheSalt: "scope/one")
        let engine = PrefixScriptedEngine(cache: cache, layerKind: kind)
        let prompts = [[1, 2, 3], [1, 2, 4], [1, 2, 5], [1, 2, 6]]

        let batch = try await QwenPrefixEngineRunner.run(
            engine: engine,
            cache: cache,
            prompts: prompts,
            decodeTokens: 2,
            requestIDBase: 900,
            prefixCacheEnabled: true,
            cacheSalt: "scope/one")

        #expect(batch.rows.count == 4)
        #expect(batch.rows.map(\.row) == [0, 1, 2, 3])
        #expect(batch.rows.allSatisfy { $0.usage.prefixCacheOutcome == .hit })
        #expect(batch.rows.allSatisfy { $0.usage.prefixCacheMatchedTokens == 2 })
        #expect(batch.rows.allSatisfy { $0.usage.prefixCachePrefillTokensSaved == 2 })
        #expect(batch.rows.allSatisfy { $0.stateBytesCloned > 0 })
        #expect(batch.rows.allSatisfy { $0.tokenIDs.count == 2 })

        let submitted = engine.submitted.sorted { $0.id.raw < $1.id.raw }
        #expect(submitted.map(\.id.raw) == [900, 901, 902, 903])
        #expect(submitted.map(\.promptTokens) == prompts)
        #expect(submitted.allSatisfy { $0.prefixCacheEnabled })
        #expect(submitted.allSatisfy { $0.cacheSalt == "scope/one" })
        #expect(submitted.allSatisfy { $0.prefixCacheReceiptID == $0.id })
        #expect(submitted.allSatisfy { $0.sampling.temperature == 0 })
        #expect(submitted.allSatisfy { $0.stopTokens.isEmpty && $0.stopStrings.isEmpty })
    }

    @Test
    func trackingCacheReportsOnlyPublishedStateBytes() throws {
        let cache = QwenPrefixTrackingCache(config: .init(
            blockSize: 2,
            materializeOnDonate: false))
        let kind = CBv2LayerKind(
            attention: .full,
            headDim: 2,
            kvHeads: 1,
            queryHeads: 1)
        let keys = MLXArray.zeros([1, 1, 4, 2])
        let values = MLXArray.ones([1, 1, 4, 2])
        let donorID = CBv2RequestID(1)

        cache.donate(
            requestID: donorID,
            tokens: [10, 11, 12, 13],
            snapshots: [(keys: keys, values: values, offset: 4)],
            layerKinds: [kind],
            cacheSalt: "scope")
        #expect(cache.donation(for: donorID) != nil)
        #expect(cache.bytesInUse == keys.nbytes + values.nbytes)

        let lookupID = CBv2RequestID(2)
        let hit = cache.lookup(
            requestID: lookupID,
            tokens: [10, 11, 99],
            layerKinds: [kind],
            cacheSalt: "scope")
        let match = try #require(hit)
        #expect(match.matched == 2)
        let entry = try #require(match.prefix[0])
        let expectedBytes = entry.keys.nbytes + entry.values.nbytes
        #expect(cache.lookupStateBytes(for: lookupID) == expectedBytes)
        cache.endAdoption(
            requestID: lookupID,
            tokens: [10, 11, 99],
            matched: match.matched,
            cacheSalt: "scope")

        let refusedID = CBv2RequestID(3)
        cache.evict(toFit: 0)
        cache.donate(
            requestID: refusedID,
            tokens: [1, 2, 3, 4],
            snapshots: [nil],
            layerKinds: [kind],
            cacheSalt: "other")
        #expect(cache.donation(for: refusedID) == nil)
        #expect(cache.bytesInUse == 0)
    }

    @Test
    func exactTrackingCacheReportsWholeHybridSnapshotBytes() async throws {
        let snapshot = try exactSnapshot(tokenCount: 3)
        #expect(snapshot.byteCount % snapshot.tokenCount != 0)
        let cache = QwenExactPrefixTrackingCache(config: .init(
            modelIdentity: "qwen-exact-test",
            maxBytes: snapshot.byteCount * 2))
        let donorID = CBv2RequestID(40)
        let tokens = [10, 11, 12]
        cache.donateExact(
            requestID: donorID,
            tokens: tokens,
            snapshot: snapshot,
            layerKinds: [exactLayerKind],
            cacheSalt: "scope")
        #expect(cache.donation(for: donorID) != nil)

        let engine = ExactPrefixScriptedEngine(
            cache: cache,
            layerKind: exactLayerKind,
            recurrentSpec: exactRecurrentSpec)
        let batch = try await QwenPrefixEngineRunner.run(
            engine: engine,
            cache: cache,
            prompts: [tokens],
            decodeTokens: 2,
            requestIDBase: 50,
            prefixCacheEnabled: true,
            cacheSalt: "scope")

        let row = try #require(batch.rows.first)
        #expect(row.usage.prefixCacheOutcome == .hit)
        #expect(row.usage.prefixCacheMatchedTokens == tokens.count)
        #expect(row.stateBytesCloned == snapshot.byteCount)
    }

    @Test
    func exactTrackingCacheReportsLongestPartialBoundaryBytes() async throws {
        let at2 = try exactSnapshot(tokenCount: 2, includesFrontier: false)
        let at4 = try exactSnapshot(tokenCount: 4, includesFrontier: false)
        let cache = QwenExactPrefixTrackingCache(config: .init(
            modelIdentity: "qwen-exact-partial-test",
            blockSize: 2,
            maxBytes: at2.byteCount + at4.byteCount))
        let prefix = [10, 11, 12, 13]
        cache.donateExact(
            requestID: CBv2RequestID(60),
            tokens: Array(prefix.prefix(2)),
            snapshot: at2,
            layerKinds: [exactLayerKind],
            cacheSalt: "scope")
        cache.donateExact(
            requestID: CBv2RequestID(60),
            tokens: prefix,
            snapshot: at4,
            layerKinds: [exactLayerKind],
            cacheSalt: "scope")

        let engine = ExactPrefixScriptedEngine(
            cache: cache,
            layerKind: exactLayerKind,
            recurrentSpec: exactRecurrentSpec)
        let batch = try await QwenPrefixEngineRunner.run(
            engine: engine,
            cache: cache,
            prompts: [prefix + [99]],
            decodeTokens: 2,
            requestIDBase: 70,
            prefixCacheEnabled: true,
            cacheSalt: "scope")

        let row = try #require(batch.rows.first)
        #expect(row.usage.prefixCacheOutcome == .hit)
        #expect(row.usage.prefixCacheMatchedTokens == prefix.count)
        #expect(row.stateBytesCloned == at4.byteCount)
    }

    @Test
    func reportRoundTripsAndKeepsConstructionMissInRates() throws {
        let report = makeReport()
        try report.validate()

        for scenario in report.scenarios {
            let sample = try #require(scenario.samples.first)
            #expect(sample.cacheConstruction.row.cacheOutcome == "miss")
            #expect(sample.cacheAccountingIncludingConstruction.requestCount
                == scenario.batchSize + 1)
            #expect(sample.cacheAccountingIncludingConstruction.missCount == 1)
            #expect(sample.cacheAccountingIncludingConstruction.hitCount
                == scenario.batchSize)
            #expect(sample.cacheAccountingIncludingConstruction.hitRate
                == Double(scenario.batchSize) / Double(scenario.batchSize + 1))
        }

        let data = Data(try report.jsonString().utf8)
        let decoded = try JSONDecoder().decode(QwenPrefixReuseReport.self, from: data)
        try decoded.validate()

        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        var scenarios = try #require(object["scenarios"] as? [[String: Any]])
        var samples = try #require(scenarios[0]["samples"] as? [[String: Any]])
        var accounting = try #require(
            samples[0]["cacheAccountingIncludingConstruction"] as? [String: Any])
        accounting["missCount"] = 0
        samples[0]["cacheAccountingIncludingConstruction"] = accounting
        scenarios[0]["samples"] = samples
        object["scenarios"] = scenarios
        let tampered = try JSONDecoder().decode(
            QwenPrefixReuseReport.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: QwenPrefixReportError.invalidSample(
            scenario: "identical-b1", iteration: 1))
        {
            try tampered.validate()
        }
    }

    @Test
    func exactReportAcceptsFullAndLongestBlockAlignedPartialHits() throws {
        let report = makeReport(exactCache: true)
        try report.validate()

        for scenario in report.scenarios {
            let sample = try #require(scenario.samples.first)
            let warmRows = sample.warm.rows
            #expect(sample.equality.allSatisfy { $0.fullTokensEqual })
            if scenario.kind == "identical" {
                #expect(warmRows.allSatisfy {
                    $0.cacheOutcome == "hit"
                        && $0.matchedTokens == $0.promptTokens
                        && $0.savedPrefillTokens == $0.promptTokens
                })
            } else {
                let expected = try #require(scenario.constructedCommonPrefixTokens)
                let expectedMatched = (expected / 256) * 256
                #expect(warmRows.allSatisfy {
                    $0.cacheOutcome == "hit"
                        && $0.matchedTokens == expectedMatched
                        && $0.savedPrefillTokens == expectedMatched
                })
                if (scenario.requestedCommonPrefixFraction ?? 0) >= 0.75 {
                    #expect(warmRows.allSatisfy {
                        Double($0.matchedTokens) / Double($0.promptTokens) >= 0.60
                    })
                }
            }
        }
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func prefixCorpus(suffixIDs: [String]) -> QwenPrefixCorpus {
        QwenPrefixCorpus(
            id: "test-prefix",
            version: "v1",
            description: "Synthetic prefix test",
            license: "CC0-1.0",
            provenance: "Unit test",
            sharedPrefix: "shared",
            suffixes: suffixIDs.map {
                .init(id: $0, text: "suffix-\($0)")
            })
    }

    private var exactLayerKind: CBv2LayerKind {
        CBv2LayerKind(
            attention: .full,
            headDim: 1,
            kvHeads: 1,
            queryHeads: 1)
    }

    private var exactRecurrentSpec: CBv2RecurrentStateSpec {
        CBv2RecurrentStateSpec(layers: [
            CBv2RecurrentLayerStateSpec(
                modelLayerIndex: 0,
                convShape: [1, 1, 1],
                convDType: .float32,
                ssmShape: [1, 1, 1, 1],
                ssmDType: .float32)
        ])
    }

    private func exactSnapshot(
        tokenCount: Int,
        includesFrontier: Bool = true
    ) throws -> CBv2ExactPrefixSnapshot {
        let attention = try CBv2ExactAttentionSnapshot(
            keys: MLXArray.zeros([1, 1, tokenCount, 1]),
            values: MLXArray.ones([1, 1, tokenCount, 1]),
            offset: tokenCount,
            detaching: true)
        let recurrent = try CBv2RecurrentStateSnapshot(
            spec: exactRecurrentSpec,
            layers: [
                0: CBv2RecurrentLayerState(
                    conv: MLXArray.zeros([1, 1, 1]),
                    ssm: MLXArray.ones([1, 1, 1, 1]))
            ],
            detaching: true)
        let snapshot = try CBv2ExactPrefixSnapshot(
            tokenCount: tokenCount,
            modelPosition: tokenCount,
            attention: [attention],
            recurrentState: recurrent,
            frontierLogits:
                includesFrontier ? MLXArray([Float(1), Float(-1)]) : nil,
            detachingFrontier: true)
        eval(snapshot.evaluationArrays)
        return snapshot
    }

    private func makeReport(exactCache: Bool = false) -> QwenPrefixReuseReport {
        let promptTokens = 1_024
        let decodeTokens = 2
        let shapes: [(String, String, Int, Double)] = [
            ("identical-b1", "identical", 1, 1),
            ("identical-b2", "identical", 2, 1),
            ("identical-b4", "identical", 4, 1),
            ("common-prefix-25", "common-prefix", 4, 0.25),
            ("common-prefix-50", "common-prefix", 4, 0.50),
            ("common-prefix-75", "common-prefix", 4, 0.75),
            ("common-prefix-90", "common-prefix", 4, 0.90),
        ]
        let scenarios = shapes.enumerated().map { scenarioIndex, shape in
            let commonTokens = Int((Double(promptTokens) * shape.3).rounded(.down))
            let matchedTokens = min(
                commonTokens,
                ((promptTokens - 1) / 256) * 256)
            let warmHit = true
            let coldRows = (0 ..< shape.2).map {
                reportRow(
                    row: $0,
                    requestID: UInt64(1_000 + scenarioIndex * 100 + $0),
                    outcome: "disabled",
                    matched: 0,
                    saved: 0)
            }
            let construction = reportRow(
                row: 0,
                requestID: UInt64(2_000 + scenarioIndex * 100),
                outcome: "miss",
                matched: 0,
                saved: 0)
            let warmRows = (0 ..< shape.2).map {
                reportRow(
                    row: $0,
                    requestID: UInt64(3_000 + scenarioIndex * 100 + $0),
                    outcome: warmHit ? "hit" : "miss",
                    matched:
                        warmHit
                        ? (exactCache && shape.1 == "identical"
                            ? promptTokens : matchedTokens)
                        : 0,
                    saved:
                        warmHit
                        ? (exactCache && shape.1 == "identical"
                            ? promptTokens : matchedTokens)
                        : 0,
                    stateBytes:
                        warmHit
                        ? (exactCache
                            ? (shape.1 == "identical" ? promptTokens : matchedTokens) * 16 + 7
                            : matchedTokens * 16)
                        : 0)
            }
            let cold = reportBatch(rows: coldRows, enabled: false)
            let warm = reportBatch(rows: warmRows, enabled: true)
            let cacheRows = [construction] + warmRows
            let equalities = (0 ..< shape.2).map {
                QwenPrefixReuseReport.Equality(
                    row: $0,
                    firstTokenEqual: true,
                    fullTokensEqual: true,
                    finishReasonEqual: true)
            }
            let sample = QwenPrefixReuseReport.Sample(
                iteration: 1,
                coldBaseline: cold,
                cacheConstruction: .init(
                    row: construction,
                    donationObserved: true,
                    submitToCacheReadyMs: 12,
                    cacheReadyMinusTerminalMs: -1,
                    cacheBytesAfterReady: commonTokens * 16),
                warm: warm,
                cacheAccountingIncludingConstruction: .init(rows: cacheRows),
                equality: equalities)
            let suffixes = shape.1 == "common-prefix"
                ? (0 ..< shape.2).map { "suffix-\($0)" }
                : Array(repeating: "same", count: shape.2)
            return QwenPrefixReuseReport.Scenario(
                id: shape.0,
                kind: shape.1,
                batchSize: shape.2,
                requestedCommonPrefixFraction: shape.3,
                constructedCommonPrefixTokens: commonTokens,
                constructedCommonPrefixFraction:
                    Double(commonTokens) / Double(promptTokens),
                suffixIDs: suffixes,
                samples: [sample],
                summary: .init(
                    medianColdMakespanMs: cold.makespanMs,
                    medianWarmMakespanMs: warm.makespanMs,
                    medianCacheConstructionRequestMs: construction.totalTimeMs,
                    medianSubmitToCacheReadyMs: 12,
                    warmCacheAccounting: .init(rows: warmRows),
                    cacheAccountingIncludingConstruction: .init(rows: cacheRows),
                    totalSavedPrefillTokens:
                        warmRows.reduce(0) { $0 + $1.savedPrefillTokens },
                    totalStateBytesCloned:
                        warmRows.reduce(0) { $0 + $1.stateBytesCloned },
                    equalityComparisons: equalities.count,
                    firstTokenEqualityRate: 1,
                    fullTokenEqualityRate: 1))
        }
        return QwenPrefixReuseReport(
            createdAtUTC: "2026-08-24T00:00:00.000Z",
            model: .init(
                id: "qwen-test",
                path: "/models/qwen-test",
                artifactSHA256: String(repeating: "a", count: 64),
                modelType: "qwen3_5_moe",
                architecture: "Qwen35ForConditionalGeneration",
                maximumContextTokens: 32_768),
            corpus: .init(
                id: "test-prefix",
                version: "v1",
                path: "/prefix.json",
                sha256: String(repeating: "b", count: 64),
                license: "CC0-1.0",
                provenance: "synthetic",
                suffixCount: 5),
            hardware: .init(
                machineModel: "Mac15,9",
                chipName: "Apple M3 Max",
                memoryGB: 64,
                gpuCores: 40),
            engine: .init(
                factory: "EngineV2Factory.makeProductionBuild", // pragma: allowlist secret
                instanceCount: 1,
                maxConcurrentRequests: 4,
                kvBackend: BenchmarkKVBackend(
                    selection: "contiguous",
                    resolved: ["contiguous"]),
                kvBytesCapacity: 4 * 1024 * 1024 * 1024,
                prefixCacheImplementation:
                    exactCache ? "ExactPrefixCacheV2" : "PrefixCacheV2",
                prefixCacheMatchPolicy:
                    exactCache ? "longest-exact-block-prefix" : "whole-block-prefix",
                prefixCacheRequested: true,
                prefixCacheBudgetBytes: exactCache ? 1_024 * 1_024 * 1_024 : nil,
                cacheBlockTokens: 256,
                cacheSaltScope: "unique per scenario iteration",
                capabilitySupported: true,
                capabilityStrategy: "direct",
                capabilityUnsupportedReason: nil,
                replayBoundTokens: 0,
                warmupPerformed: true,
                policyEnvironment: [:]),
            configuration: .init(
                promptTokens: promptTokens,
                decodeTokens: decodeTokens,
                iterations: 1,
                identicalBatchSizes: [1, 2, 4],
                commonPrefixFractions: [0.25, 0.50, 0.75, 0.90],
                commonPrefixBatchSize: 4,
                donationTimeoutMs: 10_000,
                generationPolicy: "greedy-fixed-length-no-stop-tokens"),
            scenarios: scenarios)
    }

    private func reportRow(
        row: Int,
        requestID: UInt64,
        outcome: String,
        matched: Int,
        saved: Int,
        stateBytes: Int = 0
    ) -> QwenPrefixReuseReport.Row {
        let tokens = [41 + row, 99]
        return QwenPrefixReuseReport.Row(
            row: row,
            requestID: requestID,
            promptTokens: 1_024,
            ttftMs: 4,
            totalTimeMs: 6,
            firstTokenID: tokens[0],
            firstTokenChecksum: ArrivalPrefillAccounting.tokenChecksum([tokens[0]]),
            tokenIDs: tokens,
            tokenChecksum: ArrivalPrefillAccounting.tokenChecksum(tokens),
            finishReason: "length",
            cacheOutcome: outcome,
            matchedTokens: matched,
            savedPrefillTokens: saved,
            replayTokens: 0,
            reuseStrategy: outcome == "hit" ? "direct" : nil,
            replayBoundarySplits: 0,
            stateBytesCloned: stateBytes)
    }

    private func reportBatch(
        rows: [QwenPrefixReuseReport.Row],
        enabled: Bool
    ) -> QwenPrefixReuseReport.Batch {
        QwenPrefixReuseReport.Batch(
            prefixCacheEnabled: enabled,
            makespanMs: 8,
            firstTokenMakespanMs: 5,
            rows: rows,
            cacheAccounting: .init(rows: rows),
            totalSavedPrefillTokens: rows.reduce(0) { $0 + $1.savedPrefillTokens },
            totalStateBytesCloned: rows.reduce(0) { $0 + $1.stateBytesCloned })
    }
}

private final class PrefixTokenizer: Tokenizer, @unchecked Sendable {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        if text == "shared" { return [10, 11, 12, 13] }
        switch text {
        case "suffix-a": return [101, 1, 2]
        case "suffix-b": return [102, 2, 3]
        case "suffix-c": return [103, 3, 4]
        case "suffix-d": return [104, 4, 5]
        case "suffix-e": return [105, 5, 6]
        default: return [999]
        }
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "\(tokenIds)" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        [0]
    }
}

private final class PrefixScriptedEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private let cache: QwenPrefixTrackingCache
    private let layerKind: CBv2LayerKind
    private var submittedRequests: [CBv2Request] = []

    init(cache: QwenPrefixTrackingCache, layerKind: CBv2LayerKind) {
        self.cache = cache
        self.layerKind = layerKind
    }

    var submitted: [CBv2Request] {
        lock.withLock { submittedRequests }
    }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        lock.withLock { submittedRequests.append(request) }
        let hit = cache.lookup(
            requestID: request.prefixCacheReceiptID ?? request.id,
            tokens: request.promptTokens,
            layerKinds: [layerKind],
            cacheSalt: request.cacheSalt)
        if let hit {
            cache.endAdoption(
                requestID: request.prefixCacheReceiptID ?? request.id,
                tokens: request.promptTokens,
                matched: hit.matched,
                cacheSalt: request.cacheSalt)
        }
        let tokens = [Int(request.id.raw), Int(request.id.raw) + 1]
        return AsyncStream { continuation in
            continuation.yield(.delta(text: "", tokens: [tokens[0]], logprobs: nil))
            continuation.yield(.delta(text: "", tokens: [tokens[1]], logprobs: nil))
            continuation.yield(.finished(
                reason: .length,
                usage: CBv2Usage(
                    promptTokens: request.promptTokens.count,
                    completionTokens: tokens.count,
                    prefixCacheHitTokens: 2,
                    prefixCacheOutcome: .hit,
                    prefixCacheMatchedTokens: 2,
                    prefixCachePrefillTokensSaved: 2,
                    prefixCacheStrategy: .direct)))
            continuation.finish()
        }
    }

    func cancel(_: CBv2RequestID) {}

    func capacity() -> CBv2CapacitySnapshot {
        CBv2CapacitySnapshot(
            activeRequests: 0,
            waitingRequests: 0,
            kvBytesInUse: 0,
            kvBytesCapacity: 1 << 20,
            activeTokens: 0)
    }

    func shutdown() async {}
}

private final class ExactPrefixScriptedEngine: CBv2Engine, @unchecked Sendable {
    private let cache: QwenExactPrefixTrackingCache
    private let layerKind: CBv2LayerKind
    private let recurrentSpec: CBv2RecurrentStateSpec

    init(
        cache: QwenExactPrefixTrackingCache,
        layerKind: CBv2LayerKind,
        recurrentSpec: CBv2RecurrentStateSpec
    ) {
        self.cache = cache
        self.layerKind = layerKind
        self.recurrentSpec = recurrentSpec
    }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let receiptID = request.prefixCacheReceiptID ?? request.id
        let hit = cache.lookupExact(
            requestID: receiptID,
            tokens: request.promptTokens,
            layerKinds: [layerKind],
            recurrentStateSpec: recurrentSpec,
            cacheSalt: request.cacheSalt)
        if let hit {
            cache.endAdoption(
                requestID: receiptID,
                tokens: request.promptTokens,
                matched: hit.tokenCount,
                cacheSalt: request.cacheSalt)
        }
        let tokens = [Int(request.id.raw), Int(request.id.raw) + 1]
        return AsyncStream { continuation in
            continuation.yield(.delta(text: "", tokens: [tokens[0]], logprobs: nil))
            continuation.yield(.delta(text: "", tokens: [tokens[1]], logprobs: nil))
            continuation.yield(.finished(
                reason: .length,
                usage: CBv2Usage(
                    promptTokens: request.promptTokens.count,
                    completionTokens: tokens.count,
                    prefixCacheHitTokens: hit?.tokenCount ?? 0,
                    prefixCacheOutcome: hit == nil ? .miss : .hit,
                    prefixCacheMatchedTokens: hit?.tokenCount ?? 0,
                    prefixCachePrefillTokensSaved: hit?.tokenCount ?? 0,
                    prefixCacheStrategy: hit == nil ? nil : .direct)))
            continuation.finish()
        }
    }

    func cancel(_: CBv2RequestID) {}

    func capacity() -> CBv2CapacitySnapshot {
        CBv2CapacitySnapshot(
            activeRequests: 0,
            waitingRequests: 0,
            kvBytesInUse: 0,
            kvBytesCapacity: 1 << 20,
            activeTokens: 0)
    }

    func shutdown() async {}
}
