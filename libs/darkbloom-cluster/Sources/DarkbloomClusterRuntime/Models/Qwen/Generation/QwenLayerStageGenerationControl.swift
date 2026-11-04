import Foundation

/// Serialized control state, with no model, clock, socket or background work.
/// The runtime calls these acknowledgements only after actual local commit or
/// a validated peer message; this class cannot establish physical execution.
final class QwenLayerStageGenerationControl {
    enum Phase { case frame, committingFrame, token, publishing, decision, deciding, retiring, retired }
    enum Retirement: String { case retired, fenced }
    let agreement: QwenLayerStageGenerationAgreement
    private var schedule: QwenLayerStageGenerationSchedule
    private(set) var phase: Phase = .frame
    private(set) var isFailed = false
    private(set) var selectedTokenCount = 0
    private(set) var tokenChainSHA256: String
    private(set) var finishReason: QwenLayerStageGenerationFinishReason?
    private(set) var lastTokenID: Int?
    private var pendingFrame: QwenLayerStageGenerationBoundaryExpectation?
    private var boundaryFingerprint: String?
    private var tokenPacket: QwenLayerStageGenerationTokenPacket?
    private var decisionPacket: QwenLayerStageGenerationDecisionPacket?
    private var acknowledgedRanks = Set<Int>()
    private var retiredRanks = Set<Int>()
    var committedTokens: Int { schedule.committedTokens }
    var completedFrames: Int { schedule.nextSequence }
    var isRetired: Bool { phase == .retired }

    init(agreement: QwenLayerStageGenerationAgreement) {
        self.agreement = agreement; schedule = .init(request: agreement.request)
        tokenChainSHA256 = agreement.initialTokenChainSHA256
    }

    func beginFrame() throws -> QwenLayerStageGenerationBoundaryExpectation {
        try operation {
            guard phase == .frame else { throw ProbeError("Generation frame requires preceding decision agreement") }
            let frame = try agreement.request.frame(sequence: schedule.nextSequence)
            let tokens: [Int]
            if frame.phase == .prefill {
                tokens = Array(agreement.request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)])
            } else {
                guard let lastTokenID, selectedTokenCount == schedule.decodeForwardCount + 1 else {
                    throw ProbeError("Generation decode requires the agreed previous target token")
                }
                tokens = [lastTokenID]
            }
            let expected = try QwenLayerStageGenerationBoundaryExpectation(agreement: agreement, frame: frame,
                tokenIDs: tokens, previousTokenChainSHA256: tokenChainSHA256)
            pendingFrame = expected; boundaryFingerprint = nil; acknowledgedRanks.removeAll(); phase = .committingFrame
            return expected
        }
    }

    func acknowledgeFrame(rank: Int, packet: QwenLayerStageGenerationBoundaryPacket,
                          nativeCommittedTokens: Int) throws {
        try operation {
            guard phase == .committingFrame, let pendingFrame,
                  packet.content.expectation == pendingFrame,
                  nativeCommittedTokens == pendingFrame.frame.tokenOffset + pendingFrame.frame.tokenCount else {
                throw ProbeError("Generation frame acknowledgement lacks matching native commit")
            }
            if let boundaryFingerprint, boundaryFingerprint != packet.fingerprint {
                throw ProbeError("Generation ranks acknowledged different residuals")
            }
            try acknowledge(rank)
            boundaryFingerprint = packet.fingerprint
            if acknowledgedRanks.count == 2 {
                try schedule.commit(pendingFrame.frame)
                phase = pendingFrame.frame.finalPromptChunk || pendingFrame.frame.phase == .decode ? .token : .frame
                self.pendingFrame = nil; acknowledgedRanks.removeAll()
            }
        }
    }

    func acknowledgeToken(rank: Int, packet: QwenLayerStageGenerationTokenPacket) throws {
        try operation {
            guard phase == .token, let boundaryFingerprint else { throw ProbeError("Generation token precedes both native commits") }
            let expected = try QwenLayerStageGenerationTokenPacket(agreement: agreement,
                boundaryFingerprint: boundaryFingerprint, previousTokenChainSHA256: tokenChainSHA256,
                ordinal: selectedTokenCount, committedTokens: schedule.committedTokens, tokenID: packet.content.tokenID)
            guard packet.content == expected.content,
                  tokenPacket == nil || tokenPacket?.content == packet.content else {
                throw ProbeError("Generation token agreement/history differs")
            }
            try acknowledge(rank); tokenPacket = packet
            if acknowledgedRanks.count == 2 {
                selectedTokenCount += 1; lastTokenID = packet.content.tokenID
                tokenChainSHA256 = packet.nextTokenChainSHA256
                acknowledgedRanks.removeAll(); phase = .publishing
            }
        }
    }

    /// Called once after both ranks accept the scalar. Only the request owner
    /// publishes it; no next forward is authorized until the decision is ACKed.
    func takeCommittedToken() throws -> Int {
        try operation {
            guard phase == .publishing, let lastTokenID else { throw ProbeError("Generation token is not publishable twice") }
            phase = .decision; return lastTokenID
        }
    }

    func decide(continueRequested: Bool) throws -> QwenLayerStageGenerationDecisionPacket {
        try operation {
            guard phase == .decision, let tokenPacket else { throw ProbeError("Generation decision precedes token publication") }
            let packet = try QwenLayerStageGenerationDecisionPacket(agreement: agreement,
                token: tokenPacket, continueRequested: continueRequested)
            decisionPacket = packet; acknowledgedRanks.removeAll(); phase = .deciding
            return packet
        }
    }

    func acknowledgeDecision(rank: Int, packet: QwenLayerStageGenerationDecisionPacket) throws {
        try operation {
            guard phase == .deciding, let decisionPacket, packet.content == decisionPacket.content else {
                throw ProbeError("Generation ranks disagree about continuation or stop")
            }
            try acknowledge(rank)
            if acknowledgedRanks.count == 2 {
                if packet.content.decision == .proceed {
                    tokenPacket = nil; self.decisionPacket = nil; phase = .frame
                } else {
                    guard let reason = QwenLayerStageGenerationFinishReason(rawValue: packet.content.decision.rawValue),
                          let lastTokenID else { throw ProbeError("Generation stop reason missing") }
                    try schedule.finish(reason, selectedTokenCount: selectedTokenCount, lastTokenID: lastTokenID)
                    finishReason = reason; phase = .retiring
                }
                acknowledgedRanks.removeAll()
            }
        }
    }

    /// Idempotent failed cancellation; does not claim either rank is retired.
    func cancel() {
        guard !isRetired else { return }
        isFailed = true; finishReason = nil; phase = .retiring
        pendingFrame = nil; tokenPacket = nil; decisionPacket = nil; acknowledgedRanks.removeAll()
    }

    func acceptCancellation(_ packet: QwenLayerStageGenerationCancelPacket) throws {
        guard packet.content.agreementFingerprint == agreement.fingerprint else {
            cancel(); throw ProbeError("Generation cancellation belongs to another membership/request")
        }
        cancel()
    }

    /// Runtime-owned evidence, not a timer/EOF/sent-cancel substitute. A fence
    /// permits resource reclamation but never converts failure to clean finish.
    func acknowledgeRetirement(rank: Int, disposition: Retirement) throws {
        guard phase == .retiring, (0...1).contains(rank), !retiredRanks.contains(rank) else {
            cancel(); throw ProbeError("Generation retirement acknowledgement out of order")
        }
        if disposition == .fenced { isFailed = true }
        retiredRanks.insert(rank)
        if retiredRanks.count == 2 { phase = .retired }
    }

    private func acknowledge(_ rank: Int) throws {
        guard (0...1).contains(rank), acknowledgedRanks.insert(rank).inserted else {
            throw ProbeError("Generation acknowledgement rank repeated or invalid")
        }
    }
    private func operation<T>(_ body: () throws -> T) throws -> T {
        do {
            guard !isFailed, phase != .retiring, phase != .retired else { throw ProbeError("Generation control is retiring") }
            return try body()
        } catch { cancel(); throw error }
    }
}
