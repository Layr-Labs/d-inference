import Foundation

/// What both ranks of a `pipeline_mtp_v1` session agree before either stage is
/// read: the head's fixed draft depth and the verification rule. The depth is
/// fixed for a session, so a run is repeatable; it is bound into the load
/// agreement and into every request agreement (as its decode framing).
struct MiMoMTPTerms: Equatable, Sendable, Encodable {
    /// The product drafter's own ceiling (`MiMoV26MTPAssistant.maximumDraftTokens`,
    /// one per trained head).
    static let maximumDepth = 3
    let schema = "mimo_pipeline_speculative_head_v1"
    /// Drafts per round. A round verifies the last selected token and up to
    /// this many drafts in one window through both stages and keeps 1 to
    /// depth + 1 tokens.
    let depth: Int
    /// Every emitted token is the target's own choice at its window column:
    /// the greedy argmax, or for a sampled request the product's keyed target
    /// sample at that output index (target-prefix acceptance).
    let verification = "pipeline_window_target_prefix_v1"

    init(depth: Int) throws {
        guard (1...Self.maximumDepth).contains(depth) else {
            throw ProbeError("MiMo speculative depth must be 1...\(Self.maximumDepth)")
        }
        self.depth = depth
    }

    /// The depth a session runs when its launcher declares none: the fastest
    /// measured across the cable (M5 Ultra rank 0, M3 Ultra decoding, cut 47,
    /// 4,096-token prompt, 64 outputs, one hold, 2026-10-14): depth 2 decoded
    /// 58.0 tok/s, depth 1 49.5, depth 3 36.2, the plain pipeline 35.3. A
    /// window of four rows through the routed experts costs about 1.5 times
    /// one of three on rank 0 (47 against 32 ms a round) and four times on the
    /// decoding rank, which more than eats the extra accepted draft (86 % of
    /// drafts were accepted at depth 3). The product drafter's ceiling stays 3.
    static let standard = try! MiMoMTPTerms(depth: 2)

    /// Bound into the resident load agreement after the mode, before either
    /// stage is read. The head's tensors (`MiMoMTPHeadInventory`) are bound
    /// after the artifact is verified, into the loaded-ready agreement.
    var loadAgreementFields: [String] { [schema, "depth=\(depth)", "verification=\(verification)"] }

    /// The request agreement's decode framing: both ranks frame decode as rounds.
    var decodeFraming: String { "speculative_rounds_v1|depth=\(depth)|\(verification)" }

    private enum CodingKeys: String, CodingKey { case schema, depth, verification }
}

extension MiMoMTPTerms: PipelineSpeculativeRoundTerms {
    static var roundFamily: String { "mimo" }
}

/// Rank 1 to rank 0, once per decode step: the window rank 0 is to run. The
/// first row is the last selected token at the committed frontier; the drafts
/// follow (none for a plain step). Every field but the drafts must equal rank
/// 0's own state exactly.
struct MiMoMTPRoundPacket {
    struct Content: Encodable, Equatable {
        let schema: String
        let agreementFingerprint: String
        let membershipEpoch: String
        let requestFingerprint: String
        let firstOrdinal: Int
        let previousTokenChainSHA256: String
        let committedTokens: Int
        let lastTokenID: Int
        let draftTokenIDs: [Int]
    }
    static let frameBytes = 2048
    let content: Content
    let fingerprint: String
    var window: [Int] { [content.lastTokenID] + content.draftTokenIDs }

    /// The family tag of this round (`PipelineSpeculativeRoundTerms.roundFamily`).
    var family: String { String(content.schema.prefix { $0 != "_" }) }

    init<Terms: PipelineSpeculativeRoundTerms>(agreement: QwenLayerStageGenerationAgreement, terms: Terms,
         firstOrdinal: Int, previousTokenChainSHA256: String, lastTokenID: Int, draftTokenIDs: [Int]) throws {
        let request = agreement.request
        let committed = request.promptCount + firstOrdinal - 1
        guard (1..<request.outputCount).contains(firstOrdinal), qwenStageWireIsSHA256(previousTokenChainSHA256),
              draftTokenIDs.count <= terms.depth,
              // Never past the output limit: every window row may be kept.
              firstOrdinal + draftTokenIDs.count < request.outputCount,
              committed + 1 + draftTokenIDs.count <= request.maximumTokens,
              ([lastTokenID] + draftTokenIDs).allSatisfy({ (0..<request.profile.vocabularySize).contains($0) }),
              !request.stopTokenIDs.contains(lastTokenID) else {
            throw ProbeError("Speculative round differs from the agreed depth, ordinals or vocabulary")
        }
        content = .init(schema: Terms.roundFamily + "_pipeline_speculative_round_v1",
            agreementFingerprint: agreement.fingerprint, membershipEpoch: agreement.descriptor.membershipEpoch,
            requestFingerprint: request.fingerprint, firstOrdinal: firstOrdinal,
            previousTokenChainSHA256: previousTokenChainSHA256, committedTokens: committed,
            lastTokenID: lastTokenID, draftTokenIDs: draftTokenIDs)
        fingerprint = try qwenGenerationFingerprint("mimo-speculative-round", content)
    }

    func encoded() throws -> Data {
        let data = try canonicalJSONData(content)
        guard data.count <= Self.frameBytes - QwenControlFrame.headerBytes else {
            throw ProbeError("Speculative round exceeds its fixed frame")
        }
        return data
    }

    /// Only the drafts are read from the wire; everything else is rank 0's own.
    static func decode<Terms: PipelineSpeculativeRoundTerms>(_ data: Data, agreement: QwenLayerStageGenerationAgreement,
                       terms: Terms, firstOrdinal: Int, previousTokenChainSHA256: String, lastTokenID: Int) throws -> Self {
        let object = try QwenLayerStageGenerationWireJSON.object(data, maximumBytes: frameBytes)
        guard let raw = object["draftTokenIDs"] as? [Any] else { throw ProbeError("Speculative round lists no drafts") }
        let drafts = try raw.map { value -> Int in
            guard let token = BoundedProbeInput.integer(value) else { throw ProbeError("Draft token must be an integer") }
            return token
        }
        let result = try Self(agreement: agreement, terms: terms, firstOrdinal: firstOrdinal,
            previousTokenChainSHA256: previousTokenChainSHA256, lastTokenID: lastTokenID, draftTokenIDs: drafts)
        try QwenLayerStageGenerationWireJSON.requireExact(object, result.content)
        return result
    }
}

/// Rank 1 to rank 0 after the window: the tokens it keeps (each the target's
/// own choice at its column) and each kept row's residual digest. A token
/// before the last equals the draft it accepted; rank 0 checks both against
/// its own window.
struct MiMoMTPRoundResultPacket {
    struct Content: Encodable, Equatable {
        let schema: String
        let agreementFingerprint: String
        let roundFingerprint: String
        let firstOrdinal: Int
        let tokenIDs: [Int]
        let payloadSHA256: [String]
    }
    static let frameBytes = 4096
    let content: Content
    let fingerprint: String

    init(agreement: QwenLayerStageGenerationAgreement, round: MiMoMTPRoundPacket, tokenIDs: [Int],
         payloadSHA256: [String]) throws {
        let request = agreement.request, drafts = round.content.draftTokenIDs
        guard round.content.agreementFingerprint == agreement.fingerprint,
              (1...(drafts.count + 1)).contains(tokenIDs.count), payloadSHA256.count == tokenIDs.count,
              payloadSHA256.allSatisfy(qwenStageWireIsSHA256),
              tokenIDs.allSatisfy({ (0..<request.profile.vocabularySize).contains($0) }),
              // Every kept token but the last is an accepted draft.
              Array(tokenIDs.dropLast()) == Array(drafts.prefix(tokenIDs.count - 1)),
              // A stop token ends the round; nothing may follow it.
              !tokenIDs.dropLast().contains(where: request.stopTokenIDs.contains) else {
            throw ProbeError("Speculative round result differs from its window")
        }
        content = .init(schema: round.family + "_pipeline_speculative_result_v1",
            agreementFingerprint: agreement.fingerprint, roundFingerprint: round.fingerprint,
            firstOrdinal: round.content.firstOrdinal, tokenIDs: tokenIDs, payloadSHA256: payloadSHA256)
        fingerprint = try qwenGenerationFingerprint("mimo-speculative-result", content)
    }

    func encoded() throws -> Data {
        let data = try canonicalJSONData(content)
        guard data.count <= Self.frameBytes - QwenControlFrame.headerBytes else {
            throw ProbeError("Speculative round result exceeds its fixed frame")
        }
        return data
    }

    static func decode(_ data: Data, agreement: QwenLayerStageGenerationAgreement,
                       round: MiMoMTPRoundPacket) throws -> Self {
        let object = try QwenLayerStageGenerationWireJSON.object(data, maximumBytes: frameBytes)
        guard let raw = object["tokenIDs"] as? [Any], let digests = object["payloadSHA256"] as? [String] else {
            throw ProbeError("Speculative round result lists no tokens")
        }
        let tokens = try raw.map { value -> Int in
            guard let token = BoundedProbeInput.integer(value) else { throw ProbeError("Kept token must be an integer") }
            return token
        }
        let result = try Self(agreement: agreement, round: round, tokenIDs: tokens, payloadSHA256: digests)
        try QwenLayerStageGenerationWireJSON.requireExact(object, result.content)
        return result
    }
}

/// Rank 0's answer to a round result: how many of its tokens it published and
/// the decision after the last of them. Only a stop may leave kept tokens
/// unpublished.
struct MiMoMTPRoundDecisionPacket {
    struct Content: Encodable, Equatable {
        let schema: String
        let agreementFingerprint: String
        let resultFingerprint: String
        let acceptedCount: Int
        let selectedTokenCount: Int
        let tokenChainSHA256: String
        let decision: QwenLayerStageGenerationDecision
    }
    static let frameBytes = 2048
    let content: Content
    let fingerprint: String

    init(agreement: QwenLayerStageGenerationAgreement, result: MiMoMTPRoundResultPacket, acceptedCount: Int,
         selectedTokenCount: Int, tokenChainSHA256: String, decision: QwenLayerStageGenerationDecision) throws {
        let count = result.content.tokenIDs.count
        guard result.content.agreementFingerprint == agreement.fingerprint, (1...count).contains(acceptedCount),
              selectedTokenCount == result.content.firstOrdinal + acceptedCount,
              qwenStageWireIsSHA256(tokenChainSHA256), acceptedCount == count || decision != .proceed else {
            throw ProbeError("Speculative round decision differs from its result")
        }
        content = .init(schema: String(result.content.schema.prefix { $0 != "_" }) + "_pipeline_speculative_decision_v1",
            agreementFingerprint: agreement.fingerprint, resultFingerprint: result.fingerprint,
            acceptedCount: acceptedCount, selectedTokenCount: selectedTokenCount,
            tokenChainSHA256: tokenChainSHA256, decision: decision)
        fingerprint = try qwenGenerationFingerprint("mimo-speculative-decision", content)
    }

    func encoded() throws -> Data { try canonicalJSONData(content) }

    static func decode(_ data: Data, agreement: QwenLayerStageGenerationAgreement,
                       result: MiMoMTPRoundResultPacket) throws -> Self {
        let object = try QwenLayerStageGenerationWireJSON.object(data, maximumBytes: frameBytes)
        guard let accepted = BoundedProbeInput.integer(object["acceptedCount"]),
              let selected = BoundedProbeInput.integer(object["selectedTokenCount"]),
              let chain = object["tokenChainSHA256"] as? String, let spelling = object["decision"] as? String,
              let decision = QwenLayerStageGenerationDecision(rawValue: spelling) else {
            throw ProbeError("Speculative round decision is incomplete")
        }
        let result = try Self(agreement: agreement, result: result, acceptedCount: accepted,
            selectedTokenCount: selected, tokenChainSHA256: chain, decision: decision)
        try QwenLayerStageGenerationWireJSON.requireExact(object, result.content)
        return result
    }
}

/// The exact acceptance walk, shared by rank 1 (which decides) and the tests:
/// drafts are kept while each equals the target's own token at the column
/// before it; the target's token at the first mismatch (or the bonus column)
/// follows. Never past `remaining` tokens or a stop token.
enum MiMoMTPAcceptance {
    static func kept(drafts: [Int], targets: [Int], remaining: Int, stopTokens: Set<Int>) throws
        -> (tokens: [Int], acceptedDrafts: Int) {
        guard targets.count == drafts.count + 1, remaining >= 1 else {
            throw ProbeError("A verify window has one target column more than drafts")
        }
        var accepted = 0
        while accepted < drafts.count, targets[accepted] == drafts[accepted] { accepted += 1 }
        var emitted = min(accepted + 1, remaining)
        if let stop = targets[..<emitted].firstIndex(where: stopTokens.contains) { emitted = stop + 1 }
        return (Array(targets[..<emitted]), min(accepted, emitted - 1))
    }
}
