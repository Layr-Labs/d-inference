import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM
import Testing
@_spi(Benchmark) @testable import DarkbloomClusterRuntime

@Suite("GLM regular pipeline over actual two-rank local sockets", .serialized)
struct GLM5NextPipelineGenerationTests {
    private enum Failure: Error { case cancelled, tokenACK, fence, wrongRank, retirement }

    private struct Fixture {
        let artifact: GLM5NextStageSessionTests.Artifact
        let contract: GLM5NextStageContract
        let first: GLM5NextStageBinding
        let last: GLM5NextStageBinding
        let profile: QwenLayerStageGenerationProfile

        init() throws {
            artifact = try .init()
            let loader = try artifact.loader(), c = loader.configuration.textConfig
            contract = try GLM5NextStageSessionTests.Fixture.contract(loader: loader)
            first = try contract.loadStage(using: loader, stageIndex: 0)
            last = try contract.loadStage(using: artifact.loader(), stageIndex: 1)
            profile = try .init(identifier: "glm-pipeline-fixture", vocabularySize: c.vocabularySize,
                hiddenSize: c.hiddenSize, activationDType: c.dtype, maximumPromptTokens: 128,
                maximumChunkTokens: 16, maximumOutputTokens: 8, maximumContextTokens: 256,
                residualStreams: 4)
        }

        func request(chunk: Int = 2, outputs: Int = 3, stops: Set<Int> = [],
                     sampling: ClusterWorkerSampling? = nil) throws -> QwenLayerStageGenerationRequest {
            try .init(profile: profile, requestID: UUID(), promptTokenIDs: [4, 5, 6, 7, 8],
                chunkSize: chunk, outputCount: outputs, stopTokenIDs: stops, sampling: sampling)
        }

        func agreement(_ request: QwenLayerStageGenerationRequest,
                       lookahead: Bool = false, compact: Bool = false,
                       mtp: Bool = false) throws -> QwenLayerStageGenerationAgreement {
            try .init(request: request, membershipEpoch: UUID(), source: contract.source,
                consumerStageFingerprint: contract.stageFingerprints[1],
                rankBuildSHA256: [String(repeating: "1", count: 64), String(repeating: "2", count: 64)],
                numericalPolicySHA256: contract.numericalPolicySHA256,
                prefillPolicy: lookahead ? .oneChunkLookahead : .serial, compactDecode: compact,
                speculativeRoundsFraming: mtp ? "pipeline_mtp_v1" : nil)
        }

        /// Full target oracle on its own cache, with the same prompt chunks and
        /// greedy scalar selection. No stage or distributed driver is involved.
        func request(prompt: [Int], chunk: Int = 2, outputs: Int = 3) throws -> QwenLayerStageGenerationRequest {
            try .init(profile: profile, requestID: UUID(), promptTokenIDs: prompt, chunkSize: chunk,
                outputCount: outputs, stopTokenIDs: [], sampling: nil)
        }

        func greedyOracle(_ request: QwenLayerStageGenerationRequest) throws -> [Int] {
            try MLX.withError { error in
                let model = try artifact.loader().loadTextModel(), cache = model.newTextCache()
                var selected: [Int] = []
                for sequence in 0..<request.forwardCount {
                    let frame = try request.frame(sequence: sequence)
                    let tokens = frame.phase == .prefill
                        ? Array(request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)])
                        : [try #require(selected.last)]
                    let value = try model.prepareForward(tokens: MLXArray(tokens.map(Int32.init), [1, tokens.count]),
                        cache: cache).commit { roots in
                            eval(roots); Stream.gpu.synchronize(); try error.check()
                        }
                    if frame.finalPromptChunk || frame.phase == .decode {
                        let scalar = argMax(value.logits[0..., -1, 0...])
                        eval(scalar); Stream.gpu.synchronize(); try error.check()
                        selected.append(Int(scalar.item(UInt32.self)))
                    }
                }
                Stream.cpu.synchronize(); try error.check()
                return selected
            }
        }
    }

    private final class Pair {
        let wire: ResidualStreamCollectiveFixture
        let first: GLM5NextPipelineGeneration
        let last: GLM5NextPipelineGeneration

        init(_ fixture: Fixture, agreement: QwenLayerStageGenerationAgreement,
             peerAgreement: QwenLayerStageGenerationAgreement? = nil) throws {
            wire = try .init()
            first = try .init(session: .init(stage: fixture.first, agreement: agreement), collective: wire.first)
            last = try .init(session: .init(stage: fixture.last, agreement: peerAgreement ?? agreement), collective: wire.last)
        }

        /// Both results are observed only after the real peer worker joins,
        /// including a throwing sender. This join is the test's peer fence.
        func run(onToken: (Int) throws -> Bool,
                 firstCheck: () throws -> Void = {},
                 lastCheck: @escaping () throws -> Void = {}) throws
            -> (Result<QwenLayerStageGenerationResult, Error>, Result<QwenLayerStageGenerationResult, Error>) {
            var producer: Result<QwenLayerStageGenerationResult, Error>?
            let consumer = try wire.exchange(send: {
                producer = Result { try first.run(onCommittedToken: onToken, check: firstCheck) }
            }, receive: { [self] _ in
                Result { try last.run(onCommittedToken: { _ in throw Failure.wrongRank }, check: lastCheck) }
            })
            return (try #require(producer), consumer)
        }

        func closeFailed() throws {
            try first.closeAfterPeerFence(peerFence: {}, check: {})
            try last.closeAfterPeerFence(peerFence: {}, check: {})
        }
    }

    private func biasedSampling() -> ClusterWorkerSampling {
        // Exercises the real keyed product sampler with an unambiguous token,
        // including its history-dependent bias and selected-token accounting.
        .init(temperature: 0.5, topP: 1, topK: 1, minP: 0, repetitionPenalty: 1,
            repetitionContextSize: 0, frequencyPenalty: 0, presencePenalty: 0,
            seed: 123, stream: 456, logitBias: [.init(tokenID: 9, bias: 1000)])
    }

    @Test func chunkedPrefillAndSequentialGreedyDecodeMatchFullTargetAcrossRepeatedLifetimes() throws {
        let fixture = try Fixture()
        for chunk in [1, 2, 5] {
            let request = try fixture.request(chunk: chunk), expected = try fixture.greedyOracle(request)
            let agreement = try fixture.agreement(request), pair = try Pair(fixture, agreement: agreement)
            var published: [Int] = []
            let results = try pair.run(onToken: { token in
                #expect(pair.first.control.phase == .decision)
                #expect(pair.first.control.selectedTokenCount == published.count + 1)
                #expect(pair.first.session.committedTokens == request.promptCount + published.count)
                #expect(!pair.first.session.isClosed)
                // Callback re-entry cannot start a second forward or drop state.
                #expect(throws: ProbeError.self) { try pair.first.run(onCommittedToken: { _ in true }, check: {}) }
                #expect(throws: ProbeError.self) { try pair.first.closeAfterPeerFence(peerFence: {}, check: {}) }
                published.append(token)
                return true
            })
            let first = try results.0.get(), last = try results.1.get()
            #expect(published == expected && published.count == 3)
            #expect(first.selectedTokenIDs == expected && last.selectedTokenIDs == expected)
            #expect(first.tokenChainSHA256 == last.tokenChainSHA256)
            #expect(first.tokenChainSHA256 != agreement.initialTokenChainSHA256)
            #expect(first.completedFrames == request.prefillFrameCount + 2)
            #expect(first.completedFrames == last.completedFrames)
            #expect(first.committedTokens == 7 && last.committedTokens == 7)
            #expect(first.finishReason == .length && last.finishReason == .length)
            #expect(first.bothRequestStatesRetired && last.bothRequestStatesRetired)
            #expect(pair.first.session.isClosed && pair.last.session.isClosed)
            #expect(pair.first.control.isRetired && pair.last.control.isRetired)
            #expect(!pair.first.session.isFailed && !pair.last.session.isFailed)
            #expect(throws: ProbeError.self) { try pair.first.run(onCommittedToken: { _ in true }, check: {}) }
        }
    }

    @Test func productSamplerHasDeterministicOutputAndStopsAtEOSLengthOrClientStop() throws {
        let fixture = try Fixture()
        for reason in [QwenLayerStageGenerationFinishReason.length, .eos, .clientStop] {
            let request = try fixture.request(outputs: 3, stops: reason == .eos ? [9] : [], sampling: biasedSampling())
            let pair = try Pair(fixture, agreement: fixture.agreement(request))
            var published: [Int] = []
            let results = try pair.run(onToken: { token in
                published.append(token)
                return reason != .clientStop
            })
            let first = try results.0.get(), last = try results.1.get()
            let count = reason == .length ? 3 : 1
            #expect(published == Array(repeating: 9, count: count))
            #expect(first.selectedTokenIDs == published && last.selectedTokenIDs == published)
            #expect(first.finishReason == reason && last.finishReason == reason)
            #expect(first.committedTokens == request.promptCount + count - 1)
            #expect(first.tokenChainSHA256 == last.tokenChainSHA256)
            #expect(request.sampler?.selected == published)
            #expect(pair.first.session.isClosed && pair.last.session.isClosed)
        }
    }

    @Test func tokenAcknowledgementFailurePublishesNothingAndRequiresExplicitFencedClose() throws {
        let fixture = try Fixture(), request = try fixture.request()
        let pair = try Pair(fixture, agreement: fixture.agreement(request))
        var published: [Int] = []
        let results = try pair.run(onToken: { published.append($0); return true }, firstCheck: {
            // Both local token ACKs have been recorded, but the real socket ACK
            // has not yet been sent. The client callback must still be withheld.
            if pair.first.control.phase == .publishing { throw Failure.tokenACK }
        })
        #expect(throws: Failure.self) { try results.0.get() }
        #expect(throws: (any Error).self) { try results.1.get() }
        #expect(published.isEmpty)
        #expect(pair.first.session.committedTokens == 5 && pair.last.session.committedTokens == 5)
        #expect(pair.first.control.selectedTokenCount == 1 && pair.last.control.selectedTokenCount == 0)
        #expect(pair.first.session.isFailed && pair.last.session.isFailed)
        #expect(pair.first.transport.isFailed && pair.last.transport.isFailed)
        #expect(!pair.first.session.isClosed && !pair.last.session.isClosed)
        #expect(throws: Failure.self) {
            try pair.first.closeAfterPeerFence(peerFence: { throw Failure.fence }, check: {})
        }
        #expect(!pair.first.session.isClosed)
        #expect(throws: Failure.self) {
            try pair.first.closeAfterPeerFence(peerFence: {}, check: { throw Failure.fence })
        }
        #expect(!pair.first.session.isClosed)
        try pair.closeFailed()
        #expect(pair.first.session.isClosed && pair.last.session.isClosed)
        #expect(pair.first.control.isRetired && pair.last.control.isRetired)
        #expect(pair.first.control.isFailed && pair.last.control.isFailed)
        // Completed cleanup is idempotent, including an obsolete throwing fence.
        try pair.first.closeAfterPeerFence(peerFence: { throw Failure.fence }, check: {})
    }

    @Test func cancellationAfterPublicationCannotStartAnotherDecodeOrClaimCleanFinish() throws {
        let fixture = try Fixture(), pair = try Pair(fixture, agreement: fixture.agreement(fixture.request()))
        var cancelled = false, published: [Int] = []
        let results = try pair.run(onToken: { token in
            published.append(token); cancelled = true
            return true
        }, firstCheck: { if cancelled { throw Failure.cancelled } })
        #expect(throws: Failure.self) { try results.0.get() }
        #expect(throws: (any Error).self) { try results.1.get() }
        #expect(published.count == 1)
        #expect(pair.first.session.committedTokens == 5 && pair.last.session.committedTokens == 5)
        #expect(pair.first.control.finishReason == nil && pair.last.control.finishReason == nil)
        #expect(!pair.first.session.isClosed && !pair.last.session.isClosed)
        try pair.closeFailed()
    }

    @Test func mismatchedReadinessFailsBeforeFirstNativeFrameOrToken() throws {
        let fixture = try Fixture(), request = try fixture.request()
        let pair = try Pair(fixture, agreement: fixture.agreement(request),
            peerAgreement: fixture.agreement(request)) // distinct membership epochs
        var publications = 0
        let results = try pair.run(onToken: { _ in publications += 1; return true })
        #expect(throws: ProbeError.self) { try results.0.get() }
        #expect(throws: ProbeError.self) { try results.1.get() }
        #expect(publications == 0)
        #expect(pair.first.session.committedTokens == 0 && pair.last.session.committedTokens == 0)
        #expect(pair.first.session.isFailed && pair.last.session.isFailed)
        try pair.closeFailed()
    }

    @Test func lostRetirementAcknowledgementDoesNotDoubleRetireDuringFencedCleanup() throws {
        let fixture = try Fixture(), request = try fixture.request(outputs: 1)
        let pair = try Pair(fixture, agreement: fixture.agreement(request))
        var published: [Int] = []
        let results = try pair.run(onToken: { published.append($0); return true }, firstCheck: {
            // Local cache retirement and its control ACK precede the exchange.
            if pair.first.session.isClosed { throw Failure.retirement }
        })
        #expect(throws: Failure.self) { try results.0.get() }
        #expect(throws: (any Error).self) { try results.1.get() }
        #expect(published.count == 1)
        #expect(pair.first.session.isClosed && pair.last.session.isClosed)
        #expect(!pair.first.control.isRetired && !pair.last.control.isRetired)
        try pair.closeFailed()
        #expect(pair.first.control.isRetired && pair.last.control.isRetired)
        #expect(pair.first.control.isFailed && pair.last.control.isFailed)
    }

    /// The actual feature owner is attached after driver initialization, as in
    /// the resident. The text fixture avoids image preparation: this exercises
    /// ownership across the real generation/retirement path, not image parity.
    private func attachFeatureOwner(to driver: GLM5NextPipelineGeneration, fixture: Fixture) throws {
        let roots = GLM5NextArtifactLoadRoots()
        let vision = try GLM5NextStageVision(loader: fixture.artifact.loader(), roots: roots,
            beforeRead: { _, _ in }, check: {})
        driver.session.imageFeatures = GLM5NextStageImageFeatures(
            media: .init(configurationSHA256: driver.session.identity.sourceConfigurationSHA256, images: []), owner: vision)
    }

    @Test func lateImageFeatureOwnerSurvivesLostRetirementACKAndFailedFence() throws {
        let fixture = try Fixture(), request = try fixture.request(outputs: 1)
        let pair = try Pair(fixture, agreement: fixture.agreement(request))
        try attachFeatureOwner(to: pair.first, fixture: fixture)
        weak var features = pair.first.session.imageFeatures
        #expect(features != nil)
        var observedAfterLocalClose = false
        let results = try pair.run(onToken: { _ in true }, firstCheck: {
            if pair.first.session.isClosed {
                observedAfterLocalClose = true
                #expect(pair.first.session.imageFeatures == nil)
                #expect(features != nil, "Driver must retain the real feature owner after local close")
                throw Failure.retirement
            }
        })
        #expect(observedAfterLocalClose)
        #expect(throws: Failure.self) { try results.0.get() }
        #expect(throws: (any Error).self) { try results.1.get() }
        #expect(!pair.first.control.isRetired && features != nil)
        #expect(throws: Failure.self) {
            try pair.first.closeAfterPeerFence(peerFence: { throw Failure.fence }, check: {})
        }
        #expect(features != nil, "Failed peer fence grants no release authority")
        #expect(throws: Failure.self) {
            try pair.first.closeAfterPeerFence(peerFence: {}, check: { throw Failure.fence })
        }
        #expect(features != nil, "Failed local cleanup grants no release authority")
        try pair.closeFailed() // The fixture joined both real workers before this fence.
        #expect(pair.first.control.isRetired && pair.first.session.isClosed)
        #expect(features == nil, "Successful fenced cleanup releases the driver's final feature reference")
        try pair.first.closeAfterPeerFence(peerFence: { throw Failure.fence }, check: {})
    }

    @Test func lateImageFeatureOwnerReleasesOnlyAfterBilateralRetirement() throws {
        let fixture = try Fixture(), request = try fixture.request(outputs: 1)
        let pair = try Pair(fixture, agreement: fixture.agreement(request))
        try attachFeatureOwner(to: pair.first, fixture: fixture)
        weak var features = pair.first.session.imageFeatures
        var observedAfterLocalClose = false
        let results = try pair.run(onToken: { _ in true }, firstCheck: {
            if pair.first.session.isClosed && !pair.first.control.isRetired {
                observedAfterLocalClose = true
                #expect(features != nil, "Local close alone must not release media")
            }
        })
        _ = try results.0.get(); _ = try results.1.get()
        #expect(observedAfterLocalClose)
        #expect(pair.first.control.isRetired && pair.last.control.isRetired)
        #expect(features == nil, "Both retirement ACKs permit media release")
    }

    @Test func postRetirementCheckFailureDoesNotStrandFeatureOwner() throws {
        let fixture = try Fixture(), request = try fixture.request(outputs: 1)
        let pair = try Pair(fixture, agreement: fixture.agreement(request))
        try attachFeatureOwner(to: pair.first, fixture: fixture)
        weak var features = pair.first.session.imageFeatures
        let results = try pair.run(onToken: { _ in true }, firstCheck: {
            if pair.first.control.isRetired { throw Failure.retirement }
        })
        #expect(throws: Failure.self) { try results.0.get() }
        #expect(pair.first.control.isRetired && pair.first.session.isClosed)
        #expect(features != nil)
        // Both ACKs already exist. Cleanup is idempotent and must neither
        // demand another fence nor leave the driver's feature owner stranded.
        try pair.first.closeAfterPeerFence(peerFence: { throw Failure.fence }, check: { throw Failure.fence })
        #expect(features == nil)
        try pair.last.closeAfterPeerFence(peerFence: {}, check: {})
    }

    @Test func unsupportedModesRefuseBeforeTransfersAndWrongRankCannotBorrowSession() throws {
        let fixture = try Fixture(), request = try fixture.request(), agreement = try fixture.agreement(request)
        for batchSize in [0, 2, Int.max] {
            #expect(throws: ProbeError.self) {
                try GLM5NextPipelineGeneration.requireSupported(agreement, batchSize: batchSize)
            }
        }
        let unsupported = [
            try fixture.agreement(request, lookahead: true),
            try fixture.agreement(request, compact: true),
            try fixture.agreement(request, mtp: true),
        ]
        // A reused prefix and a split final token are the prefix plan's framing.
        try GLM5NextPipelineGeneration.requireSupported(try agreement.planned(request.planned(reusedPrefix: 2, splitFinalToken: false)))
        try GLM5NextPipelineGeneration.requireSupported(try agreement.planned(request.planned(reusedPrefix: 0, splitFinalToken: true)))
        for value in unsupported {
            #expect(throws: ProbeError.self) { try GLM5NextPipelineGeneration.requireSupported(value) }
        }
        let wire = try ResidualStreamCollectiveFixture()
        let session = try GLM5NextStageSession(stage: fixture.first, agreement: agreement)
        #expect(throws: ProbeError.self) { try GLM5NextPipelineGeneration(session: session, collective: wire.last) }
        #expect(throws: ProbeError.self) {
            try GLM5NextPipelineGeneration(session: session, collective: wire.first, batchSize: 2)
        }
        #expect(!session.isFailed && session.committedTokens == 0)
        try session.close(check: {})
    }

    /// Both ranks keep their own prompt prefix (`QwenStagePrefixCache`, one per
    /// rank) and agree on what to reuse: a repeat restores the split frontier
    /// on both, a longer prompt reuses the shared part, and every request
    /// selects exactly the full target's greedy tokens.
    @Test func promptPrefixReuseRestoresBothStagesAndMatchesFullTarget() throws {
        let fixture = try Fixture()
        let caches = [QwenStagePrefixCache(strideTokens: 2), QwenStagePrefixCache(strideTokens: 2)]
        func run(_ request: QwenLayerStageGenerationRequest) throws
            -> (tokens: [Int], reused: [Int], stored: [[Int]], tiers: [String?]) {
            let agreement = try fixture.agreement(request), wire = try ResidualStreamCollectiveFixture()
            func rank(_ index: Int) throws -> (QwenLayerStageGenerationResult, QwenStagePrefixSummary, [Int]) {
                let cache = caches[index], collective = index == 0 ? wire.first : wire.last
                let planned = try agreeGLM5NextStagePrefixPlan(cache: cache, stage: index == 0 ? fixture.first : fixture.last,
                    agreement: agreement, collective: collective, check: {})
                let limit = beginClusterStagePrefixCapture(cache: cache, capture: planned.session.prefixCapture)
                defer { cache.endCapture() }
                let driver = try GLM5NextPipelineGeneration(session: planned.session, collective: collective)
                let result = try driver.run(onCommittedToken: { _ in
                    guard index == 0 else { throw Failure.wrongRank }
                    return true
                }, check: {})
                let stored = storeClusterStagePrefix(cache: cache, capture: planned.session.prefixCapture,
                    agreement: planned.agreement, rank: index, captureLimit: limit, family: "glm", skippedKey: "skipped")
                return (result, planned.summary, stored)
            }
            var producer: Result<(QwenLayerStageGenerationResult, QwenStagePrefixSummary, [Int]), Error>?
            let consumer = try wire.exchange(send: { producer = Result { try rank(0) } },
                                             receive: { _ in Result { try rank(1) } })
            let first = try #require(producer).get(), last = try consumer.get()
            #expect(first.0.selectedTokenIDs == last.0.selectedTokenIDs)
            #expect(first.0.tokenChainSHA256 == last.0.tokenChainSHA256)
            return (first.0.selectedTokenIDs, [first.1.reusedPromptTokens, last.1.reusedPromptTokens],
                    [first.2, last.2], [first.1.restoredTier, last.1.restoredTier])
        }
        let prompt = [4, 5, 6, 7, 8]
        let cold = try fixture.request(prompt: prompt)
        let coldRun = try run(cold)
        #expect(coldRun.tokens == (try fixture.greedyOracle(cold)))
        #expect(coldRun.reused == [0, 0])
        #expect(coldRun.stored.allSatisfy { $0.contains(4) })
        let repeated = try fixture.request(prompt: prompt)
        let repeatRun = try run(repeated)
        #expect(repeatRun.reused == [4, 4] && repeatRun.tiers == ["resident", "resident"])
        #expect(repeatRun.tokens == coldRun.tokens)
        let longer = try fixture.request(prompt: prompt + [9, 10])
        let longerRun = try run(longer)
        #expect(longerRun.reused[0] == longerRun.reused[1] && longerRun.reused[0] >= 2)
        #expect(longerRun.tokens == (try fixture.greedyOracle(longer)))
    }
}
