import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation
import MLX
import Testing
@testable import DarkbloomClusterRuntime

/// Every Qwen TP row's header-only quote is its own native LOAD ledger: the
/// 9B and 27B dense rows and the Qwen3.6 35B A3B routed-expert row (real
/// retained headers and configurations; no payloads, model or GPU).
struct QwenTensorParallelRowQuoteTests {
    private struct Tensor: Decodable { let name: String; let shape: [Int]; let sourceDType: String; let byteCount: Int }
    private struct Profile: Decodable { let configuration: Data; let canonicalTensors: [Tensor] }
    private struct Retained: Decodable { let nine: Profile; let twentySeven: Profile }
    private struct Assistant: Decodable {
        struct Tensor: Decodable { let name: String; let shape: [Int]; let dtype: String; let byteCount: Int }
        let configurationSHA256: String
        let tensors: [Tensor]
    }
    private static let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    private func bound(_ bytes: Int) -> Int { ((bytes + 16_383) / 16_384) * 16_384 }

    private func rows() throws -> [(name: String, profile: Profile)] {
        let retained = try JSONDecoder().decode(Retained.self, from: Data(contentsOf: Self.tests.deletingLastPathComponent()
            .appendingPathComponent("StageMetadataChecks/Inputs/qwen-retained-inputs.json")))
        let routed = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: Self.tests.deletingLastPathComponent()
            .appendingPathComponent("PlacementChecks/Inputs/qwen36-projection-budget.json")))
        return [("9B", retained.nine), ("27B", retained.twentySeven), ("3.6 A3B", routed)]
    }

    private func scope(_ family: QwenDensePlacementFamily) throws -> ClusterPlacementRequestScope {
        let p = family.profile
        return try ClusterPlacementRequestScope(runtimeModelID: family.runtimeModelID,
            artifactSHA256: family.definition.specification.artifactSHA256,
            configurationSHA256: family.definition.specification.configurationSHA256,
            promptTokens: 32, outputTokens: 8, maximumPromptTokens: p.maximumPromptTokens,
            maximumOutputTokens: p.maximumOutputTokens, maximumContextTokens: p.maximumContextTokens,
            requestChargeEveryRankBytes: family.requestChargeEveryRankBytes(contextTokens: 40))
    }

    private func stored(_ tensors: [Tensor]) -> [ClusterPlacementStoredTensor] {
        tensors.map { .init(name: $0.name, byteCount: $0.byteCount, dtype: $0.sourceDType, shape: $0.shape) }
    }

    @Test func everyTensorRowQuotesItsOwnNativeLedgerAtEveryWidth() throws {
        var perLane: [String: Int] = [:]
        for (name, profile) in try rows() {
            let family = try QwenDensePlacementFamily(configuration: profile.configuration)
            let plan = try #require(family.tensorParallel, "\(name) has a TP plan")
            #expect(ClusterPlacementTensorBatchQuote.runtimeModelIDs.contains(family.runtimeModelID))
            let stored = stored(profile.canonicalTensors), canonical = try family.requireRegisteredInventory(stored)
            let request = try scope(family)
            var previous = 0
            for lanes in [1, 2, 4, 8] {
                let quote = try ClusterPlacementArtifact.tensorBatchQuote(configuration: profile.configuration,
                    stored: stored, request: request, chunkTokens: 16, lanes: lanes, allocationBound: bound)
                let native = try QwenTensorParallelBatchBudget.derive(geometry: family.geometry, plan: plan,
                    tensors: canonical, maximumTokens: family.profile.maximumContextTokens,
                    chunkSize: family.profile.maximumChunkTokens, lanes: lanes, paged: true, allocationBound: bound)
                #expect(quote.allowance == native.allowance, "\(name) lanes=\(lanes)")
                #expect(quote.perLaneStateBytes == native.perLaneStateBytes)
                #expect(quote.allowance.maximumCollectivePayloadBytes >= lanes * plan.maximumPartialBytesPerToken)
                #expect(quote.allowance.reservedBytes > previous, "\(name): a wider quote reserves more")
                previous = quote.allowance.reservedBytes
                #expect(try ClusterPlacementTensorBatchQuote.decode(JSONEncoder().encode(quote)) == quote)
                // Each rank of every quoted split reserves its own heads; the
                // routed-expert row splits equally only.
                let splits = try #require(quote.rankQuotes).map(\.shares)
                #expect(splits.contains([1, 1]) && (!plan.routedExperts || splits == [[1, 1]]))
                if lanes == 1 { perLane[name] = quote.perLaneStateBytes }
            }
            if plan.routedExperts {
                // The packed MoE payload's source partials ride in the shared charge.
                let scalar = try QwenTensorParallelRequestBudget.derive(geometry: family.geometry, plan: plan,
                    tensors: canonical, maximumTokens: family.profile.maximumContextTokens,
                    chunkSize: family.profile.maximumChunkTokens, allocationBound: bound)
                let native = try QwenTensorParallelBatchBudget.derive(geometry: family.geometry, plan: plan,
                    tensors: canonical, maximumTokens: family.profile.maximumContextTokens,
                    chunkSize: family.profile.maximumChunkTokens, lanes: 8, paged: true, allocationBound: bound)
                #expect(scalar.packingBytes > 0 && native.sharedBytesExcludingCollectives > scalar.packingBytes)
                #expect(throws: (any Error).self) {
                    try ClusterPlacementArtifact.tensorBatchQuote(configuration: profile.configuration, stored: stored,
                        request: request, chunkTokens: 16, lanes: 1, assistantDepth: 3, allocationBound: bound)
                }
            }
        }
        // Each row is priced by its own geometry, not the 27B's.
        #expect(perLane["9B"]! < perLane["27B"]! && perLane["3.6 A3B"]! < perLane["27B"]!)
    }

    @Test func nineBAssistantFollowsItsOwnInlineHead() throws {
        let profile = try rows()[0].profile
        let family = try QwenDensePlacementFamily(configuration: profile.configuration)
        let plan = try #require(family.tensorParallel)
        let assistant = try JSONDecoder().decode(Assistant.self, from: Data(contentsOf: Self.tests
            .appendingPathComponent("Inputs/qwen9-tp-mtp-inventory.json")))
        #expect(assistant.configurationSHA256 == family.definition.specification.configurationSHA256)
        let tensors = Dictionary(uniqueKeysWithValues: assistant.tensors.map {
            ($0.name, (shape: $0.shape, dtype: $0.dtype == "U32" ? DType.uint32 : .bfloat16, byteCount: $0.byteCount))
        })
        let footprint = try QwenTensorParallelMTPInventory.footprint(tensors: tensors,
            specification: family.definition.specification, configuration: profile.configuration, allocationBound: bound)
        #expect(footprint.storageBytes == 136_881_152 && footprint.allocationBytes >= footprint.storageBytes)
        #expect(footprint.largestAllocationBytes >= bound(4_096 * 12_288 * 4))
        let head = try QwenTensorParallelMTPInventory.Head(configuration: profile.configuration)
        var changed = tensors; changed["mtp.fc.weight"]!.shape[0] += 1
        #expect(throws: ProbeError.self) { try QwenTensorParallelMTPInventory.validateStoredTensors(changed, head: head) }
        let stored = stored(profile.canonicalTensors) + assistant.tensors.map {
            ClusterPlacementStoredTensor(name: $0.name, byteCount: $0.byteCount, dtype: $0.dtype, shape: $0.shape)
        }
        let canonical = try family.requireRegisteredInventory(stored)
        for lanes in [1, 2, 4] {
            let quote = try ClusterPlacementArtifact.tensorBatchQuote(configuration: profile.configuration, stored: stored,
                request: try scope(family), chunkTokens: 16, lanes: lanes, assistantDepth: 3, allocationBound: bound)
            let native = try QwenTensorParallelBatchMTPBudget.derive(geometry: family.geometry, plan: plan,
                tensors: canonical, maximumTokens: family.profile.maximumContextTokens,
                promptTokens: family.profile.maximumPromptTokens, chunkSize: family.profile.maximumChunkTokens,
                lanes: lanes, depth: 3, allocationBound: bound).allowance
            #expect(quote.allowance == native)
            #expect(quote.assistant?.policy.inventorySHA256 == footprint.fingerprint)
            #expect(quote.assistant?.residentBytes == footprint.allocationBytes)
        }
        #expect(QwenTensorParallelMTPPolicy.models == [.qwen35NineB, .qwen38TwentySevenB])
        #expect(ClusterQwenTensorAssistantPolicy.runtimeModelIDs == ["registered_qwen35_9b", "registered_qwen38_27b"])
    }
}
