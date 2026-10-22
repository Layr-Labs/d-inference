import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

// `pipeline_mtp_v1` for the registered Qwen rows: the decode framing both
// ranks agree, the round wire (shared with MiMo, its own family and the
// row's own depth), the replay of a round through both ranks' unchanged
// generation control, the default depth hook, and the embedding copy's
// module (a tiny synthetic table; no artifact, collective or network).

private enum QwenPipelineFixture {
    static func configuration(_ model: QwenRegisteredDenseModel) throws -> Data {
        let libraries = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let name = model == .qwen35NineB ? "qwen35-9b" : "qwen38-27b"
        return try Data(contentsOf: libraries.appendingPathComponent(
            "darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures/registered-\(name).configuration.json"))
    }

    static func specification(_ model: QwenRegisteredDenseModel) throws -> QwenDenseRegisteredSpecification {
        try QwenResidentModelDefinition(model: model).specification
    }

    static func request(_ model: QwenRegisteredDenseModel = .qwen38TwentySevenB, promptCount: Int = 24,
                        outputCount: Int = 12, stopTokenIDs: Set<Int> = []) throws -> QwenLayerStageGenerationRequest {
        try QwenLayerStageGenerationRequest(
            profile: try QwenResidentAdapterDefinition.profile(specification: try specification(model)),
            requestID: UUID(uuidString: "3c1b8f0a-2a44-4b1e-9d1c-5e2f7a9b0c11")!,
            promptTokenIDs: (0..<promptCount).map { 1000 + $0 }, chunkSize: 16, outputCount: outputCount,
            stopTokenIDs: stopTokenIDs)
    }

    static func agreement(_ request: QwenLayerStageGenerationRequest, model: QwenRegisteredDenseModel = .qwen38TwentySevenB,
                          cut: Int = 16, framing: String?, split: Bool = false,
                          speculativeHead: QwenMTPTerms? = nil) throws -> QwenLayerStageGenerationAgreement {
        let data = try configuration(model), spec = try specification(model)
        let plan = try QwenLayerStagePlan(configuration: data, ranges: [0..<cut, cut..<spec.layers])
        return try QwenLayerStageGenerationAgreement(request: request,
            membershipEpoch: UUID(uuidString: "6f0c7a54-11d2-4c1e-9a44-0d5a6a5f0b11")!,
            source: try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: sha256(data),
                artifactAggregateSHA256: spec.artifactSHA256, storageCommitmentSHA256: String(repeating: "c", count: 64),
                planFingerprint: plan.fingerprint, producerStageFingerprint: plan.stages[0].fingerprint),
            consumerStageFingerprint: plan.stages[1].fingerprint,
            rankBuildSHA256: [String(repeating: "1", count: 64), String(repeating: "1", count: 64)],
            numericalPolicySHA256: String(repeating: "3", count: 64),
            phaseSplit: split ? try QwenPhaseSplitPlan(plan: plan, geometry: try spec.expectedGeometry(), request: request) : nil,
            speculativeHead: speculativeHead, speculativeRoundsFraming: framing)
    }

    /// Both ranks' control after the prompt frames and the first token.
    static func controlAfterPrompt(_ agreement: QwenLayerStageGenerationAgreement, firstToken: Int = 41) throws
        -> QwenLayerStageGenerationControl {
        let control = QwenLayerStageGenerationControl(agreement: agreement)
        while control.phase == .frame {
            let expected = try control.beginFrame()
            let packet = try QwenLayerStageGenerationBoundaryPacket(expected: expected,
                payloadSHA256: sha256(Data("prompt-\(expected.frame.sequence)".utf8)))
            let committed = expected.frame.tokenOffset + expected.frame.tokenCount
            try control.acknowledgeFrame(rank: 0, packet: packet, nativeCommittedTokens: committed)
            try control.acknowledgeFrame(rank: 1, packet: packet, nativeCommittedTokens: committed)
            guard control.phase == .token else { continue }
            let token = try QwenLayerStageGenerationTokenPacket(agreement: agreement, boundaryFingerprint: packet.fingerprint,
                previousTokenChainSHA256: control.tokenChainSHA256, ordinal: 0,
                committedTokens: control.committedTokens, tokenID: firstToken)
            try control.acknowledgeToken(rank: 1, packet: token); try control.acknowledgeToken(rank: 0, packet: token)
            _ = try control.takeCommittedToken()
            let decision = try control.decide(continueRequested: true)
            try control.acknowledgeDecision(rank: 0, packet: decision); try control.acknowledgeDecision(rank: 1, packet: decision)
            break
        }
        return control
    }
}

@Suite("Qwen speculative decode on a pipeline (contracts, synthetic embedding copy)")
struct QwenPipelineSpeculativeTests {
    fileprivate typealias F = QwenPipelineFixture

    @Test func theFramingIsDeclaredAndFencedFromThePhaseSplitHead() throws {
        let request = try F.request()
        let four = try QwenMTPTerms(depth: 4), two = try QwenMTPTerms(depth: 2)
        let plain = try F.agreement(request, framing: nil)
        let deep = try F.agreement(request, framing: four.pipelineDecodeFraming)
        let shallow = try F.agreement(request, framing: two.pipelineDecodeFraming)
        #expect(Set([plain.fingerprint, deep.fingerprint, shallow.fingerprint]).count == 3)
        #expect(four.pipelineDecodeFraming == "speculative_rounds_v1|depth=4|qwen_pipeline_window_target_prefix_v1")
        // Never MiMo's framing at the same depth, so neither family reads the other's session.
        #expect(try QwenMTPTerms(depth: 2).pipelineDecodeFraming != MiMoMTPTerms.standard.decodeFraming)
        let encoded = String(decoding: try canonicalJSONData(deep.descriptor), as: UTF8.self)
        #expect(encoded.contains("qwen_pipeline_window_target_prefix_v1") && !deep.descriptor.mtpEnabled)
        #expect(deep.speculativeHead == nil && deep.phaseSplit == nil)
        // Rounds frame a plain pipeline's decode only: not a phase split, and not with its head terms.
        #expect(throws: ProbeError.self) { _ = try F.agreement(request, framing: four.pipelineDecodeFraming, split: true) }
        #expect(throws: ProbeError.self) {
            _ = try F.agreement(request, framing: four.pipelineDecodeFraming, split: true, speculativeHead: four)
        }
    }

    @Test func everyRowWithAHeadRunsItOnThePipelineAtADepthItCanDraft() throws {
        for model in QwenRegisteredDenseModel.allCases {
            let row = try QwenResidentModelDefinition(model: model).supportedGenerationModes
            #expect(row.contains(.pipelineMTP) == row.contains(.phaseSplitMTP), "\(model)")
            let depth = QwenMTPTerms.standard(for: model, mode: .pipelineMTP).depth
            #expect((1...QwenMTPTerms.maximumDepth).contains(depth))
            // A phase split's default is unchanged.
            #expect(QwenMTPTerms.standard(for: model, mode: .phaseSplitMTP) == QwenMTPTerms.standard(for: model))
        }
        #expect(ClusterGenerationMode.pipelineMTP.usesSpeculativeHead && !ClusterGenerationMode.pipelineMTP.isPhaseSplit)
        #expect(ClusterGenerationMode.pipelineMTP.loadAgreementFields == ["qwen-resident-generation-mode-v1", "pipeline_mtp_v1"])
    }

    @Test func aQwenRoundIsItsOwnFamilysAndGivesBothRanksOneHistory() throws {
        let request = try F.request(outputCount: 12, stopTokenIDs: [99])
        let terms = try QwenMTPTerms(depth: 4)
        let agreement = try F.agreement(request, framing: terms.pipelineDecodeFraming)
        let producer = try F.controlAfterPrompt(agreement), consumer = try F.controlAfterPrompt(agreement)
        func digest(_ row: Int) -> String { sha256(Data("window-row-\(row)".utf8)) }

        // Four drafts: the Qwen head's own ceiling, beyond MiMo's three.
        let round = try MiMoMTPRoundPacket(agreement: agreement, terms: terms, firstOrdinal: consumer.selectedTokenCount,
            previousTokenChainSHA256: consumer.tokenChainSHA256, lastTokenID: 41, draftTokenIDs: [50, 51, 52, 53])
        #expect(round.content.schema == "qwen_pipeline_speculative_round_v1" && round.family == "qwen")
        let bytes = try round.encoded()
        let received = try MiMoMTPRoundPacket.decode(bytes, agreement: agreement, terms: terms,
            firstOrdinal: producer.selectedTokenCount, previousTokenChainSHA256: producer.tokenChainSHA256,
            lastTokenID: try #require(producer.lastTokenID))
        #expect(received.fingerprint == round.fingerprint && received.window == [41, 50, 51, 52, 53])
        // A MiMo reader refuses a Qwen round (its family and its depth), and a Qwen reader at another depth too.
        #expect(throws: ProbeError.self) {
            _ = try MiMoMTPRoundPacket.decode(bytes, agreement: agreement, terms: MiMoMTPTerms.standard,
                firstOrdinal: 1, previousTokenChainSHA256: producer.tokenChainSHA256, lastTokenID: 41)
        }
        #expect(throws: ProbeError.self) {
            _ = try MiMoMTPRoundPacket.decode(bytes, agreement: agreement, terms: try QwenMTPTerms(depth: 3),
                firstOrdinal: 1, previousTokenChainSHA256: producer.tokenChainSHA256, lastTokenID: 41)
        }
        // A MiMo round of the same drafts is another packet.
        let mimo = try MiMoMTPRoundPacket(agreement: agreement, terms: try MiMoMTPTerms(depth: 3), firstOrdinal: 1,
            previousTokenChainSHA256: consumer.tokenChainSHA256, lastTokenID: 41, draftTokenIDs: [50, 51, 52])
        #expect(mimo.content.schema == "mimo_pipeline_speculative_round_v1" && mimo.fingerprint != round.fingerprint)
        #expect(throws: ProbeError.self) {
            _ = try MiMoMTPRoundPacket.decode(try mimo.encoded(), agreement: agreement, terms: try QwenMTPTerms(depth: 3),
                firstOrdinal: 1, previousTokenChainSHA256: producer.tokenChainSHA256, lastTokenID: 41)
        }

        // Rank 1 kept three drafts and the target's token at the fourth column.
        let result = try MiMoMTPRoundResultPacket(agreement: agreement, round: round, tokenIDs: [50, 51, 52, 60],
            payloadSHA256: (0..<4).map(digest))
        #expect(result.content.schema == "qwen_pipeline_speculative_result_v1")
        let answer = try MiMoMTPRoundResultPacket.decode(try result.encoded(), agreement: agreement, round: received)
        var published: [Int] = []
        var last: QwenLayerStageGenerationDecisionPacket?
        for (index, token) in answer.content.tokenIDs.enumerated() {
            last = try QwenPhaseSplitGeneration.replay(tokenID: token, payloadSHA256: answer.content.payloadSHA256[index],
                control: producer) { published.append($0); return true }
        }
        #expect(published == [50, 51, 52, 60] && producer.selectedTokenCount == 5)
        let decision = try MiMoMTPRoundDecisionPacket(agreement: agreement, result: answer, acceptedCount: 4,
            selectedTokenCount: producer.selectedTokenCount, tokenChainSHA256: producer.tokenChainSHA256,
            decision: try #require(last).content.decision)
        #expect(decision.content.schema == "qwen_pipeline_speculative_decision_v1")
        let verdict = try MiMoMTPRoundDecisionPacket.decode(try decision.encoded(), agreement: agreement, result: result).content
        for index in 0..<verdict.acceptedCount {
            let proceed = index + 1 < verdict.acceptedCount || verdict.decision == .proceed
            _ = try QwenPhaseSplitGeneration.replay(tokenID: result.content.tokenIDs[index],
                payloadSHA256: result.content.payloadSHA256[index], control: consumer) { _ in proceed }
        }
        #expect(consumer.tokenChainSHA256 == producer.tokenChainSHA256 && consumer.committedTokens == 28)
        #expect(consumer.lastTokenID == 60 && consumer.phase == .frame)
        // Never past the output limit: with 12 outputs, a depth-4 window from ordinal 8 is refused, from 7 not.
        #expect(throws: ProbeError.self) {
            _ = try MiMoMTPRoundPacket(agreement: agreement, terms: terms, firstOrdinal: 8,
                previousTokenChainSHA256: digest(1), lastTokenID: 41, draftTokenIDs: [1, 2, 3, 4])
        }
        _ = try MiMoMTPRoundPacket(agreement: agreement, terms: terms, firstOrdinal: 7,
            previousTokenChainSHA256: digest(1), lastTokenID: 41, draftTokenIDs: [1, 2, 3, 4])
        // Five drafts exceed the agreed depth.
        #expect(throws: ProbeError.self) {
            _ = try MiMoMTPRoundPacket(agreement: agreement, terms: terms, firstOrdinal: 1,
                previousTokenChainSHA256: digest(1), lastTokenID: 41, draftTokenIDs: [1, 2, 3, 4, 5])
        }
    }

    /// A recording request runs the rounds too (pp-mtp-cache item 7 refused it):
    /// the last rank holds the head, rank 0 never does, and rounds never frame a
    /// phase split.
    @Test func aRecordingRunsTheRoundsWithTheHeadOnTheLastRankOnly() throws {
        let request = try F.request()
        let terms = try QwenMTPTerms(depth: 4)
        let rounds = try F.agreement(request, framing: terms.pipelineDecodeFraming)
        try requireQwenSpeculativeRole(agreement: rounds, rounds: terms, holdsHead: true, rank: 1)
        try requireQwenSpeculativeRole(agreement: rounds, rounds: terms, holdsHead: false, rank: 0)
        #expect(throws: ProbeError.self) { try requireQwenSpeculativeRole(agreement: rounds, rounds: terms, holdsHead: true, rank: 0) }
        #expect(throws: ProbeError.self) { try requireQwenSpeculativeRole(agreement: rounds, rounds: terms, holdsHead: false, rank: 1) }
        // Terms the agreement does not frame, or rounds without terms, are refused.
        #expect(throws: ProbeError.self) {
            try requireQwenSpeculativeRole(agreement: rounds, rounds: try QwenMTPTerms(depth: 2), holdsHead: true, rank: 1)
        }
        #expect(throws: ProbeError.self) { try requireQwenSpeculativeRole(agreement: rounds, rounds: nil, holdsHead: false, rank: 1) }
        let plain = try F.agreement(request, framing: nil)
        try requireQwenSpeculativeRole(agreement: plain, rounds: nil, holdsHead: false, rank: 1)
        #expect(throws: ProbeError.self) { try requireQwenSpeculativeRole(agreement: plain, rounds: nil, holdsHead: true, rank: 1) }
    }

    /// A recorded step is the row's digest over its native bytes and its four
    /// highest candidates, exact widenings, highest first, ties by lower token:
    /// what a qualification step carries, so the near-tie rule reads every
    /// accepted token of a speculative pipeline.
    @Test func aRecordedStepIsTheRowsDigestAndHighestCandidates() throws {
        let vocabulary = 10
        let values: [Float] = [0.5, 3.0, -1.0, 2.0, 3.0, 1.0, 0.0, 2.5, -2.0, 1.5]
        let row = MLXArray(values).reshaped([1, vocabulary]).asType(.bfloat16)
        eval(row)
        let request = try F.request()
        let frame = try request.frame(sequence: request.prefillFrameCount + 2)
        let step = try QwenRecordedStep(row, ordinal: 3, frame: frame, tokenID: 1, vocabularySize: vocabulary,
            rowDType: "bfloat16", sampled: false)
        #expect(step.topTokenIDs == [1, 4, 7, 3] && step.topLogits == [3.0, 3.0, 2.5, 2.0])
        #expect(step.maximumTieCount == 2 && step.ordinal == 3 && step.tokenID == 1)
        #expect(step.rowSHA256 == sha256(row.asData(access: .copy).data) && step.rowDType == "bfloat16")
        #expect(step.frameSequence == frame.sequence && step.committedTokens == frame.tokenOffset + frame.tokenCount)
        // The qualification step's field names, so a pair report reads it as one.
        let encoded = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(step)) as? [String: Any]
        #expect(Set(encoded?.keys.map { $0 } ?? []) == ["ordinal", "frameSequence", "committedTokens", "tokenID",
            "topTokenIDs", "topLogits", "maximumTieCount", "rowSHA256", "rowDType"])
        // A greedy token that is not its row's top candidate is refused; a sampled draw is not.
        #expect(throws: ProbeError.self) {
            _ = try QwenRecordedStep(row, ordinal: 3, frame: frame, tokenID: 7, vocabularySize: vocabulary,
                rowDType: "bfloat16", sampled: false)
        }
        _ = try QwenRecordedStep(row, ordinal: 3, frame: frame, tokenID: 7, vocabularySize: vocabulary,
            rowDType: "bfloat16", sampled: true)
        // Another dtype or width than the profile's is refused.
        #expect(throws: ProbeError.self) {
            _ = try QwenRecordedStep(row, ordinal: 3, frame: frame, tokenID: 1, vocabularySize: vocabulary,
                rowDType: "float16", sampled: false)
        }
        #expect(throws: ProbeError.self) {
            _ = try QwenRecordedStep(row, ordinal: 3, frame: frame, tokenID: 1, vocabularySize: vocabulary + 1,
                rowDType: "bfloat16", sampled: false)
        }
    }

    /// The copy's module is the producer stage's declared affine table:
    /// looking a token up gives the rows the packed table dequantizes to.
    @Test func theEmbeddingCopyIsTheDeclaredAffineTable() throws {
        let vocabulary = 8, hidden = 128
        let table = MLXRandom.normal([vocabulary, hidden], key: MLXRandom.key(3))
        let (weight, scales, biases) = MLX.quantized(table, groupSize: 64, bits: 4, mode: .affine)
        eval(weight, scales, biases!)
        let declared = BaseConfiguration.Quantization(groupSize: 64, bits: 4)
        let module = try QwenEmbeddingCopy.module(["weight": weight, "scales": scales, "biases": biases!],
            quantization: declared, hiddenSize: hidden, vocabularySize: vocabulary)
        #expect(module is QuantizedEmbedding)
        let ids = MLXArray([Int32(5), 2]).reshaped([1, 2])
        let looked = module(ids)
        let expected = dequantized(weight, scales: scales, biases: biases, groupSize: 64, bits: 4, mode: .affine)[MLXArray([Int32(5), 2])]
        #expect(allClose(looked[0], expected).item(Bool.self))
        // Another declared layout, a missing part, or another vocabulary is refused.
        #expect(throws: (any Error).self) {
            _ = try QwenEmbeddingCopy.module(["weight": weight, "scales": scales, "biases": biases!],
                quantization: BaseConfiguration.Quantization(groupSize: 32, bits: 4), hiddenSize: hidden,
                vocabularySize: vocabulary)
        }
        #expect(throws: ProbeError.self) {
            _ = try QwenEmbeddingCopy.module(["weight": weight, "scales": scales], quantization: declared,
                hiddenSize: hidden, vocabularySize: vocabulary)
        }
        #expect(throws: ProbeError.self) {
            _ = try QwenEmbeddingCopy.module(["weight": weight, "scales": scales, "biases": biases!],
                quantization: declared, hiddenSize: hidden, vocabularySize: vocabulary + 1)
        }
        // An unquantized table is its weight alone.
        let plain = try QwenEmbeddingCopy.module(["weight": table], quantization: nil, hiddenSize: hidden,
            vocabularySize: vocabulary)
        #expect(!(plain is QuantizedEmbedding) && allClose(plain(ids)[0], table[MLXArray([Int32(5), 2])]).item(Bool.self))
    }
}
