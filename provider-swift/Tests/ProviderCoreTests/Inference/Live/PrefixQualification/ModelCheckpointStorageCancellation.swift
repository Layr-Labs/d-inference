import Foundation
import MLXLMCommon
import Testing

@_spi(Benchmarking) @testable import ProviderCore

struct ModelCheckpointStorageCancellation: Codable, Sendable {
    let cell: String
    let pair: Int
    let cancellationIssued: Bool
    let cancelledTerminalObserved: Bool
    let outputTokensBeforeTerminal: Int
    let stageDisposition: String
    let restoredTokens: Int
    let filesWrittenDelta: Int
    let bytesWrittenDelta: Int
    let stagedBytesAfterRetirement: Int
    let writeHostBytesAfterRetirement: Int
    let memoryAfterRetirement: ModelPrefixBenchmarkMemoryObservation
}

extension ModelPrefixBenchmarkFixture {
    /// Cancel a real SSD-restored request after visible output, then acknowledge
    /// its terminal and join ordinary retirement before another request starts.
    /// This is not cancellation-during-decryption evidence; SDK tests own that.
    func cancelRestored(cell: String, pair: Int, tokens: [Int], scope: String) async throws
        -> ModelCheckpointStorageCancellation
    {
        let before = try #require(await session.cacheSnapshot().checkpoints)
        let request = CBv2Request(id: .init(19), promptTokens: tokens,
            sampling: .init(temperature: 0), maxTokens: 1_024, stopTokens: [],
            cacheSalt: scope, prefixCacheEnabled: true, prefixCheckpointTargetTokens: 0)
        let submitted = try await session.submit(request)
        var issued = false
        var outputCount = 0
        var finish: CBv2FinishReason?
        var usage: CBv2Usage?
        for await event in submitted.events {
            switch event {
            case .delta(_, let tokens, _):
                outputCount += tokens.count
                if !tokens.isEmpty && !issued {
                    issued = true
                    session.rawEngine.cancel(request.id)
                }
            case .finished(let reason, let value):
                finish = reason
                usage = value
            }
        }
        // Error/retained native terminals must go through throwing shutdown,
        // never wait indefinitely on a successful-retirement acknowledgement.
        try #require(finish == .cancelled || finish == .length || finish == .stop)
        let finalUsage = try #require(usage)
        await session.complete(receiptID: submitted.receiptID)
        try await requireIdle()
        try await session.drainCheckpointWrites()
        let cache = try #require(await session.cacheSnapshot().checkpoints)
        return ModelCheckpointStorageCancellation(cell: cell, pair: pair,
            cancellationIssued: issued, cancelledTerminalObserved: finish == .cancelled,
            outputTokensBeforeTerminal: outputCount, stageDisposition: submitted.stageDisposition,
            restoredTokens: finalUsage.prefixCachePrefillTokensSaved,
            filesWrittenDelta: cache.filesWritten - before.filesWritten,
            bytesWrittenDelta: cache.bytesWritten - before.bytesWritten,
            stagedBytesAfterRetirement: cache.stagedBytesInUse,
            writeHostBytesAfterRetirement: cache.writeHostBytesInUse,
            memoryAfterRetirement: memoryObservation())
    }
}
