import Foundation

/// Fabricated receipts exercise rejection/order only; they are never native or
/// physical acceptance evidence. The compiled native/registered checks are separate.
private final class Fixture {
    let agreement: QwenLayerStageGenerationAgreement
    let generation: QwenLayerStageGenerationControl
    let rounds = QwenMTPAcceptedRoundControl()
    init(mtp: Bool = true, outputs: Int = 8) throws {
        let profile = try QwenLayerStageGenerationProfile(identifier: "accepted-mtp-control-fixture",
            vocabularySize: 248320, hiddenSize: 4096, activationDType: "bfloat16", maximumPromptTokens: 5,
            maximumChunkTokens: 2, maximumOutputTokens: 8, maximumContextTokens: 13)
        let request = try QwenLayerStageGenerationRequest(profile: profile,
            requestID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            promptTokenIDs: [1,2,3,4,5], chunkSize: 2, outputCount: outputs, stopTokenIDs: [])
        let source = try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: String(repeating: "a", count: 64),
            artifactAggregateSHA256: String(repeating: "b", count: 64), storageCommitmentSHA256: String(repeating: "c", count: 64),
            planFingerprint: String(repeating: "d", count: 64), producerStageFingerprint: String(repeating: "e", count: 64))
        agreement = try .init(request: request, membershipEpoch: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            source: source, consumerStageFingerprint: String(repeating: "f", count: 64),
            rankBuildSHA256: [String(repeating: "1", count: 64), String(repeating: "2", count: 64)],
            numericalPolicySHA256: String(repeating: "3", count: 64),
            speculation: mtp ? .registered9BDepth1Short : nil)
        generation = .init(agreement: agreement)
        while generation.committedTokens < request.promptCount { try consume(token: 8) }
    }
    func consume(token: Int, proceed: Bool = true) throws {
        let expected = try generation.beginFrame()
        let boundary = try QwenLayerStageGenerationBoundaryPacket(expected: expected, payloadSHA256: String(repeating: "0", count: 64))
        for rank in 0...1 {
            try generation.acknowledgeFrame(rank: rank, packet: boundary,
                nativeCommittedTokens: expected.frame.tokenOffset + expected.frame.tokenCount)
        }
        if generation.phase != .token { return }
        let packet = try QwenLayerStageGenerationTokenPacket(agreement: agreement, boundaryFingerprint: boundary.fingerprint,
            previousTokenChainSHA256: generation.tokenChainSHA256, ordinal: generation.selectedTokenCount,
            committedTokens: generation.committedTokens, tokenID: token)
        for rank in 0...1 { try generation.acknowledgeToken(rank: rank, packet: packet) }
        _ = try generation.takeCommittedToken()
        let decision = try generation.decide(continueRequested: proceed)
        for rank in 0...1 { try generation.acknowledgeDecision(rank: rank, packet: decision) }
    }
    func begin(id: UUID = UUID(), draft: Int = 9) throws -> QwenTargetVerificationRequest {
        let p = QwenResidentMTPProposal(requestID: agreement.request.requestID, roundID: id,
            agreementFingerprint: agreement.fingerprint, committedTargetInputs: generation.committedTokens,
            seedTokenID: generation.lastTokenID!, previousTokenChainSHA256: generation.tokenChainSHA256, proposedTokenID: draft)
        let request = try rounds.begin(proposal: p, generation: generation)
        for step in 0..<request.maximumSteps { try rounds.didStage(step: step) }
        return request
    }
    func join(_ receipts: [QwenTargetVerificationLocalReceipt]) throws -> QwenMTPJoinedReceipt {
        try rounds.authorizeCommit(generation: generation)
        return try rounds.joinCommit(receipts)
    }
    func receipts(_ request: QwenTargetVerificationRequest, retained: Int, final: Bool = false)
        -> [QwenTargetVerificationLocalReceipt] {
        (0...1).map { .init(verificationFingerprint: request.fingerprint, rank: $0, base: request.base,
            stagedInputs: request.maximumSteps, retainedInputs: retained, committedInputs: request.base + retained,
            pendingInputs: final ? 0 : request.maximumSteps - retained, newlyCommittedInputs: final ? 0 : 1, isFinal: final) }
    }
}

@main struct AcceptedRoundControlCheck {
    static func main() throws {
        var passed = [String]()
        func require(_ value: Bool, _ message: String) throws { if !value { throw ProbeError(message) } }
        func rejects(_ name: String, _ body: () throws -> Void) throws {
            var rejected = false; do { try body() } catch { rejected = true }
            try require(rejected, "Unexpected acceptance: " + name); passed.append(name)
        }
        let pair = try Fixture(), first = try pair.begin()
        _ = try pair.join(pair.receipts(first, retained: 1)); try pair.consume(token: first.proposal.proposedTokenID)
        _ = try pair.join(pair.receipts(first, retained: 2)); try pair.consume(token: 10)
        _ = try pair.rounds.joinReconciliation(pair.receipts(first, retained: 2, final: true))
        try pair.rounds.finish(generation: pair.generation)
        let second = try pair.begin(draft: 11)
        _ = try pair.join(pair.receipts(second, retained: 1)); try pair.consume(token: 12)
        _ = try pair.rounds.joinReconciliation(pair.receipts(second, retained: 1, final: true))
        try pair.rounds.finish(generation: pair.generation)
        try require(pair.rounds.roundCount == 2 && pair.generation.committedTokens == 8,
                    "Repeated accept then mismatch lost the exact target frontier")
        passed.append("repeated accepted-two then mismatched-one round preserves frontier")
        try rejects("round UUID reuse after a successful reconciliation") { _ = try pair.begin(id: first.proposal.roundID) }

        let stop = try Fixture(), stopped = try stop.begin()
        _ = try stop.join(stop.receipts(stopped, retained: 1)); try stop.consume(token: 9, proceed: false)
        _ = try stop.rounds.joinReconciliation(stop.receipts(stopped, retained: 1, final: true))
        try stop.rounds.finish(generation: stop.generation)
        try require(stop.generation.phase == .retiring && stop.generation.committedTokens == 6,
                    "Client stop committed the unused draft")
        passed.append("client stop after seed preserves prefix and discards pending draft")

        for field in 0..<10 {
            try rejects("both receipts identically wrong field \(field) still refuse") {
                let f = try Fixture(), request = try f.begin()
                let altered = f.receipts(request, retained: 1).map { r in
                    QwenTargetVerificationLocalReceipt(
                        verificationFingerprint: field == 0 ? String(repeating: "0", count: 64) : r.verificationFingerprint,
                        rank: field == 1 ? 0 : r.rank, base: r.base + (field == 2 ? 1 : 0),
                        stagedInputs: r.stagedInputs + (field == 3 ? 1 : 0),
                        retainedInputs: r.retainedInputs + (field == 4 ? 1 : 0),
                        committedInputs: r.committedInputs + (field == 5 ? 1 : 0),
                        pendingInputs: r.pendingInputs + (field == 6 ? 1 : 0),
                        newlyCommittedInputs: field == 7 ? 0 : r.newlyCommittedInputs,
                        isFinal: field == 8 ? true : r.isFinal)
                }
                _ = try f.join(field == 9 ? Array(altered.prefix(1)) : altered)
            }
        }
        try rejects("reconcile cannot commit an unpublished second input") {
            let f = try Fixture(), r = try f.begin(); _ = try f.join(f.receipts(r, retained: 1))
            _ = try f.rounds.joinReconciliation(f.receipts(r, retained: 2, final: true))
        }
        try rejects("next round before reconciliation") {
            let f = try Fixture(); _ = try f.begin(); _ = try f.begin()
        }
        try rejects("finalize without generation publication") {
            let f = try Fixture(), r = try f.begin(); _ = try f.join(f.receipts(r, retained: 1))
            _ = try f.rounds.joinReconciliation(f.receipts(r, retained: 1, final: true))
            try f.rounds.finish(generation: f.generation)
        }
        try rejects("cancelled generation cannot open verification") {
            let f = try Fixture(); f.generation.cancel(); _ = try f.begin()
        }
        try rejects("mismatching target token cannot authorize staged draft") {
            let f = try Fixture(), r = try f.begin(draft: 9)
            _ = try f.join(f.receipts(r, retained: 1)); try f.consume(token: 10)
            try f.rounds.authorizeCommit(generation: f.generation)
        }
        try rejects("client stop cannot authorize staged draft") {
            let f = try Fixture(), r = try f.begin(draft: 9)
            _ = try f.join(f.receipts(r, retained: 1)); try f.consume(token: 9, proceed: false)
            try f.rounds.authorizeCommit(generation: f.generation)
        }
        try rejects("receipts cannot bypass pre-commit agreement") {
            let f = try Fixture(), r = try f.begin()
            _ = try f.rounds.joinCommit(f.receipts(r, retained: 1))
        }
        let wire = QwenMTPAcceptedWire.Proposal(first.proposal, ordinal: 0)
        let encoded = try QwenMTPAcceptedWire.encode(wire)
        let decoded = try QwenMTPAcceptedWire.decode(QwenMTPAcceptedWire.Proposal.self, encoded)
        try require(try decoded.proposal(expectedOrdinal: 0) == first.proposal, "Proposal codec did not preserve exact identity")
        passed.append("proposal canonical identity roundtrip")
        try rejects("proposal round ordinal substitution") { _ = try decoded.proposal(expectedOrdinal: 1) }
        try rejects("surplus canonical field") {
            var value = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]; value["extra"] = 1
            _ = try QwenMTPAcceptedWire.decode(QwenMTPAcceptedWire.Proposal.self,
                JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
        }
        try rejects("truncated proposal") { _ = try QwenMTPAcceptedWire.decode(QwenMTPAcceptedWire.Proposal.self, Data(encoded.dropLast())) }
        try rejects("oversized frame") { _ = try QwenMTPAcceptedWire.decode(QwenMTPAcceptedWire.Proposal.self, Data(repeating: 0, count: 4097)) }
        let off = try Fixture(mtp: false)
        let offObject = try JSONSerialization.jsonObject(with: canonicalJSONData(off.agreement.descriptor)) as! [String: Any]
        try require(offObject["mtpPolicySHA256"] == nil && offObject["mtpEnabled"] as? Bool == false,
                    "Default agreement added speculative authority")
        try require(off.agreement.fingerprint != pair.agreement.fingerprint, "MTP on/off agreement did not bind policy")
        passed.append("default off encoding omits the policy and differs from explicit on")
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: ["passed": passed,
            "nativeExecution": false, "physicalCommitEvidence": false], options: [.sortedKeys]))
        FileHandle.standardOutput.write(Data([10]))
    }
}
