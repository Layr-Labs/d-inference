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
    /// Set when both ranks ended the request alone (D6): its runtime's `start`
    /// then throws `ClusterResidentRequestAbort` instead of returning.
    public var abort: ClusterWorkerAbort? = nil
    /// The refusing rank's own sentence, or the peer's abort as this rank saw it.
    public var abortMessage: String? = nil
    public let physicalTransferQualified = false
    public let independentNumericalComparisonPerformed = false
    public let externalTTFTMeasured = false

    /// A request both ranks ended alone and retired, with nothing selected
    /// here to report: what a runtime's scope returns before `start` throws.
    static func aborted(requestID: UUID, abort: ClusterWorkerAbort, message: String, rank: Int) -> Self {
        log("darkbloom-stage-abort-v1 rank=\(rank) request=\(requestID.uuidString.lowercased())"
            + " stopped_rank=\(abort.rank) reason=\(abort.reason.rawValue) retired=both")
        var value = QwenResidentGenerationCompletion(requestID: requestID, finishReason: .clientStop, selectedTokenIDs: [],
            completedFrames: 0, committedTokens: 0, tokenChainSHA256: String(repeating: "0", count: 64),
            bothRequestStatesRetired: true)
        value.abort = abort; value.abortMessage = message
        return value
    }

    /// Throws the request's abort, if both ranks ended it alone.
    func requireNotAborted() throws -> Self {
        guard let abort else { return self }
        throw ClusterResidentRequestAbort(abort: abort, message: abortMessage
            ?? "The pair ended this request alone: rank \(abort.rank)'s memory refused it while it ran")
    }
}
