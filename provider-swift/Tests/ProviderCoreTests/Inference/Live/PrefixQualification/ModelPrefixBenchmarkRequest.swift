import CryptoKit
import Foundation
import MLXLMCommon
import Testing

@_spi(Benchmarking) @testable import ProviderCore

extension ModelPrefixBenchmarkFixture {
    func run(cell: String, pair: Int, role: String, tokens: [Int], scope: String,
             target: Int?, cacheEnabled: Bool, observeStorage: Bool = false,
             expectedMarker: String? = nil, recordPrefillRanges: Bool = false) async throws -> ModelPrefixBenchmarkRow {
        let before = await session.cacheSnapshot().checkpoints ?? SSDHybridCheckpointStats()
        let configuration = schedulerConfiguration
        let mtpBefore = session.rawEngine.mtpMetricsSnapshot()
        let captureDiagnostics = specification.captureTokenDiagnostics == true
        var request = Self.benchmarkRequest(tokens: tokens, scope: scope, target: target,
            cacheEnabled: cacheEnabled, outputTokens: specification.outputTokens,
            captureDiagnostics: captureDiagnostics)
        let trace = recordPrefillRanges ? try prefillTraceRecorder() : nil
        let capture = try trace?.begin(requestID: request.id, promptTokens: tokens.count)
        defer { if let capture { trace?.end(capture) } }
        let memory = observeStorage ? ModelPrefixBenchmarkPrefillMemoryCapture(requestID: request.id) : nil
        if let memory {
            request.onPrefillCompleted = { [weak engine = session.rawEngine] usage in
                if let engine { memory.record(usage: usage, engine: engine) }
            }
        }
        let started = ContinuousClock.now
        let submitted = try await session.submit(request)
        var outputTiming = ModelPrefixBenchmarkOutputTiming()
        var terminal: ContinuousClock.Instant?
        var output: [Int] = []
        var observedLogprobs: [CBv2TokenLogprob] = []
        var finalUsage: CBv2Usage?
        var finish: CBv2FinishReason?
        for await event in submitted.events {
            switch event {
            case .delta(_, let newTokens, let logprobs):
                guard !newTokens.isEmpty else { continue }
                outputTiming.record(tokenCount: newTokens.count, at: .now)
                output += newTokens
                if captureDiagnostics { observedLogprobs += logprobs ?? [] }
            case .finished(let reason, let usage):
                terminal = .now
                finish = reason
                finalUsage = usage
            }
        }
        let usage = try await ModelPrefixBenchmarkTerminal.completeSuccessfulRequest(
            finish: finish, usage: finalUsage, outputCount: output.count,
            expectedOutputCount: specification.outputTokens) {
                await session.complete(receiptID: submitted.receiptID)
            }
        let complete = ContinuousClock.now
        let quiescence = try await ModelPrefixBenchmarkQuiescenceTiming.measure(
            started: started, receiptCompleted: complete, outputTokens: output.count,
            requireIdle: { try await requireIdle() },
            drainCheckpointWrites: { try await session.drainCheckpointWrites() })
        let mtp = ModelPrefixBenchmarkMTPObservation(requested: specification.mtpEnabled ?? false,
            before: mtpBefore, after: session.rawEngine.mtpMetricsSnapshot())
        let after = await session.cacheSnapshot().checkpoints ?? SSDHybridCheckpointStats()
        let firstSeconds = seconds((try #require(outputTiming.first)) - started)
        let lastSeconds = seconds((try #require(outputTiming.last)) - started)
        let terminalSeconds = seconds((try #require(terminal)) - started)
        let completionSeconds = seconds(complete - started)
        let outputBytes = output.flatMap { value -> [UInt8] in
            let bits = UInt32(value)
            return (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
        }
        let digest = SHA256.hash(data: Data(outputBytes)).map { String(format: "%02x", $0) }.joined()
        let diagnostics = captureDiagnostics
            ? try ModelPrefixBenchmarkTokenDiagnostics(tokens: output, logprobs: observedLogprobs) : nil
        var row = ModelPrefixBenchmarkRow(cell: cell, pair: pair, role: role,
            promptTokens: tokens.count, completedOutputTokens: output.count,
            firstOutputTokenCount: outputTiming.firstOutputTokenCount,
            outputEventCount: outputTiming.outputEventCount, targetTokens: target,
            firstOutputSeconds: firstSeconds, lastOutputSeconds: lastSeconds,
            terminalSeconds: terminalSeconds, receiptCompletionSeconds: completionSeconds,
            quiescenceCompletionSeconds: quiescence.quiescenceCompletionSeconds,
            receiptToQuiescenceMilliseconds: quiescence.receiptToQuiescenceMilliseconds,
            checkpointWritesDrained: quiescence.checkpointWritesDrained,
            generationTPS: outputTiming.generationTPS,
            endToEndTPS: Double(output.count) / terminalSeconds,
            receiptCompletionTPS: Double(output.count) / completionSeconds,
            quiescenceCompletionTPS: quiescence.quiescenceCompletionTPS,
            stageMilliseconds: submitted.stageMilliseconds, stageDisposition: submitted.stageDisposition,
            restoredTokens: usage.prefixCachePrefillTokensSaved,
            matchedTokens: usage.prefixCacheMatchedTokens, replayTokens: usage.prefixCacheReplayTokens,
            cacheTier: usage.prefixCacheTier?.rawValue, outputSHA256: digest,
            filesWrittenDelta: after.filesWritten - before.filesWritten,
            bytesWrittenDelta: after.bytesWritten - before.bytesWritten,
            filesReadDelta: after.filesRead - before.filesRead, bytesReadDelta: after.bytesRead - before.bytesRead,
            writeMillisecondsDelta: after.writeMilliseconds - before.writeMilliseconds,
            packedPrefillChunks: usage.timing.packedPrefillChunks, prefillChunks: usage.timing.prefillChunks,
            preemptions: usage.timing.preemptions, peakStagingBytes: after.peakStagingReservationBytes,
            peakWriteHostBytes: after.peakWriteHostBytes,
            schedulerConfiguration: configuration, tokenDiagnostics: diagnostics, mtp: mtp)
        row.memoryAtPrefillCompletion = try memory?.snapshot()
        if observeStorage {
            row.memoryAfterRetirement = memoryObservation()
        }
        if let expectedMarker {
            let text = tokenizer.inner.decode(tokenIds: output)
            row.publicOutput = ModelPrefixBenchmarkPublicOutput(expectedMarker: expectedMarker,
                containsExpectedMarker: text.contains(expectedMarker), decodedText: text, tokenIDs: output)
        }
        row.stageConsumptionsDelta = after.stageConsumptions - before.stageConsumptions
        row.stagedBytesAfterRetirement = after.stagedBytesInUse
        row.writeHostBytesAfterRetirement = after.writeHostBytesInUse
        row.promptSHA256 = try ModelCheckpointStoragePrompts.digest(tokens)
        row.decodeSteps = usage.timing.decodeSteps
        row.chainedDecodeSteps = usage.timing.chainedDecodeSteps
        row.prefixCacheEnabled = request.prefixCacheEnabled
        row.samplingRequestID = request.id.raw
        row.samplingTemperature = request.sampling.temperature
        row.stopTokenCount = request.stopTokens.count
        row.cacheScopeSHA256 = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        if let trace, let capture {
            let ranges = trace.snapshot(capture)
            try ModelCheckpointPrefillRange.validate(ranges, promptTokens: tokens.count,
                prefillChunks: usage.timing.prefillChunks, packedPrefillChunks: usage.timing.packedPrefillChunks,
                preemptions: usage.timing.preemptions)
            row.prefillRanges = ranges
        }
        return row
    }

    static func benchmarkRequest(tokens: [Int], scope: String, target: Int?, cacheEnabled: Bool,
                                 outputTokens: Int, captureDiagnostics: Bool = false) -> CBv2Request {
        CBv2Request(id: .init(11), promptTokens: tokens,
            sampling: .init(temperature: 0, topLogprobs: captureDiagnostics ? 2 : 0),
            maxTokens: outputTokens, stopTokens: [], cacheSalt: scope, prefixCacheEnabled: cacheEnabled,
            prefixCheckpointTargetTokens: target)
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
