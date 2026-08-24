import Foundation
import MLXLMCommon
import Testing

@testable import ProviderBenchmark

@Suite("Qwen quality corpus")
struct QwenQualityCorpusTests {
    @Test
    func committedCorpusIsValidAndDiverse() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let corpusURL = root.appendingPathComponent(
            "Benchmarks/QualityCorpus/qwen-quality-v1.json")

        let loaded = try QwenQualityCorpusLoader.load(from: corpusURL)

        #expect(loaded.corpus.id == "darkbloom-qwen-quality")
        #expect(loaded.sha256.count == 64)
        let categories = Set(loaded.corpus.cases.map(\.category))
        #expect(categories.isSuperset(of: [
            "reasoning", "code", "factual", "long-context", "instruction",
        ]))
        #expect(loaded.corpus.cases.count >= 10)
        #expect(loaded.corpus.cases.allSatisfy {
            $0.prompt.utf8.count <= QwenQualityCorpusLoader.maximumPromptBytes
        })

        for schemaName in [
            "qwen-quality-corpus.schema.json",
            "qwen-quality-report.schema.json",
        ] {
            let data = try Data(contentsOf: root.appendingPathComponent(
                "Benchmarks/QualityCorpus/\(schemaName)"))
            let schema = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(schema?["$schema"] as? String
                == "https://json-schema.org/draft/2020-12/schema")
        }
    }

    @Test
    func validationRejectsDuplicateIDsAndBlankPrompts() {
        let duplicate = corpus(cases: [
            .init(id: "same", category: "reasoning", prompt: "First"),
            .init(id: "same", category: "code", prompt: "Second"),
        ])
        #expect(throws: QwenQualityCorpusError.duplicateCaseID("same")) {
            try QwenQualityCorpusLoader.validate(duplicate)
        }

        let blank = corpus(cases: [
            .init(id: "blank", category: "reasoning", prompt: " \n "),
        ])
        #expect(throws: QwenQualityCorpusError.emptyPrompt(caseID: "blank")) {
            try QwenQualityCorpusLoader.validate(blank)
        }
    }

    @Test
    func loaderRejectsUnknownFields() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quality-corpus-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("""
            {
              "schemaVersion": 1,
              "id": "corpus",
              "version": "v1",
              "description": "test",
              "license": "CC0-1.0",
              "provenance": "synthetic",
              "cases": [
                {"id": "one", "category": "reasoning", "prompt": "Why?", "promt": "typo"}
              ]
            }
            """.utf8).write(to: url)

        #expect(throws: QwenQualityCorpusError.unknownFields(
            path: "$.cases[0]", fields: ["promt"]))
        {
            _ = try QwenQualityCorpusLoader.load(from: url)
        }
    }

    @Test
    func executorUsesChatTemplateAndRunsFixedGreedyRequestsSequentially() async throws {
        let tokenizer = QualityTokenizer()
        let input = corpus(cases: [
            .init(id: "one", category: "reasoning", prompt: "alpha"),
            .init(id: "two", category: "code", prompt: "beta"),
        ])
        let prepared = try QwenQualityCorpusExecutor.prepare(
            corpus: input,
            maximumTokens: 32,
            maximumContextTokens: 128,
            tokenizer: tokenizer)
        let engine = QualityScriptedEngine()

        let results = try await QwenQualityCorpusExecutor.execute(
            engine: engine,
            preparedCases: prepared,
            maximumTokens: 32,
            requestIDBase: 700)

        #expect(tokenizer.renderedPrompts == ["alpha", "beta"])
        #expect(results.count == 2)
        #expect(results.map(\.promptTokenCount) == [3, 3])
        #expect(results.allSatisfy { $0.generatedTokenCount == 32 })
        #expect(results.allSatisfy { $0.generatedTokenIDs.count == 32 })
        #expect(results.allSatisfy { $0.finishReason == "length" })
        #expect(results.allSatisfy {
            $0.tokenChecksum
                == ArrivalPrefillAccounting.tokenChecksum($0.generatedTokenIDs)
        })
        #expect(results.map(\.text) == ["row-700-done", "row-701-done"])

        let submitted = engine.submitted
        #expect(submitted.map(\.id.raw) == [700, 701])
        #expect(submitted.map(\.promptTokens) == prepared.map(\.promptTokens))
        #expect(submitted.allSatisfy { $0.sampling.temperature == 0 })
        #expect(submitted.allSatisfy { $0.sampling.topP == 1 })
        #expect(submitted.allSatisfy { $0.sampling.topK == 0 })
        #expect(submitted.allSatisfy { $0.maxTokens == 32 })
        #expect(submitted.allSatisfy { $0.stopTokens.isEmpty })
        #expect(submitted.allSatisfy { $0.stopStrings.isEmpty })
        #expect(submitted.allSatisfy { !$0.prefixCacheEnabled })
        #expect(engine.maximumActiveSubmissions == 1)
    }

    @Test
    func executorRejectsTooShortGenerationWindowAndContextOverflow() {
        let tokenizer = QualityTokenizer()
        let input = corpus(cases: [
            .init(id: "one", category: "reasoning", prompt: "alpha"),
        ])

        #expect(throws: QwenQualityCorpusExecutionError.invalidGenerationWindow(
            actual: 31, minimum: 32, maximum: 4_096))
        {
            _ = try QwenQualityCorpusExecutor.prepare(
                corpus: input,
                maximumTokens: 31,
                maximumContextTokens: 128,
                tokenizer: tokenizer)
        }
        #expect(throws: QwenQualityCorpusExecutionError.contextLengthExceeded(
            caseID: "one",
            promptTokens: 3,
            generationTokens: 32,
            maximumContextTokens: 34))
        {
            _ = try QwenQualityCorpusExecutor.prepare(
                corpus: input,
                maximumTokens: 32,
                maximumContextTokens: 34,
                tokenizer: tokenizer)
        }
    }

    @Test
    func runnerRejectsShortOrFailedStreams() async throws {
        let prepared = QwenQualityPreparedCase(
            corpusCase: .init(id: "one", category: "reasoning", prompt: "alpha"),
            promptTokens: [1, 2, 3])
        let short = QualityScriptedEngine(outputCount: 31)
        await #expect(throws: QwenQualityCorpusExecutionError.unexpectedTokenCount(
            caseID: "one", expected: 32, actual: 31))
        {
            _ = try await QwenQualityCorpusEngineRunner.run(
                engine: short,
                prepared: prepared,
                maximumTokens: 32,
                requestID: CBv2RequestID(1))
        }

        let failed = QualityScriptedEngine(terminalError: "injected")
        await #expect(throws: QwenQualityCorpusExecutionError.unexpectedTerminal(
            caseID: "one", reason: "error: injected"))
        {
            _ = try await QwenQualityCorpusEngineRunner.run(
                engine: failed,
                prepared: prepared,
                maximumTokens: 32,
                requestID: CBv2RequestID(2))
        }
    }

    @Test
    func comparisonReportsExactCasesAndFirstMismatch() throws {
        let baseline = report(
            label: "baseline",
            outputs: [
                ("one", Array(0 ..< 32)),
                ("two", Array(100 ..< 132)),
            ])
        var moved = Array(100 ..< 132)
        moved[7] = 999
        let candidate = report(
            label: "top4",
            outputs: [
                ("one", Array(0 ..< 32)),
                ("two", moved),
            ],
            policy: ["DARKBLOOM_QWEN35_PREFILL_MOE_TOP_K": "4"])

        let comparison = try QwenQualityCorpusComparison.compare(
            baseline: baseline,
            candidate: candidate)

        #expect(comparison.comparedCaseCount == 2)
        #expect(comparison.exactMatchCaseCount == 1)
        #expect(comparison.exactMatchRate == 0.5)
        #expect(comparison.cases[0].tokenIDsMatch)
        #expect(!comparison.cases[1].tokenIDsMatch)
        #expect(comparison.cases[1].commonPrefixTokenCount == 7)
        #expect(comparison.cases[1].firstMismatchTokenIndex == 7)
    }

    @Test
    func comparisonRefusesDifferentModelArtifact() {
        let baseline = report(label: "baseline", outputs: [
            ("one", Array(0 ..< 32)),
        ])
        let candidate = report(
            label: "candidate",
            outputs: [("one", Array(0 ..< 32))],
            artifactHash: String(repeating: "b", count: 64))

        #expect(throws: QwenQualityCorpusComparisonError.modelArtifactMismatch) {
            _ = try QwenQualityCorpusComparison.compare(
                baseline: baseline,
                candidate: candidate)
        }
    }

    @Test
    func reportRoundTripsAndValidatesChecksums() throws {
        let original = report(label: "baseline", outputs: [
            ("one", Array(0 ..< 32)),
        ])
        let json = try original.jsonString()
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(
            QwenQualityCorpusReport.self, from: data)

        try decoded.validate()
        #expect(decoded.cases == original.cases)
        #expect(decoded.model == original.model)

        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        var rows = try #require(object["cases"] as? [[String: Any]])
        rows[0]["tokenChecksum"] = String(repeating: "0", count: 16)
        object["cases"] = rows
        let tampered = try JSONDecoder().decode(
            QwenQualityCorpusReport.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: QwenQualityCorpusReportError.invalidCase("one")) {
            try tampered.validate()
        }
    }

    @Test
    func policyEnvironmentCaptureIsAllowlisted() {
        let captured = QwenQualityCorpusBenchmark.capturedPolicyEnvironment([
            "DARKBLOOM_QWEN35_PREFILL_MOE_TOP_K": "4",
            "DARKBLOOM_CBV2_PREFILL_NARROWING": "0",
            "DARKBLOOM_QUALITY_CANONICAL_EXACT_PREFILL": "1",
            "DARKBLOOM_API_TOKEN": "secret",
            "HOME": "/Users/test",
        ])

        #expect(captured == [
            "DARKBLOOM_QWEN35_PREFILL_MOE_TOP_K": "4",
            "DARKBLOOM_CBV2_PREFILL_NARROWING": "0",
            "DARKBLOOM_QUALITY_CANONICAL_EXACT_PREFILL": "1",
        ])
    }

    private func corpus(cases: [QwenQualityCorpus.Case]) -> QwenQualityCorpus {
        QwenQualityCorpus(
            id: "test-corpus",
            version: "v1",
            description: "Synthetic test corpus",
            license: "CC0-1.0",
            provenance: "Created for unit tests",
            cases: cases)
    }

    private func report(
        label: String,
        outputs: [(String, [Int])],
        policy: [String: String] = [:],
        artifactHash: String = String(repeating: "a", count: 64)
    ) -> QwenQualityCorpusReport {
        let rows = outputs.map { id, tokens in
            QwenQualityCorpusReport.CaseResult(
                id: id,
                category: "reasoning",
                prompt: "Prompt \(id)",
                promptTokenCount: 12,
                timeToFirstTokenMs: 10,
                estimatedPrefillTokensPerSecond: 1_100,
                totalTimeMs: 20,
                generatedTokenCount: tokens.count,
                generatedTokenIDs: tokens,
                tokenChecksum: ArrivalPrefillAccounting.tokenChecksum(tokens),
                text: "text",
                finishReason: "length")
        }
        return QwenQualityCorpusReport(
            run: .init(label: label, createdAtUTC: "2026-08-24T00:00:00.000Z"),
            model: .init(
                id: "qwen-test",
                path: "/models/qwen-test",
                artifactSHA256: artifactHash,
                modelType: "qwen3_5_moe",
                architecture: "Qwen35ForConditionalGeneration",
                maximumContextTokens: 4_096),
            corpus: .init(
                id: "test-corpus",
                version: "v1",
                path: "/corpus.json",
                sha256: String(repeating: "c", count: 64),
                caseCount: rows.count,
                license: "CC0-1.0",
                provenance: "synthetic"),
            hardware: .init(
                machineModel: "Mac15,9",
                chipName: "Apple M3 Max",
                memoryGB: 64,
                gpuCores: 40),
            engine: .init(
                factory: "EngineV2Factory.makeProductionBuild", // pragma: allowlist secret
                kvBackendSelection: "contiguous",
                resolvedKVBackend: "contiguous",
                maxConcurrentRequests: 1,
                requestsExecutedSequentially: true,
                prefixCacheEnabled: false,
                warmupPerformed: true,
                policyEnvironment: policy),
            generation: .init(
                temperature: 0,
                topP: 1,
                topK: 0,
                maximumTokens: 32,
                minimumRequiredTokens: 32,
                stopPolicy: "fixed-length-no-stop-tokens"),
            cases: rows)
    }
}

private final class QualityTokenizer: Tokenizer, @unchecked Sendable {
    private let lock = NSLock()
    private var prompts: [String] = []

    var renderedPrompts: [String] {
        lock.withLock { prompts }
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1, 2, 3] }
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
        let prompt = messages.first?["content"] as? String ?? ""
        lock.withLock { prompts.append(prompt) }
        return [11, prompt.utf8.count, 12]
    }
}

private final class QualityScriptedEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var submittedRequests: [CBv2Request] = []
    private var activeSubmissions = 0
    private var maximumActive = 0
    private let outputCount: Int?
    private let terminalError: String?

    init(outputCount: Int? = nil, terminalError: String? = nil) {
        self.outputCount = outputCount
        self.terminalError = terminalError
    }

    var submitted: [CBv2Request] {
        lock.withLock { submittedRequests }
    }

    var maximumActiveSubmissions: Int {
        lock.withLock { maximumActive }
    }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        try lock.withLock {
            guard activeSubmissions == 0 else {
                throw QualityScriptedEngineError.overlappingSubmission
            }
            activeSubmissions += 1
            maximumActive = max(maximumActive, activeSubmissions)
            submittedRequests.append(request)
        }

        let count = outputCount ?? request.maxTokens
        let tokens = (0 ..< count).map { Int(request.id.raw % 1_000) * 100 + $0 }
        return AsyncStream { continuation in
            if let first = tokens.first {
                continuation.yield(.delta(
                    text: "row-\(request.id.raw)-",
                    tokens: [first],
                    logprobs: nil))
                continuation.yield(.delta(
                    text: "done",
                    tokens: Array(tokens.dropFirst()),
                    logprobs: nil))
            }
            let reason = terminalError.map(CBv2FinishReason.error) ?? .length
            continuation.yield(.finished(
                reason: reason,
                usage: CBv2Usage(
                    promptTokens: request.promptTokens.count,
                    completionTokens: tokens.count)))
            lock.withLock { activeSubmissions -= 1 }
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

private enum QualityScriptedEngineError: Error {
    case overlappingSubmission
}
