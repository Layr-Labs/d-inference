import Foundation
import Testing
@testable import DarkbloomClusterRuntime

// The resident request allowance was written for per-request contiguous KV:
// it charges the whole model's F32 keys and values at the request length plus
// three generations of every recurrent layer's state. A paged stage instead
// takes page-rounded native-dtype pages from one pool that grows in 64 MB
// segments. This checks, for every registered Qwen 3.5 geometry, every
// possible share of attention layers in one stage and request lengths from one
// token to the 64K limit, that the unrounded state charge already covers one
// request's pages plus a whole segment, so the paged pool never needs memory
// the gate did not admit. Arithmetic on registered metadata only.

@Suite("Paged stage KV stays inside the resident request allowance (registered geometry, no model)")
struct CBv2StageKVAllowanceTests {
    static let lengths = [1, 15, 16, 17, 127, 512, 513, 2048, 4096, 8191, 8192, 20_480, 32_767, 32_768, 32_769, 65_535, 65_536]

    static var geometries: [(QwenRegisteredDenseModel, QwenLongPrefillBudgetGeometry)] {
        get throws {
            try QwenDenseRegisteredSpecification.all.filter { $0.model != .nemotron35Lightning }
                .map { ($0.model, try $0.expectedGeometry()) }
        }
    }

    @Test func everyStageShareFitsTheStateChargeWithASegment() throws {
        let cases = try Self.geometries
        #expect(!cases.isEmpty)
        for (model, geometry) in cases {
            for tokens in Self.lengths {
                let budget = try QwenLongPrefillTensorBudget.estimate(geometry: geometry,
                    maximumTokens: tokens, chunkSize: min(512, tokens))
                for attention in 1...geometry.attentionLayers {
                    for dtypeSize in [2, 4] {
                        let pages = try CBv2StageKVHost.pageRoundedRequestBytes(
                            kvShapes: Array(repeating: (geometry.kvHeads, geometry.headDimension), count: attention),
                            maximumTokens: tokens, dtypeSize: dtypeSize)
                        #expect(pages + CBv2StageKVHost.segmentBytes <= budget.conservativeStateAndBoundaryBytes,
                            "\(model.rawValue) tokens=\(tokens) attention=\(attention) dtype=\(dtypeSize)")
                    }
                }
            }
        }
    }

    /// Lanes: the pool's ceiling (lanes x pages + one segment) is inside the
    /// sum of the lanes' state charges, which batch admission holds live.
    @Test func lanesTogetherStayInsideTheirCharges() throws {
        for (model, geometry) in try Self.geometries {
            for tokens in [1, 4096, 32_768, 65_536] {
                let state = try QwenLongPrefillTensorBudget.estimate(geometry: geometry,
                    maximumTokens: tokens, chunkSize: min(512, tokens)).conservativeStateAndBoundaryBytes
                let pages = try CBv2StageKVHost.pageRoundedRequestBytes(
                    kvShapes: Array(repeating: (geometry.kvHeads, geometry.headDimension), count: geometry.attentionLayers),
                    maximumTokens: tokens, dtypeSize: 2)
                for lanes in 1...8 {
                    #expect(lanes * pages + CBv2StageKVHost.segmentBytes <= lanes * state,
                        "\(model.rawValue) tokens=\(tokens) lanes=\(lanes)")
                }
            }
        }
    }

    @Test func fullContextDoublesPageCapacityAndRejectsBudgetOverflow() throws {
        let old = try CBv2StageKVHost.pageRoundedRequestBytes(kvShapes: [(4, 256)],
            maximumTokens: 32_768, dtypeSize: 2)
        let full = try CBv2StageKVHost.pageRoundedRequestBytes(kvShapes: [(4, 256)],
            maximumTokens: 65_536, dtypeSize: 2)
        let lastPage = try CBv2StageKVHost.pageRoundedRequestBytes(kvShapes: [(4, 256)],
            maximumTokens: 65_535, dtypeSize: 2)
        #expect(full == 2 * old && lastPage == full)
        for (_, geometry) in try Self.geometries {
            #expect(throws: (any Error).self) {
                _ = try QwenLongPrefillTensorBudget.estimate(geometry: geometry,
                    maximumTokens: 65_537, chunkSize: 512)
            }
        }
    }

    @Test func pagesRoundUpToWholePages() throws {
        let one = try CBv2StageKVHost.pageRoundedRequestBytes(kvShapes: [(4, 256)], maximumTokens: 1, dtypeSize: 2)
        let page = try CBv2StageKVHost.pageRoundedRequestBytes(kvShapes: [(4, 256)], maximumTokens: 16, dtypeSize: 2)
        let next = try CBv2StageKVHost.pageRoundedRequestBytes(kvShapes: [(4, 256)], maximumTokens: 17, dtypeSize: 2)
        #expect(one == 16 * 4 * 256 * 2 * 2 && page == one && next == 2 * one)
        #expect(throws: (any Error).self) {
            try CBv2StageKVHost.pageRoundedRequestBytes(kvShapes: [(4, 256)], maximumTokens: 0, dtypeSize: 2)
        }
    }
}
