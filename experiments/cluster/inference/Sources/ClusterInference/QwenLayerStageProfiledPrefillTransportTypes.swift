import Foundation

// New value-only callback namespace; the v1/v2/v3 owners and codecs are unchanged.
enum QwenLayerStageProfiledPrefillSendPhase {
    case beginHeader, headerSendCompleted, readyACKAccepted, beginPayloadSend
    case payloadSendCompleted, receivedACKAccepted, beginConsumedDrain, consumedACKAccepted
}

enum QwenLayerStageProfiledPrefillReceivePhase {
    case beginHeaderReceive, headerValidated, beginReadyACK, readyACKSendCompleted
    case beginPayloadReceive, payloadReceivedAndValidated, beginReceivedACK, receivedACKSendCompleted
    case beginConsumption, consumptionAndSelectionValidated, consumedBoundaryReleased
    case beginConsumedACK, consumedACKSendCompleted
}

enum QwenLayerStageProfiledPrefillControlPhase {
    case beginStartSend, startSendCompleted, beginStartReceive, startValidated
    case beginTokenSend, tokenSendCompleted, beginTokenReceive, tokenValidated
    case beginPostStopSend, postStopSendCompleted, beginPostStopReceive, postStopValidated
}

/// Only the actual completed native commit and optional final selection escape
/// the receive scope. An intermediate frame must have nil selection; final must
/// have one. There is no generic result that can carry an MLXArray.
struct QwenLayerStageProfiledPrefillConsumption {
    let commit: QwenLayerStagePrefillCommit
    let selection: QwenLayerStagePrefillTokenReceipt?
}

struct QwenLayerStageProfiledPrefillReceiveResult {
    let ticket: QwenLayerStageProfiledPrefillBoundaryTicket
    let commit: QwenLayerStagePrefillCommit
    let selection: QwenLayerStagePrefillTokenReceipt?
    let tokenPacket: QwenLayerStageProfiledPrefillFirstTokenWirePacket?
}
