import DarkbloomClusterPlacement
@testable import DarkbloomClusterProtocol
import Foundation
import Testing
@testable import DarkbloomClusterRuntime

/// Real retained 27B headers and the production budget derivations: what each
/// rank of every supported split reserves at LOAD. No payloads, no GPU.
struct QwenTensorParallelRankLedgerTests {
    private struct Retained: Decodable {
        struct Tensor: Decodable { let name: String; let shape: [Int]; let sourceDType: String; let byteCount: Int }
        struct Profile: Decodable { let configuration: Data; let canonicalTensors: [Tensor] }
        let twentySeven: Profile
    }
    private struct Assistant: Decodable {
        struct Tensor: Decodable { let name: String; let shape: [Int]; let dtype: String; let byteCount: Int }
        let tensors: [Tensor]
    }
    private func inputs() throws -> (Data, [ClusterPlacementStoredTensor], QwenDensePlacementFamily, ClusterPlacementRequestScope) {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let retained = try JSONDecoder().decode(Retained.self, from: Data(contentsOf: tests.deletingLastPathComponent()
            .appendingPathComponent("StageMetadataChecks/Inputs/qwen-retained-inputs.json"))).twentySeven
        let assistant = try JSONDecoder().decode(Assistant.self, from: Data(contentsOf: tests
            .appendingPathComponent("Inputs/qwen27-tp-mtp-inventory.json")))
        let family = try QwenDensePlacementFamily(configuration: retained.configuration), p = family.profile
        let stored = retained.canonicalTensors.map {
            ClusterPlacementStoredTensor(name: $0.name, byteCount: $0.byteCount, dtype: $0.sourceDType, shape: $0.shape)
        } + assistant.tensors.map {
            ClusterPlacementStoredTensor(name: $0.name, byteCount: $0.byteCount, dtype: $0.dtype, shape: $0.shape)
        }
        let request = try ClusterPlacementRequestScope(runtimeModelID: family.runtimeModelID,
            artifactSHA256: family.definition.specification.artifactSHA256,
            configurationSHA256: family.definition.specification.configurationSHA256,
            promptTokens: 32, outputTokens: 8, maximumPromptTokens: p.maximumPromptTokens,
            maximumOutputTokens: p.maximumOutputTokens, maximumContextTokens: p.maximumContextTokens,
            requestChargeEveryRankBytes: family.requestChargeEveryRankBytes(contextTokens: 40))
        return (retained.configuration, stored, family, request)
    }
    private func bound(_ bytes: Int) -> Int { ((bytes + 16_383) / 16_384) * 16_384 }

    @Test func everyDividedTensorSplitsExactlyBetweenTheRanks() throws {
        let (_, stored, family, _) = try inputs()
        let tensors = try family.requireRegisteredInventory(stored)
        let splits = [try #require(family.tensorParallel)] + family.tensorParallelSharePlans
        #expect(splits.count == 1 + family.tensorParallelShareOptions.count && splits.count > 1)
        for plan in splits {
            let shards = try (0..<2).map { try family.geometry.tensorParallelShard(plan: plan, rank: $0) }
            #expect(shards[0].kvHeads + shards[1].kvHeads == family.geometry.kvHeads)
            #expect(shards[0].queryHeads + shards[1].queryHeads == family.geometry.queryHeads)
            #expect(shards[0].linearKeyHeads + shards[1].linearKeyHeads == family.geometry.linearKeyHeads)
            #expect(shards[0].linearValueHeads + shards[1].linearValueHeads == family.geometry.linearValueHeads)
            #expect(shards.allSatisfy { $0.hiddenSize == family.geometry.hiddenSize && $0.layers == family.geometry.layers })
            for tensor in tensors {
                let disposition = try plan.disposition(key: tensor.name, rank: 0)
                if case .skip = disposition { continue }
                let whole = tensor.shape.reduce(1, *)
                let held = try (0..<2).map { try plan.rankElements(of: tensor, rank: $0) }
                if case .load(.replicate) = disposition {
                    #expect(held == [whole, whole], "\(tensor.name)")
                } else {
                    #expect(held[0] + held[1] == whole && held.allSatisfy { $0 > 0 }, "\(tensor.name) \(plan.shares)")
                }
            }
        }
        #expect(try family.geometry.tensorParallelShard(plan: splits[0], rank: nil) == family.geometry)
        #expect(throws: (any Error).self) { try family.geometry.tensorParallelShard(plan: splits[0], rank: 2) }
    }

    @Test func eachRankReservesOnlyItsOwnHeadsUnderEverySplit() throws {
        let (_, stored, family, _) = try inputs()
        let tensors = try family.requireRegisteredInventory(stored)
        let g = family.geometry, p = family.profile
        for plan in [try #require(family.tensorParallel)] + family.tensorParallelSharePlans {
            for lanes in [1, 2] {
                func plain(_ rank: Int?) throws -> QwenTensorParallelBatchBudget {
                    try QwenTensorParallelBatchBudget.derive(geometry: g, plan: plan, tensors: tensors,
                        maximumTokens: p.maximumContextTokens, chunkSize: p.maximumChunkTokens, lanes: lanes,
                        paged: true, rank: rank, allocationBound: bound)
                }
                func assisted(_ rank: Int?) throws -> QwenTensorParallelBatchMTPBudget {
                    try QwenTensorParallelBatchMTPBudget.derive(geometry: g, plan: plan, tensors: tensors,
                        maximumTokens: p.maximumContextTokens, promptTokens: p.maximumPromptTokens,
                        chunkSize: p.maximumChunkTokens, lanes: lanes, depth: 2, maximumSpeculativeWidth: lanes,
                        rank: rank, allocationBound: bound)
                }
                for (whole, ranks) in [
                    (try plain(nil).allowance, try (0..<2).map { try plain($0).allowance }),
                    (try assisted(nil).allowance, try (0..<2).map { try assisted($0).allowance }),
                ] {
                    #expect(ranks.allSatisfy { $0.requestBytesExcludingCollectives < whole.requestBytesExcludingCollectives })
                    #expect(ranks.allSatisfy { $0.collectiveScratchBytes == whole.collectiveScratchBytes })
                    // KV heads, linear key heads and MLP channels: a rank holding
                    // no less of each (and more of one) reserves more.
                    let parts = (0..<2).map { [plan.kvHeadsPerRank[$0], plan.linearKeyHeadsPerRank[$0], plan.intermediatePerRank[$0]] }
                    let bytes = ranks.map(\.requestBytesExcludingCollectives)
                    if parts[0] == parts[1] {
                        #expect(ranks[0] == ranks[1], "equal parts, equal reservation \(plan.shares)")
                    } else if zip(parts[0], parts[1]).allSatisfy({ $0 >= $1 }) {
                        #expect(bytes[0] > bytes[1], "\(plan.shares)")
                    } else if zip(parts[0], parts[1]).allSatisfy({ $0 <= $1 }) {
                        #expect(bytes[1] > bytes[0], "\(plan.shares)")
                    }
                }
            }
        }
    }

    @Test func placementQuotesEveryRankAsItsLoadDerivesIt() throws {
        let (configuration, stored, family, request) = try inputs()
        let tensors = try family.requireRegisteredInventory(stored), g = family.geometry, p = family.profile
        let plans = [try #require(family.tensorParallel)] + family.tensorParallelSharePlans
        for lanes in [1, 2, 4] {
            for depth in [nil, 2] as [Int?] {
                let quote = try ClusterPlacementArtifact.tensorBatchQuote(configuration: configuration,
                    stored: depth == nil ? stored.filter { !$0.name.hasPrefix("mtp.") } : stored, request: request,
                    chunkTokens: 16, lanes: lanes, assistantDepth: depth,
                    assistantVerification: depth == nil ? .singleton : .admittedCohort, allocationBound: bound)
                let entries = try #require(quote.rankQuotes)
                #expect(entries.map(\.shares) == [[1, 1]] + family.tensorParallelShareOptions)
                for (entry, plan) in zip(entries, plans) {
                    let native = try (0..<2).map { rank -> Int in
                        if let depth {
                            return try QwenTensorParallelBatchMTPBudget.derive(geometry: g, plan: plan, tensors: tensors,
                                maximumTokens: p.maximumContextTokens, promptTokens: p.maximumPromptTokens,
                                chunkSize: p.maximumChunkTokens, lanes: lanes, depth: depth, maximumSpeculativeWidth: lanes,
                                rank: rank, allocationBound: bound).allowance.requestBytesExcludingCollectives
                        }
                        return try QwenTensorParallelBatchBudget.derive(geometry: g, plan: plan, tensors: tensors,
                            maximumTokens: p.maximumContextTokens, chunkSize: p.maximumChunkTokens, lanes: lanes,
                            paged: true, rank: rank, allocationBound: bound).allowance.requestBytesExcludingCollectives
                    }
                    #expect(entry.requestBytesExcludingCollectives == native, "\(entry.shares) lanes \(lanes) depth \(depth as Any)")
                    for rank in 0..<2 {
                        #expect(quote.rankReservedBytes(rank: rank, shares: entry.shares)
                            == native[rank] + quote.allowance.collectiveScratchBytes)
                    }
                }
                #expect(try ClusterPlacementTensorBatchQuote.decode(JSONEncoder().encode(quote)) == quote)
            }
        }
    }
}
