import Foundation
import MLXLMCommon
import Testing

@testable import ProviderBenchmark

@Suite("arrival engine runner")
struct ArrivalEngineRunnerTests {
    @Test(arguments: [2, 4])
    func batchSizeSubmitsEveryRowThroughOneEngine(batchSize: Int) async throws {
        let engine = ArrivalScriptedEngine { request in
            successfulEvents(
                request: request,
                tokens: [100 + (request.promptTokens.first ?? 0), 900])
        }
        let delays = try #require(
            ArrivalPrefillAccounting.delaysMs(
                batchSize: batchSize,
                pattern: "burst"))
        let prompts = (0 ..< batchSize).map { [$0 + 1, 42] }

        let sample = try await ArrivalEngineRunner.run(
            engine: engine,
            arrivalDelaysMs: delays,
            prompts: prompts,
            decodeTokens: 2,
            requestIDBase: 50)

        let submitted = engine.submitted.sorted { $0.id.raw < $1.id.raw }
        #expect(submitted.count == batchSize)
        #expect(submitted.map(\.id.raw) == (0 ..< batchSize).map { 50 + UInt64($0) })
        #expect(submitted.map(\.promptTokens) == prompts)
        #expect(submitted.allSatisfy { $0.maxTokens == 2 })
        #expect(sample.rows.count == batchSize)
        #expect(sample.rows.map(\.row) == Array(0 ..< batchSize))
        #expect(sample.rows.allSatisfy { $0.firstTokenAtNs >= $0.submittedAtNs })
        #expect(sample.rows.allSatisfy { $0.completedAtNs >= $0.firstTokenAtNs })
        #expect(sample.rows.allSatisfy { $0.tokenIDs.count == 2 })
    }

    @Test
    func rowWithoutFirstTokenPoisonsWholeSample() async {
        let engine = ArrivalScriptedEngine { request in
            if request.promptTokens.first == 2 {
                return [
                    .finished(
                        reason: .length,
                        usage: usage(for: request, completionTokens: 0))
                ]
            }
            return successfulEvents(request: request, tokens: [101, 901])
        }

        await #expect(
            throws: ArrivalEngineRunnerError.noFirstToken(row: 1)
        ) {
            _ = try await ArrivalEngineRunner.run(
                engine: engine,
                arrivalDelaysMs: [0, 0],
                prompts: [[1, 42], [2, 42]],
                decodeTokens: 2,
                requestIDBase: 100)
        }
        #expect(engine.submitted.count == 2)
    }

    @Test
    func rowWithoutCompletionPoisonsWholeSample() async {
        let engine = ArrivalScriptedEngine { request in
            if request.promptTokens.first == 2 {
                return [.delta(text: "", tokens: [102, 902], logprobs: nil)]
            }
            return successfulEvents(request: request, tokens: [101, 901])
        }

        await #expect(
            throws: ArrivalEngineRunnerError.missingCompletion(row: 1)
        ) {
            _ = try await ArrivalEngineRunner.run(
                engine: engine,
                arrivalDelaysMs: [0, 0],
                prompts: [[1, 42], [2, 42]],
                decodeTokens: 2,
                requestIDBase: 200)
        }
        #expect(engine.submitted.count == 2)
    }

    @Test
    func terminalErrorPoisonsWholeSample() async {
        let engine = ArrivalScriptedEngine { request in
            if request.promptTokens.first == 2 {
                return [
                    .delta(text: "", tokens: [102, 902], logprobs: nil),
                    .finished(
                        reason: .error("injected row failure"),
                        usage: usage(for: request, completionTokens: 2)),
                ]
            }
            return successfulEvents(request: request, tokens: [101, 901])
        }

        await #expect(
            throws: ArrivalEngineRunnerError.requestFailed(
                row: 1,
                message: "injected row failure")
        ) {
            _ = try await ArrivalEngineRunner.run(
                engine: engine,
                arrivalDelaysMs: [0, 0],
                prompts: [[1, 42], [2, 42]],
                decodeTokens: 2,
                requestIDBase: 300)
        }
        #expect(engine.submitted.count == 2)
    }

    @Test
    func firstTokenInvarianceRemainsExplicitWhenLaterOutputDiffers() async throws {
        let engine = ArrivalScriptedEngine { request in
            let firstToken = 100 + (request.promptTokens.first ?? 0)
            let runMarker = Int(request.id.raw / 100)
            return successfulEvents(
                request: request,
                tokens: [firstToken, 900 + runMarker])
        }
        let prompts = [[1, 42], [2, 42]]
        let burstDelays = try #require(
            ArrivalPrefillAccounting.delaysMs(
                batchSize: 2,
                pattern: "burst"))
        let staggerDelays = try #require(
            ArrivalPrefillAccounting.delaysMs(
                batchSize: 2,
                pattern: "stagger-25ms"))

        let burst = try await ArrivalEngineRunner.run(
            engine: engine,
            arrivalDelaysMs: burstDelays,
            prompts: prompts,
            decodeTokens: 2,
            requestIDBase: 1)
        let staggerOne = try await ArrivalEngineRunner.run(
            engine: engine,
            arrivalDelaysMs: staggerDelays,
            prompts: prompts,
            decodeTokens: 2,
            requestIDBase: 100)
        let staggerTwo = try await ArrivalEngineRunner.run(
            engine: engine,
            arrivalDelaysMs: staggerDelays,
            prompts: prompts,
            decodeTokens: 2,
            requestIDBase: 200)

        let invariance = ArrivalOutputInvariance.evaluate(
            outputsByIteration: [staggerOne.outputs, staggerTwo.outputs],
            burstOutputs: burst.outputs)
        #expect(invariance.firstTokensStableAcrossIterations)
        #expect(invariance.firstTokensMatchBurst)
        #expect(!invariance.outputsStableAcrossIterations)
        #expect(!invariance.outputsMatchBurst)

        for row in burst.rows.indices {
            #expect(
                ArrivalPrefillAccounting.tokenChecksum([
                    burst.rows[row].firstTokenID
                ])
                    == ArrivalPrefillAccounting.tokenChecksum([
                        staggerOne.rows[row].firstTokenID
                    ]))
            #expect(
                ArrivalPrefillAccounting.tokenChecksum(
                    burst.rows[row].tokenIDs)
                    != ArrivalPrefillAccounting.tokenChecksum(
                        staggerOne.rows[row].tokenIDs))
        }
        #expect(engine.submitted.count == 6)
    }
}

private final class ArrivalScriptedEngine: CBv2Engine, @unchecked Sendable {
    typealias Script = @Sendable (CBv2Request) throws -> [CBv2Event]

    private let lock = NSLock()
    private let script: Script
    private var submittedRequests: [CBv2Request] = []

    init(script: @escaping Script) {
        self.script = script
    }

    var submitted: [CBv2Request] {
        lock.lock()
        defer { lock.unlock() }
        return submittedRequests
    }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        lock.lock()
        submittedRequests.append(request)
        lock.unlock()

        let events = try script(request)
        return AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
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

private func successfulEvents(
    request: CBv2Request,
    tokens: [Int]
) -> [CBv2Event] {
    [
        .delta(text: "", tokens: Array(tokens.prefix(1)), logprobs: nil),
        .delta(text: "", tokens: Array(tokens.dropFirst()), logprobs: nil),
        .finished(
            reason: .length,
            usage: usage(for: request, completionTokens: tokens.count)),
    ]
}

private func usage(
    for request: CBv2Request,
    completionTokens: Int
) -> CBv2Usage {
    CBv2Usage(
        promptTokens: request.promptTokens.count,
        completionTokens: completionTokens)
}
