import Foundation
import MLXLMCommon
import Testing

@_spi(Benchmarking) @testable import ProviderCore

/// Conservative per-request ceiling: a slower request is cancelled and its cell
/// stopped, never retried. Must match CELL_* in run-real-model.py, which sums
/// these budgets into the recorded suite watchdog.
enum GLM5NextRealTimingBudget {
    static let fixedSeconds = 60.0, prefillFloorTokensPerSecond = 100.0, decodeFloorTokensPerSecond = 4.0
    static let warmRepetitions = 3, longWarmRepetitions = 2
    /// (prompt tokens, output budget, content class). Must match CELLS in
    /// run-real-model.py.
    static let cells: [(Int, Int, String)] = [512, 2048, 4096].flatMap { context in
        [(context, 128, "prose"), (context, 1024, "prose")]
    } + ["code", "json_tool", "reasoning"].map { (4096, 1024, $0) } + [(7936, 128, "prose")]
    /// Near-bound feasibility probe (the qualification context bound is 8192).
    static func isLong(_ context: Int) -> Bool { context > 4096 }
    static func seconds(context: Int, output: Int) -> Double {
        fixedSeconds + Double(context) / prefillFloorTokensPerSecond + Double(output) / decodeFloorTokensPerSecond
    }
}

extension GLM5NextRealModelHarness {
    /// Preserve the rendered chat suffix while shortening only natural-text
    /// content tokens. The measured count is the final submitted template count.
    func exactPrompt(count: Int, contentClass: String, nonce: String) async throws -> [Int] {
        let samples = [
            "prose": "The river passes a quiet village. Trees shade the banks and birds cross the water. ",
            "code": "func sum(_ values: [Int]) -> Int { values.reduce(0, +) } // explain this function\n",
            "json_tool": "{\"tool\":\"clock\",\"arguments\":{},\"result\":{\"hour\":12}}\n",
            "reasoning": "If every square is a rectangle, but not every rectangle is a square, explain the implication. ",
        ]
        let sample = try #require(samples[contentClass])
        // Provider default reasoning effort (max), as an unconfigured client
        // request is served.
        let empty = try await prompt("", effort: nil)
        var text = "Qualification nonce: \(nonce).\n"
        var rendered = try await prompt(text, effort: nil)
        while rendered.count < count + empty.count + 128 {
            text += String(repeating: sample, count: max(1, count / 32))
            rendered = try await prompt(text, effort: nil)
        }
        var suffix = 0
        while suffix < min(empty.count, rendered.count),
            empty[empty.count - 1 - suffix] == rendered[rendered.count - 1 - suffix] { suffix += 1 }
        try #require(suffix > 0 && count > empty.count + 32)
        let result = Array(rendered.prefix(count - suffix)) + Array(rendered.suffix(suffix))
        try #require(result.count == count)
        return result
    }

    func timingRecord(_ run: GLM5NextRealRun) throws -> [String: Any] {
        // Never persist arbitrary engine error messages: they are not part of
        // the numeric measurement schema. Typed deadline/watchdog causes survive.
        let reason: String
        switch run.reason {
        case .length?: reason = "length"
        case .stop?: reason = "stop"
        case .cancelled?: reason = "cancelled"
        case .terminal(let cause, _)?: reason = "terminal:\(cause)"
        case .error?: reason = "engine_error"
        case nil: reason = "missing_terminal"
        }
        var value: [String: Any] = ["finishReason": reason,
            "wallSeconds": run.wallSeconds, "ttftSeconds": run.ttftSeconds.map { $0 as Any } ?? NSNull(),
            "completionTokens": run.tokens.count, "tokenSHA256": Self.tokenHash(run.tokens),
            "lastDeltaSeconds": run.lastDeltaSeconds.map { $0 as Any } ?? NSNull(),
            "finishedSeconds": run.finishedSeconds.map { $0 as Any } ?? NSNull(),
            "stopTokens": run.stopTokens.sorted(), "eosSuppressed": run.stopTokens.isEmpty]
        if let mtp = run.mtp { value["mtpMetrics"] = mtp.record }
        if let usage = run.usage {
            let t = usage.timing
            let prefill = t.promptComputedNanos > t.prefillFirstLaunchNanos && t.prefillFirstLaunchNanos > 0
                ? Double(usage.promptTokens) * 1e9 / Double(t.promptComputedNanos - t.prefillFirstLaunchNanos) : nil
            let decode = t.lastTokenNanos > t.firstTokenNanos && usage.completionTokens > 1
                ? Double(usage.completionTokens - 1) * 1e9 / Double(t.lastTokenNanos - t.firstTokenNanos) : nil
            value["prefillTokensPerSecond"] = prefill.map { $0 as Any } ?? NSNull()
            value["decodeTokensPerSecond"] = decode.map { $0 as Any } ?? NSNull()
            value["timing"] = ["prefillFirstLaunchNanos": t.prefillFirstLaunchNanos,
                "promptComputedNanos": t.promptComputedNanos, "firstTokenNanos": t.firstTokenNanos,
                "lastTokenNanos": t.lastTokenNanos, "finishedNanos": t.finishedNanos,
                "prefillChunks": UInt64(t.prefillChunks), "prefillChunkTokensMax": UInt64(t.prefillChunkTokensMax),
                "soloStripeChunks": UInt64(t.soloStripeChunks), "decodeSteps": UInt64(t.decodeSteps),
                "chainedDecodeSteps": UInt64(t.chainedDecodeSteps), "stepLatencyNanosSum": t.stepLatencyNanosSum,
                "stepLatencyNanosMax": t.stepLatencyNanosMax, "preemptions": UInt64(t.preemptions),
                "mtpRounds": UInt64(t.mtpRounds), "mtpProposed": UInt64(t.mtpProposed), "mtpAccepted": UInt64(t.mtpAccepted)]
        }
        return value
    }
}
