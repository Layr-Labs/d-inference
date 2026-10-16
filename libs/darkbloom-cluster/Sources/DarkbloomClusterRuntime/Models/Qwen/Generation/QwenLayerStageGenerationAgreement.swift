import Foundation

/// Bound metadata, not physical peer attestation or actual resource admission.
/// The owner supplies identities from both loaded receipts before any request.
struct QwenLayerStageGenerationAgreement {
    struct Descriptor: Encodable {
        let schema = "qwen_stage_generation_agreement_v1"
        let rankCount = 2
        let membershipEpoch: String
        let requestID: String
        let requestFingerprint: String
        let profileFingerprint: String
        let sourceConfigurationSHA256: String
        let artifactAggregateSHA256: String
        let storageCommitmentSHA256: String
        let planFingerprint: String
        let stageFingerprints: [String]
        let rankBuildSHA256: [String]
        let numericalPolicySHA256: String
        let prefillSchedulingPolicy: String?
        /// True only for a phase-split request whose decoding rank runs the
        /// model's speculative head; false keeps every earlier agreement's bytes.
        let mtpEnabled: Bool
        /// Nil is omitted, so a pipeline agreement keeps its existing bytes.
        let phaseSplit: QwenPhaseSplitTerms?
        /// Nil is omitted. The head's fixed draft depth and verification rule.
        let speculativeHead: QwenMTPTerms?
        /// Nil is omitted. Both ranks must frame decode steps the same way.
        let decodeFraming: String?
    }
    private(set) var request: QwenLayerStageGenerationRequest
    let descriptor: Descriptor
    let fingerprint: String
    let initialTokenChainSHA256: String
    let prefillPolicy: QwenResidentPrefillPolicy
    /// Present only for a declared phase-split request.
    let phaseSplit: QwenPhaseSplitPlan?
    /// Present only for a phase-split request whose decoding rank drafts and
    /// verifies with the model's speculative head (`phase_split_mtp_v1`).
    let speculativeHead: QwenMTPTerms?
    /// Decode steps use one fixed frame per message and no separate ready,
    /// consumed or token acknowledgements.
    let compactDecode: Bool
    static let compactDecodeFraming = "combined_frames_v1"
    /// Decode runs as speculative rounds through both stages of a pipeline
    /// (`pipeline_mtp_v1`): the framing names the round terms both ranks hold.
    /// Nil for every other request, whose bytes it leaves unchanged.
    let speculativeRoundsFraming: String?

    init(request: QwenLayerStageGenerationRequest, membershipEpoch: UUID,
         source: QwenLayerStageWireSourceIdentity, consumerStageFingerprint: String,
         rankBuildSHA256: [String], numericalPolicySHA256: String,
         prefillPolicy: QwenResidentPrefillPolicy = .serial,
         phaseSplit: QwenPhaseSplitPlan? = nil, compactDecode: Bool = false,
         speculativeHead: QwenMTPTerms? = nil, speculativeRoundsFraming: String? = nil) throws {
        guard rankBuildSHA256.count == 2,
              (rankBuildSHA256 + [consumerStageFingerprint, numericalPolicySHA256]).allSatisfy(qwenStageWireIsSHA256),
              consumerStageFingerprint != source.producerStageFingerprint else {
            throw ProbeError("Generation agreement requires two explicit stage/build identities")
        }
        if let phaseSplit {
            guard phaseSplit.terms.handoffCommittedTokens == request.promptCount else {
                throw ProbeError("Phase-split terms were derived for a different request")
            }
        }
        // Only a phase split's decoding rank holds every layer, so only it can serve a request alone.
        guard !request.decodingRankAlone || phaseSplit != nil else {
            throw ProbeError("A request routed to the decoding rank alone needs a phase split: no rank holds every layer")
        }
        guard speculativeHead == nil || (phaseSplit != nil && !compactDecode) else {
            throw ProbeError("A speculative head runs only on the decoding rank of a phase-split request")
        }
        guard speculativeRoundsFraming.map({ !$0.isEmpty && $0.utf8.count <= 256 && phaseSplit == nil && !compactDecode
                && speculativeHead == nil }) ?? true else {
            throw ProbeError("Speculative rounds frame the decode of a plain pipeline request only")
        }
        self.request = request
        self.prefillPolicy = prefillPolicy
        self.phaseSplit = phaseSplit
        self.compactDecode = compactDecode
        self.speculativeHead = speculativeHead
        self.speculativeRoundsFraming = speculativeRoundsFraming
        descriptor = .init(membershipEpoch: membershipEpoch.uuidString.lowercased(),
            requestID: request.requestID.uuidString.lowercased(), requestFingerprint: request.fingerprint,
            profileFingerprint: request.profile.fingerprint,
            sourceConfigurationSHA256: source.sourceConfigurationSHA256,
            artifactAggregateSHA256: source.artifactAggregateSHA256,
            storageCommitmentSHA256: source.storageCommitmentSHA256, planFingerprint: source.planFingerprint,
            stageFingerprints: [source.producerStageFingerprint, consumerStageFingerprint],
            rankBuildSHA256: rankBuildSHA256, numericalPolicySHA256: numericalPolicySHA256,
            prefillSchedulingPolicy: prefillPolicy == .serial ? nil : prefillPolicy.rawValue,
            mtpEnabled: speculativeHead != nil, phaseSplit: phaseSplit?.terms,
            speculativeHead: speculativeHead,
            decodeFraming: compactDecode ? Self.compactDecodeFraming : speculativeRoundsFraming)
        fingerprint = try qwenGenerationFingerprint("agreement", descriptor)
        initialTokenChainSHA256 = sha256(Data(("qwen-generation-history-v1|" + fingerprint + "|"
            + qwenGenerationTokenHash(request.promptTokenIDs)).utf8))
    }
}

extension QwenLayerStageGenerationAgreement {
    /// The same agreement after both ranks agreed a prefix plan for its
    /// request. The descriptor and fingerprint are unchanged: the plan only
    /// moves where prefill frames start and end, and every frame packet
    /// carries its offsets, which both ranks check against this request.
    func planned(_ planned: QwenLayerStageGenerationRequest) throws -> QwenLayerStageGenerationAgreement {
        guard planned.fingerprint == request.fingerprint, planned.promptTokenIDs == request.promptTokenIDs else {
            throw ProbeError("A prefix plan belongs to a different request")
        }
        var copy = self
        copy.request = planned
        return copy
    }
}

func qwenGenerationFingerprint<T: Encodable>(_ domain: String, _ value: T) throws -> String {
    sha256(Data(("qwen-stage-generation-v1|" + domain + "|").utf8) + (try canonicalJSONData(value)))
}

enum QwenLayerStageGenerationWireJSON {
    static func object(_ data: Data, maximumBytes: Int = 16_384) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= maximumBytes else { throw ProbeError("Generation packet byte bound") }
        try validateWorkerJSON(data)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProbeError("Generation packet must be an object")
        }
        return value
    }
    static func requireExact<T: Encodable>(_ actual: [String: Any], _ expected: T) throws {
        let normalized = try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys, .withoutEscapingSlashes])
        let expectedObject = try JSONSerialization.jsonObject(with: canonicalJSONData(expected))
        guard normalized == (try JSONSerialization.data(withJSONObject: expectedObject, options: [.sortedKeys, .withoutEscapingSlashes])) else {
            throw ProbeError("Generation wire fields differ from exact local expectation")
        }
    }
}
