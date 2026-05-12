import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Result of a single benchmark iteration.
public struct BenchmarkIterationResult: Sendable {
    public let iteration: Int
    public let promptTokens: Int
    public let completionTokens: Int
    public let prefillLatencyMs: Double
    public let decodeTokensPerSecond: Double
    public let totalTimeMs: Double
}

/// Aggregated benchmark results across all iterations.
public struct BenchmarkReport: Sendable {
    public let modelID: String
    public let modelPath: String
    public let prompt: String
    public let iterations: [BenchmarkIterationResult]
    public let hardwareDescription: String

    public var avgPrefillLatencyMs: Double {
        guard !iterations.isEmpty else { return 0 }
        return iterations.map(\.prefillLatencyMs).reduce(0, +) / Double(iterations.count)
    }

    public var avgDecodeTokensPerSecond: Double {
        guard !iterations.isEmpty else { return 0 }
        return iterations.map(\.decodeTokensPerSecond).reduce(0, +) / Double(iterations.count)
    }

    public var avgTotalTimeMs: Double {
        guard !iterations.isEmpty else { return 0 }
        return iterations.map(\.totalTimeMs).reduce(0, +) / Double(iterations.count)
    }

    public var avgPromptTokens: Int {
        guard !iterations.isEmpty else { return 0 }
        return iterations.map(\.promptTokens).reduce(0, +) / iterations.count
    }

    public var avgCompletionTokens: Int {
        guard !iterations.isEmpty else { return 0 }
        return iterations.map(\.completionTokens).reduce(0, +) / iterations.count
    }

    public func printTable() {
        print("")
        print("Benchmark: \(modelID)")
        print("Path: \(modelPath)")
        print("Hardware: \(hardwareDescription)")
        print("Prompt: \"\(prompt)\"")
        print("Iterations: \(iterations.count)")
        print("")

        let headers = ["ITER", "PREFILL", "DECODE TPS", "TOTAL", "PROMPT TOK", "COMP TOK"]
        let rows = iterations.map { iter in
            [
                "\(iter.iteration)",
                String(format: "%.1f ms", iter.prefillLatencyMs),
                String(format: "%.2f tok/s", iter.decodeTokensPerSecond),
                String(format: "%.0f ms", iter.totalTimeMs),
                "\(iter.promptTokens)",
                "\(iter.completionTokens)",
            ]
        }

        let widths = headers.enumerated().map { index, header in
            rows.reduce(header.count) { max($0, $1[index].count) }
        }

        func line(_ columns: [String]) -> String {
            columns.enumerated().map { index, value in
                value.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }

        print(line(headers))
        print(line(widths.map { String(repeating: "-", count: $0) }))
        for row in rows {
            print(line(row))
        }

        print("")
        print("Average:")
        print("  Prefill latency:    \(String(format: "%.1f ms", avgPrefillLatencyMs))")
        print("  Decode throughput:  \(String(format: "%.2f tok/s", avgDecodeTokensPerSecond))")
        print("  Total time:         \(String(format: "%.0f ms", avgTotalTimeMs))")
        print("  Prompt tokens:      \(avgPromptTokens)")
        print("  Completion tokens:  \(avgCompletionTokens)")
    }
}

/// Runs standardized inference benchmarks against a local MLX model.
public struct ModelBenchmark: Sendable {

    public static let defaultPrompt = "Write a short story about a robot learning to paint."
    public static let defaultIterations = 3
    public static let defaultMaxTokens = 256

    /// Select the best model to benchmark from available models.
    ///
    /// Picks the largest model that fits in available memory, matching the
    /// provider's model selection logic.
    public static func selectModel(
        models: [ModelInfo],
        preferredModel: String?
    ) -> ModelInfo? {
        if let preferredModel {
            return models.first { $0.id == preferredModel }
        }
        // Pick the largest model (models are sorted by estimated memory ascending)
        return models.last
    }

    /// Run the benchmark against a model.
    public static func run(
        modelID: String,
        modelDirectory: URL,
        prompt: String = defaultPrompt,
        iterations: Int = defaultIterations,
        maxTokens: Int = defaultMaxTokens,
        hardware: HardwareInfo
    ) async throws -> BenchmarkReport {
        let hardwareDesc = "\(hardware.chipName), \(hardware.memoryGb) GB RAM, \(hardware.gpuCores) GPU cores, \(hardware.memoryBandwidthGbs) GB/s"

        print("Loading model: \(modelID)")
        print("Path: \(modelDirectory.path)")

        let container = try await LLMModelFactory.shared.loadContainer(
            from: modelDirectory,
            using: LocalTokenizerLoader()
        )

        print("Model loaded. Running \(iterations) iteration(s)...")
        print("")

        var results: [BenchmarkIterationResult] = []

        for i in 1...iterations {
            print("Iteration \(i)/\(iterations)...")

            let result = try await runIteration(
                container: container,
                modelID: modelID,
                prompt: prompt,
                maxTokens: maxTokens,
                iteration: i
            )
            results.append(result)
        }

        return BenchmarkReport(
            modelID: modelID,
            modelPath: modelDirectory.path,
            prompt: prompt,
            iterations: results,
            hardwareDescription: hardwareDesc
        )
    }

    private static func runIteration(
        container: ModelContainer,
        modelID: String,
        prompt: String,
        maxTokens: Int,
        iteration: Int
    ) async throws -> BenchmarkIterationResult {
        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: prompt)
        ]

        let request = ChatCompletionRequest(
            model: modelID,
            messages: messages,
            temperature: 0.6,
            max_tokens: maxTokens,
            stream: false
        )

        let rawMessages = try messages.map { msg -> MLXLMCommon.Message in
            ["role": msg.role, "content": msg.content] as MLXLMCommon.Message
        }

        let iterationStart = ContinuousClock.now

        let generationStream: AsyncStream<Generation> = try await container.perform {
            context in
            let input = try await context.processor.prepare(
                input: UserInput(messages: rawMessages))
            let params = GenerateParameters(
                maxTokens: request.max_tokens,
                temperature: request.temperature ?? 0.6,
                topP: request.top_p ?? 1.0,
                topK: request.top_k ?? 0
            )
            return try MLXLMCommon.generate(
                input: input, parameters: params, context: context)
        }

        var promptTokens = 0
        var completionTokens = 0
        var prefillLatencyMs: Double = 0
        var firstTokenTime: ContinuousClock.Instant?

        for await generation in generationStream {
            switch generation {
            case .chunk:
                if firstTokenTime == nil {
                    firstTokenTime = .now
                    let elapsed = firstTokenTime! - iterationStart
                    prefillLatencyMs = Double(elapsed.components.attoseconds) / 1e15
                }

            case .info(let info):
                promptTokens = info.promptTokenCount
                completionTokens = info.generationTokenCount
                // Use the info's own timing if we didn't capture first token
                if prefillLatencyMs == 0 {
                    prefillLatencyMs = info.promptTime * 1000
                }

            case .toolCall:
                break
            }
        }

        let totalElapsed = ContinuousClock.now - iterationStart
        let totalTimeMs = Double(totalElapsed.components.attoseconds) / 1e15

        // Calculate decode TPS from the generation info's timing when available,
        // otherwise approximate from wall-clock
        let decodeTimeMs = totalTimeMs - prefillLatencyMs
        let decodeTokensPerSecond: Double
        if completionTokens > 0 && decodeTimeMs > 0 {
            decodeTokensPerSecond = Double(completionTokens) / (decodeTimeMs / 1000)
        } else {
            decodeTokensPerSecond = 0
        }

        return BenchmarkIterationResult(
            iteration: iteration,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            prefillLatencyMs: prefillLatencyMs,
            decodeTokensPerSecond: decodeTokensPerSecond,
            totalTimeMs: totalTimeMs
        )
    }
}
