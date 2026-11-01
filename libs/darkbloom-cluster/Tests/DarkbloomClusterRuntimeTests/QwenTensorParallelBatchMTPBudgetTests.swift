import DarkbloomClusterPlacement
import Foundation
import Testing
@testable import DarkbloomClusterRuntime

struct QwenTensorParallelBatchMTPBudgetTests {
    private struct Retained: Decodable {
        struct Tensor: Decodable { let name: String; let shape: [Int]; let sourceDType: String; let byteCount: Int }
        struct Profile: Decodable { let configuration: Data; let canonicalTensors: [Tensor] }
        let twentySeven: Profile
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

    @Test func everyLaneRetainsBoundedHistoryWhileOnlyOneDraftWorkspaceIsShared() throws {
        let (family, tensors) = try input(), plan = try #require(family.tensorParallel)
        let rows = QwenTensorParallelMTPPolicy.historyFlushRows
        for context in [65, 1024, 32768] {
            for depth in [1, 4] {
                let chunk = min(context, 512), prompt = context / 2 + 1
                let solo = try QwenTensorParallelMTPBudget.derive(geometry: family.geometry, plan: plan,
                    tensors: tensors, maximumTokens: context, promptTokens: prompt,
                    chunkSize: min(chunk, prompt), depth: depth, allocationBound: bound)
                var shared: Int?
                for lanes in [2, 4, 8] {
                    let value = try QwenTensorParallelBatchMTPBudget.derive(geometry: family.geometry, plan: plan,
                        tensors: tensors, maximumTokens: context, promptTokens: prompt, chunkSize: chunk,
                        lanes: lanes, depth: depth, allocationBound: bound)
                    let target = value.target
                    // A batched lane keeps at most its prompt checkpoint's
                    // rows, or one flush block plus one prompt frame, of chunk
                    // roots (leading complete blocks move into head K/V as
                    // the prompt is observed), then at most one flush bound
                    // of one-token roots. Every held root and the
                    // concatenated first-draft banks stay charged.
                    let piece = min(chunk, prompt), chunks = (prompt + piece - 1) / piece
                    let held = min(prompt, max(min(4096, context), rows + piece + 1))
                    let heldChunks = min(chunks, (held + piece - 1) / piece + 2)
                    let historyFloor = 2 * heldChunks * bound(piece * 5120 * 2) + 2 * min(rows, context) * bound(5120 * 2)
                        + 3 * bound(min(context, held + min(rows, context)) * 5120 * 2)
                    #expect(solo.trustedHistoryBytes >= historyFloor)
                    if prompt > held {
                        // Never the whole prompt's banks any more.
                        #expect(solo.trustedHistoryBytes < 3 * bound(min(context, prompt + rows) * 5120 * 2))
                    }
                    #expect(value.assistantCarryBytes == bound(max(lanes, chunk, depth + 1) * 5120 * 2))
                    #expect(value.assistantPerLaneBytes == solo.assistantPageBytes + solo.assistantGatherBytes
                        + solo.trustedHistoryBytes + solo.prefix.captureBytes + value.assistantCarryBytes)
                    #expect(value.assistantSharedBytes == solo.promptWorkspaceBytes + solo.capturedTargetBytes
                        + solo.targetPageSupplementBytes + solo.windowBytes + solo.prefix.residentBytes)
                    // The shared first draft is one bounded block plus its
                    // proposal row, never the whole trusted history.
                    #expect(value.assistantSharedBytes >= 16 * bound(min(prompt, rows + 1) * 5120 * 4))
                    if let shared { #expect(value.assistantSharedBytes == shared) }
                    shared = value.assistantSharedBytes
                    #expect(value.perLaneStateBytes == target.perLaneStateBytes + value.assistantPerLaneBytes)
                    #expect(value.sharedBytesExcludingCollectives == target.sharedBytesExcludingCollectives + value.assistantSharedBytes)
                    #expect(value.allowance.requestBytesExcludingCollectives ==
                        lanes * value.perLaneStateBytes + value.sharedBytesExcludingCollectives)
                    #expect(value.allowance.requestBytesExcludingCollectives > target.allowance.requestBytesExcludingCollectives)
                    #expect(value.allowance.maximumCollectivePayloadBytes >= (depth + 1) * 248320 * 4)
                    #expect(value.allowance.maximumCollectivePayloadBytes >= target.allowance.maximumCollectivePayloadBytes)
                }
            }
        }
    }

    @Test func assistantSupplementCannotBypassTargetCapacityOrAllocatorRefusal() throws {
        let (family, tensors) = try input(), plan = try #require(family.tensorParallel)
        func quote(lanes: Int = 2, context: Int = 1024, prompt: Int = 512, chunk: Int = 512,
                   depth: Int = 4, allocator: (Int) throws -> Int = { $0 }) throws -> QwenTensorParallelBatchMTPBudget {
            try .derive(geometry: family.geometry, plan: plan, tensors: tensors, maximumTokens: context,
                promptTokens: prompt, chunkSize: chunk, lanes: lanes, depth: depth, allocationBound: allocator)
        }
        // Width one is the request-owned singleton; it is priced by this same ledger.
        for value in [Int.min, -1, 0, 9, Int.max] {
            #expect(throws: (any Error).self) { try quote(lanes: value) }
        }
        for value in [Int.min, -1, 0, Int.max] {
            #expect(throws: (any Error).self) { try quote(context: value) }
            #expect(throws: (any Error).self) { try quote(prompt: value) }
            #expect(throws: (any Error).self) { try quote(chunk: value) }
            #expect(throws: (any Error).self) { try quote(depth: value) }
        }
        #expect(throws: (any Error).self) { try quote(depth: 5) }
        #expect(throws: (any Error).self) { try quote(prompt: 1025) }
        #expect(throws: (any Error).self) { try quote(allocator: { $0 - 1 }) }
        #expect(throws: (any Error).self) { try quote(allocator: { _ in Int.max }) }
    }

    /// A settled survivor keeps its own S window rows of recurrent SSM state
    /// (it replays from its own input and a kept state is copied out of the
    /// cohort), measured by
    /// `QwenTensorParallelBatchMemoryTests.cohortSurvivorKeepsOnlyItsOwnRows`;
    /// every other retained term (convolution-sized inputs that may view the
    /// cohort, hidden, logits, scalars) stays priced at the whole B*S window,
    /// and the in-flight cohort's whole B*S rectangle is priced once, shared.
    @Test func eachSurvivorKeepsItsOwnRowsAndTheNextWindowIsPricedSeparately() throws {
        let (family, tensors) = try input(), plan = try #require(family.tensorParallel)
        for lanes in [2, 4, 8] {
            for depth in [1, 4] {
                // A one-token chunk makes the B*S window the collective and
                // carry bound, rather than hiding it behind a larger prompt.
                let context = 256, chunk = 1, rows = lanes * (depth + 1)
                let value = try QwenTensorParallelBatchMTPBudget.derive(geometry: family.geometry, plan: plan,
                    tensors: tensors, maximumTokens: context, promptTokens: context, chunkSize: chunk, lanes: lanes,
                    depth: depth, maximumSpeculativeWidth: lanes, allocationBound: bound)
                let singleton = try QwenTensorParallelBatchMTPBudget.derive(geometry: family.geometry, plan: plan,
                    tensors: tensors, maximumTokens: context, promptTokens: context, chunkSize: chunk, lanes: lanes,
                    depth: depth, allocationBound: bound)
                let full = try QwenTensorParallelMTPBudget.derive(geometry: family.geometry, plan: plan,
                    tensors: tensors, maximumTokens: context, promptTokens: context,
                    chunkSize: 1, depth: depth, allocationBound: bound)
                let state = try QwenLongPrefillTensorBudget.estimate(geometry: family.geometry,
                    maximumTokens: context, chunkSize: chunk)
                func backing(state stateRows: Int) -> Int {
                    48 * (bound(rows * state.convolutionBytesPerLayer) + bound(stateRows * state.ssmBytesPerLayer))
                        + 8 * bound(rows * 5120 * 4) + 4 * bound(rows * 248320 * 4) + 8 * bound(rows * 4)
                }
                let cohort = backing(state: rows), own = backing(state: depth + 1)
                #expect(value.maximumSpeculativeWidth == lanes && value.depth == depth)
                #expect(value.assistantCarryBytes == bound(rows * 5120 * 2))
                #expect(value.retainedCohortBytesPerLane == own && own < cohort)
                #expect(value.assistantPerLaneBytes == full.assistantPageBytes + full.assistantGatherBytes
                    + full.trustedHistoryBytes + full.prefix.captureBytes + value.assistantCarryBytes + own)
                #expect(value.cohortTransientBytes > 0)
                #expect(value.assistantSharedBytes == full.promptWorkspaceBytes + cohort + value.cohortTransientBytes
                    + lanes * full.targetPageSupplementBytes + full.prefix.residentBytes)
                #expect(value.allowance.requestBytesExcludingCollectives == lanes * value.perLaneStateBytes
                    + value.sharedBytesExcludingCollectives)
                #expect(value.allowance.maximumCollectivePayloadBytes >= rows * 248320 * 4)
                #expect(value.allowance.maximumCollectivePayloadBytes >= rows * plan.maximumPartialBytesPerToken)
                #expect(value.allowance.requestBytesExcludingCollectives > singleton.allowance.requestBytesExcludingCollectives)
                #expect(singleton.maximumSpeculativeWidth == 1 && singleton.retainedCohortBytesPerLane == 0)
                #expect(singleton.cohortTransientBytes == 0)
            }
        }
    }

    @Test func cohortCannotPartiallyPriceAnAdmittedOwnerOrIgnoreAllocationFailure() throws {
        let (family, tensors) = try input(), plan = try #require(family.tensorParallel)
        func quote(width: Int, allocator: (Int) throws -> Int = { $0 }) throws -> QwenTensorParallelBatchMTPBudget {
            try .derive(geometry: family.geometry, plan: plan, tensors: tensors,
                maximumTokens: 256, promptTokens: 256, chunkSize: 1, lanes: 8, depth: 4,
                maximumSpeculativeWidth: width, allocationBound: allocator)
        }
        for width in [Int.min, -1, 0, 2, 4, 7, 9, Int.max] {
            #expect(throws: (any Error).self) { try quote(width: width) }
        }
        #expect(throws: (any Error).self) { try quote(width: 8, allocator: { $0 - 1 }) }
        #expect(throws: (any Error).self) { try quote(width: 8, allocator: { _ in Int.max }) }
        // Refuse a specific new cohort-root allocation after the unchanged
        // scalar and singleton assistant ledgers have already been priced.
        let retainedLogits = 8 * 5 * 248320 * 4
        #expect(throws: (any Error).self) {
            try quote(width: 8, allocator: { bytes in
                if bytes == retainedLogits { throw ProbeError("Injected cohort allocation refusal") }
                return bytes
            })
        }
    }
}
