import CryptoKit
import Foundation
import MLXLMCommon
@_spi(Benchmarking) import ProviderCore

/// Bounded observations from natural generation, not a representative quality
/// benchmark or a release verdict. Input tokens already include any template.
public enum KVQualityBenchmark {
    public enum Failure: Error {
        case invalidDeclaration, modelHashMismatch, runtimeIdentityUnavailable
        case unexpectedServingMode, caseIdentityMismatch
    }

    struct CaseResult: Codable, Sendable {
        let name: String
        let index: Int
        let requestID: UInt64
        let receiptID: UInt64?
        let promptTokenCount: Int
        let maximumTokens: Int
        let generatedTokenIDs: [Int]
        let decodedText: String
        let streamedText: String
        let finishReason: String?
        let terminalCause: String?
        let error: String?
        let issues: [String]
        let elapsedMs: Double
        let firstTokenMs: Double?
        let expectedTextProvided: Bool
        let expectedExactMatch: Bool?
        let expectedOuterWhitespaceMatch: Bool?
        let servingContent: String
        let servingExpectedExactMatch: Bool?
        let servingExpectedOuterWhitespaceMatch: Bool?
    }

    struct Report: Encodable {
        let schema = 1
        let scope = "bounded_free_generation_observations"
        let status: String
        let input: KVQualityInput
        let inputSHA256: String
        let beforeModelAggregateSHA256: String
        let afterModelAggregateSHA256: String
        let executableSHA256: String
        let metallibSHA256: String
        let modelDirectory: String
        let resolvedBackend: String
        let kvQuantizationIdentity: String?
        let quantizedPrefill: BenchmarkQuantizedPrefillReceipt?
        let stopTokenIDs: [Int]
        let expectedTextMatchSource = "production_streamed_text"
        let declaredModelType: String?
        let servingParserFormat: String
        let servingExpectedTextMatchSource = "production_streaming_reasoning_parser_content"
        let temperature = 0
        let seed = 0
        let cacheMode = "off"
        let mtpEnabled = false
        let maximumCaseSeconds = 300
        let concurrency: Int
        let kvCapacityBytes: Int
        let productionGrant: EngineV2BenchmarkProductionGrant
        let memoryBefore: ProcessMemoryTelemetry?
        let memoryAfter: ProcessMemoryTelemetry?
        let cases: [CaseResult]
        let limits = [
            "Pinned token prompts are used verbatim; no chat template is inferred or rendered.",
            "Expected-text checks use authoritative streamedText, comparing exact text or trimming outer whitespace only; absent expectations are ungraded.",
            "Supplemental serving-content checks apply the production default streaming reasoning parser selected from the verified model declaration; raw text and raw grades remain unchanged.",
            "Generated code is recorded and never executed.",
            "Token IDs and streamed text are the production engine's emitted deltas; decodedText is a native-tokenizer diagnostic and may include suppressed stop-token renderings.",
            "Early EOS is a valid natural finish; maxTokens is a budget, not a required output length.",
            "This small case set is observational and does not certify general quality or performance.",
        ]
    }

    public static func run(
        modelID: String, modelDirectory: URL, inputURL: URL, backend: String,
        kvQuantization: EngineV2KVQuantizationSelection = .native,
        quantizedPrefillMode: PagedQuantizedPrefillMode = .direct
    ) async throws -> (json: String, controlsPassed: Bool) {
        try TeacherForcedBenchmark.validateBackend(backend)
        try BenchmarkQuantizedPrefillReceipt.validateSelection(quantization: kvQuantization, mode: quantizedPrefillMode)
        let (input, inputData) = try KVQualityInput.read(inputURL)
        try input.validate(modelID: modelID)
        guard let verified = WeightHasher.computeHash(snapshotDir: modelDirectory, modelID: modelID),
            verified == input.expectedModelAggregateSHA256 else { throw Failure.modelHashMismatch }
        let declaration = try JSONDecoder().decode(TeacherForcedBenchmarkInput.Declaration.self,
            from: TeacherForcedBenchmarkInput.readBounded(modelDirectory.appendingPathComponent("config.json")))
        guard let vocabulary = declaration.vocabularySize else { throw Failure.invalidDeclaration }
        try input.validate(modelID: modelID, vocabularySize: vocabulary)
        guard let metallib = bindRuntimeMetallibForMLX(), let executable = selfBinaryHash() else {
            throw Failure.runtimeIdentityUnavailable
        }
        let isVLM = declaration.visionConfig != nil
        let container = try await BenchmarkModelLoading.load(directory: modelDirectory, isVLM: isVLM)
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
            kvBytesCapacity: 1 << 30, maxConcurrentRequests: input.resolvedConcurrency, mtpEnabled: false,
            useProductionKVGrant: true, kvBackendConfig: backend,
            kvQuantizationConfig: kvQuantization.rawValue, quantizedPrefillMode: quantizedPrefillMode,
            requirePersistentKey: false,
            environment: environment)
        do {
            let cache = await session.cacheSnapshot()
            guard session.backend == backend, session.backendFallback == nil,
                session.kvQuantizationIdentity == kvQuantization.configuration?.identity,
                !cache.memoryEnabled, cache.durableMode == nil, cache.recurrentBankBudgetBytes == 0,
                session.rawEngine.mtpMetricsSnapshot() == nil, let grant = cache.productionGrant else {
                throw Failure.unexpectedServingMode
            }
            let collected = try await collect(input: input, session: session)
            var results: [CaseResult] = []
            for row in try KVQualityEventCollector.ordered(collected, count: input.cases.count) {
                let sample = input.cases[row.index]
                var issues = row.issues
                let text: String
                if row.tokens.allSatisfy({ $0 >= 0 && $0 < vocabulary }) {
                    text = await container.perform { $0.tokenizer.decode(tokenIds: row.tokens) }
                } else {
                    text = ""
                    issues.append("invalid_generated_token")
                }
                let matches = KVQualityEventCollector.matches(row.streamedText, expected: sample.expectedText)
                let servingContent = BenchmarkServingContent.parse(
                    chunks: [row.streamedText], modelType: declaration.modelType)
                let servingMatches = KVQualityEventCollector.matches(servingContent, expected: sample.expectedText)
                results.append(.init(name: sample.name, index: row.index, requestID: row.requestID,
                    receiptID: row.receiptID, promptTokenCount: sample.promptTokens.count,
                    maximumTokens: sample.maxTokens, generatedTokenIDs: row.tokens,
                    decodedText: text, streamedText: row.streamedText, finishReason: row.finishReason,
                    terminalCause: row.terminalCause, error: row.error, issues: issues,
                    elapsedMs: row.elapsedMs, firstTokenMs: row.firstTokenMs,
                    expectedTextProvided: sample.expectedText != nil, expectedExactMatch: matches.exact,
                    expectedOuterWhitespaceMatch: matches.outerWhitespace,
                    servingContent: servingContent, servingExpectedExactMatch: servingMatches.exact,
                    servingExpectedOuterWhitespaceMatch: servingMatches.outerWhitespace))
            }
            let memoryAfter = await session.memorySnapshot()
            await session.shutdown()
            guard let after = WeightHasher.computeHash(snapshotDir: modelDirectory, modelID: modelID),
                after == verified else { throw Failure.modelHashMismatch }
            let controlsPassed = results.allSatisfy { $0.issues.isEmpty && $0.error == nil }
            let quantizedPrefill = try BenchmarkQuantizedPrefillReceipt.capture(
                engine: session.rawEngine, quantization: kvQuantization, mode: quantizedPrefillMode,
                successfulTerminalControls: controlsPassed)
            let report = Report(status: controlsPassed ? "observed" : "inconclusive", input: input,
                inputSHA256: SHA256.hash(data: inputData).map { String(format: "%02x", $0) }.joined(),
                beforeModelAggregateSHA256: verified, afterModelAggregateSHA256: after,
                executableSHA256: executable, metallibSHA256: metallib, modelDirectory: modelDirectory.path,
                resolvedBackend: session.backend, kvQuantizationIdentity: session.kvQuantizationIdentity,
                quantizedPrefill: quantizedPrefill,
                stopTokenIDs: session.stopTokenIDs.sorted(), declaredModelType: declaration.modelType,
                servingParserFormat: BenchmarkServingContent.parserFormat(modelType: declaration.modelType),
                concurrency: input.resolvedConcurrency,
                kvCapacityBytes: cache.engineKVCapacityBytes, productionGrant: grant,
                memoryBefore: cache.processMemory, memoryAfter: memoryAfter, cases: results)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return (String(decoding: try encoder.encode(report), as: UTF8.self), controlsPassed)
        } catch {
            await session.shutdown()
            throw error
        }
    }
}
