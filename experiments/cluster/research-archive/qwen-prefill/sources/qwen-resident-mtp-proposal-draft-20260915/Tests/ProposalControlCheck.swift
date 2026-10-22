import Foundation

private func fixtureAgreement(outputCount: Int = 4, policy: QwenResidentPrefillPolicy = .serial) throws -> QwenLayerStageGenerationAgreement {
    let profile = try QwenLayerStageGenerationProfile(identifier: "mtp-control-fixture", vocabularySize: 32,
        hiddenSize: 4, activationDType: "bfloat16", maximumPromptTokens: 5,
        maximumChunkTokens: 2, maximumOutputTokens: 4, maximumContextTokens: 9)
    let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
        promptTokenIDs: [1,2,3,4,5], chunkSize: 2, outputCount: outputCount, stopTokenIDs: [31])
    let source = try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: String(repeating:"a",count:64),
        artifactAggregateSHA256: String(repeating:"b",count:64), storageCommitmentSHA256: String(repeating:"c",count:64),
        planFingerprint: String(repeating:"d",count:64), producerStageFingerprint: String(repeating:"e",count:64))
    return try .init(request: request, membershipEpoch: UUID(), source: source,
        consumerStageFingerprint: String(repeating:"f",count:64), rankBuildSHA256: [String(repeating:"1",count:64),String(repeating:"2",count:64)],
        numericalPolicySHA256: String(repeating:"3",count:64), prefillPolicy: policy)
}

private final class PairFixture {
    let agreement: QwenLayerStageGenerationAgreement
    let generation: QwenLayerStageGenerationControl
    let mtp: QwenResidentMTPProposalControl
    var lastBoundary: QwenLayerStageGenerationBoundaryPacket?
    init() throws {
        agreement = try fixtureAgreement(); generation = .init(agreement: agreement)
        mtp = try .init(agreement: agreement)
    }
    func frame(complete: Bool = true, corruptTokens: Bool = false) throws {
        let expected = try generation.beginFrame()
        let packet = try QwenLayerStageGenerationBoundaryPacket(expected: expected, payloadSHA256: String(repeating:"0",count:64))
        let end = expected.frame.tokenOffset+expected.frame.tokenCount
        try generation.acknowledgeFrame(rank: 0, packet: packet, nativeCommittedTokens: end)
        if complete { try generation.acknowledgeFrame(rank: 1, packet: packet, nativeCommittedTokens: end) }
        var tokens = Array(agreement.request.promptTokenIDs[expected.frame.tokenOffset..<end])
        if corruptTokens { tokens[0] = 9 }
        try mtp.observe(frame: expected.frame, tokenIDs: tokens, generation: generation)
        lastBoundary = packet
    }
    func history() throws {
        while mtp.phase == .observing { try frame() }
    }
    func firstToken(_ token: Int = 8, continueRequested: Bool = true, decisionComplete: Bool = true) throws {
        let packet = try QwenLayerStageGenerationTokenPacket(agreement: agreement,
            boundaryFingerprint: lastBoundary!.fingerprint, previousTokenChainSHA256: generation.tokenChainSHA256,
            ordinal: 0, committedTokens: generation.committedTokens, tokenID: token)
        for rank in [0,1] { try generation.acknowledgeToken(rank: rank, packet: packet) }
        _ = try generation.takeCommittedToken()
        let decision = try generation.decide(continueRequested: continueRequested)
        try generation.acknowledgeDecision(rank: 0, packet: decision)
        if decisionComplete { try generation.acknowledgeDecision(rank: 1, packet: decision) }
    }
    func ready() throws { try history(); try firstToken() }
}

@main struct ProposalControlCheck {
    static func main() throws {
        var accepted = [String](), rejected = [String]()
        func require(_ value: Bool, _ message: String) throws { if !value { throw ProbeError(message) } }
        func reject(_ name: String, _ body: () throws -> Void) throws {
            var failed = false
            do { try body() } catch { failed = true }
            try require(failed, "Unexpected acceptance: "+name); rejected.append(name)
        }
        let valid = try PairFixture(); try valid.ready()
        let round = UUID()
        try valid.mtp.begin(generation: valid.generation, roundID: round)
        let proposal = try valid.mtp.proposed(9)
        try require(proposal.seedTokenID == 8 && proposal.committedTargetInputs == 5 && proposal.proposedTokenID == 9
            && proposal.previousTokenChainSHA256 == valid.generation.tokenChainSHA256 && proposal.roundID == round
            && !proposal.accepted && proposal.draftDepth == 1, "Proposal binding differs")
        try valid.mtp.discarded(); valid.mtp.retired(failed: true)
        try require(valid.mtp.phase == .retired && valid.mtp.failed, "Retirement erased cancellation")
        accepted.append("three committed prompt chunks, agreed seed, one unaccepted proposal, discard and retirement")
        try reject("single output cannot use a proposal") { _ = try QwenResidentMTPProposalControl(agreement: fixtureAgreement(outputCount: 1)) }
        try reject("lookahead not admitted in first proposal path") { _ = try QwenResidentMTPProposalControl(agreement: fixtureAgreement(policy: .oneChunkLookahead)) }
        try reject("one local frame ACK is not committed history") { try PairFixture().frame(complete: false) }
        try reject("wrong prompt tokens cannot enter history") { try PairFixture().frame(corruptTokens: true) }
        try reject("history is not enough before target selection") {
            let f = try PairFixture(); try f.history(); try f.mtp.begin(generation: f.generation, roundID: UUID())
        }
        try reject("one decision ACK is not permission to draft") {
            let f = try PairFixture(); try f.history(); try f.firstToken(decisionComplete: false)
            try f.mtp.begin(generation: f.generation, roundID: UUID())
        }
        try reject("EOS seed ends without drafting") {
            let f = try PairFixture(); try f.history(); try f.firstToken(31)
            try f.mtp.begin(generation: f.generation, roundID: UUID())
        }
        try reject("client stop ends without drafting") {
            let f = try PairFixture(); try f.history(); try f.firstToken(continueRequested: false)
            try f.mtp.begin(generation: f.generation, roundID: UUID())
        }
        try reject("proposal cannot use another request/control") {
            let f = try PairFixture(), other = try PairFixture(); try f.ready(); try other.ready()
            try f.mtp.begin(generation: other.generation, roundID: UUID())
        }
        try reject("proposal vocabulary is bounded") {
            let f = try PairFixture(); try f.ready(); try f.mtp.begin(generation: f.generation, roundID: UUID())
            _ = try f.mtp.proposed(32)
        }
        try reject("proposal cannot be produced twice") {
            let f = try PairFixture(); try f.ready(); try f.mtp.begin(generation: f.generation, roundID: UUID())
            _ = try f.mtp.proposed(9); _ = try f.mtp.proposed(10)
        }
        try reject("discarded trusted seed cannot be retried") {
            let f = try PairFixture(); try f.ready(); try f.mtp.begin(generation: f.generation, roundID: UUID())
            _ = try f.mtp.proposed(9); try f.mtp.discarded()
            try f.mtp.begin(generation: f.generation, roundID: UUID())
        }
        try reject("failed generation control cannot draft") {
            let f = try PairFixture(); try f.ready(); f.generation.cancel()
            try f.mtp.begin(generation: f.generation, roundID: UUID())
        }
        let receipt: [String: Any] = ["accepted":accepted,"rejected":rejected,
            "nativeHistoryOrProposalExecuted":false,"distributedVerificationImplemented":false]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: receipt,options:[.sortedKeys]))
        FileHandle.standardOutput.write(Data([10]))
    }
}
