import Foundation

/// Local CPU boundaries of the resident-generation protocol. In particular,
/// payloadSendEnd means local send completion, never peer validation.
enum QwenGenerationPhase: String, Encodable, CaseIterable {
    case requestBegin, readinessBegin, readinessEnd, stateBegin, stateEnd
    case frameBegin, prepareBegin, prepareEnd, originalWrapperReleased
    case headerSendBegin, headerSendEnd, readyAckWaitBegin, readyAckWaitEnd
    case payloadSendBegin, payloadSendEnd, consumedAckWaitBegin, consumedAckWaitEnd
    case headerReceiveBegin, headerReceiveEnd, readyAckSendBegin, readyAckSendEnd
    case payloadReceiveBegin, payloadReceiveEnd, payloadValidated
    case consumeBegin, consumeEnd, consumedAckSendBegin, consumedAckSendEnd
    case selectionBegin, selectionEnd, tokenSendBegin, tokenSendEnd
    case tokenReceiveBegin, tokenReceiveEnd, tokenAckBegin, tokenAckEnd
    case firstTokenAgreed, requestRetired

    var requiredRank: Int? {
        switch self {
        case .prepareBegin, .prepareEnd, .originalWrapperReleased,
             .headerSendBegin, .headerSendEnd, .readyAckWaitBegin, .readyAckWaitEnd,
             .payloadSendBegin, .payloadSendEnd, .consumedAckWaitBegin, .consumedAckWaitEnd,
             .tokenReceiveBegin, .tokenReceiveEnd, .tokenAckBegin, .tokenAckEnd: return 0
        case .headerReceiveBegin, .headerReceiveEnd, .readyAckSendBegin, .readyAckSendEnd,
             .payloadReceiveBegin, .payloadReceiveEnd, .payloadValidated,
             .consumeBegin, .consumeEnd, .consumedAckSendBegin, .consumedAckSendEnd,
             .selectionBegin, .selectionEnd, .tokenSendBegin, .tokenSendEnd: return 1
        default: return nil
        }
    }
}

struct QwenGenerationPhaseFrame: Encodable, Equatable {
    let sequence: Int
    let tokenOffset: Int
    let tokenCount: Int
    let finalPromptChunk: Bool
}

/// A missing frontier means it was not observed at this boundary. Local state
/// can be one chunk ahead of bilateral control; keep these values separate.
struct QwenGenerationPhaseObservation: Encodable {
    let phase: QwenGenerationPhase
    let frame: QwenGenerationPhaseFrame?
    let localCommittedTokens: Int?
    let agreedCommittedTokens: Int?

    func deliver(to observer: QwenGenerationPhaseObserver, check: () throws -> Void) throws {
        do { try observer(self) }
        catch {
            let observationError = error
            // Reuse the owner's existing error/deadline precedence on failure.
            try check()
            throw observationError
        }
    }
}

/// Synchronous CPU scalars only. No native work, owner reentry, tensors or IO.
typealias QwenGenerationPhaseObserver = (QwenGenerationPhaseObservation) throws -> Void

struct QwenGenerationPhaseIdentity: Encodable, Equatable {
    let requestID: String
    let membershipEpoch: String
    let requestFingerprint: String
    let agreementFingerprint: String
    let profileFingerprint: String
    let sourceConfigurationSHA256: String
    let artifactAggregateSHA256: String
    let storageCommitmentSHA256: String
    let planFingerprint: String
    let stageFingerprint: String
    let buildSHA256: String
    let numericalPolicySHA256: String
    let rank: Int
    let promptCount: Int
    let chunkSize: Int
    let outputCount: Int
    let prefillPolicy: String
    let protocolBoundary = "resident_generation_send_completed_credit_v1"

    func validate() throws {
        func hash(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
        }
        guard let request = UUID(uuidString: requestID), request.uuidString.lowercased() == requestID,
              let epoch = UUID(uuidString: membershipEpoch), epoch.uuidString.lowercased() == membershipEpoch,
              [requestFingerprint, agreementFingerprint, profileFingerprint, sourceConfigurationSHA256,
               artifactAggregateSHA256, storageCommitmentSHA256, planFingerprint, stageFingerprint,
               buildSHA256, numericalPolicySHA256].allSatisfy(hash),
              (0...1).contains(rank), (1...8192).contains(promptCount),
              (1...512).contains(chunkSize), (1...128).contains(outputCount),
              promptCount + outputCount <= 8320,
              ["serial", "oneChunkLookahead"].contains(prefillPolicy) else {
            throw QwenGenerationPhaseError("Invalid resident observation identity or geometry")
        }
    }
}

struct QwenGenerationPhaseEvent: Encodable {
    let ordinal: Int
    let observation: QwenGenerationPhaseObservation
    let localUptimeNanoseconds: UInt64
}

struct QwenGenerationPhaseTrace: Encodable {
    let schema = "qwen_resident_generation_phase_trace_v1"
    let identity: QwenGenerationPhaseIdentity
    let clockSource: String
    let maximumEvents: Int
    let requiredHostReservationBytes: Int
    let events: [QwenGenerationPhaseEvent]
    let firstLocalUptimeNanoseconds: UInt64
    let lastLocalUptimeNanoseconds: UInt64
    let diagnosticOnly = true
    let includesRecorderOverhead = true
    let crossProcessClockAlignmentAsserted = false
    let gpuKernelTimeAsserted = false
    let transportWaitIsWireCost = false
    let retirementIndependentlyVerified = false
    let hostReservationIndependentlyVerified = false
}

struct QwenGenerationPhaseError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
