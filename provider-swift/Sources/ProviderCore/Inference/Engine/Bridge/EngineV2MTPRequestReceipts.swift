// Copyright © 2026 Eigen Labs.
import Foundation
import MLXLMCommon

/// One finished request's speculative-decoding counts, for measuring a
/// drafter on this Mac's own local API.
///
/// Debug only. The local API serves them at `GET /v1/debug/mtp-receipts`
/// only when it has no local key (`darkbloom start --local --no-auth`) and
/// `DARKBLOOM_DEBUG_MTP_RECEIPTS=1` is set; no response body, coordinator
/// message or telemetry event carries them. A receipt holds counts and engine
/// timing only: no prompt or output text, no token ids, no sampling values,
/// no request or account identity.
public struct MTPRequestReceipt: Codable, Sendable, Equatable {
    /// Order of finish on this bridge, from 1.
    public let sequence: Int
    public let model: String
    public let promptTokens: Int
    public let completionTokens: Int
    /// `stop`, `length`, `cancelled`, `error` or `terminal`; nil if unknown.
    public let finishReason: String?
    /// Prompt tokens the prefix cache supplied.
    public let prefixCacheMatchedTokens: Int
    public let decodeSteps: Int
    public let mtpRounds: Int
    public let mtpProposed: Int
    public let mtpAccepted: Int
    /// Decode rows of the steps this request ran in (its own included).
    public let batchRowsMin: Int
    public let batchRowsMax: Int
    public let batchRowsSum: Int
    /// Engine offsets from submission, in milliseconds; nil when not observed.
    public let firstTokenMs: Double?
    public let lastTokenMs: Double?
    public let finishedMs: Double?

    enum CodingKeys: String, CodingKey {
        case sequence, model
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case finishReason = "finish_reason"
        case prefixCacheMatchedTokens = "prefix_cache_matched_tokens"
        case decodeSteps = "decode_steps"
        case mtpRounds = "mtp_rounds"
        case mtpProposed = "mtp_proposed"
        case mtpAccepted = "mtp_accepted"
        case batchRowsMin = "batch_rows_min"
        case batchRowsMax = "batch_rows_max"
        case batchRowsSum = "batch_rows_sum"
        case firstTokenMs = "first_token_ms"
        case lastTokenMs = "last_token_ms"
        case finishedMs = "finished_ms"
    }
}

/// The `GET /v1/debug/mtp-receipts` body.
public struct MTPRequestReceiptList: Codable, Sendable, Equatable {
    public let object: String
    public let data: [MTPRequestReceipt]

    public init(data: [MTPRequestReceipt]) {
        self.object = "list"
        self.data = data
    }
}

/// The bounded list of a bridge's latest receipts. Disabled (capacity 0)
/// unless `DARKBLOOM_DEBUG_MTP_RECEIPTS=1`, so a default process records
/// nothing.
struct MTPRequestReceiptRing: Sendable {
    static let environmentKey = "DARKBLOOM_DEBUG_MTP_RECEIPTS"
    /// Enough for one measurement arm between reads.
    static let defaultCapacity = 256

    static func enabled(environment: [String: String]) -> Bool {
        environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MTPRequestReceiptRing {
        MTPRequestReceiptRing(capacity: enabled(environment: environment) ? defaultCapacity : 0)
    }

    let capacity: Int
    private(set) var receipts: [MTPRequestReceipt] = []
    private var finished = 0

    init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    mutating func record(
        model: String, usage: CBv2Usage, promptTokens: Int, completionTokens: Int,
        finishReason: CBv2FinishReason?
    ) {
        guard capacity > 0 else { return }
        finished += 1
        let t = usage.timing
        func ms(_ ns: UInt64) -> Double? { ns == 0 ? nil : Double(ns) / 1_000_000 }
        receipts.append(MTPRequestReceipt(
            sequence: finished, model: model,
            promptTokens: promptTokens, completionTokens: completionTokens,
            finishReason: finishReason.map(Self.reasonName),
            prefixCacheMatchedTokens: max(0, usage.prefixCacheMatchedTokens),
            decodeSteps: Int(t.decodeSteps), mtpRounds: Int(t.mtpRounds),
            mtpProposed: Int(t.mtpProposed), mtpAccepted: Int(t.mtpAccepted),
            batchRowsMin: Int(t.batchRowsMin), batchRowsMax: Int(t.batchRowsMax),
            batchRowsSum: Int(clamping: t.batchRowsSum),
            firstTokenMs: ms(t.firstTokenNanos), lastTokenMs: ms(t.lastTokenNanos),
            finishedMs: ms(t.finishedNanos)))
        if receipts.count > capacity { receipts.removeFirst(receipts.count - capacity) }
    }

    /// A closed name; an error's message is never copied.
    static func reasonName(_ reason: CBv2FinishReason) -> String {
        switch reason {
        case .stop: return "stop"
        case .length: return "length"
        case .cancelled: return "cancelled"
        case .error: return "error"
        case .terminal: return "terminal"
        }
    }
}

extension EngineV2Bridge {
    /// This bridge's latest receipts, oldest first; empty unless enabled.
    func mtpRequestReceiptsSnapshot() -> [MTPRequestReceipt] {
        mtpRequestReceipts.receipts
    }

    /// Tests only: record receipts without the process environment.
    func enableMTPRequestReceiptsForTesting(capacity: Int = MTPRequestReceiptRing.defaultCapacity) {
        mtpRequestReceipts = MTPRequestReceiptRing(capacity: capacity)
    }
}
