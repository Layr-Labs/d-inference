import Foundation

/// Flow identity is explicit and independent of model/artifact identity. Native
/// integration must validate a closed v2 envelope before ready ACK or payload.
enum QwenLayerStageOverlapFlow {
    static let envelopeVersion = 2
    static let name = "prompt_lookahead_one_v1"
    static let acknowledgementDomain = "qwen-stage-ack-v2"
    static let maximumHeaderBytes = 16 * 1024
    static let maximumFrames = 132
}

/// No generated-token case exists. A future production decode adapter needs a
/// verified rank-one token receipt; consumed ACK alone does not supply a token.
enum QwenLayerStageOverlapDecodeAdmission: String {
    case prefillOnly = "prefill_only"
    case frozenTeacherDiagnostic = "frozen_teacher_diagnostic"
}

/// Reuses the existing exact microchunk admission; contains no native objects,
/// token substitutions, wire parser, clock, model or transport implementation.
struct QwenLayerStageOverlapPlan {
    let request: QwenLayerStageRequestSpec
    let decodeAdmission: QwenLayerStageOverlapDecodeAdmission
    let frames: [QwenLayerStageFrame]

    init(request: QwenLayerStageRequestSpec,
         decodeAdmission: QwenLayerStageOverlapDecodeAdmission) throws {
        guard decodeAdmission != .prefillOnly || request.outputCount == 1 else {
            throw ProbeError("Prefill-only overlap cannot admit decode frames")
        }
        var schedule = QwenLayerStageSchedule(request: request)
        var frames: [QwenLayerStageFrame] = []
        while !schedule.complete {
            let frame: QwenLayerStageFrame
            if schedule.committedPromptTokens < request.promptCount {
                let count = min(request.chunkSize, request.promptCount - schedule.committedPromptTokens)
                frame = try schedule.admitPrefill(count: count, offset: schedule.committedTokens,
                    final: schedule.committedPromptTokens + count == request.promptCount)
            } else {
                frame = try schedule.admitDecode(offset: schedule.committedTokens)
            }
            try schedule.commit(frame)
            frames.append(frame)
            guard frames.count <= QwenLayerStageOverlapFlow.maximumFrames else {
                throw ProbeError("Overlap timeline exceeds its bounded frame count")
            }
        }
        self.request = request; self.decodeAdmission = decodeAdmission; self.frames = frames
    }

    var requestFingerprint: String { request.fingerprint }
    var finalCommittedTokens: Int { request.promptCount + request.outputCount - 1 }

    func matches(_ ticket: QwenLayerStageOverlapTicket, at sequence: Int) -> Bool {
        frames.indices.contains(sequence) && ticket.flow == QwenLayerStageOverlapFlow.name
            && ticket.requestFingerprint == requestFingerprint && ticket.frame == frames[sequence]
    }

    func committedTokens(after frameCount: Int) -> Int {
        precondition((0...frames.count).contains(frameCount))
        guard frameCount > 0 else { return 0 }
        let frame = frames[frameCount - 1]
        return frame.tokenOffset + frame.tokenCount
    }

    func allowsPreparation(at sequence: Int, withPendingConsumedACK: Bool) -> Bool {
        guard frames.indices.contains(sequence) else { return false }
        let frame = frames[sequence]
        if frame.phase == .prefill { return true }
        return !withPendingConsumedACK && decodeAdmission == .frozenTeacherDiagnostic
    }
}

/// CPU-only identity of one actually encoded v2 envelope. Construct only after
/// its header is validated against local expected source/frame/token geometry.
/// The transport owns bounded raw envelope bytes separately for ACK validation.
struct QwenLayerStageOverlapTicket: Equatable {
    let flow: String
    let requestFingerprint: String
    let frame: QwenLayerStageFrame
    let headerSHA256: String

    init(flow: String, requestFingerprint: String, frame: QwenLayerStageFrame,
         headerSHA256: String) throws {
        guard flow == QwenLayerStageOverlapFlow.name,
              qwenStageWireIsSHA256(requestFingerprint), qwenStageWireIsSHA256(headerSHA256) else {
            throw ProbeError("Overlap ticket requires the admitted flow and exact envelope/request hashes")
        }
        self.flow = flow; self.requestFingerprint = requestFingerprint
        self.frame = frame; self.headerSHA256 = headerSHA256
    }
}
