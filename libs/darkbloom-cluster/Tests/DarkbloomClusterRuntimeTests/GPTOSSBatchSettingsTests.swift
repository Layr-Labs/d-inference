import DarkbloomClusterProtocol
import Foundation
import Testing
@testable import DarkbloomClusterRuntime

@Suite("GPT-OSS batch admission metadata (CPU)")
struct GPTOSSBatchSettingsTests {
    @Test func effectiveWidthAndLoadAgreementStayModeBound() throws {
        let key = "DARKBLOOM_CLUSTER_BATCH_LANES"
        let single = String(repeating: "a", count: 64)
        #expect(try GPTOSSBatchSettings.fromEnvironment([:], mode: .pipeline).lanes == 1)
        for width in 1...8 {
            for mode in ClusterGenerationMode.allCases {
                let settings = try GPTOSSBatchSettings.fromEnvironment([key: String(width)], mode: mode)
                #expect(settings.lanes == (mode == .pipeline ? width : 1))
                #expect(try (settings.binding(single) == single) == (settings.lanes == 1))
            }
        }
        for invalid in ["0", "9", "invalid", "99999999999999999999999"] {
            #expect(throws: (any Error).self) { try GPTOSSBatchSettings.fromEnvironment([key: invalid], mode: .pipeline) }
        }
        #expect(try GPTOSSBatchSettings(lanes: 2).binding(single) != GPTOSSBatchSettings(lanes: 4).binding(single))
    }

    @Test func rowArithmeticCannotAgreeWithFormerWideProjectionGraph() throws {
        let single = String(repeating: "b", count: 64)
        #expect(try GPTOSSBatchSettings.single.binding(single) == single)
        for width in [2, 4, 8] {
            let former = try canonicalJSONData([single, "gptoss-batch-v1", "lanes=\(width)",
                "bf16-independent-history-v1", "prefill=original-grid-serial-v1"])
            let current = try GPTOSSBatchSettings(lanes: width).binding(single)
            #expect(current != sha256(former))
            #expect(GPTOSSBatchSettings(lanes: width).fields.contains("affine8-m1-singleton-moe-rope-norm-v2"))
        }
    }

    @Test func everyLaneRetainsWholeExistingAllowanceAndAddsBoundedBatchWorkspace() throws {
        let spec = try GPTOSSRegisteredSpecification.specification(runtimeModelID: GPTOSSRegisteredModel.twentyB.rawValue)
        for rank in 0...1 {
            let layers = (0..<12).map { GPTOSSLayerStagePlan.Layer(globalIndex: $0 + rank * 12, localIndex: $0,
                kind: $0 % 2 == 0 ? GPTOSSRegisteredSpecification.slidingAttention : GPTOSSRegisteredSpecification.fullAttention) }
            let single = try GPTOSSRequestStateBudget.estimate(specification: spec, layers: layers,
                rank: rank, maximumTokens: 32768, chunkSize: 512, bound: { $0 })
            var previous = 0
            for width in [2, 4, 8] {
                var allocations: [Int] = []
                let workspace = try GPTOSSBatchWorkspace.estimate(spec: spec, localLayers: layers.count,
                    rank: rank, lanes: width, bound: { allocations.append($0); return $0 + 4096 })
                let ledger = ClusterBatchLaneBook<GPTOSSBatchReservation>()
                let profile = try QwenLayerStageGenerationProfile(identifier: "gptoss-accounting-cpu", vocabularySize: 64,
                    hiddenSize: 64, activationDType: "bfloat16", maximumPromptTokens: 16, maximumChunkTokens: 4,
                    maximumOutputTokens: 4, maximumContextTokens: 20)
                let prefill = try QwenGenerationPrefillAllowance.derive(rank: rank, promptCount: 2,
                    chunkSize: 1, hiddenSize: 64, elementBytes: 2, bound: { $0 })
                for _ in 0..<width {
                    let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                        promptTokenIDs: [1, 2], chunkSize: 1, outputCount: 2, stopTokenIDs: [])
                    try ledger.reserve(request.requestID, .init(request: request,
                        allowance: .init(budget: single), deadline: UInt64.max, prefillAllowance: prefill), lanes: width)
                }
                let entire = try single.reservedBytes + prefill.reservedBytes
                #expect(try ledger.stateBytes() == width * entire)
                #expect(ledger.reservations().allSatisfy {
                    $0.nativeBytes == single.reservedBytes + prefill.extraNativeBytes
                        && $0.hostBytes == prefill.extraHostBytes
                })
                #expect(workspace.native > previous && workspace.host > 0)
                #expect(allocations.count == (rank == 0 ? 5 : 6) && allocations.allSatisfy { $0 > 0 })
                previous = workspace.native
            }
        }
        for invalid in [0, 1, 9] {
            #expect(throws: (any Error).self) {
                try GPTOSSBatchWorkspace.estimate(spec: spec, localLayers: 12, rank: 0, lanes: invalid, bound: { $0 })
            }
        }
        #expect(throws: (any Error).self) {
            try GPTOSSBatchWorkspace.estimate(spec: spec, localLayers: 12, rank: 0, lanes: 2, bound: { $0 - 1 })
        }
        #expect(throws: (any Error).self) {
            try GPTOSSBatchWorkspace.estimate(spec: spec, localLayers: 12, rank: 0, lanes: 2, bound: { _ in Int.max })
        }
    }
}
