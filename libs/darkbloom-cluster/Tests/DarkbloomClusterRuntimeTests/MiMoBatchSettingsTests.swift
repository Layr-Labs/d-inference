import DarkbloomClusterProtocol
import Foundation
import Testing
@testable import DarkbloomClusterRuntime

@Suite("MiMo independent batch admission (CPU)")
struct MiMoBatchSettingsTests {
    @Test func effectiveWidthBindsOnlyPlainTextPipeline() throws {
        let key = "DARKBLOOM_CLUSTER_BATCH_LANES", base = String(repeating: "a", count: 64)
        #expect(try MiMoBatchSettings.fromEnvironment([:], mode: .pipeline).lanes == 1)
        for width in 1...8 {
            for mode in ClusterGenerationMode.allCases {
                for images in [false, true] {
                    let settings = try MiMoBatchSettings.fromEnvironment([key: String(width)], mode: mode, images: images)
                    #expect(settings.lanes == (mode == .pipeline && !images ? width : 1))
                    #expect(settings.usesPagedHistory == ([ClusterGenerationMode.pipeline, .pipelineCompactDecode, .pipelineMTP, .phaseSplit].contains(mode) && !images))
                    #expect(try (settings.binding(base) == base) == !settings.usesPagedHistory)
                }
            }
        }
        for invalid in ["0", "9", "invalid", "99999999999999999999999"] {
            #expect(throws: (any Error).self) { try MiMoBatchSettings.fromEnvironment([key: invalid], mode: .pipeline) }
        }
        #expect(try MiMoBatchSettings(lanes: 2, usesPagedHistory: true).binding(base) != MiMoBatchSettings(lanes: 4, usesPagedHistory: true).binding(base))
    }

    @Test func tokenHistoryKeepsBothCopiesAndChecksArithmeticBounds() throws {
        #expect(try MiMoBatchMemory.historyBytes(maximumTokens: 32_768) == 524_288)
        for invalid in [0, -1, Int.max] {
            #expect(throws: (any Error).self) { try MiMoBatchMemory.historyBytes(maximumTokens: invalid) }
        }
    }

    @Test func pagesChargeUnequalKeyValueWidthsAndEachAllocatorRounding() throws {
        let spec = try MiMoRegisteredSpecification.specification(.v26FlashMOPD)
        // Exact pinned geometry: full layer 0 has 4 KV heads, sliding layer 1
        // has 8, K=192, V=128, BF16. 65 rows cross the 64-token page boundary.
        #expect(try MiMoPagedKVAllowance.pages(spec: spec, layers: 0..<1, maximumTokens: 65,
            chunkSize: 1, bound: { $0 }) == 988_160)
        #expect(try MiMoPagedKVAllowance.pages(spec: spec, layers: 1..<2, maximumTokens: 200,
            chunkSize: 1, bound: { $0 }) == 3_287_040)
        var calls: [Int] = []
        let rounded = try MiMoPagedKVAllowance.pages(spec: spec, layers: 0..<2, maximumTokens: 65,
            chunkSize: 1, bound: { calls.append($0); return $0 + 4096 })
        // Two page arrays per layer, two copies of each page, plus two
        // gathered/repacked buffers. Bounds are applied before multiplication.
        #expect(calls.count == 8)
        #expect(rounded == 2_964_480 + 98_304)
        for invalid in [0, 1_048_577, Int.max] {
            #expect(throws: (any Error).self) {
                try MiMoPagedKVAllowance.pages(spec: spec, layers: 0..<1, maximumTokens: invalid, chunkSize: 1, bound: { $0 })
            }
        }
        #expect(throws: (any Error).self) {
            try MiMoPagedKVAllowance.pages(spec: spec, layers: 0..<1, maximumTokens: 65, chunkSize: 1, bound: { $0 - 1 })
        }
        #expect(throws: (any Error).self) {
            try MiMoPagedKVAllowance.pages(spec: spec, layers: 0..<1, maximumTokens: 65, chunkSize: 1, bound: { _ in Int.max })
        }
    }

    @Test func everyLaneRetainsFullStatePagesAndHostHistoryUntilRetirement() throws {
        let spec = try MiMoRegisteredSpecification.specification(.v26FlashMOPD)
        let profile = try QwenLayerStageGenerationProfile(identifier: "mimo-batch-accounting-cpu", vocabularySize: 64,
            hiddenSize: 64, activationDType: "bfloat16", maximumPromptTokens: 16, maximumChunkTokens: 4,
            maximumOutputTokens: 4, maximumContextTokens: 20)
        for rank in 0...1 {
            let layers = rank == 0 ? 0..<24 : 24..<48
            let budget = try MiMoRequestStateBudget.estimate(specification: spec, layers: layers,
                rank: rank, maximumTokens: 20, chunkSize: 4, bound: { $0 })
            let pages = try MiMoPagedKVAllowance.pages(spec: spec, layers: layers, maximumTokens: 20, chunkSize: 4, bound: { $0 })
            var lastWorkspace = 0
            for width in [2, 4, 8] {
                let book = ClusterBatchLaneBook<MiMoBatchReservation>()
                let workspace = try MiMoBatchMemory.workspace(spec: spec, localLayers: 24, rank: rank, lanes: width, bound: { $0 + 4096 })
                #expect(workspace.native > lastWorkspace && workspace.host > 0)
                lastWorkspace = workspace.native
                var expected = 0
                for _ in 0..<width {
                    let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                        promptTokenIDs: [1, 2], chunkSize: 1, outputCount: 2, stopTokenIDs: [])
                    let lane = try MiMoBatchReservation(request: request, allowance: .init(budget: budget, pagedBytes: pages),
                        deadline: UInt64.max, pageBytes: pages)
                    #expect(lane.nativeBytes == budget.reservedBytes + pages)
                    #expect(lane.hostBytes == request.maximumTokens * MemoryLayout<Int>.stride * 2)
                    expected += lane.laneStateBytes
                    try book.reserve(request.requestID, lane, lanes: width)
                    try book.start(request.requestID); book.cancel(request.requestID)
                }
                #expect(try book.stateBytes() == expected)
                #expect(book.count == width)
                for lane in book.reservations() { book.finish(lane.request.requestID) }
                #expect(book.isEmpty)
            }
        }
        for invalid in [0, 1, 9, Int.max] {
            #expect(throws: (any Error).self) {
                try MiMoBatchMemory.workspace(spec: spec, localLayers: 24, rank: 0, lanes: invalid, bound: { $0 })
            }
        }
    }
}
