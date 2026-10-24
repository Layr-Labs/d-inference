import DarkbloomClusterPlacement
import Foundation
import MLX
import Testing
@testable import DarkbloomClusterRuntime

struct QwenTensorParallelMTPBudgetTests {
    private struct Retained: Decodable {
        struct Tensor: Decodable { let name: String; let shape: [Int]; let sourceDType: String; let byteCount: Int }
        struct Profile: Decodable { let configuration: Data; let canonicalTensors: [Tensor] }
        let twentySeven: Profile
    }
    private struct Assistant: Decodable {
        struct Tensor: Decodable { let name: String; let shape: [Int]; let dtype: String; let byteCount: Int }
        let configurationSHA256: String
        let tensors: [Tensor]
    }
    private func input() throws -> (QwenDensePlacementFamily, [QwenDenseCanonicalTensor]) {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("StageMetadataChecks/Inputs/qwen-retained-inputs.json")
        let input = try JSONDecoder().decode(Retained.self, from: Data(contentsOf: url)).twentySeven
        let family = try QwenDensePlacementFamily(configuration: input.configuration)
        let tensors = try family.requireRegisteredInventory(input.canonicalTensors.map {
            ClusterPlacementStoredTensor(name: $0.name, byteCount: $0.byteCount, dtype: $0.sourceDType, shape: $0.shape)
        })
        return (family, tensors)
    }
    private func bound(_ bytes: Int) -> Int { ((bytes + 16_383) / 16_384) * 16_384 }

    @Test func exactArtifactAssistantHeaderAndMalformedSourceRefusal() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Inputs/qwen27-tp-mtp-inventory.json")
        let input = try JSONDecoder().decode(Assistant.self, from: Data(contentsOf: url))
        #expect(input.configurationSHA256 == "4691da94a1b4ef415aad112ec46abebd33f8a41ad07380e486c0526eb945c1ff")
        #expect(input.tensors.count == 31 && input.tensors.reduce(0) { $0 + $1.byteCount } == 238_930_944)
        let tensors = Dictionary(uniqueKeysWithValues: input.tensors.map {
            ($0.name, (shape: $0.shape, dtype: $0.dtype == "U32" ? DType.uint32 : .bfloat16, byteCount: $0.byteCount))
        })
        try QwenTensorParallelMTPInventory.validateStoredTensors(tensors)
        for name in tensors.keys {
            var missing = tensors; missing.removeValue(forKey: name)
            #expect(throws: ProbeError.self) { try QwenTensorParallelMTPInventory.validateStoredTensors(missing) }
            var changed = tensors; changed[name]!.byteCount += 1
            #expect(throws: ProbeError.self) { try QwenTensorParallelMTPInventory.validateStoredTensors(changed) }
            changed = tensors; changed[name]!.dtype = .float32
            #expect(throws: ProbeError.self) { try QwenTensorParallelMTPInventory.validateStoredTensors(changed) }
            changed = tensors; changed[name]!.shape[0] += 1
            #expect(throws: ProbeError.self) { try QwenTensorParallelMTPInventory.validateStoredTensors(changed) }
        }
        var extra = tensors; extra["mtp.unowned.weight"] = ([1], .bfloat16, 2)
        #expect(throws: ProbeError.self) { try QwenTensorParallelMTPInventory.validateStoredTensors(extra) }
    }

    @Test func fullPromptHistoryPagesCapturedWindowsAndCollectivesStayCharged() throws {
        let (family, tensors) = try input(), plan = try #require(family.tensorParallel)
        for context in [65, 1024, 32768] {
            for depth in [1, 4] {
                let chunk = min(512, context)
                let quote = try QwenTensorParallelMTPBudget.derive(geometry: family.geometry, plan: plan,
                    tensors: tensors, maximumTokens: context, promptTokens: context - 1,
                    chunkSize: chunk, depth: depth, allocationBound: bound)
                let base = try QwenTensorParallelRequestBudget.derive(geometry: family.geometry, plan: plan,
                    tensors: tensors, maximumTokens: context, chunkSize: chunk, allocationBound: bound)
                let extras = quote.assistantPageBytes + quote.assistantGatherBytes + quote.trustedHistoryBytes
                    + quote.promptWorkspaceBytes + quote.capturedTargetBytes + quote.targetPageSupplementBytes + quote.windowBytes
                    + quote.prefix.captureBytes + quote.prefix.residentBytes
                #expect(quote.allowance.requestBytesExcludingCollectives == base.allowance.requestBytesExcludingCollectives + extras)
                let prefixCount = min(context, 4096)
                let assistantPrefix = bound((prefixCount - 1) * 5120 * 2)
                    + bound((prefixCount - 1) * 4) + bound(5120 * 2)
                #expect(quote.prefix.maximumTokens == prefixCount)
                #expect(quote.prefix.assistantCaptureBytes == assistantPrefix)
                #expect(quote.prefix.captureBytes == quote.prefix.targetCaptureBytes + assistantPrefix)
                #expect(quote.prefix.residentBytes == 2 * quote.prefix.captureBytes)
                #expect(quote.assistantPageBytes == 2 * ((context + 63) / 64) * bound(64 * 4 * 256 * 2))
                // Bounded flushes: one block plus the proposal row, and at most
                // one bound of ordinary one-token roots beside the prompt.
                let rows = QwenTensorParallelMTPPolicy.historyFlushRows
                #expect(quote.promptWorkspaceBytes >= 16 * bound(min(context - 1, rows + 1) * 5120 * 4))
                #expect(quote.trustedHistoryBytes >= 3 * bound(min(context, context - 1 + rows) * 5120 * 2)
                    + 2 * min(rows, context) * bound(5120 * 2))
                // Without them the first draft keeps its whole rectangle.
                let whole = try QwenTensorParallelMTPBudget.derive(geometry: family.geometry, plan: plan,
                    tensors: tensors, maximumTokens: context, promptTokens: context - 1,
                    chunkSize: chunk, depth: depth, flushRows: nil, allocationBound: bound)
                #expect(whole.promptWorkspaceBytes >= 16 * bound((context - 1) * 5120 * 4))
                #expect(whole.trustedHistoryBytes >= 3 * bound((context - 1) * 5120 * 2))
                #expect(quote.promptWorkspaceBytes <= whole.promptWorkspaceBytes)
                // A verify window adds tail-page replacements and segment
                // slack only; it never reserves a second history.
                #expect(quote.targetPageSupplementBytes == 4 * 16 * bound(64 * 4 * 256 * 2)
                    + 2 * CBv2StageKVHost.segmentBytes)
                #expect(quote.allowance.maximumCollectivePayloadBytes >= (depth + 1) * 248320 * 4)
                #expect(quote.allowance.maximumCollectiveFrameBytes == quote.allowance.maximumCollectivePayloadBytes + QwenTensorParallelSealCodec.frameOverhead)
                #expect(quote.allowance.reservedBytes > base.allowance.reservedBytes)
            }
        }
    }

    @Test func invalidDemandDepthAndAllocatorRefuseBeforeArithmetic() throws {
        let (family, tensors) = try input(), plan = try #require(family.tensorParallel)
        func derive(context: Int = 512, prompt: Int = 128, chunk: Int = 64, depth: Int = 4, flush: Int? = 64,
                    allocator: (Int) throws -> Int = { $0 }) throws {
            _ = try QwenTensorParallelMTPBudget.derive(geometry: family.geometry, plan: plan, tensors: tensors,
                maximumTokens: context, promptTokens: prompt, chunkSize: chunk, depth: depth, flushRows: flush,
                allocationBound: allocator)
        }
        for bad in [Int.min, -1, 0, Int.max] {
            #expect(throws: (any Error).self) { try derive(context: bad) }
            #expect(throws: (any Error).self) { try derive(prompt: bad) }
            #expect(throws: (any Error).self) { try derive(chunk: bad) }
            #expect(throws: (any Error).self) { try derive(depth: bad) }
        }
        for bad in [Int.min, -1, 0] {
            #expect(throws: (any Error).self) { try derive(flush: bad) }
        }
        // A bound beyond the history simply keeps the whole rectangle.
        for rows in [nil, 513, Int.max] { try derive(flush: rows) }
        #expect(throws: (any Error).self) { try derive(prompt: 513) }
        #expect(throws: (any Error).self) { try derive(depth: 5) }
        #expect(throws: (any Error).self) { try derive(allocator: { $0 - 1 }) }
        #expect(throws: (any Error).self) { try derive(allocator: { _ in Int.max }) }
    }
}
