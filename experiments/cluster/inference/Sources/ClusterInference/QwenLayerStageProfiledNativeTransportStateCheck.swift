import Foundation

struct QwenLayerStageProfiledNativeTransportStateCheck: Encodable {
    let kind = "qwen_layer_stage_profiled_native_transport_state_check", schemaVersion = 1
    let correctnessOnly = true, throughputMeasurementValid = false
    let nativeIOExecuted = false, nativeCommitExecuted = false
    let simulatedFramesPerRole: Int
    let rejectionLabels: [String]
}

/// CPU metadata only. The native wrapper additionally owns backend completion,
/// original-array release and callback/MLX error fencing; this does not test IO.
func checkQwenLayerStageProfiledNativeTransportState() throws
    -> QwenLayerStageProfiledNativeTransportStateCheck {
    let fixture = try QwenLayerStageProfiledWireCheckFixture()
    var checks = QwenLayerStageProfiledWireChecks()
    func owner(_ rank: Int, started: Bool = true) throws -> QwenLayerStageProfiledPrefillTransportState {
        let state = QwenLayerStageProfiledPrefillTransportState(rank: rank, agreement: fixture.agreement)
        if started { try state.requireStart(rank: rank); try state.completeStart(fixture.start) }
        return state
    }
    func envelope(_ frame: QwenLayerStageFrame) throws -> QwenLayerStageProfiledPrefillBoundaryEnvelope {
        let header = try QwenLayerStageProfiledBoundaryWireHeader(
            expected: fixture.agreement.boundaryExpectation(for: frame),
            payloadSHA256: String(repeating: "4", count: 64))
        return try .init(boundary: header, agreement: fixture.agreement)
    }
    try checks.reject("frame-before-start") {
        try owner(0, started: false).requireFrame(fixture.first.boundary.frame, rank: 0)
    }
    try checks.reject("replayed-start") { try owner(0).requireStart(rank: 0) }
    try checks.reject("wrong-role") { try owner(0).requireFrame(fixture.first.boundary.frame, rank: 1) }
    try checks.reject("skipped-local-frame") { try owner(0).requireFrame(fixture.final.boundary.frame, rank: 0) }
    let pending = try owner(0), other = try owner(0)
    let original = try pending.ticket(fixture.first)
    try pending.senderReceived(original)
    try checks.reject("next-header-before-consumed") {
        try pending.requireFrame(fixture.agreement.request.steps[1].frame, rank: 0)
    }
    try checks.reject("foreign-ticket-owner") { try pending.requirePending(other.ticket(fixture.first)) }
    try checks.reject("same-envelope-different-nonce") { try pending.requirePending(pending.ticket(fixture.first)) }
    try pending.senderConsumed(original)
    try checks.reject("consumed-ticket-replay") { try pending.requirePending(original) }
    try checks.reject("token-before-all-frames") { _ = try owner(0).requireTokenTransfer(rank: 0) }
    let recursive = try owner(0)
    try recursive.beginOperation()
    try checks.reject("recursive-operation") { try recursive.beginOperation() }
    recursive.endOperation()
    guard recursive.isFailed else { throw ProbeError("Recursive profiled transport was not fenced") }
    try checks.reject("retired-operation-reuse") { try recursive.beginOperation() }

    let sender = try owner(0), receiver = try owner(1)
    for step in fixture.agreement.request.steps {
        let packet = try envelope(step.frame)
        try sender.requireFrame(step.frame, rank: 0); try receiver.requireFrame(step.frame, rank: 1)
        let sent = try sender.ticket(packet), received = try receiver.ticket(packet)
        try sender.senderReceived(sent)
        try receiver.receiverConsumed(received, token: step.frame.finalPromptChunk ? fixture.token : nil)
        try sender.senderConsumed(sent)
    }
    guard sender.completedBoundaryCount == 16, receiver.completedBoundaryCount == 16,
          !sender.hasPendingConsumption, !receiver.hasPendingConsumption,
          !sender.isComplete, !receiver.isComplete else {
        throw ProbeError("Profiled transport state lost the complete local frame schedule")
    }
    try checks.reject("post-stop-before-token") { _ = try sender.requirePostStop(rank: 0) }
    _ = try receiver.tokenForSend()
    try receiver.completeToken(fixture.token); try sender.completeToken(fixture.token)
    try checks.reject("token-transfer-replay") { _ = try sender.requireTokenTransfer(rank: 0) }
    try sender.completePostStop(); try receiver.completePostStop()
    guard sender.isComplete, receiver.isComplete else { throw ProbeError("Profiled transport did not complete both roles") }
    try checks.reject("post-stop-replay") { try receiver.completePostStop() }
    return .init(simulatedFramesPerRole: 16, rejectionLabels: checks.rejected)
}
