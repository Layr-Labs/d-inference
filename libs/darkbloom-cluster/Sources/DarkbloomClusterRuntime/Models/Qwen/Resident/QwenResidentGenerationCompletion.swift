import DarkbloomClusterProtocol
import Foundation

public struct QwenResidentGenerationCompletion: Sendable {
    public let requestID: UUID
    public let finishReason: ClusterWorkerFinishReason
    public let selectedTokenIDs: [Int]
    public let completedFrames: Int
    public let committedTokens: Int
    public let tokenChainSHA256: String
    public let bothRequestStatesRetired: Bool
    /// Prompt tokens both ranks restored from their prefix caches.
    public var reusedPromptTokens: Int = 0
    /// Prompt frontiers this rank kept after the request.
    public var storedPromptFrontiers: [Int] = []
    /// What this rank measured of the request (hand-off, MTP acceptance), for its launcher (S24).
    public var telemetry: ClusterWorkerRequestTelemetry? = nil
    public let physicalTransferQualified = false
    public let independentNumericalComparisonPerformed = false
    public let externalTTFTMeasured = false
}
