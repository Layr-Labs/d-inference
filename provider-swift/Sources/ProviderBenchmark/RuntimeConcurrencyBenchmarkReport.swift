import Foundation
import MLXLMCommon

extension RuntimeConcurrencyBenchmark {
    struct Row: Encodable {
        let row: Int
        let promptTokenCount: Int
        /// SHA-256 of the JSON-encoded prompt token IDs.
        let promptTokensSHA256: String
        let maxTokens: Int
        let generatedTokens: [Int]
        let finishReason: String
        /// Submit to first token, and to the third.
        let firstTokenMs: Double?
        let thirdTokenMs: Double?
        /// Submit to each of the first eight tokens.
        let earlyTokenMs: [Double]
        /// (tokens - 1) / (last arrival - first arrival).
        let decodeTokensPerSecond: Double?
    }

    struct Cell: Encodable {
        let batchSize: Int
        let effectiveMaxConcurrentRequests: Int
        let resolvedBackend: String
        let kvQuantization: String
        let kvCheckpointQuantization: String
        let checkpointBackendLayout: String?
        let mtpActive: Bool
        let assistantIdentity: [String: String]
        /// Rows that did not end where their requests say; nonempty marks
        /// the cell as no valid measurement.
        let failures: [String]
        let rows: [Row]
        /// Tokens arriving while every row is past its first token and none
        /// has received its last, over that window.
        let allRowsDecodeTokensPerSecond: Double?
        let allRowsWindowMs: Double?
        let medianRowDecodeTokensPerSecond: Double?
        /// Cumulative for this cell's engine: the warmup and measured batches.
        let mtpMetrics: MTPBenchmarkMetrics
        /// Measured batch only.
        let chainedSteps: Int
    }

    /// The slot's policy lowered its width below the batch, so no rows ran.
    struct RefusedCell: Encodable {
        let batchSize: Int
        let effectiveMaxConcurrentRequests: Int
    }

    struct Report: Encodable {
        let schema = 1
        let scope = "production_runtime_concurrency"
        let modelID: String
        let verifiedModelAggregateSHA256: String
        let runtimeIdentity: [String: String]
        /// The operator prompt; row i renders "Request i+1. <prompt>".
        let promptSHA256: String
        let renderDate: String
        let mtpRequested: Bool
        let maxTokens: Int
        /// Row i of a B-row batch stops after `rowMaxTokens` tokens.
        let staggered: Bool
        let warmupMaxTokens: Int
        let cells: [Cell]
        let refusedCells: [RefusedCell]
    }

    struct Measured: Sendable {
        let promptTokens: [Int]
        let maxTokens: Int
        let submittedNanos: UInt64
        let tokens: [Int]
        let arrivalNanos: [UInt64]
        let finishReason: CBv2FinishReason?
    }

    struct Summary {
        let rows: [Row]
        let failures: [String]
        let allRowsDecodeTokensPerSecond: Double?
        let allRowsWindowMs: Double?
        let medianRowDecodeTokensPerSecond: Double?
    }

    /// A row measures its request only if it ended where that request says:
    /// `.length` exactly at its quota (a context limit also reports
    /// `.length`), or a configured stop token within it. A staggered row must
    /// reach its quota, or the cohort did not shrink one row at a time.
    static func rowFailure(
        quota: Int, tokens: [Int], finishReason: CBv2FinishReason?, stopTokens: Set<Int>,
        staggered: Bool
    ) -> String? {
        switch finishReason {
        case .length?:
            guard tokens.count == quota else {
                return "length after \(tokens.count) of \(quota) tokens"
            }
            return nil
        case .stop?:
            guard let last = tokens.last, stopTokens.contains(last) else {
                return "stop without a configured stop token"
            }
            guard tokens.count <= quota else {
                return "stopped after \(tokens.count) tokens, past its \(quota)-token quota"
            }
            guard !staggered || tokens.count == quota else {
                return "stopped after \(tokens.count) of \(quota) staggered tokens"
            }
            return nil
        case let other:
            return "unexpected finish: \(other.map { String(describing: $0) } ?? "missing")"
        }
    }

    static func summarize(
        _ measured: [Measured], stopTokens: Set<Int>, staggered: Bool
    ) throws -> Summary {
        func ms(_ nanos: UInt64, from start: UInt64) -> Double { Double(nanos &- start) / 1e6 }
        let rows = try measured.enumerated().map { index, row -> Row in
            let rate: Double? = {
                guard row.arrivalNanos.count > 1,
                    let first = row.arrivalNanos.first, let last = row.arrivalNanos.last, last > first
                else { return nil }
                return Double(row.arrivalNanos.count - 1) / (Double(last - first) / 1e9)
            }()
            return Row(
                row: index, promptTokenCount: row.promptTokens.count,
                promptTokensSHA256: RuntimeGenerationBenchmark.sha256Hex(
                    try JSONEncoder().encode(row.promptTokens)),
                maxTokens: row.maxTokens, generatedTokens: row.tokens,
                finishReason: row.finishReason.map { String(describing: $0) } ?? "missing",
                firstTokenMs: row.arrivalNanos.first.map { ms($0, from: row.submittedNanos) },
                thirdTokenMs: row.arrivalNanos.count > 2
                    ? ms(row.arrivalNanos[2], from: row.submittedNanos) : nil,
                earlyTokenMs: row.arrivalNanos.prefix(8).map { ms($0, from: row.submittedNanos) },
                decodeTokensPerSecond: rate)
        }
        let failures = measured.enumerated().compactMap { index, row in
            rowFailure(
                quota: row.maxTokens, tokens: row.tokens, finishReason: row.finishReason,
                stopTokens: stopTokens, staggered: staggered
            ).map { "row \(index): \($0)" }
        }
        var windowRate: Double?
        var windowMs: Double?
        if let start = measured.compactMap(\.arrivalNanos.first).max(),
            let end = measured.compactMap(\.arrivalNanos.last).min(), end > start
        {
            let count = measured.reduce(0) { total, row in
                total + row.arrivalNanos.filter { $0 > start && $0 <= end }.count
            }
            windowMs = Double(end - start) / 1e6
            windowRate = Double(count) / (Double(end - start) / 1e9)
        }
        let rates = rows.compactMap(\.decodeTokensPerSecond)
        return Summary(
            rows: rows, failures: failures, allRowsDecodeTokensPerSecond: windowRate,
            allRowsWindowMs: windowMs,
            medianRowDecodeTokensPerSecond: rates.isEmpty ? nil : ThroughputSweep.median(rates))
    }
}
