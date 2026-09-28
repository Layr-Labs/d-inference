import Foundation

// These boundary send events have exactly the same meanings in the v2 native
// owner. Their CPU ticket remains a distinct v3 type with no false flow bridge.
typealias QwenLayerStagePrefillSendPhase = QwenLayerStageLookaheadSendPhase

enum QwenLayerStagePrefillReceivePhase {
    case beginHeaderReceive, headerValidated, beginReadyACK, readyACKSendCompleted
    case beginPayloadReceive, payloadReceivedAndValidated, beginReceivedACK, receivedACKSendCompleted
    case beginConsumption, consumptionAndSelectionValidated, consumedBoundaryReleased
    case beginConsumedACK, consumedACKSendCompleted
}

enum QwenLayerStagePrefillControlPhase {
    case beginStartSend, startSendCompleted, beginStartReceive, startValidated
    case beginTokenSend, tokenSendCompleted, beginTokenReceive, tokenValidated
    case beginPostStopSend, postStopSendCompleted, beginPostStopReceive, postStopValidated
}

/// Only the actual completed native commit and optional final selection escape
/// the receive scope. An intermediate frame must have nil selection; final must
/// have one. There is no generic result that can carry an MLXArray.
struct QwenLayerStagePrefillConsumption {
    let commit: QwenLayerStagePrefillCommit
    let selection: QwenLayerStagePrefillTokenReceipt?
}

struct QwenLayerStagePrefillReceiveResult {
    let ticket: QwenLayerStagePrefillBoundaryTicket
    let commit: QwenLayerStagePrefillCommit
    let selection: QwenLayerStagePrefillTokenReceipt?
    let tokenPacket: QwenLayerStagePrefillFirstTokenWirePacket?
}
