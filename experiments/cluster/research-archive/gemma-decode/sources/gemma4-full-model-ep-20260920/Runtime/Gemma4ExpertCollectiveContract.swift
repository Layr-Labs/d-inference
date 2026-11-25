import Foundation
import MLX
import MLXLMCommon

/// Borrowed by the original state owner's forward closure. The implementation
/// may evaluate/read real routes for correctness, but may not commit/retire
/// cache state or mint an independent model/device owner.
protocol Gemma4ExpertForwardOperation: AnyObject {
    var partition: Gemma4ExpertPartition { get }
    var binding: Gemma4ExpertInvocationBinding { get }
    func unweighted(frame: QwenLayerStageFrame, layer: Int, input: MLXArray,
                    globalIDs: MLXArray, weights: MLXArray, bank: SwitchGLU,
                    check: () throws -> Void) throws -> MLXArray
}

struct Gemma4ExpertInvocationBinding: Codable, Equatable {
    enum Purpose: String, Codable { case probe, request }
    let purpose: Purpose
    let requestID: UUID
    let membershipEpoch: UUID
    let requestSHA256: String
    let artifactSHA256: String
    let configurationSHA256: String
    let rankBuildSHA256: [String]
    let ownershipSHA256: String

    func validate(partition: Gemma4ExpertPartition) throws {
        guard [requestSHA256, artifactSHA256, configurationSHA256, ownershipSHA256]
                .allSatisfy(qwenStageWireIsSHA256), rankBuildSHA256.count == 2,
              rankBuildSHA256.allSatisfy(qwenStageWireIsSHA256),
              ownershipSHA256 == sha256(try canonicalJSONData(partition.globalIDsByRank)) else {
            throw ProbeError("Gemma EP invocation binding lacks exact request/build/ownership scope")
        }
    }
}

/// Rank-independent equality is mandatory before any output is accepted.
/// This is identity metadata, not a source of clocks, trust, or admission.
struct Gemma4ExpertLayerScope: Encodable, Equatable {
    let binding: Gemma4ExpertInvocationBinding
    let frame: QwenLayerStageFrame
    let globalLayer: Int
    let tokenCount: Int
    let dtype: String
    let routeSHA256: String
    let inputSHA256: String
    let weightsSHA256: String
    let assignmentCounts: [Int]
    let projectionPolicies: [ExpertAxisProjectionPolicy]
}

struct Gemma4ExpertPeerRows {
    let scope: Gemma4ExpertLayerScope
    let producerRank: Int
    let array: MLXArray?
}

/// Implement on the already-owned Collective. Deterministic rank0-send-first,
/// rank1-receive-first exchanges must use completed sends/receives and consumed
/// ACKs; no weighted partials. A thrown exchange must poison that same group.
/// The first slice intentionally supplies no second wire/group or owner.
protocol Gemma4ExpertUnweightedExchange: AnyObject {
    func exchange(scope: Gemma4ExpertLayerScope, localRank: Int,
                  localRows: MLXArray?, check: () throws -> Void) throws -> Gemma4ExpertPeerRows
}
