import Foundation

/// Exercises the actual value-only generation and proposal controls. All ACKs
/// are fabricated; this does not establish native commit or physical cleanup.
private final class ProbePairFixture {
    let agreement: QwenLayerStageGenerationAgreement
    let generation: QwenLayerStageGenerationControl
    let mtp: QwenResidentMTPProposalControl
    private var boundary: QwenLayerStageGenerationBoundaryPacket?

    init() throws {
        let profile = try QwenLayerStageGenerationProfile(identifier: "registered-probe-control-fixture",
            vocabularySize: 248320, hiddenSize: 4096, activationDType: "bfloat16",
            maximumPromptTokens: 32, maximumChunkTokens: 16, maximumOutputTokens: 2, maximumContextTokens: 34)
        let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
            promptTokenIDs: Array(1...32), chunkSize: 16, outputCount: 2, stopTokenIDs: [])
        let source = try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: String(repeating: "a", count: 64),
            artifactAggregateSHA256: String(repeating: "b", count: 64), storageCommitmentSHA256: String(repeating: "c", count: 64),
            planFingerprint: String(repeating: "d", count: 64), producerStageFingerprint: String(repeating: "e", count: 64))
        agreement = try .init(request: request, membershipEpoch: UUID(), source: source,
            consumerStageFingerprint: String(repeating: "f", count: 64),
            rankBuildSHA256: [String(repeating: "1", count: 64), String(repeating: "2", count: 64)],
            numericalPolicySHA256: String(repeating: "3", count: 64))
        generation = .init(agreement: agreement); mtp = try .init(agreement: agreement)
    }

    @discardableResult func frame(secondACK: Bool = true) throws -> QwenLayerStageGenerationBoundaryExpectation {
        let expected = try generation.beginFrame()
        let packet = try QwenLayerStageGenerationBoundaryPacket(expected: expected,
            payloadSHA256: String(repeating: "0", count: 64))
        let end = expected.frame.tokenOffset + expected.frame.tokenCount
        try generation.acknowledgeFrame(rank: 0, packet: packet, nativeCommittedTokens: end)
        if secondACK { try generation.acknowledgeFrame(rank: 1, packet: packet, nativeCommittedTokens: end) }
        if expected.frame.phase == .prefill {
            try mtp.observe(frame: expected.frame,
                tokenIDs: Array(agreement.request.promptTokenIDs[expected.frame.tokenOffset..<end]), generation: generation)
        }
        boundary = packet
        return expected
    }

    func token(_ token: Int, continueRequested: Bool = true, secondDecisionACK: Bool = true) throws {
        let packet = try QwenLayerStageGenerationTokenPacket(agreement: agreement,
            boundaryFingerprint: boundary!.fingerprint, previousTokenChainSHA256: generation.tokenChainSHA256,
            ordinal: generation.selectedTokenCount, committedTokens: generation.committedTokens, tokenID: token)
        for rank in [0, 1] { try generation.acknowledgeToken(rank: rank, packet: packet) }
        _ = try generation.takeCommittedToken()
        let decision = try generation.decide(continueRequested: continueRequested)
        try generation.acknowledgeDecision(rank: 0, packet: decision)
        if secondDecisionACK { try generation.acknowledgeDecision(rank: 1, packet: decision) }
    }

    func prompt() throws { try frame(); try frame() }
    func propose(_ token: Int = 9) throws -> QwenResidentMTPProposal {
        try mtp.begin(generation: generation, roundID: UUID())
        return try mtp.proposed(token)
    }
}

@main struct ProbeControlCheck {
    static func main() throws {
        var accepted = [String](), rejected = [String]()
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw ProbeError(message) }
        }
        func reject(_ name: String, _ body: () throws -> Void) throws {
            var refused = false
            do { try body() } catch { refused = true }
            try require(refused, "Unexpected acceptance: \(name)"); rejected.append(name)
        }
        let f = try ProbePairFixture()
        try f.prompt(); try f.token(8)
        let initialChain = f.generation.tokenChainSHA256
        let proposal = try f.propose(9)
        try require(f.generation.committedTokens == 32 && f.generation.selectedTokenCount == 1
            && f.generation.lastTokenID == 8 && f.generation.tokenChainSHA256 == initialChain,
            "Unaccepted proposal changed the target frontier, selection, or chain")
        let decode = try f.frame()
        let seedExpected = try QwenLayerStageGenerationBoundaryExpectation(agreement: f.agreement,
            frame: decode.frame, tokenIDs: [8], previousTokenChainSHA256: initialChain)
        try require(decode == seedExpected && decode.frame.phase == .decode
            && decode.frame.tokenOffset == 32 && decode.frame.tokenCount == 1,
            "Ordinary decode did not use the agreed seed")
        try f.token(10)
        try require(!proposal.accepted && proposal.proposedTokenID != f.generation.lastTokenID
            && f.generation.committedTokens == 33 && f.generation.completedFrames == 3
            && f.generation.selectedTokenCount == 2 && f.generation.finishReason == .length,
            "Two-target-token probe silently accepted the mismatched draft")
        try f.generation.acknowledgeRetirement(rank: 0, disposition: .retired)
        try require(!f.generation.isRetired, "One retirement ACK released the pair")
        try f.generation.acknowledgeRetirement(rank: 1, disposition: .retired)
        try require(f.generation.isRetired && !f.generation.isFailed, "Bilateral clean retirement missing")
        accepted.append("two prompt frames, unchanged target after draft, ordinary seed decode, two targets and bilateral retirement")

        try reject("one frame ACK cannot enter assistant history") { try ProbePairFixture().frame(secondACK: false) }
        try reject("one continue ACK cannot authorize a proposal") {
            let x = try ProbePairFixture(); try x.prompt(); try x.token(8, secondDecisionACK: false); _ = try x.propose()
        }
        try reject("client stop cannot authorize proposal or seed decode") {
            let x = try ProbePairFixture(); try x.prompt(); try x.token(8, continueRequested: false); _ = try x.propose()
        }
        try reject("proposal cannot publish itself as target token two") {
            let x = try ProbePairFixture(); try x.prompt(); try x.token(8); _ = try x.propose(); try x.token(9)
        }
        try reject("only one target decode frame is admitted") {
            let x = try ProbePairFixture(); try x.prompt(); try x.token(8); _ = try x.propose()
            try x.frame(); try x.token(10); try x.frame()
        }
        let cancelled = try ProbePairFixture()
        try cancelled.prompt(); try cancelled.token(8); _ = try cancelled.propose(); cancelled.generation.cancel()
        for rank in [0, 1] { try cancelled.generation.acknowledgeRetirement(rank: rank, disposition: .fenced) }
        try require(cancelled.generation.isRetired && cancelled.generation.isFailed
            && cancelled.generation.finishReason == nil, "Cancellation/fence manufactured a clean completion")
        accepted.append("fencing reclaims failed control without a clean finish")
        let cleanupCases = try ProbeCleanupCheck.run()
        let result: [String: Any] = ["accepted": accepted, "rejected": rejected, "actualCleanupMethodCases": cleanupCases,
            "nativeForwardOrHistoryExecuted": false, "physicalAcknowledgementsObserved": false]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
        FileHandle.standardOutput.write(Data([10]))
    }
}
