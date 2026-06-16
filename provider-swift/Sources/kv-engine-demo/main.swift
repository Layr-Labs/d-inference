import ArgumentParser
import Foundation
import MLX
import MLXLMCommon
import ProviderCore

/// DAR-318 capacity demo: load Gemma 4 into the real continuous-batching
/// engine twice (fp16 baseline + K8V8 g128 quantized) and report capacity,
/// quality, and perf axes separately.
@main
struct KVEngineDemo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kv-engine-demo",
        abstract: "Compare fp16 and K8V8 g128 BatchedEngine capacity/quality/perf."
    )

    @Option(help: "Model ID to load (must be a Gemma 4 family model).")
    var modelID: String = "mlx-community/gemma-4-26b-a4b-it-qat-4bit"

    @Option(help: "Path to the model snapshot directory. Defaults to the HF cache.")
    var modelDir: String?

    @Option(help: "Max tokens to generate per prompt.")
    var maxTokens: Int = 48

    @Option(help: "Number of prompts to run.")
    var promptCount: Int = 3

    @Option(help: "Seconds to wait for a single generation before aborting.")
    var generationTimeout: Int = 120

    @Flag(help: "Skip generation and only report capacity numbers.")
    var capacityOnly: Bool = false

    @Flag(help: "Run only the quantized engine smoke (skip fp16 baseline).")
    var quantOnly: Bool = false

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

        print("\n=== Building K8V8 g128 quantized engine ===")
        let quant = try await runEngine(
            label: "k8v8:g128",
            container: container,
            kvQuantEnabled: true
        )
        reports.append(quant)
        await cleanup()

        printReport(reports: reports)
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
                    print("ok (\(result.tokens) tokens, \(String(format: "%.2f", result.tokensPerSecond)) tok/s)")
                } catch {
                    print("FAILED: \(error.localizedDescription)")
                    generations.append(GenerationResult(
                        prompt: prompt,
                        text: "",
                        tokens: 0,
                        tokensPerSecond: 0,
                        error: error.localizedDescription
                    ))
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

        var text = ""
        var tokens = 0
        var tokensPerSecond: Double = 0

        let deadline = ContinuousClock.now.advanced(by: .seconds(generationTimeout))

        for await event in stream {
            switch event {
            case .chunk(let chunk):
                text += chunk
            case .info(_, let completionTok, let tps):
                tokens = completionTok
                tokensPerSecond = tps
            case .error(let message):
                throw KVEngineDemoError.generationFailed(message)
            }

            if ContinuousClock.now > deadline {
                await scheduler.cancelAll()
                throw KVEngineDemoError.generationTimeout
            }
        }

        return GenerationResult(
            prompt: prompt,
            text: text,
            tokens: tokens,
            tokensPerSecond: tokensPerSecond,
            error: nil
        )
    }

    // MARK: - Reporting

    private func printHeader(modelDir: URL) {
        print("Darkbloom KV Engine Demo — DAR-318")
        print("Model:      \(modelID)")
        print("Model dir:  \(modelDir.path)")
        print("Max tokens: \(maxTokens)")
        print("Prompts:    \(promptCount)")
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
        for r in reports {
            let ok = r.generations.filter { $0.error == nil && $0.tokens > 0 }
            let avgTps = ok.map(\.tokensPerSecond).reduce(0, +) / Double(max(ok.count, 1))
            print("  \(r.label): avg decode tok/s = \(String(format: "%.2f", avgTps)) (\(ok.count)/\(r.generations.count) prompts succeeded)")
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

            // Simple token-level exact match using whitespace splitting.
            // Good enough for a fast demo; the real gate uses model-tokenizer
            // top-1 agreement.
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
        // Give MLX a moment to release cached buffers.
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
    let text: String
    let tokens: Int
    let tokensPerSecond: Double
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
            return "model '\(id)' not found in HF cache; pass --model-dir"
        case .generationFailed(let message):
            return "generation failed: \(message)"
        case .generationTimeout:
            return "generation timed out"
        }
    }
}
