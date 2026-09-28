import Foundation

/// Closed normalized geometry for shared native state/forward mechanics. Every
/// case carries a request whose own throwing constructor admitted its bounds.
/// This wrapper has no integer initializer, decoder or new serialized identity.
enum QwenLayerStageAdmittedRequest: Equatable {
    case legacy(QwenLayerStageRequestSpec)
    case profiled(QwenLayerStageProfiledPrefillRequestSpec)

    var requestID: UUID {
        switch self { case .legacy(let r): r.requestID; case .profiled(let r): r.requestID }
    }
    var batchSize: Int {
        switch self { case .legacy: 1; case .profiled(let r): r.batchSize }
    }
    var promptCount: Int {
        switch self { case .legacy(let r): r.promptCount; case .profiled(let r): r.promptCount }
    }
    var chunkSize: Int {
        switch self { case .legacy(let r): r.chunkSize; case .profiled(let r): r.chunkSize }
    }
    var outputCount: Int {
        switch self { case .legacy(let r): r.outputCount; case .profiled(let r): r.outputCount }
    }
    var fingerprint: String {
        switch self { case .legacy(let r): r.fingerprint; case .profiled(let r): r.fingerprint }
    }
    var profile: QwenLayerStagePrefillProfile? {
        switch self { case .legacy: nil; case .profiled(let r): r.profile }
    }
    var prefillFrameCount: Int {
        switch self {
        // The untouched legacy initializer proves 1<=P<=128 and 1<=M<=32;
        // this expression cannot overflow and remains exactly ceil(P/M).
        case .legacy(let r): (r.promptCount - 1) / r.chunkSize + 1
        case .profiled(let r): r.prefillFrameCount
        }
    }
    var forwardCount: Int {
        switch self {
        case .legacy(let r): prefillFrameCount + r.outputCount - 1 // <=131
        case .profiled(let r): r.prefillFrameCount
        }
    }
    var maximumTokens: Int {
        switch self {
        case .legacy(let r): r.promptCount + r.outputCount // <=132; reserves the output slot as before
        case .profiled(let r): r.maximumTokens
        }
    }
}
