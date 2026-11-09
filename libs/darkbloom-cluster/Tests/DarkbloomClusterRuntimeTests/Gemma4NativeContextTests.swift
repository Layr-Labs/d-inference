import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

/// Gemma 4 26B on a pair at its whole declared context, 262,144 tokens, as one
/// Mac serves it: the profile both modes advertise and hold a request to, the
/// state of a request past the protocol's standard 65,536 tokens, a
/// tensor-parallel request charged at its own context, the lookahead prefill of
/// a prompt past 32,768 tokens, and two ranks whose request is reserved past
/// the standard request answering bit for bit, with the whole model's tokens.
/// Registered metadata and a synthetic checkpoint; CPU only, no GPU.
@Suite("Gemma 4 on a pair at its native context", .serialized)
struct Gemma4NativeContextTests {
    private typealias Pair = Gemma4TensorParallelLocalPair
    private final class Box<T>: @unchecked Sendable { var value: T; init(_ value: T) { self.value = value } }
    private static func bound(_ bytes: Int) -> Int { ((bytes + 16_383) / 16_384) * 16_384 }

    /// Every registered row advertises its declared context, with the
    /// catalog's output limit, in both modes.
    @Test func everyRowAdvertisesItsDeclaredContext() throws {
        let limits = try Gemma4ResidentAdapterDefinition.contextLimits()
        #expect(limits.declaredContextTokens == 262_144 && limits.maximumContextTokens == 262_144)
        for spec in Gemma4RegisteredSpecification.all {
            let profile = try Gemma4ResidentAdapterDefinition.profile(specification: spec)
            #expect(profile.maximumContextTokens == 262_144, "\(spec.model)")
            #expect(profile.maximumPromptTokens == 262_143 && profile.maximumOutputTokens == 32_768)
            #expect(profile.maximumChunkTokens == 512)
        }
    }

    /// A stage's rows and a tensor-parallel rank's own heads of a request past
    /// the standard request: full layers keep every token, sliding layers their
    /// ring; up to the wire's longest context and no further.
    @Test(arguments: [65_537, 131_072, 262_144])
    func aRequestPastTheStandardOneHasItsState(tokens: Int) throws {
        let whole = try Gemma4StateBudget.estimate(maximumTokens: tokens, chunkSize: 512)
        let own = try Gemma4StateBudget.estimate(maximumTokens: tokens, chunkSize: 512, ranks: 2)
        #expect(whole.fullKVBytes == tokens * 2 * 512 * 2 && own.fullKVBytes == tokens * 1 * 512 * 2)
        #expect(whole.ringKVBytes == 1024 * 8 * 256 * 2 && own.ringKVBytes * 2 == whole.ringKVBytes)
        func kinds(_ range: Range<Int>) -> [CBv2LayerKind] {
            range.enumerated().map { local, global in
                let full = (global + 1) % 6 == 0
                return CBv2LayerKind(attention: full ? .full : .slidingWindow(1024), headDim: full ? 512 : 256,
                    kvHeads: full ? 2 : 8, queryHeads: 16, modelLayerIndex: local)
            }
        }
        let geometry = try CBv2RequestGeometry(gemma4StageKinds: kinds(8..<30), kvDType: .bfloat16, maximumTokens: tokens)
        #expect(geometry.kvCapacityBytes == 4 * 2 * tokens * 2 * 512 * 2 + 18 * 2 * 1024 * 8 * 256 * 2)
        #expect(throws: (any Error).self) {
            try Gemma4StateBudget.estimate(maximumTokens: ClusterWorkerLimits.wireContextTokens + 1, chunkSize: 512)
        }
    }

    /// A tensor-parallel rank charges a request past the standard request at
    /// its own context: its own KV heads grow with every token, the full
    /// layers' attention transient with the context; the standard request's
    /// quote (what LOAD and the planner size a pair for) is as before.
    @Test func aTensorParallelRequestIsChargedAtItsOwnContext() throws {
        func charge(_ context: Int, prompt: Int? = nil) throws -> Gemma4TensorParallelRequestBudget {
            try .derive(contextTokens: context, chunkTokens: 512, promptTokens: prompt ?? context - 1,
                keepsPrefixes: true, allocationBound: Self.bound)
        }
        let standard = try charge(65_536, prompt: 32_768)
        let charges = try [65_537, 131_072, 196_608, 262_144].map { try charge($0) }
        #expect(zip(charges, charges.dropFirst()).allSatisfy { $0.requestBytes < $1.requestBytes })
        #expect(charges.allSatisfy { $0.requestBytes > standard.requestBytes })
        // This rank's one full KV head of five full layers, keys and values: 10 KiB a token.
        #expect(charges[3].stateBytes - charges[1].stateBytes >= (262_144 - 131_072) * 5 * 2 * 512 * 2)
        // The rank's own reserve beside every request does not grow with the context.
        #expect(charges.allSatisfy { $0.rankBytes == standard.rankBytes })
        #expect(throws: (any Error).self) { _ = try charge(ClusterWorkerLimits.wireContextTokens + 1) }
    }

    private static let gib = QwenDenseStageLoadPolicy.gib
    private static let now: UInt64 = 1_100

    /// A rank's charge as its LOAD builds it: the native profile, and the
    /// memory plan LOAD quotes.
    private static func charge(keepsPrefixes: Bool = true) throws -> Gemma4TensorParallelRequestCharge {
        let spec = try Gemma4RegisteredSpecification.registered(.twentySixBQAT4Bit)
        return try .init(profile: Gemma4ResidentAdapterDefinition.profile(specification: spec),
            memory: Gemma4ResidentAdapterDefinition.memoryProfile(specification: spec), keepsPrefixes: keepsPrefixes,
            allocationBound: bound)
    }

    /// A consistent observation of a 256 GiB Mac with `freeBytes` free, nothing else counted.
    private static func observation(freeBytes: Int) -> QwenDenseStageLoadOSObservation {
        let page = 16_384, free = freeBytes / page, inactive = 1_000, speculative = 500
        return QwenDenseStageLoadOSObservation(startedNanoseconds: 900, completedNanoseconds: 1_000,
            timestampUTC: "2026-11-08T00:00:00Z", physicalMemoryBytes: 256 * gib, pageSizeBytes: page,
            kernelFreePages: free + speculative, freePages: free, inactivePages: inactive,
            speculativePages: speculative, actualFreeBytes: free * page,
            estimatedReclaimableBytes: (free + inactive + speculative) * page, pressureLevel: 1, swapUsedBytes: 0)
    }

    /// Every gate of a rank takes its terms from one charge (`budget`): a
    /// reservation or lane at its own context, prompt and chunk is charged as
    /// LOAD's terms derive them, with its prompt's capture when the rank keeps
    /// prefixes, and none when the request's own cache is off (or the share
    /// probe asks), whatever the rank keeps.
    @Test func aRequestIsChargedTheRanksTermsAtItsOwnContext() throws {
        for keeps in [true, false] {
            let charge = try Self.charge(keepsPrefixes: keeps)
            for (context, prompt, chunk) in [(8_320, 100, 64), (131_072, 131_071, 512), (262_144, 40_000, 512)] {
                func derived(capture: Bool) throws -> Gemma4TensorParallelRequestBudget {
                    try .derive(contextTokens: context, chunkTokens: chunk, promptTokens: prompt, keepsPrefixes: capture,
                        allocationBound: Self.bound)
                }
                #expect(try charge.budget(contextTokens: context, chunkTokens: chunk, promptTokens: prompt)
                    == derived(capture: keeps))
                #expect(try charge.budget(contextTokens: context, chunkTokens: chunk, promptTokens: prompt,
                    keepsPrefixes: false) == derived(capture: false))
            }
            #expect(try charge.budget(contextTokens: 262_144, chunkTokens: 512, keepsPrefixes: false).prefixCaptureBytes == 0)
        }
    }

    /// LOAD quotes the memory plan's request, as the planner does; READY's
    /// capacity, a ceiling and never a grant, covers one request at the
    /// native context. A profile within its memory plan is LOAD's alone.
    @Test func loadQuotesTheMemoryPlanAndReadyCoversTheNativeRequest() throws {
        for keeps in [true, false] {
            let charge = try Self.charge(keepsPrefixes: keeps)
            let standard = try Gemma4TensorParallelRequestBudget.derive(contextTokens: 65_536, chunkTokens: 512,
                promptTokens: 32_768, keepsPrefixes: keeps, allocationBound: Self.bound)
            let native = try Gemma4TensorParallelRequestBudget.derive(contextTokens: 262_144, chunkTokens: 512,
                promptTokens: 262_143, keepsPrefixes: keeps, allocationBound: Self.bound)
            #expect(try charge.memoryPlan == standard)
            #expect(try charge.requestBytes(contextTokens: 262_144) == native.requestBytes)
            #expect(try charge.capacityBytes == native.requestBytes && native.requestBytes > standard.requestBytes)
            #expect(throws: (any Error).self) { _ = try charge.requestBytes(contextTokens: 262_145) }
            #expect(throws: (any Error).self) { _ = try charge.requestBytes(contextTokens: 1) }
        }
        let spec = try Gemma4RegisteredSpecification.registered(.twentySixBQAT4Bit)
        let native = try Gemma4ResidentAdapterDefinition.profile(specification: spec)
        let memory = try Gemma4ResidentAdapterDefinition.memoryProfile(specification: spec)
        let within = try Gemma4TensorParallelRequestCharge(profile: memory, memory: memory, keepsPrefixes: true,
            allocationBound: Self.bound)
        #expect(try within.capacityBytes == within.memoryPlan.requestBytes)
        #expect(try within.servingContextTokens(reclaimableBytes: 0, on: Self.observation(freeBytes: 200 * Self.gib),
            now: Self.now) == nil)
        // A memory plan longer than its profile, or another row's, is refused.
        #expect(throws: (any Error).self) {
            _ = try Gemma4TensorParallelRequestCharge(profile: memory, memory: native, keepsPrefixes: true,
                allocationBound: Self.bound)
        }
        let other = try Gemma4ResidentAdapterDefinition.memoryProfile(specification: .registered(.twentySixB))
        #expect(throws: (any Error).self) {
            _ = try Gemma4TensorParallelRequestCharge(profile: native, memory: other, keepsPrefixes: true,
                allocationBound: Self.bound)
        }
    }

    /// READY and each keep-warm answer report the longest context the
    /// reservation gate admits now: the request at its own context, the
    /// rank's reserve beside it and the loading headroom fit. Kept prefix
    /// entries count as room, since they give way to a reservation. With no
    /// room for one chunk and one output token, that smallest request is
    /// reported, so the pair refuses every longer one before either rank.
    @Test func theServingContextIsTheLongestTheGateAdmitsNow() throws {
        let charge = try Self.charge()
        let beside = try charge.memoryPlan.rankBytes
            + QwenDenseStageLoadPolicy.loadingHeadroomBytes(physicalMemoryBytes: 256 * Self.gib)
        func total(_ context: Int) throws -> Int { try charge.requestBytes(contextTokens: context) + beside }
        func serving(_ os: QwenDenseStageLoadOSObservation, reclaimable: Int = 0) throws -> Int? {
            try charge.servingContextTokens(reclaimableBytes: reclaimable, on: os, now: Self.now)
        }
        let roomy = Self.observation(freeBytes: try total(262_144) + Self.gib)
        #expect(try charge.admits(contextTokens: 262_144, reclaimableBytes: 0, on: roomy, now: Self.now))
        #expect(try serving(roomy) == 262_144)
        let tight = Self.observation(freeBytes: (try total(65_536) + total(262_144)) / 2)
        let longest = try #require(try serving(tight))
        #expect(longest > 65_536 && longest < 262_144)
        #expect(try charge.admits(contextTokens: longest, reclaimableBytes: 0, on: tight, now: Self.now))
        #expect(!(try charge.admits(contextTokens: longest + 1, reclaimableBytes: 0, on: tight, now: Self.now)))
        #expect(try #require(try serving(tight, reclaimable: Self.gib)) > longest)
        #expect(try serving(Self.observation(freeBytes: 2 * Self.gib)) == 513)
    }

    /// The pipeline's one-chunk lookahead prefill keeps its one frame for a
    /// prompt past 32,768 tokens as for any other: its allowance does not grow
    /// with the prompt, and its window counts every frame.
    @Test func aLookaheadPrefillTakesAPromptPastTheStandardOne() throws {
        let short = try QwenGenerationPrefillAllowance.derive(rank: 0, promptCount: 32_768, chunkSize: 512,
            hiddenSize: Gemma4StageGeometry.hiddenSize, elementBytes: 2, bound: Self.bound)
        let long = try QwenGenerationPrefillAllowance.derive(rank: 0, promptCount: 262_143, chunkSize: 512,
            hiddenSize: Gemma4StageGeometry.hiddenSize, elementBytes: 2, bound: Self.bound)
        #expect(long == short)
        let window = try QwenGenerationPrefillWindow(promptCount: 262_143, chunkSize: 512)
        #expect(window.frameCount == 512)
    }

    private static let prompt = (0 ..< 40).map { ($0 * 37 + 11) % 512 }
    private static let steps = 6

    /// Six greedy steps of `prompt` on `model`, its request reserved for
    /// `outputs` tokens on a host sized for it (contiguous: the CPU runs it).
    private static func generate(_ model: Gemma4TensorParallelModel, outputs: Int) throws
        -> Gemma4TensorParallelModel.Generation {
        let maximum = prompt.count + outputs
        let host = try CBv2StageKVHost(gemma4Geometry: model.requestGeometry(maximumTokens: maximum), kind: .contiguous,
            lanes: 1, maximumTokensPerRequest: maximum, maximumChunkTokens: 16)
        let session = try Gemma4TensorParallelPagedSession(model: model, host: host, promptCount: prompt.count,
            outputCount: outputs)
        return try model.generatePaged(session: session, host: host, prompt: prompt, outputCount: steps, chunk: 16,
            recordTop: 4)
    }

    /// A synthetic checkpoint's tensor-parallel request whose reservation is
    /// past the standard request (prompt and output 65,540 tokens), on each
    /// rank's host sized for it: two in-process ranks agree bit for bit, take
    /// the whole model's tokens, and every bit equals the same request reserved
    /// at its own length. Contiguous hosts, so the arithmetic runs on the CPU.
    @Test func ranksReservedPastTheStandardRequestAgreeWithTheWholeModel() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemma4-native-context-\(UUID().uuidString)")
        try Device.withDefaultDevice(.cpu) {
            try Gemma4TensorParallelModel.writeSyntheticCheckpoint(directory: directory, bits: 4, experts: 4, topK: 4)
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let reserved = 65_500, steps = Self.steps
        let pair = Pair()
        let models = Box(try (0 ..< 2).map { rank in
            try Device.withDefaultDevice(.cpu) {
                try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .shard(rank: rank),
                                                   reduction: pair.reduction(rank: rank))
            }
        })
        let long = try Pair.run(device: .cpu) { rank in try Self.generate(models.value[rank], outputs: reserved) }
        let own = try Pair.run(device: .cpu) { rank in try Self.generate(models.value[rank], outputs: steps) }
        let whole = try Device.withDefaultDevice(.cpu) {
            try Self.generate(try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .full, reduction: nil),
                              outputs: reserved)
        }
        func bits(_ rows: [[Float]]) -> [[UInt32]] { rows.map { $0.map(\.bitPattern) } }
        #expect(Self.prompt.count + reserved > ClusterWorkerLimits.contextTokens)
        #expect(long[0].tokenIDs.count == steps && long[0].tokenIDs == long[1].tokenIDs)
        #expect(bits(long[0].topLogits) == bits(long[1].topLogits))
        #expect(bits(long[0].topLogprobs) == bits(long[1].topLogprobs))
        #expect(long[0].finalLogits.map { $0.map(\.bitPattern) } == long[1].finalLogits.map { $0.map(\.bitPattern) })
        #expect(long[0].tokenIDs == whole.tokenIDs, "ranks \(long[0].tokenIDs) against the whole model \(whole.tokenIDs)")
        for rank in 0 ..< 2 {
            #expect(long[rank].tokenIDs == own[rank].tokenIDs && bits(long[rank].topLogits) == bits(own[rank].topLogits),
                "rank \(rank): a reservation past the standard request changed its arithmetic")
            #expect(long[rank].finalLogits.map { $0.map(\.bitPattern) } == own[rank].finalLogits.map { $0.map(\.bitPattern) })
        }
    }
}
