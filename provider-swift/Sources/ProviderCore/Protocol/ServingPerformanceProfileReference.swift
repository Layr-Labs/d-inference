import Foundation

/// A reference to reviewed release data, never a self-certified batch curve.
public struct ServingPerformanceProfileReference: Codable, Sendable, Equatable {
    public var id: String
    public var runtimeRevision: String
    public var contextTokens: Int
    public var mtp: ServingMTPConfiguration? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case runtimeRevision = "runtime_revision"
        case contextTokens = "context_tokens"
        case mtp
    }
}
