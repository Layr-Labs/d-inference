import Foundation
import MLXLMCommon

struct KVQualityCollectedCase: Sendable {
    let index: Int
    let requestID: UInt64
    let receiptID: UInt64?
    let elapsedMs: Double
    let firstTokenMs: Double?
    var tokens: [Int]
    var streamedText: String
    var finishReason: String?
    var terminalCause: String?
    var error: String?
    var issues: [String]
}

/// Per-stream state stays bound to its submission, irrespective of completion
/// order. Limits protect report memory if an engine violates maxTokens.
struct KVQualityEventCollector {
    let maximumTokens: Int
    private(set) var tokens: [Int] = []
    private(set) var streamedText = ""
    private(set) var finishReason: String?
    private(set) var terminalCause: String?
    private(set) var error: String?
    private(set) var issues: [String] = []
    private var eventCount = 0

    init(maximumTokens: Int) {
        self.maximumTokens = maximumTokens
    }

    mutating func append(_ event: CBv2Event) -> Bool {
        eventCount += 1
        guard eventCount <= 4096 else { issues.append("event_limit_exceeded"); return false }
        switch event {
        case .delta(let text, let values, _):
            guard finishReason == nil else { issues.append("delta_after_terminal"); return false }
            guard values.count <= maximumTokens - tokens.count,
                text.utf8.count <= 1_048_576 - streamedText.utf8.count else {
                issues.append("output_limit_exceeded"); return false
            }
            tokens.append(contentsOf: values)
            streamedText += text
        case .finished(let reason, _):
            guard finishReason == nil else { issues.append("duplicate_terminal"); return false }
            switch reason {
            case .stop: finishReason = "stop"
            case .length: finishReason = "length"
            case .cancelled: finishReason = "cancelled"
            case .error(let message): finishReason = "error"; error = String(message.prefix(4096))
            case .terminal(let cause, let message):
                finishReason = "terminal"; terminalCause = String(describing: cause)
                error = String(message.prefix(4096))
            }
        }
        return true
    }

    mutating func close(cancelled: Bool) {
        if finishReason == nil { issues.append(cancelled ? "collection_cancelled_or_timed_out" : "missing_terminal") }
        if finishReason == "cancelled" || finishReason == "error" || finishReason == "terminal" { issues.append("unsuccessful_terminal") }
    }

    static func drain(
        events: AsyncStream<CBv2Event>, index: Int, receiptID: UInt64?,
        maximumTokens: Int, startedAt: UInt64, cancel: @Sendable () -> Void
    ) async -> KVQualityCollectedCase {
        var collector = KVQualityEventCollector(maximumTokens: maximumTokens)
        var firstTokenMs: Double?
        for await event in events {
            if case .delta(_, let tokens, _) = event, !tokens.isEmpty, firstTokenMs == nil {
                firstTokenMs = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
            }
            guard collector.append(event) else { cancel(); break }
        }
        collector.close(cancelled: Task.isCancelled)
        return .init(index: index, requestID: UInt64(index + 1), receiptID: receiptID,
            elapsedMs: Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000,
            firstTokenMs: firstTokenMs, tokens: collector.tokens, streamedText: collector.streamedText,
            finishReason: collector.finishReason, terminalCause: collector.terminalCause,
            error: collector.error, issues: collector.issues)
    }

    static func ordered(_ results: [KVQualityCollectedCase], count: Int) throws -> [KVQualityCollectedCase] {
        guard results.count == count, Set(results.map(\.index)) == Set(0..<count),
            results.allSatisfy({ $0.requestID == UInt64($0.index + 1) }) else {
            throw KVQualityBenchmark.Failure.caseIdentityMismatch
        }
        return results.sorted { $0.index < $1.index }
    }

    static func matches(_ actual: String, expected: String?) -> (exact: Bool?, outerWhitespace: Bool?) {
        guard let expected else { return (nil, nil) }
        return (actual == expected,
            actual.trimmingCharacters(in: .whitespacesAndNewlines)
                == expected.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
