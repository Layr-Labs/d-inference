import DarkbloomClusterPlacement
import Foundation
import MLX
import Testing
@testable import DarkbloomClusterRuntime

@Suite(.serialized)
struct QwenTensorParallelBatchPrefixTests {
    @Test func originalGridAndBilateralVotesNeverSplitFinalChunk() throws {
        for chunk in [1, 5, 128, 512] {
            for count in [1, 2, 5, 511, 512, 513, 4096, 8193, 33_000, 70_000] {
                let c = QwenTensorParallelBatchPrefixCache.candidates(promptCount: count,
                    chunkSize: chunk, maximumTokens: 65_536)
                #expect(c.count <= QwenTensorParallelBatchPrefixCache.maximumVoted
                    && c.allSatisfy { $0 > 0 && $0 < count && $0 <= 65_536 && $0 % chunk == 0 })
                // Every grid boundary is voted when the vote holds them all.
                if chunk == 512 { #expect(c.count == min(count - 1, 65_536) / 512) }
                #expect(try QwenTensorParallelBatchPrefixCache.agreed(candidates: c, votes: c.map { _ in 1 }) == 0)
                #expect(try QwenTensorParallelBatchPrefixCache.agreed(candidates: c, votes: c.map { _ in 2 }) == c.last ?? 0)
            }
        }
        for votes: [Float] in [[.nan], [.infinity], [-1], [3], [0.5], []] {
            #expect(throws: (any Error).self) { try QwenTensorParallelBatchPrefixCache.agreed(candidates: [512], votes: votes) }
        }
    }

    @Test func immutableIdentityAndAllocatorChargedLRURemainBounded() throws {
        try Device.withDefaultDevice(.cpu) {
            let cache = QwenTensorParallelBatchPrefixCache(enabled: true, budgetBytes: 32)
            let tokens = [1, 2, 3, 4, 5, 6]
            func keys(_ scope: String, _ input: [Int] = tokens) -> [Int: String] {
                QwenTensorParallelBatchPrefixCache.keys(scope: scope, tokens: input, frontiers: [2, 4])
            }
            let k = keys("load|media=A"), other = keys("load|media=B")
            #expect(k != other)
            #expect(k[2] == keys("load|media=A", [1, 2, 9, 4, 5, 6])[2])
            #expect(k[4] != keys("load|media=A", [1, 2, 9, 4, 5, 6])[4])
            cache.insert(key: k[2]!, state: state(2, 16)); cache.insert(key: k[4]!, state: state(4, 16))
            #expect(cache.bytesInUse == 32)
            _ = try cache.restore(key: k[2]!, frontier: 2)
            cache.insert(key: other[2]!, state: state(2, 16))
            #expect(cache.held(keys: k, candidates: [2, 4]) == [1, 0])
            #expect(cache.bytesInUse == 32)
            cache.insert(key: "too-large", state: state(4, 33))
            #expect(cache.bytesInUse == 32)
            #expect(throws: (any Error).self) { try cache.restore(key: k[2]!, frontier: 4) }
            cache.sweep(); #expect(cache.bytesInUse == 0 && cache.held(keys: k, candidates: [2, 4]) == [0, 0])
            let off = QwenTensorParallelBatchPrefixCache(enabled: false, budgetBytes: 32)
            off.insert(key: k[2]!, state: state(2, 16)); #expect(off.bytesInUse == 0)
        }
    }

    private func state(_ frontier: Int, _ bytes: Int) -> QwenTensorParallelBatchPrefixState {
        .init(committedTokens: frontier, attention: [:], recurrent: [:], allocatedBytes: bytes)
    }

    // MARK: Parity with one Mac's dense-Qwen reuse

    /// One Mac's dense-Qwen complete checkpoints for a request served alone
    /// (`docs/architecture/prefix-cache.md`, streamed complete checkpoints):
    /// solo stripes of 4,096 (`EngineV2Factory.defaultDenseQwenSoloPrefillStripeTokens`),
    /// range ends on the 256 grid from the store's 1,024-token floor, the
    /// demanded latest cut 64 tokens below the prompt end when it saves the
    /// floor (`demandedLatestCheckpointRange`), and retention of the first,
    /// the hinted fork target and the rolling latest (`CBv2CheckpointRetention`).
    private struct OneMac {
        static func latest(_ prompt: Int) -> Int {
            let stripeEnd = (prompt - 1) / 4096 * 4096
            let cut = (prompt - 1 - 64) / 256 * 256
            let start = cut / 4096 * 4096
            let deepest = cut >= 1024 && cut > start && cut - start >= 1024 ? max(stripeEnd, cut) : stripeEnd
            return deepest >= 1024 ? deepest : 0
        }
        /// The first stripe end.
        static func first(_ prompt: Int) -> Int { prompt > 4096 ? 4096 : 0 }
        /// The deepest stripe end at or below a hinted repeat of `shared` tokens.
        static func target(_ prompt: Int, shared: Int) -> Int { min(shared, prompt - 1) / 4096 * 4096 }
    }

    /// The deepest boundary a pair restores for a prompt sharing `shared`
    /// tokens with a donor of `prompt` tokens that kept `frontiers`.
    private func reuse(_ frontiers: [Int], shared: Int) -> Int { frontiers.filter { $0 <= shared }.max() ?? 0 }

    @Test func keptBoundariesReuseAtLeastWhatOneMacReusesOnTheGrid() {
        let chunk = 512
        for prompt in Swift.stride(from: 1_100, through: 70_000, by: 37) {
            let kept = QwenTensorParallelBatchPrefixBudget.frontiers(promptCount: prompt, chunkSize: chunk)
            #expect(kept.allSatisfy { $0 % chunk == 0 && $0 > 0 && $0 < prompt })
            #expect(kept.count <= QwenTensorParallelBatchPrefixBudget.maximumStripeBoundaries + 3)
            // A repeated prompt: the deepest boundary before the final token.
            let deepest = (prompt - 1) / chunk * chunk
            #expect(kept.last == deepest)
            #expect(reuse(kept, shared: prompt) >= OneMac.latest(prompt) / chunk * chunk, "repeat \(prompt)")
            // The next turn shares the prompt but its re-rendered end (under
            // 16 tokens for current templates; one Mac keeps a 64-token margin).
            for rerendered in [1, 8, 16, 63] where prompt - rerendered > 0 {
                let shared = prompt - rerendered
                let mac = [OneMac.first(prompt), OneMac.latest(prompt)].filter { $0 <= shared }.max() ?? 0
                #expect(reuse(kept, shared: shared) >= mac / chunk * chunk, "turn \(prompt) shared \(shared)")
            }
            // Prompts sharing only a system prompt: one Mac's first stripe
            // end, and with the coordinator's hint the deepest stripe end at
            // or below it, while the kept stripe is one Mac's.
            for system in Swift.stride(from: 4_096, to: prompt, by: 1_531) {
                #expect(reuse(kept, shared: system) >= OneMac.first(prompt), "system \(system) of \(prompt)")
                if (deepest - 1) / 4096 <= QwenTensorParallelBatchPrefixBudget.maximumStripeBoundaries {
                    #expect(reuse(kept, shared: system) >= OneMac.target(prompt, shared: system), "hinted \(system) of \(prompt)")
                }
            }
        }
        // The 33K repeat measured on one Mac (pw1): 32,768 there, at least that here.
        #expect(reuse(QwenTensorParallelBatchPrefixBudget.frontiers(promptCount: 33_000, chunkSize: chunk), shared: 33_000) == 32_768)
        #expect(OneMac.latest(33_000) == 32_768)
        // A restored request keeps only what lies beyond its restore.
        #expect(QwenTensorParallelBatchPrefixBudget.frontiers(promptCount: 33_000, chunkSize: chunk, restored: 16_384)
            == [20_480, 24_576, 28_672, 32_768])
        #expect(QwenTensorParallelBatchPrefixBudget.frontiers(promptCount: 32_801, chunkSize: chunk)
            == [4_096, 8_192, 12_288, 16_384, 20_480, 24_576, 28_672, 32_256, 32_768])
        #expect(QwenTensorParallelBatchPrefixBudget.frontiers(promptCount: 600, chunkSize: chunk) == [512])
        #expect(QwenTensorParallelBatchPrefixBudget.frontiers(promptCount: 512, chunkSize: chunk).isEmpty)
    }

    // MARK: Memory

    private func geometry() throws -> QwenLongPrefillBudgetGeometry {
        try QwenLongPrefillBudgetGeometry(layers: 4, fullAttentionInterval: 4, hiddenSize: 256,
            queryHeads: 4, kvHeads: 2, headDimension: 64, linearKeyHeads: 2, linearValueHeads: 4,
            linearKeyDimension: 64, linearValueDimension: 64, convolutionKernel: 4)
    }
    private func bound(_ n: Int) -> Int { (n + 16383) / 16384 * 16384 }

    @Test func aRequestIsChargedItsOwnCaptureAndLoadOneOfTheLongestPrompt() throws {
        let g = try geometry()
        let b = try QwenLongPrefillTensorBudget.estimate(geometry: g, maximumTokens: 1, chunkSize: 1)
        let perBoundary = 3 * (bound(b.convolutionBytesPerLayer) + bound(b.ssmBytesPerLayer))
        var previous = 0
        for prompt in Swift.stride(from: 1, through: 70_000, by: 97) {
            let charged = try QwenTensorParallelBatchPrefixBudget.captureBytes(geometry: g, promptCount: prompt,
                chunkSize: 512, allocationBound: bound)
            let kept = QwenTensorParallelBatchPrefixBudget.frontiers(promptCount: prompt, chunkSize: 512)
            guard let deepest = kept.last else { #expect(charged == 0); continue }
            // Its rows to the deepest boundary, and a recurrent state for at
            // least every boundary a prompt with that deepest boundary keeps.
            let states = QwenTensorParallelBatchPrefixBudget.pricedStates(deepest: deepest, chunkSize: 512)
            #expect(states >= QwenTensorParallelBatchPrefixBudget.frontiers(promptCount: deepest + 1, chunkSize: 512).count)
            #expect(states >= kept.count && states <= QwenTensorParallelBatchPrefixBudget.maximumStripeBoundaries + 3)
            #expect(charged == 2 * bound(deepest * 2 * 64 * 2) + states * perBoundary)
            #expect(charged >= previous, "prompt \(prompt)"); previous = charged
        }
        // LOAD's per-lane term is one capture of the profile's longest prompt
        // (at most the context), and nothing for a resident tier.
        let load = try QwenTensorParallelBatchPrefixBudget.derive(geometry: g, maximumTokens: 65_536,
            promptTokens: 32_768, chunkSize: 512, allocationBound: bound)
        #expect(load.captureBytes == (try QwenTensorParallelBatchPrefixBudget.captureBytes(geometry: g,
            promptCount: 32_768, chunkSize: 512, allocationBound: bound)))
        // A request is charged and captures to its own context, past LOAD's memory plan too.
        for prompt in [9_000, 100_000, 262_143] {
            #expect(try load.captureBytes(promptCount: prompt, chunkSize: 512, allocationBound: bound)
                == (try QwenTensorParallelBatchPrefixBudget.captureBytes(geometry: g, promptCount: prompt, chunkSize: 512,
                    allocationBound: bound)))
        }
        let context = try QwenTensorParallelBatchPrefixBudget.derive(geometry: g, maximumTokens: 4096, chunkSize: 512,
            allocationBound: bound)
        #expect(context.captureBytes == (try QwenTensorParallelBatchPrefixBudget.captureBytes(geometry: g,
            promptCount: 4095, chunkSize: 512, allocationBound: bound)))
        #expect(throws: (any Error).self) {
            try QwenTensorParallelBatchPrefixBudget.derive(geometry: g, maximumTokens: 4096, chunkSize: 512, allocationBound: { $0 - 1 })
        }
        #expect(throws: (any Error).self) {
            try QwenTensorParallelBatchPrefixBudget.derive(geometry: g, maximumTokens: 4096, chunkSize: 512, allocationBound: { _ in Int.max })
        }
        // A fixture's flat budget charges what it names.
        #expect(try QwenTensorParallelBatchPrefixBudget(maximumTokens: 128, captureBytes: 7)
            .captureBytes(promptCount: 100, chunkSize: 5, allocationBound: bound) == 7)
    }

    @Test func oneCapturesBoundariesShareTheirCopyAndGiveWayShallowestFirst() throws {
        let cache = QwenTensorParallelBatchPrefixCache(enabled: true, budgetBytes: 100)
        func group(_ name: String, _ frontiers: [Int], own: Int, shared: Int) -> [Int] {
            cache.insert(frontiers.map { (key: "\(name)-\($0)", state: state($0, own)) }, sharedBytes: shared)
        }
        // A: the copy (40) once and three states (10 each).
        #expect(group("a", [4, 8, 12], own: 10, shared: 40) == [4, 8, 12])
        #expect(cache.bytesInUse == 70)
        // B needs 50: A's shallower boundaries go first, never A's deepest.
        #expect(group("b", [4, 8], own: 10, shared: 30) == [4, 8])
        #expect(cache.heldFrontiers == [4, 8, 12] && cache.bytesInUse == 100)
        #expect(cache.holds(key: "a-12", frontier: 12) && !cache.holds(key: "a-4", frontier: 4))
        // The budget falls: the newest capture's shallower boundary goes
        // before any capture's deepest; then whole captures, least recent first.
        cache.setBudget(90)
        #expect(cache.holds(key: "a-12", frontier: 12) && cache.holds(key: "b-8", frontier: 8) && !cache.holds(key: "b-4", frontier: 4))
        cache.setBudget(50)
        #expect(!cache.holds(key: "a-12", frontier: 12) && cache.holds(key: "b-8", frontier: 8) && cache.bytesInUse == 40)
        // A capture whose deepest boundary does not fit keeps nothing; with
        // room for its deepest only, only that.
        #expect(group("c", [4, 8], own: 10, shared: 100) == [])
        cache.setBudget(60)
        #expect(group("d", [4, 8], own: 10, shared: 5) == [4, 8])
        #expect(group("e", [4, 8], own: 10, shared: 45) == [8])
        // A zero budget keeps nothing resident, but the cache stays on (its votes still count SSD records).
        cache.setBudget(0)
        #expect(cache.enabled && cache.bytesInUse == 0 && cache.heldFrontiers.isEmpty)
        #expect(group("f", [4], own: 10, shared: 0) == [])
    }

    @Test func pastTheCaptureLimitTheLeastRecentCaptureGoesWhole() throws {
        let cache = QwenTensorParallelBatchPrefixCache(enabled: true, budgetBytes: 1 << 30)
        let limit = QwenTensorParallelBatchPrefixCache.maximumGroups
        for index in 0..<limit {
            cache.insert([(key: "\(index)-4", state: state(4, 1)), (key: "\(index)-8", state: state(8, 1))], sharedBytes: 1)
        }
        _ = try cache.restore(key: "0-8", frontier: 8)
        cache.insert([(key: "new-4", state: state(4, 1)), (key: "new-8", state: state(8, 1))], sharedBytes: 1)
        // Capture 1, the least recently used, went whole; every other kept both boundaries.
        #expect(cache.heldFrontiers.count == 2 * limit && cache.bytesInUse == 3 * limit)
        #expect(!cache.holds(key: "1-4", frontier: 4) && !cache.holds(key: "1-8", frontier: 8))
        #expect(cache.holds(key: "0-4", frontier: 4) && cache.holds(key: "new-8", frontier: 8))
    }

    @Test func entriesGiveWayBeforeALiveGateRefuses() throws {
        let cache = QwenTensorParallelBatchPrefixCache(enabled: true, budgetBytes: 100)
        cache.insert([(key: "a-4", state: state(4, 10)), (key: "a-8", state: state(8, 10))], sharedBytes: 30)
        cache.insert([(key: "b-4", state: state(4, 10))], sharedBytes: 30)
        #expect(cache.bytesInUse == 90)
        // The gate admits once at most 40 bytes are held: entries go one at a time.
        try cache.yieldingMemory(disk: nil) {
            if cache.bytesInUse > 40 { throw ProbeError("refused") }
        }
        #expect(cache.bytesInUse <= 40 && cache.evictions >= 2)
        // A refusal with nothing left to give way is the gate's.
        #expect(throws: ProbeError.self) {
            try cache.yieldingMemory(disk: nil) { throw ProbeError("refused") }
        }
        #expect(cache.bytesInUse == 0)
    }

    /// The SSD record's scope binds the prefix policy, so a record kept under
    /// another policy (the 4,096-token one included) is never offered.
    @Test func recordsOfAnotherPolicyAreNeverOffered() throws {
        let plan = QwenTensorParallelPrefixDisk.planScopeFields(planFingerprint: "plan", planName: "qwen_dense_heads_and_channels_v1",
            shares: [1, 1], assistantPolicy: nil)
        #expect(plan.prefillSchedule.hasSuffix("|prefix=" + QwenTensorParallelBatchPrefixBudget.policy))
        #expect(QwenTensorParallelBatchPrefixBudget.policy == "qwen-tp-batch-prefix-depth-v2")
        let old = plan.prefillSchedule.replacingOccurrences(of: QwenTensorParallelBatchPrefixBudget.policy,
            with: "qwen-tp-batch-grid-prefix-4096-v1")
        func scope(_ schedule: String) -> String {
            QwenStagePrefixDiskTier.planScope(planFingerprint: plan.planFingerprint, artifactAggregateSHA256: "a",
                storageCommitmentSHA256: "s", rankBuildSHA256: ["b0", "b1"], generationMode: "tensor_parallel_v1",
                prefillSchedule: schedule)
        }
        #expect(scope(plan.prefillSchedule) != scope(old))
    }

    // MARK: The registered 27B

    private struct Inputs: Decodable {
        struct Tensor: Decodable { let name: String; let shape: [Int]; let sourceDType: String; let byteCount: Int }
        struct Profile: Decodable { let configuration: Data; let canonicalTensors: [Tensor] }
        let twentySeven: Profile
    }

    /// LOAD's quote of the registered 27B on its own heads, before (one
    /// 4,096-token capture a lane and two such banks resident) and after (one
    /// capture of the profile's longest prompt a lane, no resident term).
    @Test func registeredTwentySevenBChargesOneCaptureOfItsLongestPromptPerLane() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("StageMetadataChecks/Inputs/qwen-retained-inputs.json")
        let value = try JSONDecoder().decode(Inputs.self, from: Data(contentsOf: url)).twentySeven
        let family = try QwenDensePlacementFamily(configuration: value.configuration)
        let tensors = try family.requireRegisteredInventory(value.canonicalTensors.map {
            ClusterPlacementStoredTensor(name: $0.name, byteCount: $0.byteCount, dtype: $0.sourceDType, shape: $0.shape)
        })
        let plan = try #require(family.tensorParallel), p = family.profile
        for rank in [0, nil] as [Int?] {
            let local = try family.geometry.tensorParallelShard(plan: plan, rank: rank)
            let b = try QwenLongPrefillTensorBudget.estimate(geometry: local, maximumTokens: 4096, chunkSize: 1)
            let before = local.recurrentLayers * (bound(b.convolutionBytesPerLayer) + bound(b.ssmBytesPerLayer))
                + 2 * local.attentionLayers * bound(4096 * local.kvHeads * local.headDimension * 2)
            let after = try QwenTensorParallelBatchPrefixBudget.captureBytes(geometry: local,
                promptCount: p.maximumPromptTokens, chunkSize: p.maximumChunkTokens, allocationBound: bound)
            for lanes in [1, 8] {
                let quote = try QwenTensorParallelBatchBudget.derive(geometry: family.geometry, plan: plan, tensors: tensors,
                    maximumTokens: p.maximumContextTokens, chunkSize: p.maximumChunkTokens, lanes: lanes, paged: true,
                    rank: rank, promptTokens: p.maximumPromptTokens, allocationBound: bound)
                #expect(quote.prefix.captureBytes == after)
                let now = quote.allowance.requestBytesExcludingCollectives
                let then = now - lanes * after + lanes * before + 2 * before
                print("qwen27-tp-prefix-quote rank=\(rank.map(String.init) ?? "either") lanes=\(lanes)"
                    + " prompt=\(p.maximumPromptTokens) context=\(p.maximumContextTokens)"
                    + " capture_before=\(before) resident_before=\(2 * before) capture_after=\(after)"
                    + " request_before=\(then) request_after=\(now) delta=\(now - then)")
            }
        }
    }
}
