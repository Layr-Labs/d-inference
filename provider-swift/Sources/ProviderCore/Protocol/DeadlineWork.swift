import Foundation

/// Remaining-work upper bound owned by the shared service ledger. Full original
/// work may be retained until retirement; consumers must not interpret it as
/// work already completed or use heartbeat age as performance-sample age.
public struct DeadlineWork: Codable, Sendable, Equatable {
    public var version: Int
    public var epoch: String
    public var known: Bool
    public var prefillTokens: Int64
    public var decodeTokens: Int64
    public var requestCount: Int
    public var contextTokensMax: Int
    public var serviceFraction: Double

    enum CodingKeys: String, CodingKey {
        case version, epoch, known
        case prefillTokens = "prefill_tokens"
        case decodeTokens = "decode_tokens"
        case requestCount = "request_count"
        case contextTokensMax = "context_tokens_max"
        case serviceFraction = "service_fraction"
    }
}
