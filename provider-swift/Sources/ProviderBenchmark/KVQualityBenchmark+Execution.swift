import Foundation
import MLXLMCommon
@_spi(Benchmarking) import ProviderCore

extension KVQualityBenchmark {
    private struct Scheduled: Sendable {
        let index: Int
        let started: UInt64
        let submission: EngineV2BenchmarkSession.Submission
    }

    static func collect(input: KVQualityInput, session: EngineV2BenchmarkSession) async throws -> [KVQualityCollectedCase] {
        var results: [KVQualityCollectedCase] = []
        for first in stride(from: 0, to: input.cases.count, by: input.resolvedConcurrency) {
            try Task.checkCancellation()
            var scheduled: [Scheduled] = []
            // Submit in input order before collecting this bounded cohort.
            for index in first ..< min(input.cases.count, first + input.resolvedConcurrency) {
                let sample = input.cases[index], started = DispatchTime.now().uptimeNanoseconds
                do {
                    let submission = try await session.submit(.init(
                        id: .init(UInt64(index + 1)), promptTokens: sample.promptTokens,
                        sampling: .init(temperature: 0, seed: 0), maxTokens: sample.maxTokens,
                        stopTokens: session.stopTokenIDs, prefixCacheEnabled: false))
                    scheduled.append(.init(index: index, started: started, submission: submission))
                } catch {
                    results.append(.init(index: index, requestID: UInt64(index + 1), receiptID: nil,
                        elapsedMs: milliseconds(since: started), firstTokenMs: nil, tokens: [], streamedText: "",
                        finishReason: nil, terminalCause: nil, error: String(String(describing: error).prefix(4096)),
                        issues: ["submit_failed"]))
                }
            }
            await withTaskGroup(of: KVQualityCollectedCase.self) { group in
                for row in scheduled {
                    group.addTask { await collectOne(row: row, maximumTokens: input.cases[row.index].maxTokens, session: session) }
                }
                for await result in group { results.append(result) }
            }
        }
        try Task.checkCancellation()
        return results
    }

    private static func collectOne(row: Scheduled, maximumTokens: Int,
                                   session: EngineV2BenchmarkSession) async -> KVQualityCollectedCase {
        let requestID = CBv2RequestID(UInt64(row.index + 1))
        let collectorTask = Task {
            await KVQualityEventCollector.drain(
                events: row.submission.events, index: row.index, receiptID: row.submission.receiptID.raw,
                maximumTokens: maximumTokens, startedAt: row.started,
                cancel: { session.rawEngine.cancel(requestID) })
        }
        let deadline = KVQualityDeadline.start(startedAt: row.started) {
            session.rawEngine.cancel(requestID)
            collectorTask.cancel()
        }
        let result = await withTaskCancellationHandler {
            await collectorTask.value
        } onCancel: {
            session.rawEngine.cancel(requestID)
            collectorTask.cancel()
        }
        deadline.cancel()
        await deadline.value
        await session.complete(receiptID: row.submission.receiptID)
        return result
    }

    private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
}
