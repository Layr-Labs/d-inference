import Foundation

struct QwenLayerStageProfiledPrefillWireCheckResult: Encodable {
    let kind = "qwen_layer_stage_profiled_prefill_wire_check"
    let cpuOnly = true
    let nativeExecutionPerformed = false
    let acceptedCases: Int
    let rejectedCases: Int
    let rejectionLabels: [String]
}

/// Root may invoke this after integrating the separately frozen geometry draft.
/// All metadata/selection/payload hashes below are fabricated CPU fixtures.
func checkQwenLayerStageProfiledPrefillWire() throws -> QwenLayerStageProfiledPrefillWireCheckResult {
    typealias Boundary = QwenLayerStageProfiledPrefillBoundaryEnvelope
    typealias ACK = QwenLayerStageProfiledPrefillBoundaryAcknowledgement
    let fixture = try QwenLayerStageProfiledWireCheckFixture()
    var checks = QwenLayerStageProfiledWireChecks()
    for policy in QwenLayerStageProfiledPrefillMeasurementFlow.SchedulingPolicy.allCases {
        for dtype in ["float16", "bfloat16", "float32"] {
            let value = try QwenLayerStageProfiledWireCheckFixture(policy: policy, dtype: dtype)
            var gate = QwenLayerStageProfiledPrefillWireLifecycle(agreement: value.agreement)
            let start = try gate.acceptStart(value.start.encoded())
            guard start.fingerprint == value.start.fingerprint, start.wireBytesSHA256 == sha256(start.encoded()),
                  start.fingerprint != start.wireBytesSHA256, value.agreement.request.steps.count == 16 else {
                throw ProbeError("Profiled start identity or 8192/512 timeline differs")
            }
            for step in value.agreement.request.steps {
                let expected = try value.agreement.boundaryExpectation(for: step.frame)
                let header = try QwenLayerStageProfiledBoundaryWireHeader(expected: expected, payloadSHA256: String(repeating: "4", count: 64))
                let envelope = try Boundary(boundary: header, agreement: value.agreement)
                let decoded = try Boundary.decode(envelope.encoded(), agreement: value.agreement, expectedFrame: step.frame)
                guard decoded.boundary == header, decoded.fingerprint == envelope.fingerprint,
                      decoded.wireBytesSHA256 == sha256(envelope.encoded()), decoded.fingerprint != decoded.wireBytesSHA256,
                      step.frame.tokenOffset == step.frame.sequence * 512, step.frame.tokenCount == 512,
                      step.frame.finalPromptChunk == (step.frame.sequence == 15) else {
                    throw ProbeError("Profiled frame bytes, fingerprints or admitted timeline differ")
                }
            }
            try gate.bindFinalBoundary(value.final)
            try gate.acceptFinalConsumed(ACK.values(envelope: value.final, phase: .consumed))
            let token = try gate.acceptFirstToken(value.token.encoded())
            guard gate.firstTokenComplete, token.tokenID == 7, token.fingerprint == value.token.fingerprint,
                  token.wireBytesSHA256 == sha256(token.encoded()), token.fingerprint != token.wireBytesSHA256 else {
                throw ProbeError("Profiled token handshake or exact-byte domains differ")
            }
            var released = QwenLayerStageProfiledPrefillPostStopGate(token: token)
            try released.accept(QwenLayerStageProfiledPrefillPostStopAcknowledgement.values(token: token))
            guard released.released, !released.isFailed else { throw ProbeError("Profiled post-stop gate failed") }
            checks.accepted += 1
        }
    }
    for (prompt, chunk, frames, tail) in [(1, 1, 1, 1), (1025, 512, 3, 1), (8192, 64, 128, 64), (65, 32, 3, 1)] {
        let value = try QwenLayerStageProfiledWireCheckFixture(promptCount: prompt, chunkSize: chunk)
        guard value.agreement.request.steps.count == frames, value.final.boundary.frame.tokenCount == tail else {
            throw ProbeError("Profiled ragged or maximum-frame timeline differs")
        }
        _ = try Boundary.decode(value.final.encoded(), agreement: value.agreement, expectedFrame: value.final.boundary.frame)
        checks.accepted += 1
    }
    let maximum = try QwenLayerStageProfiledWireCheckFixture(dtype: "float32", hiddenSize: 8192)
    guard maximum.first.boundary.byteCount == 16 * 1024 * 1024,
          maximum.first.boundary.shape == [1, 512, 8192] else { throw ProbeError("Maximum native metadata payload bound differs") }
    checks.accepted += 1 // No 16 MiB payload is allocated by this metadata check.
    try checkQwenLayerStageProfiledWireRejections(fixture: fixture, checks: &checks)
    try checkQwenLayerStageProfiledWireLegacyAndBytes(fixture: fixture, checks: &checks)
    try checkQwenLayerStageProfiledWireGolden(fixture: fixture)
    checks.accepted += 1
    guard Set(checks.rejected).count == checks.rejected.count else { throw ProbeError("Profiled rejection labels repeated") }
    return .init(acceptedCases: checks.accepted, rejectedCases: checks.rejected.count, rejectionLabels: checks.rejected)
}
