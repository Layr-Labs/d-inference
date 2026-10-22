import Foundation
import MLX
import MLXLLM
import Testing
@testable import DarkbloomClusterRuntime

@Suite("GLM stage transactions", .serialized)
struct GLM5NextStageSessionTests {
    private enum Failure: Error { case acknowledgement }

    /// Real local files let sessions exercise the same verified load/binding as
    /// production while retaining the tiny deterministic tensor values.
    final class Artifact {
        let metadata: GLM5NextMetadataTestFixture
        let directory: URL

        init() throws {
            metadata = try GLM5NextMetadataTestFixture(layers: 8)
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("glm-stage-session-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            do {
                // Deliberately distinct from the normalized construction bytes.
                var config = try canonicalJSONData(metadata.configuration)
                config.append(10)
                try config.write(to: url("config.json"))
                try metadata.index.write(to: url("model.safetensors.index.json"))
                for name in metadata.shards.keys.sorted() {
                    let shard = metadata.shards[name]!
                    var header = shard.data
                    while header.count % 8 != 0 { header.append(32) }
                    var length = UInt64(header.count).littleEndian
                    var data = withUnsafeBytes(of: &length) { Data($0) }
                    data.append(header)
                    for entry in metadata.inventory.entries.values.sorted(by: { $0.tensor.name < $1.tensor.name })
                    where entry.tensor.shard == name {
                        for value in Self.values(entry) {
                            var word = value.bitPattern.littleEndian
                            withUnsafeBytes(of: &word) { data.append(contentsOf: $0) }
                        }
                    }
                    try data.write(to: url(name))
                }
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
        func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

        func loader(policy: GLM5NextExecutionPolicy = .reference) throws -> GLM5NextArtifactLoader {
            let names = ["config.json", "model.safetensors.index.json"] + metadata.shards.keys.sorted()
            let files = try Dictionary(uniqueKeysWithValues: names.map { name in
                let data = try Data(contentsOf: url(name))
                return (name, GLM5NextArtifactIdentity.File(bytes: data.count, sha256: sha256(data)))
            })
            return try .init(directory: directory, expectedIdentity: .init(
                repository: "synthetic/glm-stage-session", revision: String(repeating: "a", count: 40),
                files: files), storage: .float32, executionPolicy: policy)
        }

        private static func values(_ entry: GLM5NextWeightInventory.Entry) -> [Float] {
            let name = entry.tensor.name, count = entry.tensor.shape.reduce(1, *)
            if name.hasSuffix("_scale") || name.contains("norm.weight") {
                return Array(repeating: 1, count: count)
            }
            if name.hasSuffix("A_log") { return Array(repeating: -0.7, count: count) }
            if name.hasSuffix("dt_bias") { return Array(repeating: -0.2, count: count) }
            let salt = name.utf8.reduce(0) { ($0 + Int($1)) % 13 }
            return (0..<count).map { Float(($0 + salt) % 11 - 5) * 0.025 }
        }
    }

    struct Fixture {
        let first: GLM5NextStageSession
        let last: GLM5NextStageSession
        let full: GLM5NextTextModel
        let agreement: QwenLayerStageGenerationAgreement
        let artifact: Artifact
        let contract: GLM5NextStageContract
        let firstStage: GLM5NextStageBinding
        let lastStage: GLM5NextStageBinding

        init() throws {
            let artifact = try Artifact(), loader = try artifact.loader()
            let c = loader.configuration.textConfig
            let contract = try Self.contract(loader: loader)
            let profile = try QwenLayerStageGenerationProfile(identifier: "glm-stage-transaction-fixture",
                vocabularySize: c.vocabularySize, hiddenSize: c.hiddenSize, activationDType: c.dtype,
                maximumPromptTokens: 128, maximumChunkTokens: 16, maximumOutputTokens: 8,
                maximumContextTokens: 256, residualStreams: 4)
            let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                promptTokenIDs: [4, 5, 6, 7], chunkSize: 2, outputCount: 3, stopTokenIDs: [])
            let agreement = try QwenLayerStageGenerationAgreement(request: request, membershipEpoch: UUID(),
                source: contract.source, consumerStageFingerprint: contract.stageFingerprints[1],
                rankBuildSHA256: [String(repeating: "1", count: 64), String(repeating: "2", count: 64)],
                numericalPolicySHA256: contract.numericalPolicySHA256)
            let firstStage = try contract.loadStage(using: loader, stageIndex: 0)
            let lastStage = try contract.loadStage(using: artifact.loader(), stageIndex: 1)
            first = try .init(stage: firstStage, agreement: agreement)
            last = try .init(stage: lastStage, agreement: agreement)
            full = try artifact.loader().loadTextModel()
            self.artifact = artifact; self.contract = contract
            self.firstStage = firstStage; self.lastStage = lastStage
            self.agreement = agreement
        }

        static func contract(loader: GLM5NextArtifactLoader, cut: Int = 3,
                             loadMTPEmbedding: Bool = false) throws -> GLM5NextStageContract {
            try .init(loader: loader, artifactAggregateSHA256: String(repeating: "b", count: 64),
                storageCommitmentSHA256: String(repeating: "c", count: 64), cut: cut,
                loadMTPEmbedding: loadMTPEmbedding)
        }
    }


    @Test func foreignCutAndMTPEmbeddingOwnershipCannotReuseAgreement() throws {
        let fixture = try Fixture()
        defer { try? fixture.first.close(check: {}); try? fixture.last.close(check: {}) }
        for rank in 0...1 {
            let loader = try fixture.artifact.loader()
            let foreign = try Fixture.contract(loader: loader, cut: 2)
                .loadStage(using: loader, stageIndex: rank)
            #expect(foreign.model.plan.isFirst == (rank == 0))
            #expect(foreign.model.plan.isFinal == (rank == 1))
            #expect(foreign.model.plan.layers != (rank == 0 ? 0..<3 : 3..<8))
            #expect(throws: ProbeError.self) {
                try GLM5NextStageSession(stage: foreign, agreement: fixture.agreement)
            }
        }
        let loader = try fixture.artifact.loader()
        let mtp = try Fixture.contract(loader: loader, loadMTPEmbedding: true)
            .loadStage(using: loader, stageIndex: 1)
        #expect(mtp.model.embedding != nil && fixture.lastStage.model.embedding == nil)
        #expect(throws: ProbeError.self) {
            try GLM5NextStageSession(stage: mtp, agreement: fixture.agreement)
        }
    }

    @Test func foreignPolicyIsRefusedAtLoadAndSessionBeforeNativeCacheAllocation() throws {
        let fixture = try Fixture()
        defer { try? fixture.first.close(check: {}); try? fixture.last.close(check: {}) }
        var policy = GLM5NextExecutionPolicy.reference
        policy.stepEvaluation = .earlyAsync
        let loader = try fixture.artifact.loader(policy: policy)
        var reads = 0
        #expect(throws: ProbeError.self) {
            try fixture.contract.loadStage(using: loader, stageIndex: 0,
                beforeTensorRead: { _, _ in reads += 1 })
        }
        #expect(reads == 0)
        let foreignContract = try Fixture.contract(loader: loader)
        let foreign = try foreignContract.loadStage(using: loader, stageIndex: 0)
        #expect(foreign.model.plan.layers == fixture.firstStage.model.plan.layers)
        #expect(foreign.model.executionPolicy != fixture.firstStage.model.executionPolicy)
        #expect(throws: ProbeError.self) {
            try GLM5NextStageSession(stage: foreign, agreement: fixture.agreement)
        }

        // Even a descriptor retaining the valid plan/stage hashes must name
        // the policy that actually constructed this model.
        let changedPolicy = try QwenLayerStageGenerationAgreement(
            request: fixture.agreement.request, membershipEpoch: UUID(),
            source: fixture.contract.source,
            consumerStageFingerprint: fixture.contract.stageFingerprints[1],
            rankBuildSHA256: [String(repeating: "1", count: 64), String(repeating: "2", count: 64)],
            numericalPolicySHA256: foreignContract.numericalPolicySHA256)
        #expect(throws: ProbeError.self) {
            try GLM5NextStageSession(stage: fixture.firstStage, agreement: changedPolicy)
        }
    }

    @Test func verifiedSourceAndFullConfigurationStayBoundDespiteMatchingGeometry() throws {
        let fixture = try Fixture()
        defer { try? fixture.first.close(check: {}); try? fixture.last.close(check: {}) }
        let sourceBytes = try Data(contentsOf: fixture.artifact.url("config.json"))
        #expect(fixture.first.identity.sourceConfigurationSHA256 == sha256(sourceBytes))
        #expect(fixture.first.identity.constructionConfigurationSHA256
            != fixture.first.identity.sourceConfigurationSHA256)
        #expect(fixture.first.identity.artifactAggregateSHA256 == String(repeating: "b", count: 64))
        for changeConfiguration in [false, true] {
            let artifact = try Artifact()
            if changeConfiguration {
                let decoded = try JSONSerialization.jsonObject(with: sourceBytes)
                var root = try #require(decoded as? [String: Any])
                var text = try #require(root["text_config"] as? [String: Any])
                text["rms_norm_eps"] = 0.002
                root["text_config"] = text
                try JSONSerialization.data(withJSONObject: root).write(to: artifact.url("config.json"))
            } else {
                // Same tensor schema, config and geometry; different verified
                // payload bytes must not borrow the original artifact receipt.
                let name = try #require(artifact.metadata.shards.keys.sorted().first)
                var bytes = try Data(contentsOf: artifact.url(name))
                bytes[bytes.count - 1] ^= 1
                try bytes.write(to: artifact.url(name))
            }
            let loader = try artifact.loader()
            #expect(loader.configuration.textConfig.hiddenSize == fixture.firstStage.model.plan.configuration.hiddenSize)
            #expect(loader.configuration.textConfig.vocabularySize == fixture.firstStage.model.plan.configuration.vocabularySize)
            var reads = 0
            #expect(throws: ProbeError.self) {
                try fixture.contract.loadStage(using: loader, stageIndex: 0,
                    beforeTensorRead: { _, _ in reads += 1 })
            }
            #expect(reads == 0)
            if changeConfiguration {
                let foreign = try Fixture.contract(loader: loader).loadStage(using: loader, stageIndex: 0)
                #expect(throws: ProbeError.self) {
                    try GLM5NextStageSession(stage: foreign, agreement: fixture.agreement)
                }
            }
        }
    }

    @Test func everyExecutionPolicyFieldHasStableWireIdentity() throws {
        let reference = try GLM5NextStageContract.policySHA256(.reference)
        #expect(reference == "ef68e3beb468e8f5a073a6f0f9963c41319c5f44d8ae3124857e67076d73fe6e")
        let changes: [(inout GLM5NextExecutionPolicy) -> Void] = [
            { $0.sparseAttention = .absorbed },
            { $0.sparseSelection.selection = .parallelThreshold },
            { $0.sparseSelection.deviceRanges = true },
            { $0.sparseSelection.queryBlocks = true },
            { $0.pagedMetadataReads = .deviceTable },
            { $0.hyperConnection = .nativeRequired },
            { $0.routedExperts = .nativeCombine },
            { $0.linearAttention = .nativeRecurrence },
            { $0.normalization = .fusedKernel },
            { $0.linearDecodeStep = .fusedKernel },
            { $0.routing = .nativeKernel },
            { $0.projections = .fusedInputs },
            { $0.stepEvaluation = .earlyAsync },
            { $0.sparseDecode = .nativeKernels },
            { $0.sparsePrefill = .nativeKernel },
            { $0.prefillProjections = .nativeGEMM },
        ]
        var hashes: Set<String> = [reference]
        for change in changes {
            var policy = GLM5NextExecutionPolicy.reference
            change(&policy)
            let hash = try GLM5NextStageContract.policySHA256(policy)
            #expect(hashes.insert(hash).inserted)
        }
    }

    @Test func invalidationRetainsCommittedFrontiersUntilSuccessfulFencedClose() throws {
        let fixture = try Fixture(), frame = try fixture.agreement.request.frame(sequence: 0)
        #expect(throws: Failure.self) {
            try fixture.first.forward(frame: frame, tokens: [4, 5], afterEvaluation: { output in
                guard case .hidden(let boundary) = output else { throw ProbeError("missing boundary") }
                _ = try fixture.last.forward(frame: frame, tokens: [4, 5], incoming: boundary,
                    afterEvaluation: { _ in }, check: {})
                fixture.last.invalidate()
                throw Failure.acknowledgement
            }, check: {})
        }
        fixture.first.invalidate()
        fixture.last.invalidate()
        #expect(fixture.first.isFailed && fixture.last.isFailed)
        #expect(fixture.first.committedTokens == 0 && fixture.last.committedTokens == 2)
        #expect(!fixture.first.isClosed && !fixture.last.isClosed)
        let nextFrame = try fixture.agreement.request.frame(sequence: 1)
        #expect(throws: ProbeError.self) {
            try fixture.last.forward(frame: nextFrame, tokens: [6, 7], afterEvaluation: { _ in }, check: {})
        }
        #expect(throws: Failure.self) {
            try fixture.last.close(check: { throw Failure.acknowledgement })
        }
        #expect(!fixture.last.isClosed && fixture.last.committedTokens == 2)
        try fixture.first.close(check: {})
        try fixture.last.close(check: {})
        #expect(fixture.first.isClosed && fixture.last.isClosed)
    }

    @Test func invalidationInsideEvaluationCannotPublishTentativeCache() throws {
        let fixture = try Fixture(), frame = try fixture.agreement.request.frame(sequence: 0)
        #expect(throws: ProbeError.self) {
            try fixture.first.forward(frame: frame, tokens: [4, 5],
                afterEvaluation: { _ in fixture.first.invalidate() }, check: {})
        }
        #expect(fixture.first.isFailed && fixture.first.committedTokens == 0 && !fixture.first.isClosed)
        try fixture.first.close(check: {})
        try fixture.last.close(check: {})
    }

    @Test func receiverCommitPrecedesProducerPublicationAndMatchesFullCachedForward() throws {
        let fixture = try Fixture(), cache = fixture.full.newTextCache()
        defer { try? fixture.first.close(check: {}); try? fixture.last.close(check: {}) }
        for (sequence, tokens) in [[4, 5], [6, 7], [9]].enumerated() {
            let frame = try fixture.agreement.request.frame(sequence: sequence)
            let expected = try fixture.full.prepareForward(
                tokens: MLXArray(tokens.map(Int32.init), [1, tokens.count]), cache: cache)
                .commit { roots in eval(roots); Stream.gpu.synchronize() }
            var row: MLXArray?
            _ = try fixture.first.forward(frame: frame, tokens: tokens, afterEvaluation: { output in
                #expect(fixture.first.committedTokens == frame.tokenOffset)
                guard case .hidden(let boundary) = output else { Issue.record("missing four-stream boundary"); return }
                #expect(boundary.array.shape == [1, tokens.count, 4, 4])
                let consumed = try fixture.last.forward(frame: frame, tokens: tokens, incoming: boundary,
                    afterEvaluation: { _ in #expect(fixture.last.committedTokens == frame.tokenOffset) }, check: {})
                #expect(fixture.last.committedTokens == frame.tokenOffset + frame.tokenCount)
                #expect(fixture.first.committedTokens == frame.tokenOffset)
                if case .logits(let value) = consumed { row = value }
            }, check: {})
            #expect(fixture.first.committedTokens == cache.offset && fixture.last.committedTokens == cache.offset)
            if frame.finalPromptChunk || frame.phase == .decode {
                let actual = try #require(row)
                let reference = expected.logits[0..., -1, 0...]
                #expect(abs(actual - reference).max().item(Float.self) < 0.0001)
            } else { #expect(row == nil) }
        }
    }

    @Test func failedAcknowledgementPoisonsRequestWithoutPublishingItsNativeFrontier() throws {
        let fixture = try Fixture(), frame = try fixture.agreement.request.frame(sequence: 0)
        #expect(throws: Failure.self) {
            try fixture.first.forward(frame: frame, tokens: [4, 5], afterEvaluation: { _ in
                #expect(fixture.first.committedTokens == 0)
                throw Failure.acknowledgement
            }, check: {})
        }
        #expect(fixture.first.isFailed && fixture.first.committedTokens == 0)
        #expect(throws: ProbeError.self) {
            try fixture.first.forward(frame: frame, tokens: [4, 5], afterEvaluation: { _ in }, check: {})
        }
        try fixture.first.close(check: {})
        try fixture.last.close(check: {})
        #expect(fixture.first.isClosed && fixture.last.isClosed)
    }

    @Test func reentrantForwardAndCloseCannotInvalidateAnAcknowledgedFrame() throws {
        let fixture = try Fixture(), frame = try fixture.agreement.request.frame(sequence: 0)
        _ = try fixture.first.forward(frame: frame, tokens: [4, 5], afterEvaluation: { _ in
            #expect(throws: ProbeError.self) {
                try fixture.first.forward(frame: frame, tokens: [4, 5], afterEvaluation: { _ in }, check: {})
            }
            #expect(throws: ProbeError.self) { try fixture.first.close(check: {}) }
        }, check: {})
        #expect(!fixture.first.isFailed && fixture.first.committedTokens == 2)
        try fixture.first.close(check: {}); try fixture.last.close(check: {})
    }
}
