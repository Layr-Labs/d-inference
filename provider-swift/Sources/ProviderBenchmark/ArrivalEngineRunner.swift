import Foundation
import MLXLMCommon

/// One row completed through the arrival benchmark's real `CBv2Engine`
/// stream boundary. The runner produces a value only after both a first token
/// and a successful terminal event have been observed.
struct ArrivalEngineRow: Sendable {
    let row: Int
    let scheduledDelayMs: Int
    let tokenIDs: [Int]
    let firstTokenID: Int
    let submittedAtNs: UInt64
    let firstTokenAtNs: UInt64
    let lastTokenAtNs: UInt64
    let completedAtNs: UInt64
}

/// The result of submitting one complete arrival topology to one engine.
struct ArrivalEngineSample: Sendable {
    let scenarioStartedAtNs: UInt64
    let rows: [ArrivalEngineRow]

    var outputs: [[Int]] { rows.map(\.tokenIDs) }
}

enum ArrivalEngineRunnerError: Error, Equatable, CustomStringConvertible {
    case promptCountMismatch(expected: Int, actual: Int)
    case invalidDelay(row: Int, milliseconds: Int)
    case invalidDecodeTokenCount(Int)
    case requestIDOverflow
    case submissionFailed(row: Int, message: String)
    case noFirstToken(row: Int)
    case missingCompletion(row: Int)
    case requestFailed(row: Int, message: String)
    case unexpectedFinish(row: Int, reason: String)
    case unexpectedTokenCount(row: Int, expected: Int, actual: Int)
    case eventAfterCompletion(row: Int)
    case missingRows(expected: Int, actual: Int)

    var description: String {
        switch self {
        case .promptCountMismatch(let expected, let actual):
            return "arrival topology has \(actual) prompts for \(expected) rows"
        case .invalidDelay(let row, let milliseconds):
            return "arrival row \(row) has invalid delay \(milliseconds) ms"
        case .invalidDecodeTokenCount(let count):
            return "arrival decode token count must be positive (got \(count))"
        case .requestIDOverflow:
            return "arrival benchmark exhausted its request-id space"
        case .submissionFailed(let row, let message):
            return "arrival row \(row) submission failed: \(message)"
        case .noFirstToken(let row):
            return "arrival row \(row) completed without a first token"
        case .missingCompletion(let row):
            return "arrival row \(row) ended without a completion event"
        case .requestFailed(let row, let message):
            return "arrival row \(row) failed: \(message)"
        case .unexpectedFinish(let row, let reason):
            return "arrival row \(row) finished unexpectedly: \(reason)"
        case .unexpectedTokenCount(let row, let expected, let actual):
            return "arrival row \(row) produced \(actual) tokens, expected \(expected)"
        case .eventAfterCompletion(let row):
            return "arrival row \(row) emitted an event after completion"
        case .missingRows(let expected, let actual):
            return "arrival topology completed \(actual) rows, expected \(expected)"
        }
    }
}

/// Small serving-path seam shared by the benchmark and its tests.
///
/// The engine is generic so the runtime existential opens to the one
/// serving `CBv2Engine` instance while tests can substitute only that stream
/// boundary. Scheduling, request construction, stream consumption, and
/// fail-closed row validation remain the runtime implementation.
enum ArrivalEngineRunner {
    static func run<Engine: CBv2Engine>(
        engine: Engine,
        arrivalDelaysMs: [Int],
        prompts: [[Int]],
        decodeTokens: Int,
        requestIDBase: UInt64
    ) async throws -> ArrivalEngineSample {
        guard prompts.count == arrivalDelaysMs.count else {
            throw ArrivalEngineRunnerError.promptCountMismatch(
                expected: arrivalDelaysMs.count,
                actual: prompts.count)
        }
        guard decodeTokens > 0 else {
            throw ArrivalEngineRunnerError.invalidDecodeTokenCount(decodeTokens)
        }
        for (row, delay) in arrivalDelaysMs.enumerated() where delay < 0 {
            throw ArrivalEngineRunnerError.invalidDelay(
                row: row,
                milliseconds: delay)
        }

        let clock = SuspendingClock()
        let scenarioStartedAt = DispatchTime.now().uptimeNanoseconds
        let scenarioStartInstant = clock.now

        let rows = try await withThrowingTaskGroup(of: ArrivalEngineRow.self) { group in
            for (row, delayMs) in arrivalDelaysMs.enumerated() {
                let prompt = prompts[row]
                let requestID = try addingRequestIDs(
                    to: requestIDBase,
                    count: row)
                group.addTask {
                    try await sleepUntilArrival(
                        offsetMs: delayMs,
                        scenarioStart: scenarioStartInstant,
                        clock: clock)
                    return try await consumeRow(
                        engine: engine,
                        requestID: requestID,
                        row: row,
                        delayMs: delayMs,
                        prompt: prompt,
                        decodeTokens: decodeTokens)
                }
            }

            var completed: [ArrivalEngineRow] = []
            for try await row in group {
                completed.append(row)
            }
            return completed.sorted { $0.row < $1.row }
        }

        guard rows.count == arrivalDelaysMs.count else {
            throw ArrivalEngineRunnerError.missingRows(
                expected: arrivalDelaysMs.count,
                actual: rows.count)
        }
        return ArrivalEngineSample(
            scenarioStartedAtNs: scenarioStartedAt,
            rows: rows)
    }

    private static func sleepUntilArrival(
        offsetMs: Int,
        scenarioStart: SuspendingClock.Instant,
        clock: SuspendingClock
    ) async throws {
        guard offsetMs > 0 else { return }
        let deadline = scenarioStart.advanced(by: .milliseconds(offsetMs))
        guard clock.now < deadline else { return }
        try await Task.sleep(until: deadline, tolerance: .zero, clock: clock)
    }

    private static func consumeRow<Engine: CBv2Engine>(
        engine: Engine,
        requestID: CBv2RequestID,
        row: Int,
        delayMs: Int,
        prompt: [Int],
        decodeTokens: Int
    ) async throws -> ArrivalEngineRow {
        let submittedAt = DispatchTime.now().uptimeNanoseconds
        let stream: AsyncStream<CBv2Event>
        do {
            stream = try engine.submit(CBv2Request(
                id: requestID,
                promptTokens: prompt,
                sampling: CBv2SamplingParams(temperature: 0.0),
                maxTokens: decodeTokens,
                stopTokens: []))
        } catch {
            throw ArrivalEngineRunnerError.submissionFailed(
                row: row,
                message: String(describing: error))
        }

        var tokenIDs: [Int] = []
        var tokenTimestamps: [UInt64] = []
        var finishReason: CBv2FinishReason?
        var completedAt: UInt64?
        for await event in stream {
            guard finishReason == nil else {
                throw ArrivalEngineRunnerError.eventAfterCompletion(row: row)
            }
            let now = DispatchTime.now().uptimeNanoseconds
            switch event {
            case .delta(_, let tokens, _):
                tokenIDs.append(contentsOf: tokens)
                tokenTimestamps.append(
                    contentsOf: repeatElement(now, count: tokens.count))
            case .finished(let reason, _):
                finishReason = reason
                completedAt = now
            }
        }

        guard let finishReason, let completedAt else {
            throw ArrivalEngineRunnerError.missingCompletion(row: row)
        }
        switch finishReason {
        case .length:
            break
        case .error(let message):
            throw ArrivalEngineRunnerError.requestFailed(
                row: row,
                message: message)
        default:
            throw ArrivalEngineRunnerError.unexpectedFinish(
                row: row,
                reason: String(describing: finishReason))
        }
        guard let firstTokenID = tokenIDs.first,
              let firstTokenAt = tokenTimestamps.first,
              let lastTokenAt = tokenTimestamps.last
        else {
            throw ArrivalEngineRunnerError.noFirstToken(row: row)
        }
        guard tokenIDs.count == decodeTokens else {
            throw ArrivalEngineRunnerError.unexpectedTokenCount(
                row: row,
                expected: decodeTokens,
                actual: tokenIDs.count)
        }

        return ArrivalEngineRow(
            row: row,
            scheduledDelayMs: delayMs,
            tokenIDs: tokenIDs,
            firstTokenID: firstTokenID,
            submittedAtNs: submittedAt,
            firstTokenAtNs: firstTokenAt,
            lastTokenAtNs: lastTokenAt,
            completedAtNs: completedAt)
    }

    private static func addingRequestIDs(
        to base: UInt64,
        count: Int
    ) throws -> CBv2RequestID {
        guard count >= 0, let value = UInt64(exactly: count) else {
            throw ArrivalEngineRunnerError.requestIDOverflow
        }
        let (result, overflow) = base.addingReportingOverflow(value)
        guard !overflow else {
            throw ArrivalEngineRunnerError.requestIDOverflow
        }
        return CBv2RequestID(result)
    }
}
