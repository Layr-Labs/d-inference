import Foundation

/// The only analytics payload the inference process persists locally.
///
/// This type intentionally has no prompt, response, request-body, user, or raw
/// error fields. Adding a request-derived string here requires a privacy review.
public struct LocalAnalyticsEvent: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let eventID: String
    public let eventAt: Date
    public let eventName: String
    public let processEpoch: String
    public let jobID: String
    public let traceID: String?
    public let servingMode: String
    public let model: String?
    public let outcome: String
    public let errorClass: String?
    public let streaming: Bool
    public let promptTokens: Int64
    public let completionTokens: Int64
    public let cachedPromptTokens: Int64
    public let queueMS: Double?
    public let ttftMS: Double?
    public let totalMS: Double
    public let decodeTPS: Double?
    public let earnedMicroUSD: Int64?
    public let kvBackend: String?
    public let mtpActive: Bool?

    public init(
        eventID: String = UUID().uuidString.lowercased(),
        eventAt: Date = Date(),
        processEpoch: String,
        jobID: String,
        traceID: String? = nil,
        servingMode: String,
        model: String?,
        outcome: String,
        errorClass: String?,
        streaming: Bool,
        promptTokens: Int64,
        completionTokens: Int64,
        cachedPromptTokens: Int64,
        queueMS: Double?,
        ttftMS: Double?,
        totalMS: Double,
        decodeTPS: Double?,
        earnedMicroUSD: Int64? = nil,
        kvBackend: String? = nil,
        mtpActive: Bool? = nil
    ) {
        self.schemaVersion = Self.schemaVersion
        self.eventID = eventID
        self.eventAt = eventAt
        self.eventName = outcome == "success" ? "inference.completed" : "inference.\(outcome)"
        self.processEpoch = processEpoch
        self.jobID = jobID
        self.traceID = traceID
        self.servingMode = servingMode
        self.model = model
        self.outcome = outcome
        self.errorClass = errorClass
        self.streaming = streaming
        self.promptTokens = max(0, promptTokens)
        self.completionTokens = max(0, completionTokens)
        self.cachedPromptTokens = max(0, cachedPromptTokens)
        self.queueMS = Self.nonnegativeFinite(queueMS)
        self.ttftMS = Self.nonnegativeFinite(ttftMS)
        self.totalMS = max(0, totalMS.isFinite ? totalMS : 0)
        self.decodeTPS = Self.nonnegativeFinite(decodeTPS)
        self.earnedMicroUSD = earnedMicroUSD
        self.kvBackend = kvBackend
        self.mtpActive = mtpActive
    }

    private static func nonnegativeFinite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return max(0, value)
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case eventID = "event_id"
        case eventAt = "event_at"
        case eventName = "event_name"
        case processEpoch = "process_epoch"
        case jobID = "job_id"
        case traceID = "trace_id"
        case servingMode = "serving_mode"
        case model
        case outcome
        case errorClass = "error_class"
        case streaming
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case cachedPromptTokens = "cached_prompt_tokens"
        case queueMS = "queue_ms"
        case ttftMS = "ttft_ms"
        case totalMS = "total_ms"
        case decodeTPS = "decode_tps"
        case earnedMicroUSD = "earned_micro_usd"
        case kvBackend = "kv_backend"
        case mtpActive = "mtp_active"
    }
}
