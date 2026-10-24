import DarkbloomClusterPlacement
@testable import DarkbloomClusterProtocol
import Foundation
import MLX
import Testing
@testable import DarkbloomClusterRuntime

/// Real retained artifact headers and the production metadata/native budget
/// calculations. No tensor payloads, model construction or GPU execution.
struct QwenTensorParallelAssistantQuoteTests {
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

    @Test func allAutomaticWidthsUseTheExactNativeLedgerAndReplicatedHeadLoad() throws {
        let (configuration, stored, family, request) = try inputs()
        let plan = try #require(family.tensorParallel), tensors = try family.requireRegisteredInventory(stored)
        let descriptors = Dictionary(uniqueKeysWithValues: stored.filter { $0.name.hasPrefix("mtp.") }.map {
            ($0.name, (shape: $0.shape, dtype: $0.dtype == "U32" ? DType.uint32 : .bfloat16, byteCount: $0.byteCount))
        })
        let footprint = try QwenTensorParallelMTPInventory.footprint(tensors: descriptors,
            specification: family.definition.specification, allocationBound: bound)
        #expect(footprint.storageBytes == 238_930_944 && footprint.allocationBytes >= footprint.storageBytes)
        #expect(footprint.loadBytes == footprint.allocationBytes + footprint.constructionBytes
            + 2 * footprint.largestTensorBytes + CheckpointAlignedReadPlan.maximumScratchAllocationBytes)
        #expect(footprint.largestAllocationBytes >= bound(5_120 * 17_408 * 4))
        for lanes in [1, 2, 4, 8] {
            for depth in [1, 4] {
                let quote = try ClusterPlacementArtifact.tensorBatchQuote(configuration: configuration, stored: stored,
                    request: request, chunkTokens: 16, lanes: lanes, assistantDepth: depth, allocationBound: bound)
                let native = try QwenTensorParallelBatchMTPBudget.derive(geometry: family.geometry, plan: plan,
                    tensors: tensors, maximumTokens: family.profile.maximumContextTokens,
                    promptTokens: family.profile.maximumPromptTokens,
                    chunkSize: family.profile.maximumChunkTokens, lanes: lanes, depth: depth,
                    allocationBound: bound).allowance
                #expect(quote.allowance == native)
                #expect(quote.allowance.requestBytesExcludingCollectives
                    == lanes * quote.perLaneStateBytes + quote.sharedBytesExcludingCollectives)
                #expect(quote.assistant?.policy.depth == depth && quote.assistant?.policy.inventorySHA256 == footprint.fingerprint)
                #expect(quote.assistant?.residentBytes == footprint.allocationBytes && quote.assistant?.loadBytes == footprint.loadBytes)
                #expect(quote.allowance.maximumContextTokens == family.profile.maximumContextTokens)
                #expect(quote.allowance.maximumChunkTokens == family.profile.maximumChunkTokens)
                #expect(try ClusterPlacementTensorBatchQuote.decode(JSONEncoder().encode(quote)) == quote)
            }
        }
        let ordinary = try ClusterPlacementArtifact.tensorBatchQuote(configuration: configuration, stored: stored,
            request: request, chunkTokens: 16, lanes: 2, allocationBound: bound)
        #expect(ordinary.assistant == nil && ordinary.schema == ClusterPlacementTensorBatchQuote.schemaName)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ordinary)) as! [String: Any]
        #expect(object["assistant"] == nil)
    }

    @Test func plainSingletonIsFullyPricedByTheSameNativeRequestOwnedLedger() throws {
        let (configuration, stored, family, request) = try inputs()
        let plan = try #require(family.tensorParallel), tensors = try family.requireRegisteredInventory(stored)
        let quote = try ClusterPlacementArtifact.tensorBatchQuote(configuration: configuration,
            stored: stored.filter { !$0.name.hasPrefix("mtp.") }, request: request,
            chunkTokens: 16, lanes: 1, allocationBound: bound)
        let native = try QwenTensorParallelBatchBudget.derive(geometry: family.geometry, plan: plan,
            tensors: tensors, maximumTokens: family.profile.maximumContextTokens,
            chunkSize: family.profile.maximumChunkTokens, lanes: 1, paged: true, allocationBound: bound)
        #expect(quote.assistant == nil && quote.lanes == 1)
        #expect(quote.allowance == native.allowance && quote.perLaneStateBytes == native.perLaneStateBytes)
        #expect(quote.sharedBytesExcludingCollectives == native.sharedBytesExcludingCollectives)
        #expect(try ClusterPlacementTensorBatchQuote.decode(JSONEncoder().encode(quote)) == quote)
    }

    @Test func malformedPolicyInventoryAndQuotationFailBeforeAnyPayloadRead() throws {
        let (configuration, stored, _, request) = try inputs()
        let policy = try ClusterQwenTensorAssistantPolicy(depth: 4, inventorySHA256: String(repeating: "a", count: 64))
        #expect(try ClusterQwenTensorAssistantPolicy.decodeObject(policy.object) == policy)
        for bad in [0, 5, Int.max] {
            #expect(throws: (any Error).self) { try ClusterQwenTensorAssistantPolicy(depth: bad, inventorySHA256: policy.inventorySHA256) }
        }
        for bad in ["", String(repeating: "A", count: 64), String(repeating: "z", count: 64)] {
            #expect(throws: (any Error).self) { try ClusterQwenTensorAssistantPolicy(depth: 4, inventorySHA256: bad) }
        }
        for mutate in [
            { (x: inout [String: Any]) in x["depth"] = true },
            { (x: inout [String: Any]) in x["depth"] = 1.5 },
            { (x: inout [String: Any]) in x["extra"] = 1 },
            { (x: inout [String: Any]) in x["schema"] = "unknown" },
        ] {
            var object = policy.object; mutate(&object)
            #expect(throws: (any Error).self) { try ClusterQwenTensorAssistantPolicy.decodeObject(object) }
        }
        for tensors in [stored.filter { !$0.name.hasPrefix("mtp.") }, stored + [stored[0]]] {
            #expect(throws: (any Error).self) {
                try ClusterPlacementArtifact.tensorBatchQuote(configuration: configuration, stored: tensors,
                    request: request, chunkTokens: 16, lanes: 1, assistantDepth: 4, allocationBound: bound)
            }
        }
        for (lanes, depth) in [(0, nil), (3, 4), (1, 0), (2, 5)] as [(Int, Int?)] {
            #expect(throws: (any Error).self) {
                try ClusterPlacementArtifact.tensorBatchQuote(configuration: configuration, stored: stored,
                    request: request, chunkTokens: 16, lanes: lanes, assistantDepth: depth, allocationBound: bound)
            }
        }
        let quote = try ClusterPlacementArtifact.tensorBatchQuote(configuration: configuration, stored: stored,
            request: request, chunkTokens: 16, lanes: 1, assistantDepth: 4, allocationBound: bound)
        let encoded = String(decoding: try JSONEncoder().encode(quote), as: UTF8.self)
        for bad in [encoded.replacingOccurrences(of: "\"depth\":4", with: "\"depth\":4.0"),
                    encoded.replacingOccurrences(of: "\"depth\":4", with: "\"depth\":4,\"depth\":4")] {
            #expect(bad != encoded)
            #expect(throws: (any Error).self) { try ClusterPlacementTensorBatchQuote.decode(Data(bad.utf8)) }
        }
    }

    @Test func explicitCohortQuoteMatchesNativeLoadAtEveryInstalledCapacity() throws {
        let (configuration, stored, family, request) = try inputs()
        let plan = try #require(family.tensorParallel), tensors = try family.requireRegisteredInventory(stored)
        for width in [1, 2, 4, 8] {
            let quote = try ClusterPlacementArtifact.tensorBatchQuote(configuration: configuration, stored: stored,
                request: request, chunkTokens: 16, lanes: width, assistantDepth: 4,
                assistantVerification: .admittedCohort, allocationBound: bound)
            let policy = try #require(quote.assistant?.policy)
            #expect(policy.verification == .admittedCohort)
            let native = try QwenTensorParallelBatchMTPBudget.derive(geometry: family.geometry, plan: plan,
                tensors: tensors, maximumTokens: family.profile.maximumContextTokens,
                promptTokens: family.profile.maximumPromptTokens,
                chunkSize: family.profile.maximumChunkTokens, lanes: width, depth: 4,
                maximumSpeculativeWidth: width, allocationBound: bound).allowance
            #expect(quote.allowance == native)
            let decoded = try ClusterPlacementTensorBatchQuote.decode(JSONEncoder().encode(quote))
            #expect(decoded == quote)
            try decoded.requireAssistant(policy)
            #expect(throws: (any Error).self) {
                try decoded.requireAssistant(.init(depth: policy.depth, inventorySHA256: policy.inventorySHA256))
            }
        }
        #expect(throws: (any Error).self) {
            try ClusterPlacementArtifact.tensorBatchQuote(configuration: configuration, stored: stored,
                request: request, chunkTokens: 16, lanes: 2,
                assistantVerification: .admittedCohort, allocationBound: bound)
        }
    }

    @Test func cohortPolicyAndObservedWidthRoundTripStrictlyWithoutChangingLegacyBytes() throws {
        let old = try ClusterQwenTensorAssistantPolicy(depth: 4, inventorySHA256: String(repeating: "a", count: 64))
        let policy = try ClusterQwenTensorAssistantPolicy(depth: old.depth, inventorySHA256: old.inventorySHA256,
            verification: .admittedCohort)
        #expect(old.object["verification"] == nil && old.verificationArguments.isEmpty)
        #expect(try ClusterQwenTensorAssistantPolicy.decodeObject(old.object) == old)
        #expect(try JSONDecoder().decode(ClusterQwenTensorAssistantPolicy.self, from: JSONEncoder().encode(policy)) == policy)
        #expect(try ClusterQwenTensorAssistantPolicy.decodeObject(policy.object) == policy)
        for capacity in [1, 2, 4, 8] {
            let actual = try ClusterQwenTensorAssistantReady(policy: policy, capacity: capacity,
                maximumSpeculativeWidth: capacity)
            let decoded = try ClusterQwenTensorAssistantReady.decodeObject(actual.object)
            #expect(decoded == actual && decoded.maximumSpeculativeWidth == capacity)
            try ClusterQwenTensorAssistantReady.require(decoded, policy: policy, capacity: capacity)
            #expect(throws: (any Error).self) {
                try ClusterQwenTensorAssistantReady.require(decoded, policy: old, capacity: capacity)
            }
            let legacy = try ClusterQwenTensorAssistantReady(policy: old, capacity: capacity)
            #expect(legacy.maximumSpeculativeWidth == 1 && legacy.object["maximumSpeculativeWidth"] == nil)
            #expect(try ClusterQwenTensorAssistantReady.decodeObject(legacy.object) == legacy)
            var missing = actual.object; missing.removeValue(forKey: "maximumSpeculativeWidth")
            #expect(throws: (any Error).self) { try ClusterQwenTensorAssistantReady.decodeObject(missing) }
            if capacity > 1 {
                #expect(throws: (any Error).self) {
                    try ClusterQwenTensorAssistantReady(policy: policy, capacity: capacity, maximumSpeculativeWidth: 1)
                }
                #expect(throws: (any Error).self) {
                    try ClusterQwenTensorAssistantReady(policy: old, capacity: capacity, maximumSpeculativeWidth: capacity)
                }
            }
        }
        for value in [NSNull(), true, 1, "unknown"] as [Any] {
            var invalid = policy.object; invalid["verification"] = value
            #expect(throws: (any Error).self) { try ClusterQwenTensorAssistantPolicy.decodeObject(invalid) }
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(ClusterQwenTensorAssistantPolicy.self, from: JSONSerialization.data(withJSONObject: invalid))
            }
        }
        let ready = try ClusterQwenTensorAssistantReady(policy: policy, capacity: 4)
        for value in [NSNull(), true, 1.5, 0, 2, 8, "4"] as [Any] {
            var invalid = ready.object; invalid["maximumSpeculativeWidth"] = value
            #expect(throws: (any Error).self) { try ClusterQwenTensorAssistantReady.decodeObject(invalid) }
        }
    }
}
