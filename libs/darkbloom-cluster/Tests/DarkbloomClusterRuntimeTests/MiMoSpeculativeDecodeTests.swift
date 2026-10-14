import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

// `pipeline_mtp_v1` for MiMo: the verify window's roll back on both cache
// kinds (synthetic keys and values, exact), the acceptance walk, the round's
// wire contract against both ranks' unchanged generation control, the head's
// tensor inventory from the registered headers, the mode and planner charge,
// and the whole round on a tiny random MiMo split into its two stages. No
// artifact, collective or network.

private enum MiMoSpeculativeFixture {
    static func fixture(_ name: String) throws -> Data {
        let libraries = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: libraries.appendingPathComponent(
            "darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures/registered-mimo-v26-flash-mopd.\(name).json"))
    }

    static func headers() throws -> [MiMoMTPHeadInventory.Entry] {
        try JSONDecoder().decode([MiMoCanonicalTensor].self, from: fixture("tensor-inventory")).map {
            .init(name: $0.name, shape: $0.shape, dtype: $0.sourceDType, byteCount: $0.byteCount)
        }
    }

    static func request(promptCount: Int = 24, chunkSize: Int = 16, outputCount: Int = 12,
                        stopTokenIDs: Set<Int> = []) throws -> QwenLayerStageGenerationRequest {
        try QwenLayerStageGenerationRequest(profile: try MiMoRegisteredSpecification.specification(.v26FlashMOPD).profile(),
            requestID: UUID(uuidString: "0f6d7c3e-31a5-4b77-8a51-1f1e7d2c6a90")!,
            promptTokenIDs: (0..<promptCount).map { 1000 + $0 }, chunkSize: chunkSize, outputCount: outputCount,
            stopTokenIDs: stopTokenIDs)
    }

    static func agreement(_ request: QwenLayerStageGenerationRequest, terms: MiMoMTPTerms? = try! MiMoMTPTerms(depth: 3),
                          compact: Bool = false) throws -> QwenLayerStageGenerationAgreement {
        let plan = try MiMoLayerStagePlan(configuration: try fixture("configuration"), cut: 47)
        return try QwenLayerStageGenerationAgreement(request: request,
            membershipEpoch: UUID(uuidString: "6f0c7a54-11d2-4c1e-9a44-0d5a6a5f0b11")!,
            source: try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: sha256(try fixture("configuration")),
                artifactAggregateSHA256: try MiMoRegisteredSpecification.specification(.v26FlashMOPD).artifactSHA256,
                storageCommitmentSHA256: String(repeating: "c", count: 64), planFingerprint: plan.fingerprint,
                producerStageFingerprint: plan.stages[0].fingerprint),
            consumerStageFingerprint: plan.stages[1].fingerprint,
            rankBuildSHA256: [String(repeating: "1", count: 64), String(repeating: "1", count: 64)],
            numericalPolicySHA256: String(repeating: "3", count: 64), compactDecode: compact,
            speculativeRoundsFraming: terms?.decodeFraming)
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

    /// Distinct, exactly representable rows: `[1, heads, n, dim]`.
    static func rows(_ start: Int, _ count: Int, heads: Int = 2, dim: Int = 4) -> MLXArray {
        let values = (0..<(heads * count * dim)).map { Float(start * 1000 + $0) }
        return MLXArray(values, [1, heads, count, dim]).asType(.bfloat16)
    }

    static func bits(_ array: MLXArray) -> [UInt16] { array.view(dtype: .uint16).asArray(UInt16.self) }

    /// What an update returned, in position order: a full ring after a
    /// single-row update starts at its write index; anything else already is.
    static func temporal(_ returned: MLXArray, of cache: KVCache) -> MLXArray {
        guard let ring = cache as? RotatingKVCache, let index = Int(ring.metaState[4]),
              index < returned.dim(2), ring.offset > returned.dim(2) else { return returned }
        return concatenated([returned[.ellipsis, index..., 0...], returned[.ellipsis, ..<index, 0...]], axis: 2)
    }
}

@Suite("MiMo speculative decode on a pipeline (contracts, synthetic caches, tiny random model)")
struct MiMoSpeculativeDecodeTests {
    fileprivate typealias F = MiMoSpeculativeFixture

    // MARK: Roll back

    /// A cache that took a window of `n` rows and gave back `n - kept` must
    /// thereafter be the cache that took only the kept rows: every later
    /// update, of one row or of a window, returns the same keys and values.
    @Test(arguments: [(prompt: 2, window: 4, kept: 1), (prompt: 2, window: 4, kept: 3), (prompt: 9, window: 4, kept: 1),
                      (prompt: 9, window: 4, kept: 2), (prompt: 9, window: 2, kept: 1), (prompt: 30, window: 4, kept: 3)])
    func aRolledBackWindowIsTheCacheOfItsKeptRows(prompt: Int, window: Int, kept: Int) throws {
        for kind in ["rotating", "simple"] {
            func make() -> KVCache { kind == "rotating" ? RotatingKVCache(maxSize: 5) : KVCacheSimple() }
            let a = make(), b = make()
            // The same history on both: a prompt chunk, then single-row decode steps that wrap the ring.
            for cache in [a, b] {
                _ = cache.update(keys: F.rows(1, prompt), values: F.rows(2, prompt))
                for step in 0..<7 { _ = cache.update(keys: F.rows(10 + step, 1), values: F.rows(20 + step, 1)) }
            }
            // a: the whole window, then the rejected rows back out. b: only the kept rows.
            let keys = F.rows(40, window), values = F.rows(50, window)
            _ = a.update(keys: keys, values: values)
            try MiMoWindowRollback.trim([a], by: window - kept)
            let keptKeys = keys[.ellipsis, ..<kept, 0...], keptValues = values[.ellipsis, ..<kept, 0...]
            _ = b.update(keys: keptKeys, values: keptValues)
            #expect(a.offset == b.offset, "\(kind) offset")
            // Then one row, a window, and one row again: identical views every time.
            for (index, width) in [1, 3, 1, 4, 1].enumerated() {
                let k = F.rows(60 + index, width), v = F.rows(70 + index, width)
                let (ak, av) = a.update(keys: k, values: v), (bk, bv) = b.update(keys: k, values: v)
                // The same positions in the same order (the ring may hold them rotated differently).
                #expect(F.bits(F.temporal(ak, of: a)) == F.bits(F.temporal(bk, of: b))
                    && F.bits(F.temporal(av, of: a)) == F.bits(F.temporal(bv, of: b)),
                    "\(kind) prompt \(prompt) window \(window) kept \(kept) step \(index)")
                #expect(a.offset == b.offset)
                // The next window starts from a settled frontier; roll back nothing.
                try MiMoWindowRollback.trim([a], by: 0)
            }
        }
    }

    @Test func aCacheNotLeftByAWindowIsRefused() throws {
        let ring = RotatingKVCache(maxSize: 5)
        _ = ring.update(keys: F.rows(1, 3), values: F.rows(2, 3))
        for step in 0..<6 { _ = ring.update(keys: F.rows(10 + step, 1), values: F.rows(20 + step, 1)) }
        // After single-row steps the ring is not in window order: nothing is guessed.
        #expect(throws: ProbeError.self) { try MiMoWindowRollback.trim([ring], by: 1) }
        let simple = KVCacheSimple()
        _ = simple.update(keys: F.rows(1, 2), values: F.rows(2, 2))
        #expect(throws: ProbeError.self) { try MiMoWindowRollback.trim([simple], by: 3) }
        #expect(throws: ProbeError.self) { try MiMoWindowRollback.trim([simple], by: -1) }
        // A refusal changes no cache.
        let window = RotatingKVCache(maxSize: 5), other = RotatingKVCache(maxSize: 5)
        _ = window.update(keys: F.rows(1, 4), values: F.rows(2, 4))
        _ = other.update(keys: F.rows(1, 3), values: F.rows(2, 3))
        for step in 0..<6 { _ = other.update(keys: F.rows(10 + step, 1), values: F.rows(20 + step, 1)) }
        let before = window.metaState
        #expect(throws: ProbeError.self) { try MiMoWindowRollback.trim([window, other], by: 1) }
        #expect(window.metaState == before)
    }

    // MARK: Acceptance

    @Test func onlyTheTargetsOwnTokensAreKept() throws {
        func kept(_ drafts: [Int], _ targets: [Int], remaining: Int = 10, stops: Set<Int> = []) throws -> [Int] {
            try MiMoMTPAcceptance.kept(drafts: drafts, targets: targets, remaining: remaining, stopTokens: stops).tokens
        }
        #expect(try kept([5, 6, 7], [5, 6, 7, 8]) == [5, 6, 7, 8])                 // every draft and the bonus
        #expect(try kept([5, 6, 7], [5, 9, 7, 8]) == [5, 9])                        // the target's token at the first miss
        #expect(try kept([5, 6, 7], [4, 6, 7, 8]) == [4])                           // a plain step's worth
        #expect(try kept([], [4]) == [4])
        #expect(try kept([5, 6, 7], [5, 6, 7, 8], remaining: 2) == [5, 6])          // never past the output limit
        #expect(try kept([5, 6, 7], [5, 6, 7, 8], stops: [6]) == [5, 6])            // nothing after a stop token
        #expect(try MiMoMTPAcceptance.kept(drafts: [5, 6, 7], targets: [5, 6, 9, 8], remaining: 10, stopTokens: []).acceptedDrafts == 2)
        #expect(throws: ProbeError.self) { _ = try kept([5, 6], [5, 6]) }
        #expect(throws: ProbeError.self) { _ = try kept([5], [5, 6], remaining: 0) }
    }

    // MARK: Wire and control

    @Test func theRoundsFramingIsBoundIntoTheAgreement() throws {
        let request = try F.request()
        let plain = try F.agreement(request, terms: nil), three = try F.agreement(request)
        let two = try F.agreement(request, terms: try MiMoMTPTerms(depth: 2))
        #expect(Set([plain.fingerprint, three.fingerprint, two.fingerprint]).count == 3)
        #expect(!String(decoding: try canonicalJSONData(plain.descriptor), as: UTF8.self).contains("decodeFraming"))
        #expect(String(decoding: try canonicalJSONData(three.descriptor), as: UTF8.self).contains("speculative_rounds_v1|depth=3"))
        // Rounds frame a plain pipeline's decode only.
        #expect(throws: ProbeError.self) { _ = try F.agreement(request, compact: true) }
        #expect(throws: ProbeError.self) { _ = try MiMoMTPTerms(depth: 4) }
        #expect(throws: ProbeError.self) { _ = try MiMoMTPTerms(depth: 0) }
        #expect(MiMoMTPTerms.standard.depth == 2 && MiMoMTPTerms.maximumDepth == 3)
    }

    @Test func aRoundGivesBothRanksOneHistory() throws {
        let request = try F.request(outputCount: 12, stopTokenIDs: [99])
        let terms = try MiMoMTPTerms(depth: 3), agreement = try F.agreement(request, terms: terms)
        let producer = try F.controlAfterPrompt(agreement), consumer = try F.controlAfterPrompt(agreement)
        #expect(producer.selectedTokenCount == 1 && producer.lastTokenID == 41 && producer.committedTokens == 24)
        func digest(_ row: Int) -> String { sha256(Data("window-row-\(row)".utf8)) }

        // Rank 1 drafts three tokens after 41; rank 0 reads the window against its own state.
        let round = try MiMoMTPRoundPacket(agreement: agreement, terms: terms, firstOrdinal: consumer.selectedTokenCount,
            previousTokenChainSHA256: consumer.tokenChainSHA256, lastTokenID: 41, draftTokenIDs: [50, 51, 52])
        let frame = try QwenControlFrame.encode(try round.encoded(), frameBytes: MiMoMTPRoundPacket.frameBytes)
        let received = try MiMoMTPRoundPacket.decode(try QwenControlFrame.decode(frame, frameBytes: MiMoMTPRoundPacket.frameBytes),
            agreement: agreement, terms: terms, firstOrdinal: producer.selectedTokenCount,
            previousTokenChainSHA256: producer.tokenChainSHA256, lastTokenID: try #require(producer.lastTokenID))
        #expect(received.fingerprint == round.fingerprint && received.window == [41, 50, 51, 52])
        #expect(received.content.committedTokens == producer.committedTokens)
        // A window for another ordinal, history or last token is not this rank's next round.
        let bytes = try round.encoded()
        #expect(throws: ProbeError.self) { _ = try MiMoMTPRoundPacket.decode(bytes, agreement: agreement, terms: terms, firstOrdinal: 2, previousTokenChainSHA256: producer.tokenChainSHA256, lastTokenID: 41) }
        #expect(throws: ProbeError.self) { _ = try MiMoMTPRoundPacket.decode(bytes, agreement: agreement, terms: terms, firstOrdinal: 1, previousTokenChainSHA256: digest(0), lastTokenID: 41) }
        #expect(throws: ProbeError.self) { _ = try MiMoMTPRoundPacket.decode(bytes, agreement: agreement, terms: terms, firstOrdinal: 1, previousTokenChainSHA256: producer.tokenChainSHA256, lastTokenID: 42) }
        #expect(throws: ProbeError.self) { _ = try MiMoMTPRoundPacket.decode(bytes, agreement: agreement, terms: try MiMoMTPTerms(depth: 2), firstOrdinal: 1, previousTokenChainSHA256: producer.tokenChainSHA256, lastTokenID: 41) }

        // Rank 1 kept the first two drafts and the target's token at the third column.
        let result = try MiMoMTPRoundResultPacket(agreement: agreement, round: round, tokenIDs: [50, 51, 60],
            payloadSHA256: (0..<3).map(digest))
        let answer = try MiMoMTPRoundResultPacket.decode(try result.encoded(), agreement: agreement, round: received)
        #expect(answer.fingerprint == result.fingerprint)
        // A kept token before the last that is not the accepted draft, or a token after a stop, is refused.
        #expect(throws: ProbeError.self) { _ = try MiMoMTPRoundResultPacket(agreement: agreement, round: round, tokenIDs: [50, 59, 60], payloadSHA256: (0..<3).map(digest)) }
        #expect(throws: ProbeError.self) { _ = try MiMoMTPRoundResultPacket(agreement: agreement, round: round, tokenIDs: [50, 51, 52, 53, 54], payloadSHA256: (0..<5).map(digest)) }
        #expect(throws: ProbeError.self) { _ = try MiMoMTPRoundResultPacket(agreement: agreement, round: round, tokenIDs: [], payloadSHA256: []) }

        // Rank 0 publishes all three and answers; rank 1 replays the published ones.
        var published: [Int] = []
        var last: QwenLayerStageGenerationDecisionPacket?
        for (index, token) in answer.content.tokenIDs.enumerated() {
            last = try QwenPhaseSplitGeneration.replay(tokenID: token, payloadSHA256: answer.content.payloadSHA256[index],
                control: producer) { published.append($0); return true }
        }
        #expect(published == [50, 51, 60] && producer.phase == .frame && producer.selectedTokenCount == 4)
        let decision = try MiMoMTPRoundDecisionPacket(agreement: agreement, result: answer, acceptedCount: 3,
            selectedTokenCount: producer.selectedTokenCount, tokenChainSHA256: producer.tokenChainSHA256,
            decision: try #require(last).content.decision)
        let verdict = try MiMoMTPRoundDecisionPacket.decode(try decision.encoded(), agreement: agreement, result: result).content
        for index in 0..<verdict.acceptedCount {
            let proceed = index + 1 < verdict.acceptedCount || verdict.decision == .proceed
            _ = try QwenPhaseSplitGeneration.replay(tokenID: result.content.tokenIDs[index],
                payloadSHA256: result.content.payloadSHA256[index], control: consumer) { _ in proceed }
        }
        #expect(consumer.tokenChainSHA256 == producer.tokenChainSHA256 && consumer.tokenChainSHA256 == verdict.tokenChainSHA256)
        #expect(consumer.committedTokens == 27 && consumer.completedFrames == producer.completedFrames)
        #expect(consumer.lastTokenID == 60 && consumer.phase == .frame)
        // Only a stop may leave kept tokens unpublished.
        #expect(throws: ProbeError.self) {
            _ = try MiMoMTPRoundDecisionPacket(agreement: agreement, result: answer, acceptedCount: 2,
                selectedTokenCount: 3, tokenChainSHA256: producer.tokenChainSHA256, decision: .proceed)
        }

        // The window never reaches past the output limit: with 12 outputs and 4 selected, at most
        // ordinals 4...11 remain, so a depth-3 window from ordinal 9 is refused and one from 8 is not.
        #expect(throws: ProbeError.self) {
            _ = try MiMoMTPRoundPacket(agreement: agreement, terms: terms, firstOrdinal: 9,
                previousTokenChainSHA256: digest(1), lastTokenID: 41, draftTokenIDs: [1, 2, 3])
        }
        _ = try MiMoMTPRoundPacket(agreement: agreement, terms: terms, firstOrdinal: 8,
            previousTokenChainSHA256: digest(1), lastTokenID: 41, draftTokenIDs: [1, 2, 3])
        #expect(throws: ProbeError.self) {
            _ = try MiMoMTPRoundPacket(agreement: agreement, terms: terms, firstOrdinal: 4,
                previousTokenChainSHA256: digest(1), lastTokenID: 99, draftTokenIDs: [1])
        }
        #expect(throws: ProbeError.self) {
            _ = try MiMoMTPRoundPacket(agreement: agreement, terms: terms, firstOrdinal: 4,
                previousTokenChainSHA256: digest(1), lastTokenID: 41, draftTokenIDs: [152_576])
        }
    }

    // MARK: Head, mode and planner

    @Test func theHeadIsTheArtifactsThreeTrainedHeadsAndTheEmbedding() throws {
        let headers = try F.headers(), configuration = try F.fixture("configuration")
        let inventory = try MiMoMTPHeadInventory(configuration: configuration, headers: headers)
        #expect(inventory.head.count == 42 && inventory.embedding.count == 3)
        #expect(inventory.head.allSatisfy { $0.name.hasPrefix("language_model.model.mtp.layers.") && $0.dtype == "BF16" })
        #expect(inventory.embedding.map(\.name) == ["weight", "scales", "biases"].map { "language_model.model.embed_tokens." + $0 })
        // 1.84 GiB of heads beside the 0.62 GiB table: what the decoding rank adds.
        #expect((1_900_000_000...2_100_000_000).contains(inventory.head.reduce(0) { $0 + $1.byteCount }))
        #expect(inventory.embedding.reduce(0) { $0 + $1.byteCount } == 664_010_752)
        // Order-free, and any change of one tensor is another head.
        #expect(try MiMoMTPHeadInventory(configuration: configuration, headers: headers.reversed()).sha256 == inventory.sha256)
        var missing = headers
        missing.removeAll { $0.name == "language_model.model.mtp.layers.2.eh_proj.weight" }
        #expect(throws: ProbeError.self) { _ = try MiMoMTPHeadInventory(configuration: configuration, headers: missing) }
        var packed = headers
        let index = try #require(packed.firstIndex { $0.name == "language_model.model.mtp.layers.0.eh_proj.weight" })
        packed[index] = .init(name: packed[index].name, shape: packed[index].shape, dtype: "U32", byteCount: packed[index].byteCount)
        #expect(throws: ProbeError.self) { _ = try MiMoMTPHeadInventory(configuration: configuration, headers: packed) }
        var noHeads = try #require(JSONSerialization.jsonObject(with: configuration) as? [String: Any])
        noHeads["num_nextn_predict_layers"] = 0
        #expect(throws: ProbeError.self) {
            _ = try MiMoMTPHeadInventory(configuration: try JSONSerialization.data(withJSONObject: noHeads), headers: headers)
        }
    }

    @Test func theModeIsTheRowsAndTheCapabilityFollowsIt() throws {
        let spec = try MiMoRegisteredSpecification.specification(.v26FlashMOPD)
        #expect(spec.supportedGenerationModes == [.pipeline, .pipelineCompactDecode, .phaseSplit, .pipelineMTP])
        #expect(ClusterGenerationMode.pipelineMTP.usesSpeculativeHead && !ClusterGenerationMode.pipelineMTP.isPhaseSplit)
        #expect(ClusterGenerationMode(rawValue: "pipeline_mtp_v1") == .pipelineMTP)
        let capability = try MiMoResidentCapabilityMetadata.describe(configuration: try F.fixture("configuration"),
            manifest: try F.fixture("manifest"), runtimeBinarySHA256: String(repeating: "a", count: 64))
        #expect(capability.speculation == ClusterRuntimeCapability.decodingRankSpeculation)
        #expect(capability.supportedGenerationModes.contains(.pipelineMTP))
    }

    // MARK: The whole round on a tiny model

    /// Greedy decode through the two stages, plain (one row per step) and as
    /// speculative rounds (the window through both stages, the acceptance
    /// walk, both stages rolled back to the kept rows). Drafts are chosen to
    /// be all right, all wrong and partly right; every round's kept tokens are
    /// the target's own, so the two token streams agree.
    @Test func speculativeRoundsKeepThePlainGreedyStream() throws {
        typealias P = MiMoStagePipelineEquivalenceTests
        let data = P.configuration(dtype: "bfloat16")
        let whole = try P.whole(data, dtype: .bfloat16)
        let plan = try MiMoLayerStagePlan(configuration: data, cut: 2)
        let stages = try P.stages(plan, from: whole, dtype: .bfloat16)
        let prompt = [5, 17, 3, 44, 96, 8, 21, 60, 2, 33, 71]
        let outputs = 14
        let plain = try P.runStaged(stages, prompt: prompt, chunk: 4, outputs: outputs)
            .map { Int(argMax($0, axis: -1).item(UInt32.self)) }

        let caches = stages.map { $0.newCache() }
        let last = stages[0].configuration.numHiddenLayers - 1
        func forward(_ tokens: [Int]) throws -> MLXArray {
            let out = try stages[0].forward(inputIDs: MLXArray(tokens.map(Int32.init)).reshaped([1, tokens.count]),
                                            cache: caches[0], captureLayers: [last])
            let residual = try #require(out.layerFeatures[last])
            eval([residual] + caches[0].flatMap { $0.innerState() })
            let received = MLXArray(residual.asData().data, residual.shape, dtype: residual.dtype)
            let logits = try stages[1].forward(embeddings: received, cache: caches[1], logitsStart: 0).logits
            eval([logits] + caches[1].flatMap { $0.innerState() })
            return logits
        }
        var offset = 0, logits = MLXArray(0)
        while offset < prompt.count {
            let part = Array(prompt[offset..<min(prompt.count, offset + 4)])
            logits = try forward(part); offset += part.count
        }
        var stream = [Int(argMax(logits[0..., -1, 0...], axis: -1).item(UInt32.self))]
        var round = 0
        while stream.count < outputs {
            let remaining = outputs - stream.count
            let depth = min(3, remaining - 1)
            // Round 0: all drafts right; round 1: all wrong; then alternately one right.
            let truth = Array(plain[stream.count..<min(plain.count, stream.count + depth)])
            let drafts: [Int] = truth.enumerated().map { index, token in
                switch round % 3 {
                case 0: token
                case 1: (token + 1) % P.vocabulary
                default: index == 0 ? token : (token + 7) % P.vocabulary
                }
            }
            let window = [stream[stream.count - 1]] + drafts
            let rows = try forward(window)
            let targets = (0..<window.count).map { Int(argMax(rows[0..., $0, 0...], axis: -1).item(UInt32.self)) }
            let kept = try MiMoMTPAcceptance.kept(drafts: drafts, targets: targets, remaining: remaining, stopTokens: [])
            for cache in caches { try MiMoWindowRollback.trim(cache, by: window.count - kept.tokens.count) }
            #expect(caches.allSatisfy { $0.allSatisfy { $0.offset == prompt.count + stream.count - 1 + kept.tokens.count } })
            stream += kept.tokens
            round += 1
        }
        #expect(stream == plain, "rounds \(round)")
    }
}
