import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import ProviderCore

public struct SchedulerPrefillBenchmarkReport: Codable, Sendable {
    public struct Sample: Codable, Sendable {
        public let strategy: String
        public let promptTokens: Int
        public let iteration: Int
        public let ttftMs: Double
        public let msPerPrefillToken: Double
        public let chunks: [Chunk]
        public let finalAdaptiveChunkSize: Int?
    }

    public struct Chunk: Codable, Sendable {
        public let requestedChunkSize: Int
        public let actualChunkSize: Int
        public let durationMs: Double
        public let tokensPerSecond: Double
    }

    public let modelID: String
    public let modelPath: String
    public let promptLengths: [Int]
    public let strategies: [String]
    public let iterations: Int
    public let samples: [Sample]

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

public enum SchedulerPrefillBenchmark {
    public static let defaultStrategies = "fixed:512,adaptive"

    public enum Strategy: Sendable, Equatable {
        case fixed(Int)
        case adaptive

        public var label: String {
            switch self {
            case .fixed(let chunk): return "fixed:\(chunk)"
            case .adaptive: return "adaptive"
            }
        }
    }

    private final class ChunkRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [SchedulerPrefillBenchmarkReport.Chunk] = []

        func append(_ sample: ColdPrefillChunkSample) {
            let durationMs = sample.durationSeconds * 1000.0
            let tps = sample.durationSeconds > 0
                ? Double(sample.totalTokens) / sample.durationSeconds
                : 0
            lock.lock()
            values.append(SchedulerPrefillBenchmarkReport.Chunk(
                requestedChunkSize: sample.requestedChunkSize,
                actualChunkSize: sample.actualChunkSize,
                durationMs: durationMs,
                tokensPerSecond: tps
            ))
            lock.unlock()
        }

        func snapshot() -> [SchedulerPrefillBenchmarkReport.Chunk] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    public static func parseStrategies(_ raw: String) -> [Strategy] {
        raw.split(separator: ",")
            .compactMap { token -> Strategy? in
                let value = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if value == "adaptive" { return .adaptive }
                let prefix = "fixed:"
                guard value.hasPrefix(prefix),
                      let chunk = Int(value.dropFirst(prefix.count)),
                      chunk > 0
                else { return nil }
                return .fixed(chunk)
            }
    }

    public static func run(
        modelID: String,
        modelDirectory: URL,
        promptLengths: [Int],
        strategies: [Strategy],
        iterations: Int
    ) async throws -> SchedulerPrefillBenchmarkReport {
        let lengths = promptLengths.filter { $0 > 1 }.sorted()
        let strategies = strategies.isEmpty ? [.fixed(512)] : strategies
        let iterations = max(1, iterations)
        log("loading model \(modelID)")
        log("  path: \(modelDirectory.path)")

        let container = try await LLMModelFactory.shared.loadContainer(
            from: modelDirectory,
            using: LocalTokenizerLoader()
        )
        let baseTokens = await container.perform { ctx in
            let encoded = ctx.tokenizer.encode(text: ThroughputSweep.seedText, addSpecialTokens: false)
            return encoded.isEmpty ? [0] : encoded
        }

        // Mirror production policy construction: seed the adaptive ladder from
        // the detected GPU roofline + the model's own architecture. One runtime
        // is shared across all adaptive iterations (isolated temp store) so it
        // accumulates clean first-chunk samples and actually converges, rather
        // than re-seeding every measurement.
        let hardware = try? HardwareDetector.detect()
        let architecture = KVEstimation.parseModelArchitecture(
            at: modelDirectory.appendingPathComponent("config.json"))
        let adaptivePolicy = adaptivePolicy(
            modelID: modelID, hardware: hardware, architecture: architecture)
        if let hardware {
            log("seed: chip=\(hardware.chipName) ridge=\(String(format: "%.1f", hardware.rooflineRidgeFlopPerByte)) -> initial chunk \(adaptivePolicy.initialState().currentChunkSize), ladder \(adaptivePolicy.ladder)")
        } else {
            log("seed: hardware unknown -> generic ladder \(adaptivePolicy.ladder), initial \(adaptivePolicy.initialState().currentChunkSize)")
        }
        let sharedAdaptiveRuntime = makeAdaptiveRuntime(modelID: modelID, policy: adaptivePolicy)

        _ = try await measureOne(
            container: container,
            modelID: modelID,
            baseTokens: baseTokens,
            promptTokens: min(lengths.first ?? 128, 128),
            strategy: .fixed(512),
            iteration: 0,
            record: false,
            adaptiveRuntime: nil
        )

        var samples: [SchedulerPrefillBenchmarkReport.Sample] = []
        for length in lengths {
            for strategy in strategies {
                for iteration in 1 ... iterations {
                    let sample = try await measureOne(
                        container: container,
                        modelID: modelID,
                        baseTokens: baseTokens,
                        promptTokens: length,
                        strategy: strategy,
                        iteration: iteration,
                        record: true,
                        adaptiveRuntime: strategy == .adaptive ? sharedAdaptiveRuntime : nil
                    )
                    log("  \(strategy.label) L=\(length) i=\(iteration): \(String(format: "%.3f", sample.msPerPrefillToken)) ms/t (\(String(format: "%.1f", sample.ttftMs)) ms, chunk=\(sample.finalAdaptiveChunkSize.map(String.init) ?? "-"))")
                    samples.append(sample)
                }
            }
        }

        return SchedulerPrefillBenchmarkReport(
            modelID: modelID,
            modelPath: modelDirectory.path,
            promptLengths: lengths,
            strategies: strategies.map(\.label),
            iterations: iterations,
            samples: samples
        )
    }

    private static func measureOne(
        container: ModelContainer,
        modelID: String,
        baseTokens: [Int],
        promptTokens: Int,
        strategy: Strategy,
        iteration: Int,
        record: Bool,
        adaptiveRuntime: AdaptivePrefillRuntime?
    ) async throws -> SchedulerPrefillBenchmarkReport.Sample {
        let recorder = ChunkRecorder()

        let engine = await container.perform { ctx -> BatchedEngine in
            let prefillStepSize: Int
            switch strategy {
            case .fixed(let chunk): prefillStepSize = chunk
            case .adaptive: prefillStepSize = 512
            }
            let scheduler = Scheduler(
                model: ctx.model,
                tokenizer: ctx.tokenizer,
                config: SchedulerConfig(
                    maxNumSeqs: 1,
                    maxNumBatchedTokens: 8192,
                    prefillStepSize: prefillStepSize,
                    streamInterval: 1,
                    maxKVCacheTokens: 0
                ),
                eosTokenIds: ctx.configuration.eosTokenIds,
                prefixCache: nil
            )
            if let adaptiveRuntime {
                scheduler.adaptivePrefillChunkSizer = adaptiveRuntime.proposeChunkSize
                scheduler.onColdPrefillChunk = { sample in
                    recorder.append(sample)
                    adaptiveRuntime.record(sample)
                }
            } else {
                scheduler.onColdPrefillChunk = recorder.append
            }
            return BatchedEngine(
                scheduler: scheduler,
                tokenizer: ctx.tokenizer,
                modelName: modelID,
                config: ContinuousBatchingConfig(
                    schedulerConfig: scheduler.config,
                    stepInterval: 0.001,
                    prefixCacheConfig: nil,
                    mtpEnabled: false
                ),
                externalChatTemplate: nil
            )
        }
        await engine.start()

        let prompt = ThroughputSweep.tile(baseTokens, to: promptTokens, offset: iteration * 17)
        let requestID = "prefill-bench-\(UUID().uuidString.prefix(8))"
        let started = ContinuousClock.now
        _ = await engine.core.addRequest(Request(
            requestId: requestID,
            prompt: prompt as AnyHashable,
            samplingParams: SamplingParams(maxTokens: 1, temperature: 0.0)
        ))

        var firstOutput: Duration?
        var errorMessage: String?
        for await output in engine.core.streamOutputs(requestId: requestID) {
            if firstOutput == nil {
                firstOutput = ContinuousClock.now - started
            }
            if let error = output.error {
                errorMessage = error
                break
            }
            if output.finished { break }
        }
        if let errorMessage {
            await stopAndReclaim(engine)
            throw BenchmarkError.requestFailed(errorMessage)
        }
        let elapsed = firstOutput ?? (ContinuousClock.now - started)
        let ttftMs = ThroughputSweep.seconds(elapsed) * 1000.0
        let prefillTokens = max(1, promptTokens - 1)
        await stopAndReclaim(engine)
        return SchedulerPrefillBenchmarkReport.Sample(
            strategy: strategy.label,
            promptTokens: promptTokens,
            iteration: iteration,
            ttftMs: ttftMs,
            msPerPrefillToken: ttftMs / Double(prefillTokens),
            chunks: record ? recorder.snapshot() : [],
            finalAdaptiveChunkSize: adaptiveRuntime?.snapshotState().currentChunkSize
        )
    }

    private static func modelDirectoryIdentity(modelID: String) -> String {
        "bench:\(modelID)"
    }

    /// Production-mirrored policy: roofline-seeded from hardware + architecture
    /// when both are available, else the generic empirical default.
    private static func adaptivePolicy(
        modelID: String,
        hardware: HardwareInfo?,
        architecture: ModelArchitecture
    ) -> AdaptivePrefillPolicy {
        guard let hardware else { return .liveDefault() }
        return AdaptivePrefillSeed.policy(hardware: hardware, model: architecture)
    }

    /// One adaptive runtime per benchmark run, backed by an isolated temp store
    /// so prior on-disk learned state never taints the measurement.
    private static func makeAdaptiveRuntime(
        modelID: String,
        policy: AdaptivePrefillPolicy
    ) -> AdaptivePrefillRuntime {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("darkbloom-adaptive-prefill-bench-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state.json")
        let key = AdaptivePrefillStoreKey(
            modelId: modelID,
            weightIdentity: modelDirectoryIdentity(modelID: modelID),
            kvMode: "fp16",
            hardwareMemoryFingerprint: "bench:\(ProcessInfo.processInfo.physicalMemory)"
        )
        return AdaptivePrefillRuntime(
            policy: policy,
            store: AdaptivePrefillStore(url: storeURL),
            key: key
        )
    }

    private static func stopAndReclaim(_ engine: BatchedEngine) async {
        await engine.core.stopAndWait()
        Stream().synchronize()
        Memory.clearCache()
    }

    private enum BenchmarkError: Error, CustomStringConvertible {
        case requestFailed(String)

        var description: String {
            switch self {
            case .requestFailed(let message): return message
            }
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[scheduler-prefill] \(message)\n".utf8))
    }
}
