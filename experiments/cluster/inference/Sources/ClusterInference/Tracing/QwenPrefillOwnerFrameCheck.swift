import Foundation

/// Actual native frame type and selector, CPU-only; no model is constructed.
func checkQwenPrefillOwnerFrameBinding() throws {
    let identity = try QwenPrefillOwnerIdentity(requestFingerprint: String(repeating: "a", count: 64),
        profile: "long_prefill_8k_v1", role: .solo)
    let frame = QwenLayerStageFrame(sequence: 7, phase: .prefill, tokenOffset: 3584,
        tokenCount: 512, finalPromptChunk: false)
    var calls = 0
    let factory: QwenPrefillOwnerObserverFactory = { _ in calls += 1; return { _ in } }
    for sequence in 0..<16 {
        let candidate = QwenLayerStageFrame(sequence: sequence, phase: .prefill, tokenOffset: sequence * 512,
            tokenCount: 512, finalPromptChunk: sequence == 15)
        let observer = try qwenPrefillSelectedOwnerObserver(for: candidate, factory: factory)
        guard (observer != nil) == (sequence == 7) else { throw ProbeError("Owner selector acquired another chunk") }
    }
    guard calls == 1, try qwenPrefillSelectedOwnerObserver(for: frame, factory: nil) == nil else {
        throw ProbeError("Owner selector changed disabled or one-chunk behavior")
    }
    let recorder = QwenPrefillOwnerRecorder(identity: identity)
    let bound = qwenPrefillOwnerObserverFactory(recorder: recorder)
    let observe = try bound(frame)
    for (index, phase) in CBv2OwnerPhase.allCases.enumerated() {
        try observe(.init(phase: phase, tokenCount: 512, committedTokens: index == 7 ? 4096 : 3584))
    }
    try recorder.sealAfterOuterSuccess()
    guard try recorder.successfulTrace().events.count == 8 else { throw ProbeError("Owner frame lost events") }

    func reject(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw ProbeError("Invalid selected owner frame was accepted")
    }
    try reject { _ = try bound(frame) }
    try reject { _ = try recorder.successfulTrace() }
    let invalid = [
        QwenLayerStageFrame(sequence: 6, phase: .prefill, tokenOffset: 3584, tokenCount: 512, finalPromptChunk: false),
        QwenLayerStageFrame(sequence: 7, phase: .decode, tokenOffset: 3584, tokenCount: 512, finalPromptChunk: false),
        QwenLayerStageFrame(sequence: 7, phase: .prefill, tokenOffset: 3583, tokenCount: 512, finalPromptChunk: false),
        QwenLayerStageFrame(sequence: 7, phase: .prefill, tokenOffset: 3584, tokenCount: 511, finalPromptChunk: false),
        QwenLayerStageFrame(sequence: 7, phase: .prefill, tokenOffset: 3584, tokenCount: 512, finalPromptChunk: true),
    ]
    for candidate in invalid {
        let fresh = QwenPrefillOwnerRecorder(identity: identity)
        try reject { _ = try qwenPrefillOwnerObserverFactory(recorder: fresh)(candidate) }
        try reject { try fresh.observe(.init(phase: .graphConstructionBegin, tokenCount: 512, committedTokens: 3584)) }
    }
    struct Record: Encodable {
        let kind = "qwen_prefill_owner_frame_binding_check", cpuOnly = true
        let selectedFrames = 1, skippedFrames = 15, events = 8, rejectedCases = 12
    }
    try emitJSON(Record())
}
