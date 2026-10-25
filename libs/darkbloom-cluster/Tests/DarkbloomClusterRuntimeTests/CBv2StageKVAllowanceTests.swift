import Foundation
import MLX
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

// The resident request allowance was written for per-request contiguous KV:
// it charges the whole model's F32 keys and values at the request length plus
// three generations of every recurrent layer's state. A paged stage instead
// takes page-rounded pages from one pool that grows in 64 MB segments, at the
// pool's real bytes per token: native-dtype rows, or packed rows plus each
// request's original-precision recent tokens when the launch selects main's
// live KV quantization. This checks, for every registered Qwen 3.5 geometry,
// every possible share of attention layers in one stage, request lengths from
// one token to the 64K limit and every live precision, that the unrounded state
// charge already covers one request's KV plus a whole segment, so the paged
// pool never needs memory the gate did not admit. Arithmetic on registered
// metadata and the SDK's own pricing only; no model is loaded.

@Suite("Paged stage KV stays inside the resident request allowance (registered geometry, no model)")
struct CBv2StageKVAllowanceTests {
    static let lengths = [1, 15, 16, 17, 127, 512, 513, 2048, 4096, 8191, 8192, 20_480, 32_767, 32_768, 32_769, 65_535, 65_536]

    static var geometries: [(QwenRegisteredDenseModel, QwenLongPrefillBudgetGeometry)] {
        get throws {
            try QwenDenseRegisteredSpecification.all.filter { $0.model != .nemotron35Lightning }
                .map { ($0.model, try $0.expectedGeometry()) }
        }
    }

    /// `count` full-attention layers of a registered geometry, as a stage host holds them.
    static func attention(_ geometry: QwenLongPrefillBudgetGeometry, count: Int) -> [CBv2LayerKind] {
        Array(repeating: CBv2LayerKind(attention: .full, headDim: geometry.headDimension, kvHeads: geometry.kvHeads,
            queryHeads: geometry.queryHeads), count: count)
    }

    /// One request's KV on a host of `kinds`: its pages at the pool's real
    /// rate and, for packed storage, its original-precision recent rows as
    /// main's admission prices them (`CBv2StageKVHost.nativeRecentBytesPerRequest`,
    /// which depends on the layers and the chunk, not the request length).
    static func requestBytes(_ kinds: [CBv2LayerKind], dtype: DType, _ selection: PagedKVQuantizationSelection,
                             tokens: Int, chunk: Int, recent: inout [String: Int]) throws -> Int {
        let pages = try CBv2StageKVHost.pagedRequestBytes(kinds: kinds, dtype: dtype, quantization: selection,
            maximumTokens: tokens, maximumChunkTokens: chunk)
        guard selection != .native else { return pages }
        let key = "\(kinds.count)x\(kinds[0].kvHeads)x\(kinds[0].headDim)-\(dtype)-\(selection)-\(chunk)"
        if recent[key] == nil {
            let pool = try PagedKVBackend.segmented(admittedGrantBytes: CBv2StageKVHost.segmentBytes, layerKinds: kinds,
                layerDTypes: Array(repeating: dtype, count: kinds.count), maxPrefillChunk: chunk,
                nominalMaxSequenceLength: tokens, maxBufferLength: 1 << 30, quantization: selection.configuration)
            recent[key] = try CBv2StageKVHost.nativeRecentBytes(pool)
            #expect(recent[key]! > 0, "\(key): a packed pool prices its native rows")
        }
        return pages + recent[key]!
    }

    @Test func everyStageShareFitsTheStateChargeWithASegment() throws {
        let cases = try Self.geometries
        #expect(!cases.isEmpty)
        var recent: [String: Int] = [:]
        for (model, geometry) in cases {
            for tokens in Self.lengths {
                let chunk = min(512, tokens)
                let budget = try QwenLongPrefillTensorBudget.estimate(geometry: geometry,
                    maximumTokens: tokens, chunkSize: chunk)
                for attention in 1...geometry.attentionLayers {
                    for dtype in [DType.bfloat16, .float32] {
                        for selection in PagedKVQuantizationSelection.allCases {
                            let request = try Self.requestBytes(Self.attention(geometry, count: attention), dtype: dtype,
                                selection, tokens: tokens, chunk: chunk, recent: &recent)
                            #expect(request + CBv2StageKVHost.segmentBytes <= budget.conservativeStateAndBoundaryBytes,
                                "\(model.rawValue) tokens=\(tokens) attention=\(attention) dtype=\(dtype) kv=\(selection)")
                        }
                    }
                }
            }
        }
    }

    /// Lanes: the pool's ceiling (lanes x pages + one segment) and every
    /// lane's recent rows are inside the sum of the lanes' state charges,
    /// which batch admission holds live.
    @Test func lanesTogetherStayInsideTheirCharges() throws {
        var recent: [String: Int] = [:]
        for (model, geometry) in try Self.geometries {
            for tokens in [1, 4096, 32_768, 65_536] {
                let chunk = min(512, tokens)
                let state = try QwenLongPrefillTensorBudget.estimate(geometry: geometry,
                    maximumTokens: tokens, chunkSize: chunk).conservativeStateAndBoundaryBytes
                for selection in PagedKVQuantizationSelection.allCases {
                    let request = try Self.requestBytes(Self.attention(geometry, count: geometry.attentionLayers),
                        dtype: .bfloat16, selection, tokens: tokens, chunk: chunk, recent: &recent)
                    for lanes in 1...8 {
                        #expect(lanes * request + CBv2StageKVHost.segmentBytes <= lanes * state,
                            "\(model.rawValue) tokens=\(tokens) lanes=\(lanes) kv=\(selection)")
                    }
                }
            }
        }
    }

    @Test func fullContextDoublesPageCapacityAndRejectsBudgetOverflow() throws {
        let kinds = [CBv2LayerKind(attention: .full, headDim: 256, kvHeads: 4, queryHeads: 16)]
        func pages(_ tokens: Int) throws -> Int {
            try CBv2StageKVHost.pagedRequestBytes(kinds: kinds, dtype: .bfloat16, maximumTokens: tokens,
                maximumChunkTokens: 512)
        }
        let old = try pages(32_768), full = try pages(65_536), lastPage = try pages(65_535)
        #expect(full == 2 * old && lastPage == full)
        for (_, geometry) in try Self.geometries {
            #expect(throws: (any Error).self) {
                _ = try QwenLongPrefillTensorBudget.estimate(geometry: geometry,
                    maximumTokens: 65_537, chunkSize: 512)
            }
        }
    }

    @Test func pagesRoundUpToWholePages() throws {
        let kinds = [CBv2LayerKind(attention: .full, headDim: 256, kvHeads: 4, queryHeads: 16)]
        func pages(_ tokens: Int) throws -> Int {
            try CBv2StageKVHost.pagedRequestBytes(kinds: kinds, dtype: .bfloat16, maximumTokens: tokens,
                maximumChunkTokens: 512)
        }
        let one = try pages(1), page = try pages(16), next = try pages(17)
        #expect(one == 16 * 4 * 256 * 2 * 2 && page == one && next == 2 * one)
        #expect(throws: (any Error).self) { try pages(0) }
    }
}
