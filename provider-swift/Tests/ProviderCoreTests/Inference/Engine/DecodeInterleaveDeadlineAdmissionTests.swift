import Foundation
import MLX
import Testing

@testable import MLXLMCommon
@testable import ProviderCore

/// First-content deadline admission with GLM's decode-only steps between
/// prompt chunks, through `EngineV2Bridge` and a real `EngineV2` over a
/// fixture model. The engine prices the held steps; it no longer refuses every
/// deadline as an unprojectable scheduler.
@Suite("Deadline admission with decode-only steps between chunks", .serialized)
struct DecodeInterleaveDeadlineAdmissionTests {
    private let now = ContinuousClock.now
    private let request = ChatCompletionRequest(
        model: "decode-interleave-fixture", messages: [], max_tokens: 1)
    /// Two 16-token chunks.
    private let prompt = Array(repeating: 1, count: 32)

    /// GLM's default interleave on 16-token chunks, a step that holds one
    /// chunk beside two decode rows, measured at 16 prompt tokens per second
    /// and one-second steps of two decode rows.
    private func bridge() async throws -> (EngineV2Bridge, EngineV2) {
        let model = DeadlineAdmissionFixtureModel()
        var scheduler = CBv2SchedulerConfig(
            maxConcurrentRequests: 3, maxBatchedTokensPerStep: 18, prefillChunkSize: 16,
            maxConcurrentPartialPrefills: 1, maxWaiting: 4)
        scheduler.decodeStepsBetweenPrefillChunks =
            try EngineV2Factory.glm5NextDecodeStepsBetweenChunks(environment: [:])
        let engine = EngineV2(
            model: model, layerKinds: model.kinds,
            backend: CBv2ContiguousKVBackend(config: .init(bytesCapacity: 1 << 20)),
            cacheProvider: CBv2LayerCacheBank(layerKinds: model.kinds),
            sampler: CBv2GreedySampler(), schedulerConfig: scheduler,
            loopConfig: .init(clock: CBv2Clock { [now] in now }))
        let bridge = EngineV2Bridge(
            engine: engine, modelId: "decode-interleave-fixture",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()), eosTokenIds: [],
            prefillDeadlineMode: .enforce, admissionFixes: true)
        await bridge.updatePrefillTpsEwma(16, isolated: true)
        await bridge.updateDecodeTpsEwma(1, shape: .init(batchRows: 2))
        return (bridge, engine)
    }

    private func deadline(seconds: Int64) -> FirstContentDeadline {
        FirstContentDeadline(relativeBudgetMilliseconds: seconds * 1_000, receivedAt: now)
    }

    private func drain(_ stream: AsyncStream<GenerationEvent>) async -> [String] {
        var errors: [String] = []
        for await event in stream {
            if case .error(let message) = event { errors.append(message) }
        }
        return errors
    }

    @Test("a request served alone is priced for its prompt only")
    func loneRequestHasNoHeldSteps() async throws {
        let (bridge, engine) = try await bridge()
        do {
            let profile = RequestProfileBuilder()
            let stream = try await bridge.submitTokenized(
                promptTokens: prompt, request: request, requestId: "alone",
                firstContentDeadline: deadline(seconds: 60), profile: profile)
            #expect(await drain(stream).isEmpty)
            let decision = try #require(profile.wireObject().deadlineDecision)
            #expect(decision.verdict == .accepted)
            #expect(decision.projectedPrefillTokens == 32 && decision.projectedDecodeTokens == 0)
            #expect(decision.projectedServiceUs == 2_000_000)
            #expect(engine.capacity().activeRequests == 0)
            await bridge.shutdown()
        } catch {
            await bridge.shutdown()
            throw error
        }
    }

    @Test("a deadline that covers the held steps is admitted, a shorter one refused as bounded work")
    func heldDecodeStepsArePriced() async throws {
        let (bridge, engine) = try await bridge()
        let loop = engine.loopForTesting
        let decoders = (0 ..< 2).map {
            CBv2Request(id: .init(920_001 + UInt64($0)), promptTokens: [1], maxTokens: 64)
        }
        func release() {
            loop.onEngineQueueSync {
                for decoder in decoders { loop.finishRequest(decoder.id, reason: .cancelled) }
                loop.suspendStepExecutionAtCountForTesting = nil
            }
        }
        do {
            try loop.onEngineQueueSync {
                // Freeze right after the loop launches one decode step for both
                // rows; admissions still run on the engine queue.
                loop.suspendStepExecutionAtCountForTesting = 1
                for decoder in decoders { try loop.scheduler.enqueue(decoder) }
                for (id, _) in loop.scheduler.plan().assignments {
                    loop.scheduler.markPendingSamples(ids: [id])
                    loop.scheduler.recordSampled(id: id, token: 2)
                }
            }
            var polls = 0
            while loop.onEngineQueueSync({ loop.stepCount }) < 1, polls < 1_000 {
                try await Task.sleep(for: .milliseconds(5))
                polls += 1
            }
            #expect(loop.onEngineQueueSync { loop.stepCount } == 1)

            // The launched decode step, chunk 1 beside both rows, eight held
            // steps and chunk 2: 32 prompt tokens in 2 s and eleven one-second
            // two-row steps.
            let short = RequestProfileBuilder()
            await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
                _ = try await bridge.submitTokenized(
                    promptTokens: prompt, request: request, requestId: "short",
                    firstContentDeadline: deadline(seconds: 12), profile: short)
            }
            let refused = try #require(short.wireObject().deadlineDecision)
            #expect(refused.verdict == .deadlineUnreachable)
            #expect(refused.projection == .bounded)
            #expect(refused.projectedPrefillTokens == 32 && refused.projectedDecodeTokens == 22)
            #expect(refused.projectedServiceUs == 13_000_000)

            let covered = RequestProfileBuilder()
            let stream = try await bridge.submitTokenized(
                promptTokens: prompt, request: request, requestId: "covered",
                firstContentDeadline: deadline(seconds: 60), profile: covered)
            let admitted = try #require(covered.wireObject().deadlineDecision)
            #expect(admitted.verdict == .accepted)
            #expect(admitted.projectedServiceUs == 13_000_000)

            release()
            #expect(await drain(stream).isEmpty)
            await bridge.shutdown()
        } catch {
            release()
            await bridge.shutdown()
            throw error
        }
    }
}
