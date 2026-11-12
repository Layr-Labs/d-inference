import Foundation
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing

@testable import ProviderCore

/// No weights and no inference: the slot's container is never run.
private final class InFlightStubModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], state: LMOutput.State?, prefill: PrefillParameters) throws
        -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

private struct InFlightUnusedProcessor: UserInputProcessor {
    private struct NotUsed: Error {}
    func prepare(input: UserInput) async throws -> LMInput { throw NotUsed() }
}

/// Holds every request open and writes its tokens only when told: an answer in
/// flight. No tensors.
private final class InFlightEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [(request: CBv2Request, events: AsyncStream<CBv2Event>.Continuation)] = []

    var submitted: Int { lock.withLock { held.count } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        lock.withLock { held.append((request, continuation)) }
        return stream
    }

    func write(tokens: Int) {
        for (_, events) in lock.withLock({ held }) {
            for _ in 0..<tokens { events.yield(.delta(text: "x", tokens: [7], logprobs: nil)) }
        }
    }

    func finish(completionTokens: Int) {
        for (request, events) in lock.withLock({ held }) {
            events.yield(.finished(reason: .stop, usage: CBv2Usage(promptTokens: request.promptTokens.count,
                                                                   completionTokens: completionTokens)))
            events.finish()
        }
    }

    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        lock.withLock {
            .init(activeRequests: held.count, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 1 << 30,
                  activeTokens: 0)
        }
    }
    func shutdown() async {}
}

/// W1-D1 (0.10.12 W1): on a Mac that serves only you (`darkbloom start --local`),
/// the standalone server writes the state file `darkbloom status` reads, and it
/// must carry the answers in progress as the coordinator-connected provider's
/// does (`DaemonState.runningRequests`). Before, a local answer in flight was
/// never listed there.
@Suite("Only me: status lists the answers in progress", .serialized)
struct StandaloneRunningRequestsTests {
    static let model = "qwen3.6-35b-a3b-vl-mtp-mxfp8"

    @Test func aLocalAnswerInFlightIsInTheStateFileStatusReads() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("only-me-running-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateFile = directory.appendingPathComponent("daemon-state.json")

        let engine = InFlightEngine()
        let tokenizer = TokenizerHandle(StubBridgeTokenizer())
        let bridge = EngineV2Bridge(engine: engine, modelId: Self.model, tokenizer: tokenizer, eosTokenIds: [],
            defaultMaxTokens: 32_768, defaultMaxTokensContextLimit: 262_144, maxConcurrentRequests: 4,
            kvBudget: GlobalKVCacheBudget(memorySnapshot: {
                .init(total: 256 << 30, active: 0, cache: 0, systemAvailable: 256 << 30)
            }))
        let server = StandaloneServer(config: .init(port: 0))
        await server.installSlotForTesting(
            modelId: Self.model, bridge: bridge,
            container: ModelContainer(context: ModelContext(configuration: ModelConfiguration(id: Self.model),
                model: InFlightStubModel(), processor: InFlightUnusedProcessor(), tokenizer: StubBridgeTokenizer())),
            tokenizer: tokenizer,
            sizing: SlotSizingSnapshot(weightsBytes: 1 << 20, fp16KVBytesPerToken: 1024, maxContextLength: 262_144,
                                       defaultMaxTokens: 32_768),
            modelType: "qwen3_5_moe")
        await server.startLifecycleControl(stateFile: stateFile)

        // The owner's own request on the local API: it never meets a coordinator.
        let events = await bridge.submitTokenized(
            promptTokens: [1, 2, 3],
            request: ChatCompletionRequest(model: Self.model, messages: [ChatMessage(role: "user", content: "hi")],
                                           max_tokens: 64, stream: true),
            requestId: "local-7f3a")
        let reader = Task { for await _ in events {} }
        #expect(await Self.eventually { engine.submitted == 1 })
        engine.write(tokens: 3)

        let listed = await Self.eventually {
            DaemonStateFile.read(from: stateFile)?.runningRequests?.first?.outputTokens == 3
        }
        #expect(listed, "the answer in flight is in the state file `status` reads")
        let running = DaemonStateFile.read(from: stateFile)?.runningRequests ?? []
        #expect(running.map(\.model) == [Self.model])
        #expect(running.map(\.ref) == [RunningRequestProgressTracker.ref("local-7f3a")])

        engine.finish(completionTokens: 3)
        await reader.value
        #expect(await Self.eventually { DaemonStateFile.read(from: stateFile)?.runningRequests == [] },
                "the list empties when the answer finishes")
        await server.stop()
    }

    /// Polls `condition` until it holds or `timeout` passes (the state file is
    /// rewritten every 250 ms; the list is sampled every 2 s).
    static func eventually(timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }
}
