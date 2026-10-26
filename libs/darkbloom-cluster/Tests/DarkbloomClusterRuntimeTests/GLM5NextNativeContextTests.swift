import DarkbloomClusterProtocol
import Foundation
import MLXLLM
import Testing
@testable import DarkbloomClusterRuntime

/// The registered GLM row advertises its native context (1,048,576) and the
/// registered output limit, with no service-level cap; LOAD and the planner
/// size the pair for the standard request; a tensor-parallel request is
/// charged at its own context, with every DSA history capped at its length.
/// Metadata and synthetic fixtures only: no model, no GPU work.
@Suite("GLM native context and per-request charges", .serialized)
struct GLM5NextNativeContextTests {
    typealias Budget = GLM5NextRequestStateBudget

    @Test func theRowAdvertisesTheNativeContextAndPlansTheStandardRequest() throws {
        let spec = try #require(GLM5NextRegisteredSpecification.all.first)
        let native = try spec.profile(), memory = try spec.memoryProfile()
        #expect(native.maximumContextTokens == 1_048_576 && native.maximumPromptTokens == 1_048_575)
        #expect(native.maximumOutputTokens == 65_536 && native.maximumChunkTokens == 2048)
        #expect(memory.maximumContextTokens == 65_536 && memory.maximumPromptTokens == 32_768)
        #expect(memory.maximumOutputTokens == 32_768 && memory.maximumChunkTokens == 2048)
        #expect(native.identifier == memory.identifier)
        #expect(GLM5NextRegisteredSpecification.registeredOutputTokens <= ClusterWorkerLimits.wireOutputTokens)
    }

    @Test func contextLimitsTakeANativeCeilingWithinTheWire() throws {
        let standard = try QwenResidentContextLimits(declaredContextTokens: 1_048_576)
        #expect(standard.maximumContextTokens == ClusterWorkerLimits.contextTokens)
        #expect(standard.maximumPromptTokens == ClusterWorkerLimits.promptTokens)
        #expect(standard.maximumOutputTokens == ClusterWorkerLimits.outputTokens)
        let native = try QwenResidentContextLimits(declaredContextTokens: 1_048_576, prefillChunkTokens: 2048,
            ceiling: .native(outputTokens: 131_072))
        #expect(native.maximumContextTokens == 1_048_576 && native.maximumPromptTokens == 1_048_575)
        #expect(native.maximumOutputTokens == 131_072 && native.maximumChunkTokens == 2048)
        let short = try QwenResidentContextLimits(declaredContextTokens: 4096, ceiling: .native(outputTokens: 65_536))
        #expect(short.maximumContextTokens == 4096 && short.maximumOutputTokens == 4095)
        #expect(throws: (any Error).self) {
            _ = try QwenResidentContextLimits(declaredContextTokens: 4096,
                ceiling: .native(outputTokens: ClusterWorkerLimits.wireOutputTokens + 1))
        }
    }

    @Test func aCappedHistoryIsChargedTwiceAtItsLengthNotThreeTimesItsDoubling() throws {
        let inventory = try GLM5NextMetadataTestFixture(layers: 8).inventory
        func quote(_ history: Budget.HistoryBound) throws -> Budget {
            try Budget.estimate(inventory: inventory, layers: 0..<4, rank: 0, scope: GLM5NextRequestStateBudgetTests.scope,
                executionPolicy: .reference, executionEnvironmentSHA256: GLM5NextRequestStateBudgetTests.environment,
                workspace: GLM5NextRequestStateBudgetTests.workspace(inventory),
                transport: GLM5NextRequestStateBudgetTests.transport, maximumBufferBytes: Int.max,
                allocationBound: { $0 }, hostAllocationBound: { $0 }, history: history)
        }
        // One DSA layer of 25 bytes a token (`GLM5NextRequestStateBudgetTests`):
        // three of the doubling's 512 columns, or two of the capped 259.
        let geometric = try quote(.geometric), capped = try quote(.reserved(tokens: 259))
        #expect(geometric.dsaCapacityTokens == 512 && geometric.dsaTransactionBytes == (3 * 512 + 16) * 25)
        #expect(capped.dsaCapacityTokens == 259 && capped.dsaTransactionBytes == (2 * 259 + 16) * 25)
        #expect(capped.reservedBytes == geometric.reservedBytes - geometric.dsaTransactionBytes + capped.dsaTransactionBytes)
        #expect(throws: ProbeError.self) { _ = try quote(.reserved(tokens: 255)) }
    }

    @Test func aLaneStateAtACappedHistoryCountsTheBatchedAppend() throws {
        let c = try GLM5NextMetadataTestFixture(layers: 8).configuration.textConfig
        let dsa = c.layerTypes.filter { $0 == .deepseekSparseAttention }.count
        let kda = c.layerTypes.filter { $0 == .linearAttention }.count
        let row = c.kvLoraRank * 4 + 2 * c.indexHeadDim * 4 + 1
        let linear = c.linearAttention
        let settled = linear.numHeads * linear.headDim * linear.headDim * 4
            + 3 * linear.numHeads * linear.headDim * linear.shortConvKernelSize * 4
        let windows = 2 * kda * (GLM5NextTensorParallelResidentRuntime.mtpDepth + 1)
            * (linear.numHeads * linear.headDim * linear.headDim * 4
                + 3 * linear.numHeads * linear.headDim * linear.shortConvKernelSize * 4)
        let capped = try GLM5NextTensorParallelResidentRuntime.laneStateBytes(configuration: c, contextTokens: 100,
            speculative: true, historyTokens: 103, allocationBound: { $0 })
        // Every DSA history twice and the NextN history three times: a batched
        // verification forward appends every lane at once.
        #expect(capped == 103 * row * (2 * dsa + 3) + settled * kda + windows)
        let plain = try GLM5NextTensorParallelResidentRuntime.laneStateBytes(configuration: c, contextTokens: 100,
            speculative: false, historyTokens: 103, allocationBound: { $0 })
        #expect(plain == 103 * row * 2 * dsa + settled * kda)
    }

    @Test func theNextNHistoryIsChargedAtTheCappedLength() throws {
        let c = try GLM5NextMetadataTestFixture(layers: 8).configuration.textConfig
        let profile = try QwenLayerStageGenerationProfile(identifier: "glm-tp-native-fixture",
            vocabularySize: c.vocabularySize, hiddenSize: c.hiddenSize, activationDType: c.dtype,
            maximumPromptTokens: 128, maximumChunkTokens: 16, maximumOutputTokens: 8,
            maximumContextTokens: 256, residualStreams: 4)
        func bytes(_ history: Budget.HistoryBound) throws -> Int {
            try GLM5NextTensorParallelResidentRuntime.speculationRequestBytes(configuration: c, profile: profile,
                depth: 2, executionPolicy: .reference, allocationBound: { $0 }, contextTokens: 256, history: history)
        }
        let row = c.kvLoraRank * 4 + 2 * c.indexHeadDim * 4 + 1
        // Three copies either way: of the doubling's 512 columns, or of the capped 259.
        #expect(try bytes(.geometric) - bytes(.reserved(tokens: 259)) == 3 * (512 - 259) * row)
        #expect(try bytes(.geometric) == GLM5NextTensorParallelResidentRuntime.speculationRequestBytes(configuration: c,
            profile: profile, depth: 2, executionPolicy: .reference, allocationBound: { $0 }))
    }

    /// The context-dependent terms of the real model's charge (configuration
    /// only; set `DARKBLOOM_GLM_CONFIG` to its config.json): printed for the
    /// operator's notes, and the 1,048,576-token request's within reach of a
    /// 256 GB Mac holding the 93 GB model.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_GLM_CONFIG"] != nil))
    func theRealModelsPerTokenCharge() throws {
        let path = ProcessInfo.processInfo.environment["DARKBLOOM_GLM_CONFIG"] ?? "/"
        let c = try JSONDecoder().decode(GLM5NextConfiguration.self,
            from: Data(contentsOf: URL(fileURLWithPath: path))).textConfig
        let spec = try #require(GLM5NextRegisteredSpecification.all.first)
        let profile = try spec.profile()
        let dsa = c.layerTypes.filter { $0 == .deepseekSparseAttention }.count
        let row = c.kvLoraRank * 4 + 2 * c.indexHeadDim * 4 + 1
        var lines: [String] = []
        for context in [32_768, 65_536, 131_072, 262_144, 524_288, 1_048_576] {
            let tokens = context + GLM5NextTensorParallelResidentRuntime.mtpDepth + 1
            let history = 2 * dsa * row * tokens
            let nextN = try GLM5NextTensorParallelResidentRuntime.speculationRequestBytes(configuration: c,
                profile: profile, depth: GLM5NextTensorParallelResidentRuntime.mtpDepth, executionPolicy: .serving,
                allocationBound: { $0 }, contextTokens: context, history: .reserved(tokens: tokens))
            let scores = try GLM5NextTensorParallelRequestCharge.indexScoreBytes(configuration: c,
                contextTokens: context, referenceContextTokens: 65_536)
            let geometric = 6 * dsa * row * max(256, 2 * context) + (try GLM5NextTensorParallelResidentRuntime
                .speculationRequestBytes(configuration: c, profile: profile, depth: GLM5NextTensorParallelResidentRuntime.mtpDepth,
                    executionPolicy: .serving, allocationBound: { $0 }, contextTokens: context))
            lines.append("context=\(context) dsa_history=\(history) nextn=\(nextN) index_scores=\(scores)"
                + " total=\(history + nextN + scores) previous_formula=\(geometric)")
            if context == 1_048_576 { #expect(history + nextN + scores < 110_000_000_000) }
        }
        print(lines.joined(separator: "\n"))
        #expect(dsa == 11 && row == 3073)
    }

    @Test func aTensorParallelRequestIsChargedAtItsOwnContext() throws {
        let fixture = try GLM5NextResidentRuntimeTests.Fixture()
        let d = fixture.descriptor
        let configuration = try Data(contentsOf: fixture.artifact.url("config.json"))
        func descriptor(_ memory: GLM5NextResidentDescriptor.MemoryScope?) throws -> GLM5NextResidentDescriptor {
            try GLM5NextResidentDescriptor(modelID: d.modelID, artifactIdentity: d.artifactIdentity,
                artifactAggregateSHA256: d.artifactAggregateSHA256, configurationBytes: configuration, cut: d.cut,
                storage: .float32, executionPolicy: .reference, profileID: d.profile.identifier,
                maximumPromptTokens: 128, maximumChunkTokens: 16, maximumOutputTokens: 8, maximumContextTokens: 256,
                memoryScope: memory)
        }
        // The memory plan sized for 72 tokens: a new descriptor; none, or one
        // at the profile's own scope, keeps the bytes it always had.
        let scoped = try descriptor(.init(promptTokens: 64, outputTokens: 8, contextTokens: 72))
        #expect(scoped.memoryProfile.maximumContextTokens == 72 && scoped.memoryProfile.maximumChunkTokens == 16)
        #expect(scoped.profile.maximumContextTokens == 256 && scoped.fingerprint != d.fingerprint)
        #expect(try descriptor(nil).fingerprint == d.fingerprint)
        #expect(try descriptor(.init(promptTokens: 128, outputTokens: 8, contextTokens: 256)).fingerprint == d.fingerprint)
        #expect(throws: ProbeError.self) { _ = try descriptor(.init(promptTokens: 200, outputTokens: 8, contextTokens: 210)) }

        let inventory = fixture.artifact.metadata.inventory
        let envelopes = try (0...1).map {
            try GLM5NextResidentRuntimeTests.Fixture.resources(descriptor: scoped, inventory: inventory, rank: $0)
        }
        let charge = try GLM5NextTensorParallelRequestCharge(descriptor: scoped, envelopes: envelopes, fixedBytes: 1000,
            speculativeDepth: 0, maximumBufferBytes: Int.max, allocationBound: { $0 })
        let c = scoped.configuration.textConfig
        let dsa = c.layerTypes.filter { $0 == .deepseekSparseAttention }.count
        let row = c.kvLoraRank * 4 + 2 * c.indexHeadDim * 4 + 1
        let charges = try [2, 17, 72, 100, 200, 256].map { try charge.bytes(contextTokens: $0) }
        #expect(zip(charges, charges.dropFirst()).allSatisfy { $0 < $1 })
        // Per context token: every DSA history of the whole model twice (both
        // ranks' stages, a capped history and an append's fresh buffer) and
        // both ranks' token hosts (two Int copies each)...
        let perToken = 2 * row * dsa + 2 * 2 * MemoryLayout<Int>.stride
        // ...and, past the memory plan's 72 tokens, the indexer's FP32 scores
        // of a bulk frame over one more 4-token pool every 4 tokens.
        let pools = (200 + c.indexKPool - 1) / c.indexKPool - (100 + c.indexKPool - 1) / c.indexKPool
        let scores = GLM5NextTensorParallelResidentRuntime.bulkPrefillChunkTokens * pools * 4
        #expect(charges[4] - charges[3] == 100 * perToken + scores)
        #expect(try GLM5NextTensorParallelRequestCharge.indexScoreBytes(configuration: c, contextTokens: 72,
            referenceContextTokens: 72) == 0)
        #expect(charge.historyTokens(contextTokens: 100) == 101)
        #expect(throws: ProbeError.self) { _ = try charge.bytes(contextTokens: 257) }
        #expect(throws: ProbeError.self) { _ = try charge.bytes(contextTokens: 1) }
        // The charge at the memory plan's context is what LOAD admits; the
        // profile's longest is READY's capacity.
        #expect(charges[2] < charges[5])
    }
}
