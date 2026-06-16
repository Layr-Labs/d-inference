import ArgumentParser
import Foundation
import MLX
import MLXLMCommon
import ProviderCore

/// DAR-318 capacity demo + DAR-323 long-context scaling microbenchmark.
/// Loads a model into the real continuous-batching engine (fp16 baseline +
/// quantized) and reports capacity, quality, and perf. With `--prompt-tokens`
/// it additionally runs a synthetic long-context decode scaling sweep and a
/// matching KV dequant microbenchmark for GPT-OSS.
@main
struct KVEngineDemo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kv-engine-demo",
        abstract: "Compare fp16 and quantized BatchedEngine capacity/quality/perf, plus DAR-323 long-context scaling."
    )

    @Option(help: "Model ID to load.")
    var modelID: String = "mlx-community/gpt-oss-20b-MXFP4-Q8"

    @Option(help: "Path to the model snapshot directory. Defaults to the HF cache.")
    var modelDir: String?

    @Option(help: "Max tokens to generate per prompt / decode tokens in long-context mode.")
    var maxTokens: Int = 48

    @Option(help: "Number of prompts to run in default (short-prompt) mode.")
    var promptCount: Int = 3

    @Option(help: "Seconds to wait for a single generation before aborting.")
    var generationTimeout: Int = 120

    @Option(help: "Comma-separated synthetic prompt token lengths for long-context scaling (e.g. 512,2048,4096,8192).")
    var promptTokens: String?

    @Option(help: "Iterations per context for the dequant microbenchmark.")
    var dequantIters: Int = 30

    @Flag(help: "Skip generation and only report capacity numbers.")
    var capacityOnly: Bool = false

    @Flag(help: "Run only the quantized engine smoke (skip fp16 baseline).")
    var quantOnly: Bool = false

    var contextLengths: [Int] {
        guard let spec = promptTokens else { return [] }
        return spec
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 > 0 }
    }

    mutating func run() async throws {
        let resolvedModelDir = try resolveModelDirectory()
        printHeader(modelDir: resolvedModelDir)

        let modelConfig = LocalMLXModelConfiguration(
            modelID: modelID,
            modelDirectory: resolvedModelDir
        )
        let readiness = LocalMLXModelReadiness.inspect(modelConfig)
        guard readiness.canAttemptLoad else {
            let issueStrings = readiness.issues.map { issue in
                if let detail = issue.detail {
                    return "\(issue.kind.rawValue): \(issue.path.path) — \(detail)"
                }
                return "\(issue.kind.rawValue): \(issue.path.path)"
            }
            print("ERROR: model not ready: \(issueStrings.joined(separator: "; "))")
            throw ExitCode.failure
        }

        print("Loading model container...")
        let container = try await LocalMLXModelLoader.live().loadContainer(for: modelConfig)
        print("Container loaded.\n")

        var reports: [EngineReport] = []

        if !quantOnly {
            print("=== Building fp16 baseline engine ===")
            let fp16 = try await runEngine(
                label: "fp16",
                container: container,
                kvQuantEnabled: false
            )
            reports.append(fp16)
            await cleanup()
        }

        let quantLabel = KVQuantPolicy.classify(modelID: modelID) == .gptOSS
            ? "k8v8:g64 (dequant)"
            : "k8v8:g128 (kernel)"
        print("\n=== Building \(quantLabel) quantized engine ===")
        let quant = try await runEngine(
            label: quantLabel,
            container: container,
            kvQuantEnabled: true
        )
        reports.append(quant)
        await cleanup()

        printReport(reports: reports)

        if !contextLengths.isEmpty {
            await runDequantMicrobenchmark(reports: reports)
        }
    }

    // MARK: - Engine run

    private func runEngine(
        label: String,
        container: ModelContainer,
        kvQuantEnabled: Bool
    ) async throws -> EngineReport {
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 1,
            defaultMaxTokens: maxTokens,
            kvQuantEnabled: kvQuantEnabled
        )

        await scheduler.loadModel(container: container, modelId: modelID)

        let kvBytes = await scheduler.resolvedKVBytesPerToken()
        let tokenBudget = await scheduler.resolvedTokenBudgetMax()

        print("  kv_bytes_per_token: \(kvBytes)")
        print("  token_budget_max:   \(tokenBudget)")

        var generations: [GenerationResult] = []
        if !capacityOnly {
            if !contextLengths.isEmpty {
                let tokenizer = await container.tokenizer
                for (index, contextLength) in contextLengths.enumerated() {
                    print("  generating context \(contextLength) \(index + 1)/\(contextLengths.count)...", terminator: " ")
                    do {
                        let promptTokens = syntheticPromptTokens(
                            targetCount: contextLength,
                            tokenizer: tokenizer
                        )
                        let result = try await generateTokenized(
                            scheduler: scheduler,
                            promptTokens: promptTokens,
                            index: index,
                            decodeTokens: maxTokens
                        )
                        generations.append(result)
                        print("ok (\(result.tokens) decode tok, \(String(format: "%.2f", result.decodeTokensPerSecond)) decode tok/s, reported \(String(format: "%.2f", result.reportedTokensPerSecond)) tok/s)")
                    } catch {
                        print("FAILED: \(error.localizedDescription)")
                        generations.append(GenerationResult(
                            prompt: "",
                            promptTokenCount: contextLength,
                            text: "",
                            tokens: 0,
                            decodeTokensPerSecond: 0,
                            reportedTokensPerSecond: 0,
                            error: error.localizedDescription
                        ))
                    }
                }
            } else {
                let prompts = Array(KVQuantQualityRunner.genFidelityPrompts.prefix(promptCount))
                for (index, prompt) in prompts.enumerated() {
                    print("  generating prompt \(index + 1)/\(prompts.count)...", terminator: " ")
                    do {
                        let result = try await generate(
                            scheduler: scheduler,
                            prompt: prompt,
                            index: index
                        )
                        generations.append(result)
                        print("ok (\(result.tokens) tokens, \(String(format: "%.2f", result.decodeTokensPerSecond)) tok/s decode)")
                    } catch {
                        print("FAILED: \(error.localizedDescription)")
                        generations.append(GenerationResult(
                            prompt: prompt,
                            promptTokenCount: 0,
                            text: "",
                            tokens: 0,
                            decodeTokensPerSecond: 0,
                            reportedTokensPerSecond: 0,
                            error: error.localizedDescription
                        ))
                    }
                }
            }
        }

        await scheduler.unloadModel()

        return EngineReport(
            label: label,
            kvBytesPerToken: kvBytes,
            tokenBudgetMax: tokenBudget,
            kvQuantEnabled: kvQuantEnabled,
            generations: generations
        )
    }

    // MARK: - Generation

    private func generate(
        scheduler: BatchScheduler,
        prompt: String,
        index: Int
    ) async throws -> GenerationResult {
        let request = ChatCompletionRequest(
            model: modelID,
            messages: [ChatMessage(role: "user", content: prompt)],
            temperature: 0.0,
            max_tokens: maxTokens
        )

        let stream = await scheduler.submit(request: request, requestId: "demo-\(index)")
        return try await consumeStream(
            stream: stream,
            prompt: prompt,
            promptTokenCount: 0,
            scheduler: scheduler
        )
    }

    private func generateTokenized(
        scheduler: BatchScheduler,
        promptTokens: [Int],
        index: Int,
        decodeTokens: Int
    ) async throws -> GenerationResult {
        let stream = await scheduler.submitTokenized(
            promptTokens: promptTokens,
            maxTokens: decodeTokens,
            temperature: 0.0,
            requestId: "demo-\(index)"
        )
        return try await consumeStream(
            stream: stream,
            prompt: "",
            promptTokenCount: promptTokens.count,
            scheduler: scheduler
        )
    }

    private func consumeStream(
        stream: AsyncStream<GenerationEvent>,
        prompt: String,
        promptTokenCount: Int,
        scheduler: BatchScheduler
    ) async throws -> GenerationResult {
        var text = ""
        var tokens = 0
        var reportedTokensPerSecond: Double = 0
        var firstChunkAt: ContinuousClock.Instant?
        var lastChunkAt: ContinuousClock.Instant?

        let deadline = ContinuousClock.now.advanced(by: .seconds(generationTimeout))

        for await event in stream {
            switch event {
            case .chunk(let chunk):
                text += chunk
                let now = ContinuousClock.now
                if firstChunkAt == nil { firstChunkAt = now }
                lastChunkAt = now
            case .info(_, let completionTok, let tps):
                tokens = completionTok
                reportedTokensPerSecond = tps
            case .error(let message):
                throw KVEngineDemoError.generationFailed(message)
            }

            if ContinuousClock.now > deadline {
                await scheduler.cancelAll()
                throw KVEngineDemoError.generationTimeout
            }
        }

        var decodeTokensPerSecond = reportedTokensPerSecond
        if let first = firstChunkAt, let last = lastChunkAt, tokens > 0 {
            let duration = first.duration(to: last)
            let seconds = Double(duration.components.seconds)
                + Double(duration.components.attoseconds) * 1e-18
            decodeTokensPerSecond = Double(tokens) / seconds
        }

        return GenerationResult(
            prompt: prompt,
            promptTokenCount: promptTokenCount,
            text: text,
            tokens: tokens,
            decodeTokensPerSecond: decodeTokensPerSecond,
            reportedTokensPerSecond: reportedTokensPerSecond,
            error: nil
        )
    }

    // MARK: - Synthetic prompt

    private func syntheticPromptTokens(targetCount: Int, tokenizer: any MLXLMCommon.Tokenizer) -> [Int] {
        let seed = "The quick brown fox jumps over the lazy dog. "
        let seedTokens = tokenizer.encode(text: seed, addSpecialTokens: false)
        guard !seedTokens.isEmpty else {
            return Array(repeating: 1, count: targetCount)
        }
        var tokens: [Int] = []
        tokens.reserveCapacity(targetCount)
        while tokens.count < targetCount {
            tokens.append(contentsOf: seedTokens)
        }
        return Array(tokens.prefix(targetCount))
    }

    // MARK: - Microbenchmark

    private func runDequantMicrobenchmark(reports: [EngineReport]) async {
        print("\n=== KV dequant microbenchmark (GPT-OSS dims: B=1, kvHeads=8, headDim=64, g=64, bits=8) ===")

        let kvHeads = 8
        let headDim = 64
        let groupSize = 64
        let bits = 8
        let layers = 36  // GPT-OSS 20B

        print("context | ms/layer (K+V) | ms/all-layers |")
        var rows: [(context: Int, msPerLayer: Double, msAllLayers: Double)] = []

        for contextLength in contextLengths {
            let msPerLayer = benchmarkDequant(
                contextLength: contextLength,
                kvHeads: kvHeads,
                headDim: headDim,
                groupSize: groupSize,
                bits: bits
            )
            let msAllLayers = msPerLayer * Double(layers)
            rows.append((contextLength, msPerLayer, msAllLayers))
            print(String(format: "%7d | %14.3f | %13.3f |", contextLength, msPerLayer, msAllLayers))
        }

        print("\nDequant cost as a fraction of measured per-step decode time:")
        print("context | fp16 step ms | quant step ms | dequant ms/step | dequant/quant |")
        // Pair generations by index across reports.
        let fp16Report = reports.first { !$0.kvQuantEnabled }
        let quantReport = reports.first { $0.kvQuantEnabled }
        for (offset, ctx) in contextLengths.enumerated() {
            let fp16StepMs = fp16Report.flatMap { $0.generations[safe: offset] }.flatMap { $0.error == nil && $0.decodeTokensPerSecond > 0 ? 1000.0 / $0.decodeTokensPerSecond : nil }
            let quantStepMs = quantReport.flatMap { $0.generations[safe: offset] }.flatMap { $0.error == nil && $0.decodeTokensPerSecond > 0 ? 1000.0 / $0.decodeTokensPerSecond : nil }
            let dequantMs = rows.first { $0.context == ctx }?.msAllLayers
            let ratio: Double? = {
                guard let q = quantStepMs, let d = dequantMs, q > 0 else { return nil }
                return d / q
            }()
            print(String(format: "%7d | %14.3f | %15.3f | %15.3f | %13.3f |",
                         ctx,
                         fp16StepMs ?? -1,
                         quantStepMs ?? -1,
                         dequantMs ?? -1,
                         ratio ?? -1))
        }
    }

    private func benchmarkDequant(
        contextLength: Int,
        kvHeads: Int,
        headDim: Int,
        groupSize: Int,
        bits: Int
    ) -> Double {
        let shape = [1, kvHeads, contextLength, headDim]
        let count = shape.reduce(1, *)
        let src = MLXArray(0 ..< Int32(count)).reshaped(shape).asType(.float16)
        let q = quantized(src, groupSize: groupSize, bits: bits, mode: .affine)
        if let biases = q.biases {
            eval(q.wq, q.scales, biases)
        } else {
            eval(q.wq, q.scales)
        }

        // Warmup.
        for _ in 0..<5 {
            let dq = dequantized(
                q.wq, scales: q.scales, biases: q.biases,
                groupSize: groupSize, bits: bits, mode: .affine
            )
            eval(dq)
        }

        let start = ContinuousClock.now
        for _ in 0..<dequantIters {
            let dq = dequantized(
                q.wq, scales: q.scales, biases: q.biases,
                groupSize: groupSize, bits: bits, mode: .affine
            )
            eval(dq)
        }
        let elapsed = start.duration(to: ContinuousClock.now)
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) * 1e-18
        let msPerIter = seconds * 1000.0 / Double(dequantIters)

        // We benchmark one tensor (K). In the model both K and V are
        // dequantized, and their shapes are identical, so double it.
        return msPerIter * 2.0
    }

    // MARK: - Reporting

    private func printHeader(modelDir: URL) {
        print("Darkbloom KV Engine Demo — DAR-318 / DAR-323")
        print("Model:      \(modelID)")
        print("Model dir:  \(modelDir.path)")
        print("Max tokens: \(maxTokens)")
        print("Prompts:    \(promptCount)")
        if !contextLengths.isEmpty {
            print("Contexts:   \(contextLengths)")
        }
        print("")
    }

    private func printReport(reports: [EngineReport]) {
        print("\n========== REPORT ==========")

        // 1. CAPACITY
        print("\n1. CAPACITY")
        for r in reports {
            print("  \(r.label):")
            print("    kv_bytes_per_token: \(r.kvBytesPerToken)")
            print("    token_budget_max:   \(r.tokenBudgetMax)")
        }
        if reports.count == 2 {
            let fp16 = reports[0]
            let quant = reports[1]
            let bytesRatio = Double(quant.kvBytesPerToken) / Double(max(fp16.kvBytesPerToken, 1))
            let budgetRatio = Double(quant.tokenBudgetMax) / Double(max(fp16.tokenBudgetMax, 1))
            print("  -> quantized/fp16 kv_bytes_per_token ratio: \(String(format: "%.3f", bytesRatio))")
            print("  -> quantized/fp16 token_budget_max ratio:   \(String(format: "%.3f", budgetRatio))")
        }

        // 2. QUALITY
        print("\n2. QUALITY")
        if reports.count == 2,
           let fp16 = reports.first(where: { !$0.kvQuantEnabled }),
           let quant = reports.first(where: { $0.kvQuantEnabled }) {
            compareOutputs(fp16: fp16, quant: quant)
        } else {
            print("  (need both fp16 and quant reports to compare quality)")
        }

        // 3. PERF
        print("\n3. PERF")
        if !contextLengths.isEmpty {
            print("\n  Long-context decode scaling (manual decode tok/s, first-token to last-token):")
            print("  context | engine | decode tok/s | reported tok/s |")
            for r in reports {
                for (offset, ctx) in contextLengths.enumerated() {
                    guard let gen = r.generations[safe: offset], gen.error == nil, gen.tokens > 0 else {
                        print(String(format: "  %7d | %-6@ | FAILED", ctx, r.label))
                        continue
                    }
                    print(String(format: "  %7d | %-6@ | %12.2f | %14.2f |",
                                 ctx, r.label, gen.decodeTokensPerSecond, gen.reportedTokensPerSecond))
                }
            }

            if reports.count == 2 {
                print("\n  Ratio quant/fp16 by context:")
                print("  context | ratio (decode tok/s) |")
                let fp16 = reports[0]
                let quant = reports[1]
                for (offset, ctx) in contextLengths.enumerated() {
                    let f = fp16.generations[safe: offset]?.decodeTokensPerSecond ?? 0
                    let q = quant.generations[safe: offset]?.decodeTokensPerSecond ?? 0
                    if f > 0 && q > 0 {
                        print(String(format: "  %7d | %19.3f |", ctx, q / f))
                    } else {
                        print(String(format: "  %7d | FAILED", ctx))
                    }
                }
            }
        } else {
            for r in reports {
                let ok = r.generations.filter { $0.error == nil && $0.tokens > 0 }
                let avgTps = ok.map(\.decodeTokensPerSecond).reduce(0, +) / Double(max(ok.count, 1))
                print("  \(r.label): avg decode tok/s = \(String(format: "%.2f", avgTps)) (\(ok.count)/\(r.generations.count) prompts succeeded)")
            }
        }

        print("\n============================")
    }

    private func compareOutputs(fp16: EngineReport, quant: EngineReport) {
        let pairs = zip(fp16.generations, quant.generations)
        var totalMatches = 0
        var totalTokens = 0
        var divergences: [String] = []

        for (fp16Gen, quantGen) in pairs {
            guard fp16Gen.error == nil, quantGen.error == nil,
                  !fp16Gen.text.isEmpty, !quantGen.text.isEmpty else {
                continue
            }

            let refTokens = fp16Gen.text.split(separator: " ")
            let quantTokens = quantGen.text.split(separator: " ")
            let minLen = min(refTokens.count, quantTokens.count)
            var matches = 0
            var firstDivergence: Int? = nil
            for i in 0..<minLen {
                if refTokens[i] == quantTokens[i] {
                    matches += 1
                } else if firstDivergence == nil {
                    firstDivergence = i
                }
            }
            totalMatches += matches
            totalTokens += minLen

            if let first = firstDivergence {
                let preview = quantGen.text.prefix(120)
                divergences.append("prompt '\(fp16Gen.prompt.prefix(40))...' diverged at token \(first); quant output: \(preview)")
            }
        }

        let matchRate = totalTokens > 0 ? Double(totalMatches) / Double(totalTokens) : 0
        print("  exact-token match rate (whitespace tokens): \(String(format: "%.3f", matchRate)) (\(totalMatches)/\(totalTokens))")
        if !divergences.isEmpty {
            print("  divergence points:")
            for d in divergences.prefix(3) {
                print("    - \(d)")
            }
        }
    }

    // MARK: - Helpers

    private func resolveModelDirectory() throws -> URL {
        if let modelDir {
            let url = URL(fileURLWithPath: modelDir)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw KVEngineDemoError.modelDirectoryNotFound(url.path)
            }
            return url
        }

        guard let path = ModelScanner.resolveLocalPath(modelID: modelID) else {
            throw KVEngineDemoError.modelNotInCache(modelID)
        }
        return path
    }

    private func cleanup() async {
        MLX.Memory.clearCache()
        try? await Task.sleep(for: .milliseconds(200))
    }
}

// MARK: - Types

private struct EngineReport {
    let label: String
    let kvBytesPerToken: Int
    let tokenBudgetMax: Int
    let kvQuantEnabled: Bool
    let generations: [GenerationResult]
}

private struct GenerationResult {
    let prompt: String
    let promptTokenCount: Int
    let text: String
    let tokens: Int
    let decodeTokensPerSecond: Double
    let reportedTokensPerSecond: Double
    let error: String?
}

private enum KVEngineDemoError: Error, LocalizedError {
    case modelDirectoryNotFound(String)
    case modelNotInCache(String)
    case generationFailed(String)
    case generationTimeout

    var errorDescription: String? {
        switch self {
        case .modelDirectoryNotFound(let path):
            return "model directory not found: \(path)"
        case .modelNotInCache(let id):
            return "model '\(id)'' not found in HF cache; pass --model-dir"
        case .generationFailed(let message):
            return "generation failed: \(message)"
        case .generationTimeout:
            return "generation timed out"
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
