import Foundation
import MLXLMCommon

struct QwenPrefixEngineRow: Sendable {
    let row: Int
    let requestID: CBv2RequestID
    let promptTokenCount: Int
    let submittedAtNs: UInt64
    let firstTokenAtNs: UInt64
    let completedAtNs: UInt64
    let tokenIDs: [Int]
    let finishReason: String
    let usage: CBv2Usage
    let stateBytesCloned: Int
}

struct QwenPrefixEngineBatch: Sendable {
    let rows: [QwenPrefixEngineRow]

    var startedAtNs: UInt64 {
        rows.map(\.submittedAtNs).min() ?? 0
    }

    var completedAtNs: UInt64 {
        rows.map(\.completedAtNs).max() ?? startedAtNs
    }
}

enum QwenPrefixEngineRunner {
    static func run<Engine: CBv2Engine>(
        engine: Engine,
        cache: any QwenPrefixBenchmarkCache,
        prompts: [[Int]],
        decodeTokens: Int,
        requestIDBase: UInt64,
        prefixCacheEnabled: Bool,
        cacheSalt: String
    ) async throws -> QwenPrefixEngineBatch {
        guard !prompts.isEmpty else {
            throw QwenPrefixEngineRunnerError.emptyBatch
        }
        guard decodeTokens > 0 else {
            throw QwenPrefixEngineRunnerError.invalidDecodeTokens(decodeTokens)
        }
        guard prompts.allSatisfy({ !$0.isEmpty }) else {
            throw QwenPrefixEngineRunnerError.emptyPrompt
        }

        // One shared future deadline gives B2/B4 tasks time to enter the task
        // group before submission. This avoids a fast first row completing
        // before the final row has even called `submit` in scripted tests and
        // preserves the intended burst topology on the real engine.
        let clock = SuspendingClock()
        let submitAt = clock.now.advanced(
            by: prompts.count > 1 ? .milliseconds(10) : .zero)
        let rows = try await withThrowingTaskGroup(of: QwenPrefixEngineRow.self) { group in
            for (row, prompt) in prompts.enumerated() {
                let requestID = try checkedRequestID(base: requestIDBase, offset: row)
                group.addTask {
                    if clock.now < submitAt {
                        try await Task.sleep(
                            until: submitAt,
                            tolerance: .zero,
                            clock: clock)
                    }
                    return try await consume(
                        engine: engine,
                        cache: cache,
                        row: row,
                        requestID: requestID,
                        prompt: prompt,
                        decodeTokens: decodeTokens,
                        prefixCacheEnabled: prefixCacheEnabled,
                        cacheSalt: cacheSalt)
                }
            }

            var completed: [QwenPrefixEngineRow] = []
            completed.reserveCapacity(prompts.count)
            for try await row in group {
                completed.append(row)
            }
            return completed.sorted { $0.row < $1.row }
        }
        guard rows.count == prompts.count else {
            throw QwenPrefixEngineRunnerError.missingRows(
                expected: prompts.count,
                actual: rows.count)
        }
        return QwenPrefixEngineBatch(rows: rows)
    }

    static func describe(_ outcome: CBv2PrefixCacheOutcome) -> String {
        switch outcome {
        case .disabled: return "disabled"
        case .skippedPolicy: return "skipped_policy"
        case .miss: return "miss"
        case .hit: return "hit"
        case .skippedCapacity: return "skipped_capacity"
        case .adoptionFailed: return "adoption_failed"
        }
    }

    private static func consume<Engine: CBv2Engine>(
        engine: Engine,
        cache: any QwenPrefixBenchmarkCache,
        row: Int,
        requestID: CBv2RequestID,
        prompt: [Int],
        decodeTokens: Int,
        prefixCacheEnabled: Bool,
        cacheSalt: String
    ) async throws -> QwenPrefixEngineRow {
        let submittedAt = DispatchTime.now().uptimeNanoseconds
        let stream: AsyncStream<CBv2Event>
        do {
            stream = try engine.submit(CBv2Request(
                id: requestID,
                promptTokens: prompt,
                sampling: CBv2SamplingParams(
                    temperature: 0,
                    topP: 1,
                    topK: 0,
                    minP: 0,
                    repetitionPenalty: 1,
                    frequencyPenalty: 0,
                    presencePenalty: 0),
                maxTokens: decodeTokens,
                stopTokens: [],
                stopStrings: [],
                cacheSalt: cacheSalt,
                prefixCacheEnabled: prefixCacheEnabled,
                prefixCacheReceiptID: requestID))
        } catch {
            throw QwenPrefixEngineRunnerError.submissionFailed(
                row: row,
                message: String(describing: error))
        }

        var tokenIDs: [Int] = []
        tokenIDs.reserveCapacity(decodeTokens)
        var firstTokenAt: UInt64?
        var terminal: (reason: CBv2FinishReason, usage: CBv2Usage, at: UInt64)?
        for await event in stream {
            guard terminal == nil else {
                throw QwenPrefixEngineRunnerError.eventAfterTerminal(row: row)
            }
            let now = DispatchTime.now().uptimeNanoseconds
            switch event {
            case .delta(_, let tokens, _):
                if firstTokenAt == nil, !tokens.isEmpty { firstTokenAt = now }
                tokenIDs.append(contentsOf: tokens)
                guard tokenIDs.count <= decodeTokens else {
                    throw QwenPrefixEngineRunnerError.unexpectedTokenCount(
                        row: row,
                        expected: decodeTokens,
                        actual: tokenIDs.count)
                }
            case .finished(let reason, let usage):
                terminal = (reason, usage, now)
            }
        }

        guard let firstTokenAt else {
            throw QwenPrefixEngineRunnerError.noFirstToken(row: row)
        }
        guard let terminal else {
            throw QwenPrefixEngineRunnerError.missingTerminal(row: row)
        }
        guard case .length = terminal.reason else {
            throw QwenPrefixEngineRunnerError.unexpectedTerminal(
                row: row,
                reason: describe(terminal.reason))
        }
        guard tokenIDs.count == decodeTokens else {
            throw QwenPrefixEngineRunnerError.unexpectedTokenCount(
                row: row,
                expected: decodeTokens,
                actual: tokenIDs.count)
        }
        guard terminal.usage.promptTokens == prompt.count,
              terminal.usage.completionTokens == tokenIDs.count
        else {
            throw QwenPrefixEngineRunnerError.usageMismatch(
                row: row,
                expectedPrompt: prompt.count,
                actualPrompt: terminal.usage.promptTokens,
                expectedCompletion: tokenIDs.count,
                actualCompletion: terminal.usage.completionTokens)
        }

        let stateBytes = try adoptedStateBytes(
            usage: terminal.usage,
            lookupBytes: cache.lookupStateBytes(for: requestID),
            row: row)
        return QwenPrefixEngineRow(
            row: row,
            requestID: requestID,
            promptTokenCount: prompt.count,
            submittedAtNs: submittedAt,
            firstTokenAtNs: firstTokenAt,
            completedAtNs: terminal.at,
            tokenIDs: tokenIDs,
            finishReason: "length",
            usage: terminal.usage,
            stateBytesCloned: stateBytes)
    }

    private static func checkedRequestID(
        base: UInt64,
        offset: Int
    ) throws -> CBv2RequestID {
        guard offset >= 0, let value = UInt64(exactly: offset) else {
            throw QwenPrefixEngineRunnerError.requestIDOverflow
        }
        let (result, overflow) = base.addingReportingOverflow(value)
        guard !overflow else {
            throw QwenPrefixEngineRunnerError.requestIDOverflow
        }
        return CBv2RequestID(result)
    }

    /// Convert the request-correlated lookup size to the state handed to
    /// backend adoption. Exact-state direct hits adopt the whole atomic
    /// snapshot, including non-token-linear recurrent state and, only for a
    /// full-prompt hit, frontier logits. Historical tail replay slices
    /// token-linear full-attention arrays to the saved-token frontier.
    private static func adoptedStateBytes(
        usage: CBv2Usage,
        lookupBytes: Int,
        row: Int
    ) throws -> Int {
        guard usage.prefixCacheOutcome == .hit else { return 0 }
        let matched = max(
            usage.prefixCacheMatchedTokens,
            usage.prefixCacheHitTokens)
        let saved = max(
            usage.prefixCachePrefillTokensSaved,
            usage.prefixCacheHitTokens)
        guard matched > 0,
              saved > 0,
              lookupBytes > 0,
              let strategy = usage.prefixCacheStrategy
        else {
            throw QwenPrefixEngineRunnerError.invalidStateByteAccounting(row: row)
        }
        switch strategy {
        case .direct, .frozenFullReplay:
            // Direct exact-state Qwen hits include fixed recurrent state and
            // may include frontier logits, so bytes are not generally
            // divisible by the matched length. Adopt the complete snapshot.
            return lookupBytes
        case .tailReplay:
            // The historical KV-only cache exposes token-linear full-
            // attention arrays. Tail replay slices those arrays to the saved
            // frontier before adoption.
            guard lookupBytes % matched == 0 else {
                throw QwenPrefixEngineRunnerError.invalidStateByteAccounting(row: row)
            }
            let (bytes, overflow) = (lookupBytes / matched)
                .multipliedReportingOverflow(by: saved)
            guard !overflow, bytes > 0 else {
                throw QwenPrefixEngineRunnerError.invalidStateByteAccounting(row: row)
            }
            return bytes
        }
    }

    private static func describe(_ reason: CBv2FinishReason) -> String {
        switch reason {
        case .stop: return "stop"
        case .length: return "length"
        case .cancelled: return "cancelled"
        case .error(let message): return "error: \(message)"
        case .terminal(let cause, let message): return "terminal \(cause): \(message)"
        }
    }
}

enum QwenPrefixEngineRunnerError: Error, Equatable, CustomStringConvertible {
    case emptyBatch
    case emptyPrompt
    case invalidDecodeTokens(Int)
    case requestIDOverflow
    case submissionFailed(row: Int, message: String)
    case noFirstToken(row: Int)
    case missingTerminal(row: Int)
    case eventAfterTerminal(row: Int)
    case unexpectedTerminal(row: Int, reason: String)
    case unexpectedTokenCount(row: Int, expected: Int, actual: Int)
    case invalidStateByteAccounting(row: Int)
    case usageMismatch(
        row: Int,
        expectedPrompt: Int,
        actualPrompt: Int,
        expectedCompletion: Int,
        actualCompletion: Int
    )
    case missingRows(expected: Int, actual: Int)

    var description: String {
        switch self {
        case .emptyBatch:
            return "Qwen prefix benchmark batch must contain at least one row"
        case .emptyPrompt:
            return "Qwen prefix benchmark prompts must not be empty"
        case .invalidDecodeTokens(let count):
            return "Qwen prefix decode tokens must be positive (got \(count))"
        case .requestIDOverflow:
            return "Qwen prefix benchmark exhausted the CBv2 request-id space"
        case .submissionFailed(let row, let message):
            return "Qwen prefix row \(row) submission failed: \(message)"
        case .noFirstToken(let row):
            return "Qwen prefix row \(row) completed without a first token"
        case .missingTerminal(let row):
            return "Qwen prefix row \(row) stream ended without a terminal event"
        case .eventAfterTerminal(let row):
            return "Qwen prefix row \(row) emitted an event after its terminal"
        case .unexpectedTerminal(let row, let reason):
            return "Qwen prefix row \(row) finished unexpectedly: \(reason)"
        case .unexpectedTokenCount(let row, let expected, let actual):
            return "Qwen prefix row \(row) emitted \(actual) tokens; expected \(expected)"
        case .invalidStateByteAccounting(let row):
            return "Qwen prefix row \(row) reported a cache hit whose adopted "
                + "state bytes could not be accounted exactly"
        case .usageMismatch(
            let row, let expectedPrompt, let actualPrompt,
            let expectedCompletion, let actualCompletion
        ):
            return "Qwen prefix row \(row) usage mismatch: prompt "
                + "\(actualPrompt)/\(expectedPrompt), completion "
                + "\(actualCompletion)/\(expectedCompletion)"
        case .missingRows(let expected, let actual):
            return "Qwen prefix batch completed \(actual) rows; expected \(expected)"
        }
    }
}
