import Foundation

enum ContributionScope: String, CaseIterable, Codable, Identifiable, Sendable {
    case thisMac = "this-mac"
    case allMacs = "all-macs"

    var id: String { rawValue }
}

/// A privacy-safe completed earning. Prompt and generated content are deliberately
/// absent; only coordinator accounting metadata crosses this domain boundary.
struct ContributionRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var timestamp: Date
    /// X25519 daemon-session key. Account history maps every key back to the
    /// hardware serial before deciding whether the record belongs to this Mac.
    var providerKey: String
    /// Ephemeral coordinator session identifier retained only as record metadata.
    /// Never use this value to decide which physical Mac earned a record.
    var providerID: String
    var providerName: String
    var modelID: String
    var modelName: String
    var inputTokens: UInt64
    var outputTokens: UInt64
    var amount: MicroUSD

    var totalTokens: UInt64 {
        let result = inputTokens.addingReportingOverflow(outputTokens)
        return result.overflow ? .max : result.partialValue
    }
}
